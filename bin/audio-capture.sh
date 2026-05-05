#!/usr/bin/env bash
set -euo pipefail

CAPTURE_DIR="${CAPTURE_DIR:-$HOME/capture}"
INCOMING="$CAPTURE_DIR/audio/incoming"
DWR_REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIST_DEVICES="$DWR_REPO/bin/list-audio-devices.sh"

# Read a flat TOML value: `key = "..."` or `key = '...'` or `key = bareword`.
toml_read() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    awk -v k="$key" '
        $0 ~ "^[[:space:]]*"k"[[:space:]]*=" {
            sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            if ($0 ~ /^".*"$/) { print substr($0, 2, length($0)-2) }
            else if ($0 ~ /^'\''.*'\''$/) { print substr($0, 2, length($0)-2) }
            else { print $0 }
            exit
        }
    ' "$file"
}

DWR_CONFIG="${DWR_CONFIG:-$HOME/.config/dwr/config.toml}"
: "${AUDIO_INPUT_DEVICE:=$(toml_read "$DWR_CONFIG" audio_input_device)}"
: "${SILENCE_THRESHOLD:=$(toml_read "$DWR_CONFIG" silence_threshold)}"
: "${MAX_SEGMENT_SEC:=$(toml_read "$DWR_CONFIG" max_segment_sec)}"

SILENCE_THRESHOLD="${SILENCE_THRESHOLD:--40dB}"
# 60s upper bound: caps any single recording, and bounds how long a stale
# ffmpeg keeps running after a mid-recording USB unplug before the next
# iteration gets to retry the device.
MAX_SEGMENT_SEC="${MAX_SEGMENT_SEC:-60}"

mkdir -p "$INCOMING"

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "audio-capture: 'ffmpeg' not found in PATH (brew install ffmpeg)" >&2
    exit 1
fi

# silenceremove: skip leading silence so the saved file starts at speech.
# silencedetect: emits "silence_start" to stderr after 2s of trailing silence;
# bash reads that and kills ffmpeg so it actually exits (silenceremove's own
# stop_periods does not unwind the avfoundation input, hence this approach).
filter_chain="silenceremove=start_periods=1:start_silence=0.1:start_threshold=${SILENCE_THRESHOLD},silencedetect=n=${SILENCE_THRESHOLD}:d=2"

# Cache the system default device name briefly so we don't spawn Swift on every
# fallback iteration.
cached_default=""
cached_default_at=0
default_input_device() {
    local now
    now="$(date +%s)"
    if [ -n "$cached_default" ] && [ $((now - cached_default_at)) -lt 30 ]; then
        printf '%s' "$cached_default"
        return 0
    fi
    if [ -x "$LIST_DEVICES" ]; then
        cached_default="$("$LIST_DEVICES" 2>/dev/null | awk '/^\* / { sub(/^\* /, ""); sub(/ \([0-9]+ch\)$/, ""); print; exit }')"
        cached_default_at="$now"
        printf '%s' "$cached_default"
    fi
}

ffmpeg_pid=""
ffmpeg_stderr=""

