#!/usr/bin/env bash
# env-keys — the ONLY sanctioned way to look at an .env file.
# Prints key names and value lengths; never prints a value or any part of it.
#   bash ~/.claude/hooks/env-keys.sh <file>                   → KEY len=N (empty → len=0)
#   bash ~/.claude/hooks/env-keys.sh <file> --cmp KEY_A KEY_B → equal | different | missing
# Allow-listed by env-guard.js (PreToolUse). Do not extend it to print values.
# bash 3.2 compatible (no associative arrays). Multi-line quoted values are
# consumed as one value; lines that are not KEY=... are reported as "(unparsed line)".
set -u
f="${1:-}"
[ -n "$f" ] || { echo "usage: env-keys.sh <file> [--cmp KEY_A KEY_B]" >&2; exit 2; }
[ -f "$f" ] || { echo "env-keys: no such file: $f" >&2; exit 1; }
mode="${2:-list}"; ka="${3:-}"; kb="${4:-}"
if [ "$mode" = "--cmp" ] && { [ -z "$ka" ] || [ -z "$kb" ]; }; then echo "usage: --cmp KEY_A KEY_B" >&2; exit 2; fi
va=""; vb=""; ha=0; hb=0
inquote=""   # open quote char while a quoted value spans lines
curk=""; curv=""
emit() {  # key value
  if [ "$mode" = "--cmp" ]; then
    [ "$1" = "$ka" ] && { va="$2"; ha=1; }
    [ "$1" = "$kb" ] && { vb="$2"; hb=1; }
  else
    printf '%s len=%d\n' "$1" "${#2}"
  fi
}
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  if [ -n "$inquote" ]; then               # continuation of a multi-line quoted value
    curv="$curv"$'\n'"$line"
    case "$line" in *"$inquote"*) inquote=""; emit "$curk" "$curv";; esac
    continue
  fi
  case "$line" in ''|'#'*) continue;; esac
  line="${line#export }"
  k="${line%%=*}"
  if [ "$k" = "$line" ]; then
    [ "$mode" = "--cmp" ] || echo "(unparsed line, no '=') len=${#line}"
    continue
  fi
  v="${line#*=}"
  k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
  case "$k" in *[!A-Za-z0-9_.-]*|'') [ "$mode" = "--cmp" ] || echo "(unparsed key) len=${#v}"; continue;; esac
  case "$v" in
    \"*) q='"';; \'*) q="'";; *) q="";;
  esac
  if [ -n "$q" ]; then
    rest="${v#?}"
    case "$rest" in *"$q"*) ;; *) inquote="$q"; curk="$k"; curv="$v"; continue;; esac
  fi
  emit "$k" "$v"
done < "$f"
[ -n "$inquote" ] && emit "$curk" "$curv"   # unterminated quote at EOF: still one value, never printed
if [ "$mode" = "--cmp" ]; then
  if [ $ha -eq 0 ] || [ $hb -eq 0 ]; then echo "missing"; exit 0; fi
  if [ "$va" = "$vb" ]; then echo "equal"; else echo "different"; fi
fi
exit 0
