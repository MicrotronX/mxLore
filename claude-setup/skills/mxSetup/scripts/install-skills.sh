#!/usr/bin/env bash
# Download mxLore-skills from GitHub and install skills/hooks/reference into ~/.claude/.
#
# NOTE: This script copies hook FILES into $CLAUDE_HOME/hooks/ but does NOT
# modify $CLAUDE_HOME/settings.json — hook REGISTRATION (PreToolUse/PostToolUse/
# Stop/etc. entries) is done by Claude Code in Phase 5b of /mxSetup. Running
# this script standalone leaves hook files on disk but inactive until
# settings.json is updated separately.
set -euo pipefail

# REPO_REF: default "main" (HEAD). Override with REPO_REF=v2.4.0 to pin a release tag.
# TODO(release-tagging): once mxLore-skills cuts release tags, change default
# REPO_REF to the latest tag so new installs get a pinned, verified snapshot
# instead of mutable main HEAD.
REPO_REF="${REPO_REF:-main}"
REPO_URL="${REPO_URL:-https://github.com/MicrotronX/mxLore-skills/archive/refs/heads/${REPO_REF}.zip}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_MD_STAGE="${CLAUDE_MD_STAGE:-/tmp/mxLore-skills-CLAUDE.md}"

# Per-run unique TMP paths avoid parallel-invocation races (two /mxSetup --update
# in flight would otherwise trample each other's /tmp/mxLore-skills dir).
# Prefer mktemp (available on Git-Bash + Linux + macOS), fall back to PID suffix.
if command -v mktemp >/dev/null 2>&1; then
  TMP_DIR="$(mktemp -d -t mxLore-skills.XXXXXX)"
  TMP_ZIP="$(mktemp -t mxLore-skills.zip.XXXXXX)"
else
  TMP_DIR="/tmp/mxLore-skills.$$"
  TMP_ZIP="/tmp/mxLore-skills.$$.zip"
  mkdir -p "$TMP_DIR"
fi

# Cleanup /tmp detritus on any exit path (success, error, interrupt).
# TMP_DIR/TMP_ZIP are per-run unique, so the rm is race-free.
trap 'rm -rf "$TMP_DIR" "$TMP_ZIP" 2>/dev/null || true' EXIT

# HTTPS proto-pin (--proto =https --proto-redir =https) blocks any accidental
# http:// fallback or redirect — GitHub archive URLs are always HTTPS, so a
# non-HTTPS hop indicates MITM or misconfiguration and MUST abort.
curl -fL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 --connect-timeout 10 -o "$TMP_ZIP" "$REPO_URL"
unzip -o "$TMP_ZIP" -d "$TMP_DIR" >/dev/null

# zip-slip hardening: reject any extracted entry that could escape TMP_DIR
# (symlinks or parent-traversal directory names). GitHub archive zips never
# contain these, so any hit means either a compromised zip or a bug — abort.
if find "$TMP_DIR" -lname '*' 2>/dev/null | grep -q .; then
  echo "ERROR: zip contains symlinks — rejecting for safety" >&2
  exit 3
fi
if find "$TMP_DIR" -name '..*' -type d 2>/dev/null | grep -q .; then
  echo "ERROR: zip contains parent-traversal entries — rejecting for safety" >&2
  exit 3
fi

SRC="$TMP_DIR/mxLore-skills-${REPO_REF}"

mkdir -p "$CLAUDE_HOME/skills" "$CLAUDE_HOME/hooks" "$CLAUDE_HOME/reference"

# Capture mx* directories via nullglob so an empty glob fails loudly instead of
# silently passing the literal "$SRC/mx*" to cp (which would error late and confuse).
shopt -s nullglob
mx_dirs=("$SRC"/mx*)
shopt -u nullglob
[ ${#mx_dirs[@]} -gt 0 ] || { echo "ERROR: no mx* directories found in $SRC — repo restructure?"; exit 2; }

# Opt-in pre-clean: wipe stale mx*/ dirs before re-copy. Default (CLEAN unset or 0)
# is additive cp -r so canonical-first edits in ~/.claude/skills/mx*/ are preserved
# for users who edit there and haven't synced upstream yet. Only enable CLEAN=1
# when you're sure you have NO local unsynced edits.
if [ "${CLEAN:-0}" = "1" ]; then
  echo "CLEAN=1 → removing stale mx*/ dirs in $CLAUDE_HOME/skills/ before re-copy"
  rm -rf "$CLAUDE_HOME/skills/"mx*
fi

cp -r "${mx_dirs[@]}" "$CLAUDE_HOME/skills/"
# Subshell + cp -r . avoids the unquoted-glob word-split footgun of "$SRC/hooks/"*
# (the trailing * was outside quotes and would split on spaces in filenames).
# Pre-existence guards: fail loud if a repo restructure removes hooks/ or reference/
# — an empty cd would silently no-op and leave the user thinking install succeeded.
[ -d "$SRC/hooks" ] || { echo "ERROR: $SRC/hooks not found in extracted bundle — repo restructure?" >&2; exit 2; }
( cd "$SRC/hooks" && cp -r . "$CLAUDE_HOME/hooks/" )
[ -d "$SRC/reference" ] || { echo "ERROR: $SRC/reference not found in extracted bundle — repo restructure?" >&2; exit 2; }
( cd "$SRC/reference" && cp -r . "$CLAUDE_HOME/reference/" )

# Stage CLAUDE.md for Phase 5c merge (three-branch logic).
# If the repo lacks CLAUDE.md, clear any stale stage from a previous run so
# Phase 5c doesn't merge against an outdated snapshot.
cp "$SRC/CLAUDE.md" "$CLAUDE_MD_STAGE" 2>/dev/null || { echo "WARN: CLAUDE.md missing in repo — clearing stale stage"; rm -f "$CLAUDE_MD_STAGE"; }

echo "Done. Skills/hooks/reference installed from $REPO_URL; CLAUDE.md staged at $CLAUDE_MD_STAGE."
echo "NOTE: hook FILES copied to $CLAUDE_HOME/hooks/, but settings.json hook REGISTRATION must be done by Claude Code (Phase 5b in /mxSetup) — install-skills.sh does NOT modify settings.json."
