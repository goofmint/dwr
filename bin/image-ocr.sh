#!/usr/bin/env bash
set -euo pipefail

CAPTURE_DIR="${CAPTURE_DIR:-$HOME/capture}"
INCOMING="$CAPTURE_DIR/image/incoming"
PROCESSED="$CAPTURE_DIR/image/processed"
TEXT_DIR="$CAPTURE_DIR/text/image"

DW_OCR_CLI="${DW_OCR_CLI:-$HOME/.local/bin/dw-ocr-cli}"

mkdir -p "$INCOMING" "$PROCESSED" "$TEXT_DIR"

if [ ! -x "$DW_OCR_CLI" ]; then
    echo "image-ocr: $DW_OCR_CLI not found or not executable" >&2
    exit 1
fi

shopt -s nullglob

# Recovery: a previous run may have left *.processing on a crash.
for stuck in "$INCOMING"/*.processing; do
    base="${stuck%.processing}"
    mv "$stuck" "$base"
done

for png in "$INCOMING"/*.png; do
    [ -s "$png" ] || continue

    proc="$png.processing"
    mv "$png" "$proc"

    text=""
    if ! text="$("$DW_OCR_CLI" "$proc")"; then
        echo "image-ocr: dw-ocr-cli failed for $(basename "$png")" >&2
        text=""
    fi

    fname="$(basename "$png")"

    # Skip the markdown entry if OCR yielded no text (e.g., a blank-screen
    # capture or unrecognizable content). An empty heading-only block is just
    # noise in the daily log.
    if [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        today="$(date +%Y-%m-%d)"
        now="$(date +%H:%M:%S)"
        md="$TEXT_DIR/$today.md"

        {
            printf '\n## [%s] image %s\n\n' "$now" "$fname"
            printf '%s\n' "$text"
        } >> "$md"
    fi

    mv "$proc" "$PROCESSED/$fname"
done
