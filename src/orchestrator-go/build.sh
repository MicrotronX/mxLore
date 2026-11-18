#!/usr/bin/env bash
# Build mxLoreOrchestrator (Windows, ConPTY). Output: bin/mxLoreOrchestrator.exe
set -euo pipefail
cd "$(dirname "$0")"
# Repo lives under both git and svn; disable VCS stamping.
export GOFLAGS="-buildvcs=false"
# Optional $1 = output path (release builds use their own, the running bin/ EXE is locked).
OUT="${1:-bin/mxLoreOrchestrator.exe}"
mkdir -p "$(dirname "$OUT")"
echo "Building mxLoreOrchestrator (windows/$(go env GOARCH))..."
GOOS=windows go build -trimpath -ldflags "-s -w" -o "$OUT" .
echo "Done: $OUT"

# Dev/base machine: the local server delivers <server-dir>/orchestrator/ to
# /mxSetup clients. Refresh it on every build so it never goes stale, and ship
# the Microsoft ConPTY next to the EXE (without it Windows' ConPTY is used).
SERVE_DIR="../../orchestrator"
if [ -f "../../mxLoreMCP.exe" ] && [ -f bin/conpty.dll ] && [ -f bin/OpenConsole.exe ]; then
  mkdir -p "$SERVE_DIR"
  cp "$OUT" bin/conpty.dll bin/OpenConsole.exe THIRD-PARTY-NOTICES.txt "$SERVE_DIR/"
  echo "Served copy refreshed: $SERVE_DIR (exe + conpty.dll + OpenConsole.exe + notices)"
fi
