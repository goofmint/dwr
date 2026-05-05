#!/usr/bin/env bash
# Daily Work Capture System — installer.
# Builds Swift CLIs, links them to ~/.local/bin, creates ~/capture/ tree,
# substitutes plist placeholders, and bootstraps the four launchd jobs.
# Re-runnable: existing jobs are booted out before being re-bootstrapped.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
CAPTURE_DIR="${CAPTURE_DIR:-$HOME/capture}"
LOCAL_BIN="$HOME/.local/bin"

LABELS=(
    dev.goofmint.dw.image-capture
    dev.goofmint.dw.image-ocr
    dev.goofmint.dw.audio-capture
    dev.goofmint.dw.audio-transcribe
)

uid="$(id -u)"

err()     { printf 'setup: %s\n' "$*" >&2; }
info()    { printf 'setup: %s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }

# ---- 1. Preflight ------------------------------------------------------------
section "Checking prerequisites"

if [ "$(uname)" != "Darwin" ]; then
    err "macOS required (got $(uname))"
    exit 1
fi
if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not found. Install from https://brew.sh and retry."
    exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
    err "Swift not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi
info "macOS, Homebrew, Swift OK"

# ---- 2. Homebrew dependencies -----------------------------------------------
section "Installing Homebrew dependencies"

for pkg in ffmpeg imagemagick; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
        info "$pkg already installed"
    else
        info "installing $pkg ..."
        brew install "$pkg"
    fi
done

# ---- 3. Build Swift CLIs ----------------------------------------------------
section "Building Swift CLIs (release mode)"

for cli in ocr-cli transcribe-cli; do
    info "building $cli ..."
    (cd "$REPO/swift/$cli" && swift build -c release)
done

# ---- 4. Link binaries to ~/.local/bin ---------------------------------------
section "Linking binaries to $LOCAL_BIN"

mkdir -p "$LOCAL_BIN"
ln -sfn "$REPO/swift/ocr-cli/.build/release/ocr-cli"             "$LOCAL_BIN/dw-ocr-cli"
ln -sfn "$REPO/swift/transcribe-cli/.build/release/transcribe-cli" "$LOCAL_BIN/dw-transcribe-cli"
info "linked dw-ocr-cli and dw-transcribe-cli"

# ---- 5. Create capture tree -------------------------------------------------
section "Creating $CAPTURE_DIR tree"

mkdir -p \
    "$CAPTURE_DIR/image/incoming"  "$CAPTURE_DIR/image/processed" \
    "$CAPTURE_DIR/audio/incoming"  "$CAPTURE_DIR/audio/processed" \
    "$CAPTURE_DIR/text/image"      "$CAPTURE_DIR/text/audio" \
    "$CAPTURE_DIR/state"
info "OK"

# ---- 6. Install plists ------------------------------------------------------
section "Installing launchd plists into $LAUNCHD_DIR"

mkdir -p "$LAUNCHD_DIR"

# Bootout existing jobs first so we can rewrite the plists cleanly.
for label in "${LABELS[@]}"; do
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        info "bootout $label (existing)"
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    fi
done

for label in "${LABELS[@]}"; do
    src="$REPO/launchd/${label}.plist"
    if [ ! -e "$src" ]; then
        err "missing launchd template: $src"
        exit 1
    fi
    dst="$LAUNCHD_DIR/${label}.plist"
    sed -e "s|__HOME__|$HOME|g" -e "s|__REPO__|$REPO|g" "$src" > "$dst"
    info "wrote $dst"
done

# ---- 7. Bootstrap (load) the jobs -------------------------------------------
section "Bootstrapping launchd jobs"

for label in "${LABELS[@]}"; do
    launchctl bootstrap "gui/$uid" "$LAUNCHD_DIR/${label}.plist"
    info "bootstrapped $label"
done

# ---- 8. Final notes ---------------------------------------------------------
section "Done"

cat <<EOF

Permissions still required (System Settings → Privacy & Security):
  - Screen Recording  → enable for the process that runs the launchd job
  - Microphone        → same
  - Speech Recognition → enable for transcribe-cli
  - Enable Siri OR Dictation (Apple Intelligence & Siri / Keyboard) so on-device
    Japanese recognition is available; Dictation must include 日本語.

Configure your audio device (recommended):
  $REPO/bin/configure.sh

Optional: capture system audio (per BASIC.md "マイク+システム音"):
  brew install --cask blackhole-2ch
  Then build an Aggregate Device in Audio MIDI Setup.app — see README.md.

Logs:
  $CAPTURE_DIR/state/<service>.log

To stop & uninstall:
  $REPO/uninstall.sh
EOF
