#!/usr/bin/env bash
# Download mxMCPProxy and verify integrity, then install to ~/.claude.
# Cross-platform: selects the right binary by `uname` (Windows .exe /
# macOS arm64 / macOS Intel). Candidate URLs are passed in as env vars by the
# caller (mxSetup, resolved from mx_ping) — this script hardcodes NO
# project-specific URL.
set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
MIN_SIZE="${MIN_SIZE:-102400}"  # 100 KB

# --- Platform detection (deterministic, not caller-supplied) ----------------
UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
UNAME_M="$(uname -m 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Darwin)                         PLATFORM="darwin"  ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT) PLATFORM="windows" ;;
  *)                              PLATFORM="$UNAME_S" ;;
esac

# --- Resolve URL + destination per platform ---------------------------------
# Windows: PROXY_URL (+ EXPECTED_SHA256) — server-hosted Delphi proxy (unchanged).
# macOS:   PROXY_URL_DARWIN_ARM64 / _AMD64 — GitHub release assets; the server
#          does not host these, so there is no server-side sha256 (size-check).
RESOLVED_URL=""
DEFAULT_DEST=""
USE_SHA=1     # verify EXPECTED_SHA256 when provided
CHMOD_X=0     # set the executable bit (POSIX targets)

case "$PLATFORM" in
  windows)
    : "${PROXY_URL:?PROXY_URL must be set (resolved from mx_ping proxy_download_url)}"
    RESOLVED_URL="$PROXY_URL"
    DEFAULT_DEST="$CLAUDE_HOME/mxMCPProxy.exe"
    ;;
  darwin)
    case "$UNAME_M" in
      arm64|aarch64)
        : "${PROXY_URL_DARWIN_ARM64:?PROXY_URL_DARWIN_ARM64 must be set (mx_ping proxy_download_url_darwin_arm64)}"
        RESOLVED_URL="$PROXY_URL_DARWIN_ARM64"
        ;;
      x86_64|amd64)
        : "${PROXY_URL_DARWIN_AMD64:?PROXY_URL_DARWIN_AMD64 must be set (mx_ping proxy_download_url_darwin_amd64)}"
        RESOLVED_URL="$PROXY_URL_DARWIN_AMD64"
        ;;
      *)
        echo "ERROR: unsupported macOS arch '$UNAME_M' (expected arm64 or x86_64)." >&2
        exit 1
        ;;
    esac
    DEFAULT_DEST="$CLAUDE_HOME/mxMCPProxy"
    USE_SHA=0   # no server-side sha256 for release-asset binaries → size-check
    CHMOD_X=1
    ;;
  *)
    echo "ERROR: unsupported platform '$UNAME_S'. mxMCPProxy ships for Windows + macOS only." >&2
    exit 1
    ;;
esac

DEST="${DEST:-$DEFAULT_DEST}"
DEST_NEW="${DEST}.new"

# --- Running-process warning (best-effort, OS-aware, non-fatal) -------------
if [ "$PLATFORM" = "windows" ]; then
  if command -v ps >/dev/null 2>&1 && ps -W 2>/dev/null | grep -i -q mxMCPProxy; then
    echo "WARN: mxMCPProxy.exe appears to be running — consider 'taskkill /IM mxMCPProxy.exe /F' before update." >&2
  fi
else
  if command -v pgrep >/dev/null 2>&1 && pgrep -f mxMCPProxy >/dev/null 2>&1; then
    echo "WARN: mxMCPProxy appears to be running — quit Claude Code / kill it before update if the swap fails." >&2
  fi
fi

mkdir -p "$CLAUDE_HOME"
echo "Platform: $PLATFORM/$UNAME_M  ->  $DEST"

# --- Staged download (write to .new, swap on success) -----------------------
# HTTPS proto-pin blocks any accidental http:// fallback or redirect. An
# http:// URL is only valid for the localhost admin_port (Windows internal
# fallback); to allow it, the caller may override via CURL_EXTRA, but the
# default refuses unencrypted binary downloads.
curl -fL --proto '=https' --proto-redir '=https' --retry 3 --max-time 300 --connect-timeout 10 -o "$DEST_NEW" "$RESOLVED_URL" \
  || { rm -f "$DEST_NEW"; echo "ERROR: proxy download failed from $RESOLVED_URL" >&2; exit 1; }

# --- Integrity check --------------------------------------------------------
SIZE=$(wc -c < "$DEST_NEW")
if [ "$USE_SHA" -eq 1 ] && [ -n "${EXPECTED_SHA256:-}" ]; then
  ACTUAL_SHA256=$(sha256sum "$DEST_NEW" | awk '{print $1}')
  if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    rm -f "$DEST_NEW"
    echo "ERROR: SHA256 mismatch (expected $EXPECTED_SHA256, got $ACTUAL_SHA256). Aborting." >&2
    exit 1
  fi
  echo "SHA256 verified: $ACTUAL_SHA256"
else
  if [ "$USE_SHA" -eq 1 ]; then
    echo "WARN: sha256 unavailable, weak size-check only" >&2
  else
    echo "INFO: macOS release-asset binary — size-check only (no server-side sha256)." >&2
  fi
  if [ "$SIZE" -lt "$MIN_SIZE" ]; then
    echo "ERROR: $DEST_NEW is $SIZE bytes (<$MIN_SIZE). Download failed." >&2
    rm -f "$DEST_NEW"
    exit 1
  fi
fi

# --- Install (atomic-ish swap) ----------------------------------------------
mv -f "$DEST_NEW" "$DEST" \
  || { echo "ERROR: mv $DEST_NEW -> $DEST failed (file locked? proxy still running?)" >&2; rm -f "$DEST_NEW"; exit 1; }

if [ "$CHMOD_X" -eq 1 ]; then
  chmod +x "$DEST"
fi

echo "Done. Proxy installed at $DEST ($SIZE bytes)."
