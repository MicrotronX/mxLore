#!/usr/bin/env bash
# Download mxLore-skills from GitHub and install skills/hooks/reference into ~/.claude/.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MicrotronX/mxLore-skills/archive/main.zip}"
TMP_ZIP="${TMP_ZIP:-/tmp/mxLore-skills.zip}"
TMP_DIR="${TMP_DIR:-/tmp/mxLore-skills}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_MD_STAGE="${CLAUDE_MD_STAGE:-/tmp/mxLore-skills-CLAUDE.md}"

# Cleanup /tmp detritus on any exit path (success, error, interrupt).
trap 'rm -rf "$TMP_DIR" "$TMP_ZIP" 2>/dev/null || true' EXIT

curl -fL --retry 3 --max-time 120 --connect-timeout 10 -o "$TMP_ZIP" "$REPO_URL"
unzip -o "$TMP_ZIP" -d "$TMP_DIR" >/dev/null

SRC="$TMP_DIR/mxLore-skills-main"

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
( cd "$SRC/hooks" && cp -r . "$CLAUDE_HOME/hooks/" )
( cd "$SRC/reference" && cp -r . "$CLAUDE_HOME/reference/" )

# Stage CLAUDE.md for Phase 5c merge (three-branch logic).
# If the repo lacks CLAUDE.md, clear any stale stage from a previous run so
# Phase 5c doesn't merge against an outdated snapshot.
cp "$SRC/CLAUDE.md" "$CLAUDE_MD_STAGE" 2>/dev/null || { echo "WARN: CLAUDE.md missing in repo — clearing stale stage"; rm -f "$CLAUDE_MD_STAGE"; }

echo "Done. Skills/hooks/reference installed from $REPO_URL; CLAUDE.md staged at $CLAUDE_MD_STAGE."
