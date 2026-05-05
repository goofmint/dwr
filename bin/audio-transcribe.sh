#!/usr/bin/env bash
set -euo pipefail

CAPTURE_DIR="${CAPTURE_DIR:-$HOME/capture}"
INCOMING="$CAPTURE_DIR/audio/incoming"
PROCESSED="$CAPTURE_DIR/audio/processed"
TEXT_DIR="$CAPTURE_DIR/text/audio"

DW_TRANSCRIBE_CLI="${DW_TRANSCRIBE_CLI:-$HOME/.local/bin/dw-transcribe-cli}"

mkdir -p "$INCOMING" "$PROCESSED" "$TEXT_DIR"

if [ ! -x "$DW_TRANSCRIBE_CLI" ]; then
    echo "audio-transcribe: $DW_TRANSCRIBE_CLI not found or not executable" >&2
    exit 1
fi

shopt -s nullglob

for stuck in "$INCOMING"/*.processing; do
    base="${stuck%.processing}"
    mv "$stuck" "$base"
done

for wav in "$INCOMING"/*.wav; do
    [ -s "$wav" ] || continue

    proc="$wav.processing"
    mv "$wav" "$proc"

    text=""
    if ! text="$("$DW_TRANSCRIBE_CLI" "$proc")"; then
        echo "audio-transcribe: dw-transcribe-cli failed for $(basename "$wav")" >&2
        text=""
    fi

    fname="$(basename "$wav")"
    today="$(date +%Y-%m-%d)"
    now="$(date +%H:%M:%S)"
    md="$TEXT_DIR/$today.md"

    {
        printf '\n## [%s] audio %s\n\n' "$now" "$fname"
        printf '%s\n' "$text"
    } >> "$md"

    mv "$proc" "$PROCESSED/$fname"
done
