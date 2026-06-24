#!/usr/bin/env bash
# Build mxMCPProxy (Go port). Native build for the current OS/arch.
# On the Mac mini M4 this produces an arm64 binary; no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

# The repo lives under both git and svn working copies; disable VCS stamping
# so `go build` doesn't choke on "multiple VCS detected".
export GOFLAGS="-buildvcs=false"

mkdir -p bin
echo "Building mxMCPProxy ($(go env GOOS)/$(go env GOARCH))…"
go build -o bin/mxMCPProxy .
echo "Done: $(pwd)/bin/mxMCPProxy"
echo
echo "Next: copy mxMCPProxy.ini next to the binary (or pass its path as arg1),"
echo "set Url + ApiKey, then register it in Claude Code (see README.md)."
