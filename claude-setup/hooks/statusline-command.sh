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
label=""
if [ -n "$cwd" ] && [ -f "$cwd/CLAUDE.md" ]; then
  slug=$(sed -n 's/.*\*\*Slug:\*\*[[:space:]]*`\([^`]*\)`.*/\1/p' "$cwd/CLAUDE.md" 2>/dev/null | head -1)
  if [ -n "$slug" ]; then
    label="$slug"
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

# --- Section 4: open tasks ---
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
