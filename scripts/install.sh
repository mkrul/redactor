#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
mkdir -p "$HOME/Applications"
osascript -e 'tell application id "com.redactor.app" to quit' >/dev/null 2>&1 || true
sleep 0.4
pkill -x redactor >/dev/null 2>&1 || true
sleep 0.2
rm -rf "$HOME/Applications/Redactor.app"
ditto "dist/Redactor.app" "$HOME/Applications/Redactor.app"
codesign --force --sign - "$HOME/Applications/Redactor.app/Contents/MacOS/redactor"
codesign --force --sign - "$HOME/Applications/Redactor.app"
open "$HOME/Applications/Redactor.app"
