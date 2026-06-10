#!/usr/bin/env bash
# Download mxMCPProxy.exe from the resolved URL and verify integrity
# (SHA256 via EXPECTED_SHA256 env if set, else minimum-size fallback).
set -euo pipefail

: "${PROXY_URL:?PROXY_URL must be set (resolved from mx_ping proxy_download_url)}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
DEST="${DEST:-$CLAUDE_HOME/mxMCPProxy.exe}"
DEST_NEW="${DEST}.new"
MIN_SIZE="${MIN_SIZE:-102400}"  # 100 KB

# File-lock warning (Windows): ps -W on Git-Bash lists native Windows processes.
# Not fatal — staging to ${DEST}.new + mv at the end makes the swap atomic-ish,
# but a running proxy holding the handle will cause the final mv to fail.
if command -v ps >/dev/null 2>&1; then
  if ps -W 2>/dev/null | grep -i -q mxMCPProxy; then
    echo "WARN: mxMCPProxy.exe appears to be running — consider 'taskkill /IM mxMCPProxy.exe /F' before update." >&2
  fi
fi

mkdir -p "$CLAUDE_HOME"
# Staged download: write to .new, swap on success. Prevents partial-write corruption
# of the live binary if curl fails mid-download and (mostly) sidesteps Windows
# file-locks on the existing exe until the final mv step.
# HTTPS proto-pin (--proto =https --proto-redir =https) blocks any accidental
# http:// fallback or redirect. An http:// proxy_download_url is only valid for
# localhost admin_port (127.0.0.1) — if you need that, unset the pin via
# CURL_EXTRA env var, but the default refuses unencrypted binary downloads.
curl -fL --proto '=https' --proto-redir '=https' --retry 3 --max-time 300 --connect-timeout 10 -o "$DEST_NEW" "$PROXY_URL" \
  || { rm -f "$DEST_NEW"; echo "ERROR: proxy download failed from $PROXY_URL" >&2; exit 1; }

# Integrity check: SHA256 when EXPECTED_SHA256 is provided (caller passes
# proxy_sha256 from the mx_ping response, if the server exposes it).
# Fallback: weak 100KB size check until every server ships proxy_sha256.
SIZE=$(wc -c < "$DEST_NEW")
if [ -n "${EXPECTED_SHA256:-}" ]; then
  ACTUAL_SHA256=$(sha256sum "$DEST_NEW" | awk '{print $1}')
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    rm -f "$DEST_NEW"
    echo "ERROR: SHA256 mismatch for downloaded proxy (expected $EXPECTED_SHA256, got $ACTUAL_SHA256). Download deleted, aborting." >&2
    exit 1
  fi
  echo "SHA256 verified: $ACTUAL_SHA256"
else
  echo "WARN: sha256 unavailable, weak size-check only" >&2
  # Size check (portable: wc -c works on Windows Git-Bash + Linux + macOS)
  if [ "$SIZE" -lt "$MIN_SIZE" ]; then
    echo "ERROR: $DEST_NEW is $SIZE bytes (<$MIN_SIZE). Proxy download failed." >&2
    rm -f "$DEST_NEW"
    exit 1
  fi
fi

mv -f "$DEST_NEW" "$DEST" || { echo "ERROR: mv $DEST_NEW → $DEST failed (file locked? proxy still running?)" >&2; rm -f "$DEST_NEW"; exit 1; }

echo "Done. Proxy installed at $DEST ($SIZE bytes)."
