#!/usr/bin/env bash
# Daily Work Capture System — uninstaller.
# Stops the launchd jobs, removes their plists, and unlinks the helper
# binaries. Leaves user data (~/capture/, ~/.config/dwr/) intact.
set -euo pipefail

LAUNCHD_DIR="$HOME/Library/LaunchAgents"
LOCAL_BIN="$HOME/.local/bin"

LABELS=(
    dev.goofmint.dw.image-capture
    dev.goofmint.dw.image-ocr
    dev.goofmint.dw.audio-capture
    dev.goofmint.dw.audio-transcribe
)

uid="$(id -u)"

info()    { printf 'uninstall: %s\n' "$*"; }
section() { printf '\n==> %s\n' "$*"; }

section "Stopping launchd jobs"
for label in "${LABELS[@]}"; do
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        info "bootout $label"
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    else
        info "$label not loaded (skip)"
    fi
done

section "Removing plist files"
for label in "${LABELS[@]}"; do
    f="$LAUNCHD_DIR/${label}.plist"
    if [ -f "$f" ]; then
        rm -f "$f"
        info "removed $f"
    fi
done

section "Removing $LOCAL_BIN symlinks"
for name in dw-ocr-cli dw-transcribe-cli; do
    f="$LOCAL_BIN/$name"
    if [ -L "$f" ]; then
        rm -f "$f"
        info "removed $f"
    fi
done

section "Done"
cat <<EOF

User data is preserved:
  ~/capture/           — recordings, transcripts, logs
  ~/.config/dwr/       — config.toml

To remove these too (irreversible):
  rm -rf ~/capture ~/.config/dwr
EOF
