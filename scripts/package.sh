#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "dist/Redactor.app" "$stage/Redactor.app"
cp packaging/Install.txt "$stage/Install.txt"
rm -f dist/Redactor-macOS.zip
ditto -c -k --norsrc "$stage" dist/Redactor-macOS.zip
