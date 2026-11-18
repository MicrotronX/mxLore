#!/usr/bin/env bash
# Install/update mxLoreOrchestrator.exe (Windows only) into ~/.claude.
# Caller (mxSetup) passes ORCH_URL + ORCH_SHA256 from mx_ping
# (orchestrator_download_url / orchestrator_sha256); nothing is hardcoded.
# Optional ORCH_FILES = "name=sha256 name=sha256 ..." from mx_ping
# orchestrator_files: extra files next to the exe (conpty.dll, OpenConsole.exe,
# THIRD-PARTY-NOTICES.txt), downloaded from "$ORCH_URL/<name>". Without
# conpty.dll + OpenConsole.exe the orchestrator falls back to the Windows ConPTY.
# MODE=install (default) | update (only if exe exists AND a sha differs).
# Never kills a running orchestrator: a locked file is renamed to .old
# (allowed on Windows), the new one takes its place, restart is up to the user.
# Exit: 0 installed/updated, 2 skipped (not windows / up to date / not installed), 1 error.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MODE="${MODE:-install}"
EXE_NAME="mxLoreOrchestrator.exe"
DEST="$CLAUDE_HOME/$EXE_NAME"

case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) exit 2 ;;
esac
: "${ORCH_URL:?ORCH_URL must be set (mx_ping orchestrator_download_url)}"
: "${ORCH_SHA256:?ORCH_SHA256 must be set (mx_ping orchestrator_sha256)}"
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum not found" >&2; exit 1; }

if [ "$MODE" = "update" ]; then
  [ -f "$DEST" ] || { echo "Orchestrator not installed locally - skip."; exit 2; }
fi

# https only, except the localhost admin_port (server without an external admin URL).
case "$ORCH_URL" in
  *@*) PROTO='=https' ;;
  http://localhost:[0-9]*/*|http://127.0.0.1:[0-9]*/*) PROTO='=http,https' ;;
  *) PROTO='=https' ;;
esac

sha_of() { sha256sum "$1" | awk '{print $1}'; }

# Work list: "name sha url"
ITEMS="$EXE_NAME $ORCH_SHA256 $ORCH_URL"
for pair in ${ORCH_FILES:-}; do
  name="${pair%%=*}"; sha="${pair#*=}"
  case "$name" in
    ''|*/*|*\\*|*..*) echo "ERROR: invalid file name in ORCH_FILES: $name" >&2; exit 1 ;;
  esac
  ITEMS="$ITEMS
$name $sha ${ORCH_URL%/}/$name"
done

# Pending = missing or different hash. Leftover .old removed if no longer locked.
PENDING=""
while read -r name sha url; do
  d="$CLAUDE_HOME/$name"
  rm -f "$d.old" 2>/dev/null || true
  if [ -f "$d" ] && [ "$(sha_of "$d")" = "$sha" ]; then continue; fi
  # Still locked: the file from the last swap is in use, a second swap cannot rename over it.
  if [ -f "$d.old" ]; then
    echo "The previous update is still pending - restart the orchestrator, then run the update again."; exit 2
  fi
  PENDING="$PENDING
$name $sha $url"
done <<< "$ITEMS"
PENDING="${PENDING#
}"
[ -n "$PENDING" ] || { echo "Orchestrator up to date."; exit 2; }

mkdir -p "$CLAUDE_HOME"
cleanup_new() { while read -r n _ _; do rm -f "$CLAUDE_HOME/$n.new"; done <<< "$PENDING"; }

# Download + verify everything first; swap only when all files are good.
while read -r name sha url; do
  d="$CLAUDE_HOME/$name"
  curl -fL --proto "$PROTO" --proto-redir '=https' --retry 3 --max-time 300 --connect-timeout 10 \
    -o "$d.new" "$url" \
    || { cleanup_new; echo "ERROR: download failed from $url" >&2; exit 1; }
  actual="$(sha_of "$d.new")"
  if [ "$actual" != "$sha" ]; then
    cleanup_new
    echo "ERROR: $name SHA256 mismatch (expected $sha, got $actual). Step aborted." >&2
    exit 1
  fi
done <<< "$PENDING"

LOCKED=0
while read -r name sha _; do
  d="$CLAUDE_HOME/$name"
  if [ -f "$d" ]; then
    mv -f "$d" "$d.old" \
      || { cleanup_new; echo "ERROR: cannot rename $d to .old" >&2; exit 1; }
  fi
  mv -f "$d.new" "$d" \
    || { [ -f "$d.old" ] && mv -f "$d.old" "$d"; cleanup_new; echo "ERROR: cannot move $d.new into place" >&2; exit 1; }
  echo "Installed $d (sha256 $sha)."
  # .old stays only while the previous file is still in use.
  rm -f "$d.old" 2>/dev/null || true
  if [ -f "$d.old" ]; then LOCKED=1; fi
done <<< "$PENDING"

if [ "$LOCKED" = 1 ]; then
  echo "The running orchestrator keeps the old files - restart it to use the new ones."
fi
exit 0
