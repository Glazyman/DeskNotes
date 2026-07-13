#!/bin/bash
# Desk Notes installer — https://github.com/Glazyman/DeskNotes
# usage: curl -fsSL https://raw.githubusercontent.com/Glazyman/DeskNotes/master/install.sh | bash
set -e

echo "⬇️  Downloading Desk Notes (latest release)…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fSL --progress-bar -o "$TMP/Desk-Notes.zip" \
  "https://github.com/Glazyman/DeskNotes/releases/latest/download/Desk-Notes.zip"

echo "📦 Installing to /Applications…"
ditto -xk "$TMP/Desk-Notes.zip" "$TMP"
if pgrep -x DeskNotes >/dev/null 2>&1; then pkill -x DeskNotes || true; sleep 1; fi
rm -rf "/Applications/Desk Notes.app"
mv "$TMP/Desk Notes.app" "/Applications/Desk Notes.app"
xattr -dr com.apple.quarantine "/Applications/Desk Notes.app" 2>/dev/null || true

open "/Applications/Desk Notes.app"
echo ""
echo "✅ Desk Notes installed — look for 🗒️ in your menu bar!"
