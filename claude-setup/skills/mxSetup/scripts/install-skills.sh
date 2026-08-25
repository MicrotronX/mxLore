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

# Opt-in pre-clean: wipe stale files inside the skills THIS BUNDLE SHIPS, before re-copy.
# Default (CLEAN unset or 0) is additive cp -r so canonical-first edits in
# ~/.claude/skills/mx*/ are preserved for users who edit there and haven't synced
# upstream yet. Only enable CLEAN=1 when you're sure you have NO local unsynced edits.
#
# The delete list is derived from the bundle ("$mx_dirs"), NEVER from the local mx* glob.
# A local mx*/ dir that this bundle does not ship is somebody else's skill — private,
# unpublished, quite possibly the only copy in existence — and is none of this
# script's business. The old `rm -rf "$CLAUDE_HOME/skills/"mx*` deleted those too:
# a flag documented as "remove stale files" silently wiped whole unversioned skill
# trees that this bundle had never installed and knew nothing about.
# And it does not delete even those: they are MOVED to a timestamped quarantine dir
# outside skills/ (so nothing there is ever loaded as a skill again). CLEAN's purpose
# — "files removed upstream must not linger" — is fully served by moving them out of
# the way, and the difference matters the day this script is wrong: a name collision
# between a future bundle skill and a private one of the same name, or simply a bug
# in the ownership logic above. Reversible beats clever.
if [ "${CLEAN:-0}" = "1" ]; then
  _quar="$CLAUDE_HOME/.skills-removed/$(date +%Y%m%d-%H%M%S)"
  echo "CLEAN=1 → moving bundle-owned mx*/ dirs out of $CLAUDE_HOME/skills/ (not deleting)"
  _moved=0
  for _d in "${mx_dirs[@]}"; do
    _name="$(basename "$_d")"
    [ -n "$_name" ] && [ "$_name" != "." ] && [ "$_name" != "/" ] || continue
    if [ -e "$CLAUDE_HOME/skills/$_name" ]; then
      mkdir -p "$_quar"
      mv "$CLAUDE_HOME/skills/$_name" "$_quar/$_name"
      _moved=$((_moved + 1))
    fi
  done
  if [ "$_moved" -gt 0 ]; then
    echo "  $_moved dir(s) moved to $_quar — delete it yourself once the install looks right."
  fi
  unset _d _name _quar _moved
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

# Orphan report: name files that exist locally but are not in this
# bundle. hooks/ and reference/ are copied additively, so a file removed upstream
# stays on disk forever — and for a hook that means it also stays REGISTERED in
# settings.json (Phase 5b owns that file, this script never touches it), i.e. dead
# code that still executes.
#
# Report, NEVER remove. "Not in the bundle" does not mean "stale": the bundle is
# English-only and public, so German reference files and private skills are absent
# from it ON PURPOSE (see _shared/mirror-sync.md). Measured on a real install, every
# single not-in-bundle file turned out to be deliberate — an auto-prune would have
# been wrong 100% of the time. Visibility is what is missing here, not deletion.
for _sub in hooks reference; do
  [ -d "$CLAUDE_HOME/$_sub" ] && [ -d "$SRC/$_sub" ] || continue
  ( cd "$CLAUDE_HOME/$_sub" && find . -type f | LC_ALL=C sort ) > "$TMP_DIR/orph-local.txt"
  ( cd "$SRC/$_sub"         && find . -type f | LC_ALL=C sort ) > "$TMP_DIR/orph-bundle.txt"
  _orph="$(comm -23 "$TMP_DIR/orph-local.txt" "$TMP_DIR/orph-bundle.txt")"
  if [ -n "$_orph" ]; then
    echo "NOTE: $CLAUDE_HOME/$_sub/ holds files this bundle does not ship (NOT removed):"
    echo "$_orph" | sed "s|^\./|  $_sub/|"
    echo "  → some of these are local on purpose (private/non-English files). Review before deleting anything."
    # NOTE: `[ ... ] && echo` would return 1 for the reference/ pass and kill the
    # script under `set -e`. Keep this as a real if.
    if [ "$_sub" = "hooks" ]; then
      echo "  ⚡ a leftover hook may still be registered in settings.json — check Phase 5b."
    fi
  fi
done
unset _sub _orph

# Stage CLAUDE.md for Phase 5c merge (three-branch logic).
# If the repo lacks CLAUDE.md, clear any stale stage from a previous run so
# Phase 5c doesn't merge against an outdated snapshot.
cp "$SRC/CLAUDE.md" "$CLAUDE_MD_STAGE" 2>/dev/null || { echo "WARN: CLAUDE.md missing in repo — clearing stale stage"; rm -f "$CLAUDE_MD_STAGE"; }

# Setup-version client stamp: copy the bundle's setup-version.json so
# mx_session_start reports the actually-installed bundle version (admin-side
# session tracking). Missing in bundle → keep whatever is already installed.
if [ -f "$SRC/setup-version.json" ]; then
  cp "$SRC/setup-version.json" "$CLAUDE_HOME/setup-version.json"
  echo "setup-version.json stamped: $(cat "$CLAUDE_HOME/setup-version.json")"
else
  echo "WARN: setup-version.json missing in bundle — keeping existing $CLAUDE_HOME/setup-version.json"
fi

echo "Done. Skills/hooks/reference installed from $REPO_URL; CLAUDE.md staged at $CLAUDE_MD_STAGE."
echo "NOTE: hook FILES copied to $CLAUDE_HOME/hooks/, but settings.json hook REGISTRATION must be done by Claude Code (Phase 5b in /mxSetup) — install-skills.sh does NOT modify settings.json."
