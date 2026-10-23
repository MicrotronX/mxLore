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
