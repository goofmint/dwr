#!/usr/bin/env bash
set -euo pipefail

CAPTURE_DIR="${CAPTURE_DIR:-$HOME/capture}"
INCOMING="$CAPTURE_DIR/image/incoming"
STATE_DIR="$CAPTURE_DIR/state"
LAST_FRAME="$STATE_DIR/last-frame.png"

mkdir -p "$INCOMING" "$STATE_DIR"

for cmd in compare identify; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "image-capture: '$cmd' (ImageMagick) not found in PATH" >&2
        exit 1
    fi
done

# Find the focused window of the frontmost application via CGWindowList.
# Output: "<CGWindowID>\t<AppName>". Empty output = nothing to capture.
detect_output="$(swift -e '
import AppKit
import CoreGraphics

guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
let pid = app.processIdentifier
let appName = app.localizedName ?? "Unknown"

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else { exit(1) }

// Take the topmost normal-layer window owned by the frontmost app that has
// a real size (skip helper popups, status item windows, etc.).
for w in windows {
    guard
        let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
        let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
        let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
        (bounds["Width"] ?? 0) > 200,
        (bounds["Height"] ?? 0) > 100,
        let id = w[kCGWindowNumber as String] as? CGWindowID
    else { continue }
    print("\(id)\t\(appName)")
    exit(0)
}
exit(1)
' 2>/dev/null || true)"

if [ -z "$detect_output" ]; then
    # No focused window this tick; not an error.
    exit 0
fi

window_id="${detect_output%%$'\t'*}"
app_name="${detect_output#*$'\t'}"

tmp="$(mktemp -t dw-capture).png"
trap 'rm -f "$tmp"' EXIT

# -l <id>: capture specified window. -o: omit drop shadow.
screencapture -x -o -l "$window_id" "$tmp"

if [ ! -s "$tmp" ]; then
    # Window may have closed between detection and capture; not fatal.
    exit 0
fi

# Sanitize app name for filenames (alnum/dot/underscore/hyphen only, max 32).
safe_app="$(printf '%s' "$app_name" | tr -c '[:alnum:]._-' '_' | cut -c1-32)"
ts="$(date +%Y%m%d-%H%M%S)"
out="$INCOMING/${ts}-${safe_app}.png"

if [ ! -f "$LAST_FRAME" ]; then
    cp "$tmp" "$out"
    cp "$tmp" "$LAST_FRAME"
    exit 0
fi

# Different dimensions => different window or resize; save unconditionally.
last_dim="$(identify -format '%wx%h' "$LAST_FRAME")"
new_dim="$(identify -format '%wx%h' "$tmp")"
if [ "$last_dim" != "$new_dim" ]; then
    cp "$tmp" "$out"
    cp "$tmp" "$LAST_FRAME"
    exit 0
fi

# Same dimensions: pixel diff with -fuzz to absorb cursor/AA noise.
raw_compare="$(compare -metric AE -fuzz 5% "$LAST_FRAME" "$tmp" null: 2>&1 || true)"
first_token="$(printf '%s\n' "$raw_compare" | awk 'NR==1{print $1; exit}')"

if [[ "$first_token" =~ ^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]]; then
    diff_pixels="$(printf '%.0f' "$first_token")"
else
    echo "image-capture: compare output unparseable: '$raw_compare'; saving frame" >&2
    diff_pixels="999999999"
fi

width="$(identify -format '%w' "$tmp")"
height="$(identify -format '%h' "$tmp")"
total_pixels=$((width * height))
threshold=$((total_pixels / 1000))

if [ "$diff_pixels" -le "$threshold" ]; then
    exit 0
fi

cp "$tmp" "$out"
cp "$tmp" "$LAST_FRAME"
