#!/bin/bash
set -euo pipefail
uid="$(id -u)"
launchctl bootout "gui/${uid}/com.redactor.agent" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/com.redactor.agent.plist"
osascript -e 'tell application id "com.redactor.app" to quit' >/dev/null 2>&1 || true
pkill -x redactor >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/Redactor.app"