log_dbg() {
    [ "${DWR_DEBUG:-0}" = "1" ] || return 0
    printf '[%s] audio-capture: %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

# True when the process exists AND isn't a zombie. `kill -0` returns success
# for zombies too, so polling on it alone never exits when ffmpeg ends on its
# own — that bug stranded the script on a stale Yeti handle.
ffmpeg_running() {
    local pid="$1" state
    state="$(ps -p "$pid" -o state= 2>/dev/null | tr -d '[:space:]')"
    [ -n "$state" ] && [ "${state:0:1}" != "Z" ]
}

cleanup() {
    if [ -n "$ffmpeg_pid" ]; then
        kill "$ffmpeg_pid" 2>/dev/null || true
        # Give ffmpeg a moment to flush, then SIGKILL anything stuck.
        for _ in 1 2 3 4 5; do
            ffmpeg_running "$ffmpeg_pid" || break
            sleep 0.1 || true
        done
        kill -KILL "$ffmpeg_pid" 2>/dev/null || true
    fi
    [ -n "$ffmpeg_stderr" ] && rm -f "$ffmpeg_stderr"
}
trap cleanup EXIT
# Without an explicit exit, the signal trap returns control to the loop and
# the script keeps running. Force termination on Ctrl+C / SIGTERM.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Returns 0 if ffmpeg opened the device (with or without recorded speech),
# 1 if it exited early without output (= device unavailable).
ffmpeg_record() {
    local device="$1" tmp="$2"
    local start elapsed killed_by_us=false

    # Pre-check: avfoundation does NOT surface a mid-recording USB unplug,
    # so a stale ffmpeg keeps returning silence for the full -t window and
    # masks the disconnect. Bail out before launching ffmpeg if the device
    # isn't in the live device list. (When LIST_DEVICES isn't usable we just
    # fall through to ffmpeg as before.)
    if [ -x "$LIST_DEVICES" ] && ! "$LIST_DEVICES" 2>/dev/null | grep -qF -- "$device"; then
        log_dbg "pre-check FAIL: '$device' not in device list"
        return 1
    fi
    log_dbg "pre-check OK: starting ffmpeg with '$device'"

    ffmpeg_stderr="$(mktemp -t dw-ffstderr)"
    start="$(date +%s)"

    # `-t` BEFORE `-i` limits input duration. Putting it after `-i` would limit
    # output duration, which silenceremove can hold at zero indefinitely while
    # avfoundation keeps reading silence — making ffmpeg never exit.
    ffmpeg -hide_banner -loglevel info \
        -f avfoundation -t "$MAX_SEGMENT_SEC" -i ":$device" \
        -ac 1 -ar 16000 \
        -af "$filter_chain" \
        -y "$tmp" 2>"$ffmpeg_stderr" &
    ffmpeg_pid=$!

    # Watch stderr for silence_start (= 2s of trailing silence). On detection,
    # SIGINT to ffmpeg so it finalizes the output file and exits. Otherwise
    # exit when ffmpeg finishes on its own (input -t hit or device error).
    # Also poll the device list periodically: avfoundation does NOT surface
    # mid-recording USB unplug (it just returns silence forever), so without
    # this check ffmpeg never terminates and the fallback path is unreachable.
    local last_dev_check
    last_dev_check="$(date +%s)"
    while ffmpeg_running "$ffmpeg_pid"; do
        if grep -q "silence_start" "$ffmpeg_stderr" 2>/dev/null; then
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            killed_by_us=true
            break
        fi
        if [ $(( $(date +%s) - last_dev_check )) -ge 5 ]; then
            if [ -x "$LIST_DEVICES" ] && ! "$LIST_DEVICES" 2>/dev/null | grep -qF -- "$device"; then
                log_dbg "mid-recording check: '$device' GONE, killing ffmpeg"
                # ffmpeg can be wedged in avfoundation I/O after a USB unplug;
                # try graceful SIGINT first then escalate to SIGKILL so the
                # subsequent wait doesn't hang forever.
                kill -INT "$ffmpeg_pid" 2>/dev/null || true
                for _ in 1 2 3 4 5; do
                    ffmpeg_running "$ffmpeg_pid" || break
                    sleep 0.2
                done
                if ffmpeg_running "$ffmpeg_pid"; then
                    log_dbg "ffmpeg didn't respond to SIGINT; sending SIGKILL"
                    kill -KILL "$ffmpeg_pid" 2>/dev/null || true
                fi
                break
            fi
            log_dbg "mid-recording check: '$device' still present"
            last_dev_check="$(date +%s)"
        fi
        sleep 0.2
    done

    wait "$ffmpeg_pid" 2>/dev/null || true
    elapsed=$(( $(date +%s) - start ))
    log_dbg "ffmpeg exited (device='$device', elapsed=${elapsed}s, killed_by_us=$killed_by_us, tmp_size=$(stat -f %z "$tmp" 2>/dev/null || echo 0))"

    # Failure pattern: we did NOT send SIGINT, output is empty, and ffmpeg
    # didn't run anywhere near the full -t window (which would mean "no speech
    # in this segment", not a device error).
    if [ "$killed_by_us" = false ] && [ ! -s "$tmp" ] && [ "$elapsed" -lt $((MAX_SEGMENT_SEC - 2)) ]; then
        if [ -s "$ffmpeg_stderr" ]; then
            echo "audio-capture: ffmpeg exited early for '$device' (elapsed=${elapsed}s):" >&2
            tail -3 "$ffmpeg_stderr" | sed 's/^/  /' >&2
        fi
        rm -f "$ffmpeg_stderr"
        ffmpeg_pid=""
        ffmpeg_stderr=""
        return 1
    fi
    rm -f "$ffmpeg_stderr"
    ffmpeg_pid=""
    ffmpeg_stderr=""
    return 0
}

# Track which input we're currently using so we only log on transitions.
current_state=""

record_to() {
    local tmp="$1"
    log_dbg "record_to: state='$current_state' configured='${AUDIO_INPUT_DEVICE:-}'"

    if [ -n "${AUDIO_INPUT_DEVICE:-}" ]; then
        if ffmpeg_record "$AUDIO_INPUT_DEVICE" "$tmp"; then
            log_dbg "configured device OK -> state=configured"
            if [ "$current_state" != "configured" ]; then
                echo "audio-capture: using configured device '$AUDIO_INPUT_DEVICE'" >&2
                current_state="configured"
            fi
            return 0
        fi
        log_dbg "configured device FAILED -> falling back"
        # Configured device just failed: drop the cached "system default" so
        # we re-query (the OS likely just switched its default away from the
        # disconnected device).
        cached_default=""
        cached_default_at=0
    fi

    local fallback
    fallback="$(default_input_device)"
    log_dbg "fallback resolved: '$fallback'"
    if [ -z "$fallback" ]; then
        if [ "$current_state" != "no-device" ]; then
            echo "audio-capture: no input device available" >&2
            current_state="no-device"
        fi
        return 1
    fi

    if [ -n "${AUDIO_INPUT_DEVICE:-}" ]; then
        if [ "$current_state" != "fallback:$fallback" ]; then
            echo "audio-capture: '$AUDIO_INPUT_DEVICE' unavailable; falling back to '$fallback'" >&2
            current_state="fallback:$fallback"
        fi
    elif [ "$current_state" != "default:$fallback" ]; then
        echo "audio-capture: using system default '$fallback'" >&2
        current_state="default:$fallback"
    fi

    ffmpeg_record "$fallback" "$tmp" || true
}

while true; do
    ts="$(date +%Y%m%d-%H%M%S)"
    tmp="$(mktemp -t dw-audio).wav"

    record_to "$tmp" || true

    if [ -s "$tmp" ]; then
        mv "$tmp" "$INCOMING/${ts}.wav"
    else
        rm -f "$tmp"
    fi

    sleep 0.1
done
