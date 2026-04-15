#!/usr/bin/env bash
# Statusline for Claude Code — no jq dependency, pure sed/grep
input=$(cat)

# --- Helper: extract JSON value by key (strings and numbers) ---
json_val() {
  echo "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}
json_num() {
  echo "$input" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9.eE+-]*\).*/\1/p' | head -1
}

raw_model=$(json_val "display_name")
[ -z "$raw_model" ] && raw_model="Unknown"
model=$(echo "$raw_model" | sed 's/^Claude //' | sed 's/ \([0-9]\)/\1/')

used=$(json_num "used_percentage")
cwd=$(json_val "cwd")

# --- Section 1: label (slug from CLAUDE.md or directory basename) ---
# Accepts both formats: **Slug:** `mxLore` (backticked) and **Slug:** mxLore (plain)
# Walks up the directory tree from cwd to find CLAUDE.md — robust against
# cwd drift when bash calls cd into subdirectories.
label=""
if [ -n "$cwd" ]; then
  search_dir="$cwd"
  claude_md=""
  # Walk up max 10 levels to avoid runaway on weird filesystems
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -f "$search_dir/CLAUDE.md" ]; then
      claude_md="$search_dir/CLAUDE.md"
      break
    fi
    parent=$(dirname "$search_dir")
    [ "$parent" = "$search_dir" ] && break
    search_dir="$parent"
  done

  if [ -n "$claude_md" ]; then
    slug=$(sed -n 's/.*\*\*Slug:\*\*[[:space:]]*`\([^`]*\)`.*/\1/p' "$claude_md" 2>/dev/null | head -1)
    if [ -z "$slug" ]; then
      slug=$(sed -n 's/.*\*\*Slug:\*\*[[:space:]]*\([^[:space:]]*\).*/\1/p' "$claude_md" 2>/dev/null | head -1)
    fi
    if [ -n "$slug" ]; then
      label="$slug"
    fi
  fi
fi
if [ -z "$label" ] && [ -n "$cwd" ]; then
  label=$(basename "$cwd")
fi

# --- Section 2: context percentage with color coding ---
ctx_section=""
if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ "$used_int" -ge 80 ]; then
    ctx_section=$(printf "\033[0;31m%d%%\033[0m" "$used_int")
  elif [ "$used_int" -ge 50 ]; then
    ctx_section=$(printf "\033[0;33m%d%%\033[0m" "$used_int")
  else
    ctx_section=$(printf "%d%%" "$used_int")
  fi
fi

# --- Section 3: session cost ---
cost_section=""
cost=$(json_num "cost")
if [ -n "$cost" ]; then
  cost_num=$(printf '%.2f' "$cost" 2>/dev/null)
  if [ -n "$cost_num" ] && [ "$cost_num" != "0.00" ]; then
    cost_section="\$$cost_num"
  fi
fi

# --- Section 4: session token usage (cumulative, decimal divisor) ---
tokens_section=""
in_tok=$(json_num "total_input_tokens")
out_tok=$(json_num "total_output_tokens")
in_tok_i=$(printf '%.0f' "${in_tok:-0}" 2>/dev/null)
in_tok_i=${in_tok_i:-0}
out_tok_i=$(printf '%.0f' "${out_tok:-0}" 2>/dev/null)
out_tok_i=${out_tok_i:-0}
[ "$in_tok_i" -lt 0 ] && in_tok_i=0
[ "$out_tok_i" -lt 0 ] && out_tok_i=0
total_tok=$(( in_tok_i + out_tok_i ))
if [ "$total_tok" -gt 0 ]; then
  if [ "$total_tok" -ge 1000 ]; then
    tokens_section=$(printf "T:%dk" $(( total_tok / 1000 )))
  else
    tokens_section=$(printf "T:%d" "$total_tok")
  fi
fi

# --- Section 5: open tasks ---
tasks_section=""
task_total=$(json_num "total")
task_completed=$(json_num "completed")
if [ -n "$task_total" ] && [ "$task_total" != "0" ]; then
  completed=${task_completed:-0}
  tasks_section="Tasks ${completed}/${task_total}"
fi

# --- Assemble output ---
parts=()
[ -n "$label" ]        && parts+=("$label")
[ -n "$model" ]        && parts+=("$model")
[ -n "$ctx_section" ]  && parts+=("$ctx_section")
[ -n "$cost_section" ] && parts+=("$cost_section")
[ -n "$tokens_section" ] && parts+=("$tokens_section")
[ -n "$tasks_section" ] && parts+=("$tasks_section")

output=""
for part in "${parts[@]}"; do
  if [ -z "$output" ]; then
    output="$part"
  else
    output="$output | $part"
  fi
done

printf "%b" "$output"
