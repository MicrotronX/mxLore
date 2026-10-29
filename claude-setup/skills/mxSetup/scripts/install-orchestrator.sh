#!/usr/bin/env bash
# Install/update mxLoreOrchestrator.exe (Windows only) into ~/.claude.
# Caller (mxSetup) passes ORCH_URL + ORCH_SHA256 from mx_ping
# (orchestrator_download_url / orchestrator_sha256); nothing is hardcoded.
# MODE=install (default) | update (only if exe exists AND sha differs).
# Never kills a running orchestrator: the running exe is renamed to .old
# (allowed on Windows), the new one takes its place, restart is up to the user.
# Exit: 0 installed/updated, 2 skipped (not windows / up to date / not installed), 1 error.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MODE="${MODE:-install}"
DEST="$CLAUDE_HOME/mxLoreOrchestrator.exe"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) exit 2 ;;
esac
: "${ORCH_URL:?ORCH_URL must be set (mx_ping orchestrator_download_url)}"
: "${ORCH_SHA256:?ORCH_SHA256 must be set (mx_ping orchestrator_sha256)}"
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum not found" >&2; exit 1; }

# Leftover from a previous swap: remove if no longer locked.
rm -f "$DEST.old" 2>/dev/null || true

if [ "$MODE" = "update" ]; then
  [ -f "$DEST" ] || { echo "Orchestrator not installed locally - skip."; exit 2; }
fi
if [ -f "$DEST" ] && [ "$(sha256sum "$DEST" | awk '{print $1}')" = "$ORCH_SHA256" ]; then
  echo "Orchestrator up to date."; exit 2
fi
# Still locked: the binary from the last swap is running, a second swap cannot rename over it.
if [ -f "$DEST.old" ]; then
  echo "The previous update is still pending - restart the orchestrator, then run the update again."; exit 2
fi

mkdir -p "$CLAUDE_HOME"
# https only, except the localhost admin_port (server without an external admin URL).
case "$ORCH_URL" in
  *@*) PROTO='=https' ;;
  http://localhost:[0-9]*/*|http://127.0.0.1:[0-9]*/*) PROTO='=http,https' ;;
  *) PROTO='=https' ;;
esac
curl -fL --proto "$PROTO" --proto-redir '=https' --retry 3 --max-time 300 --connect-timeout 10 \
  -o "$DEST.new" "$ORCH_URL" \
  || { rm -f "$DEST.new"; echo "ERROR: orchestrator download failed from $ORCH_URL" >&2; exit 1; }

ACTUAL="$(sha256sum "$DEST.new" | awk '{print $1}')"
if [ "$ACTUAL" != "$ORCH_SHA256" ]; then
  rm -f "$DEST.new"
  echo "ERROR: orchestrator SHA256 mismatch (expected $ORCH_SHA256, got $ACTUAL). Step aborted." >&2
  exit 1
fi

if [ -f "$DEST" ]; then
  mv -f "$DEST" "$DEST.old" \
    || { rm -f "$DEST.new"; echo "ERROR: cannot rename $DEST to .old" >&2; exit 1; }
fi
mv -f "$DEST.new" "$DEST" \
  || { [ -f "$DEST.old" ] && mv -f "$DEST.old" "$DEST"; echo "ERROR: cannot move $DEST.new into place" >&2; exit 1; }

echo "Orchestrator installed at $DEST (sha256 $ACTUAL)."
# .old stays only while the previous binary is still running.
rm -f "$DEST.old" 2>/dev/null || true
if [ -f "$DEST.old" ]; then
  echo "The running orchestrator keeps the old binary - restart it to use the new one."
fi
exit 0
