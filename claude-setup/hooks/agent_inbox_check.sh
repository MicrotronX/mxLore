#!/bin/bash
# Agent-Inbox Check Hook (UserPromptSubmit)
# Reads local inbox files written by mxMCPProxy background thread.
# Outputs message details directly so Claude can act without extra MCP call.
# No network calls - only local file reads (0ms latency).

INBOX_DIR="$HOME/.claude/agent_inbox"

# Exit silently if no inbox directory
[ -d "$INBOX_DIR" ] || exit 0

# Detect own project slug from CLAUDE.md in current directory
MY_PROJECT=""
if [ -f "CLAUDE.md" ]; then
  MY_PROJECT=$(grep -o 'Slug:\*\*.*' CLAUDE.md 2>/dev/null | head -1 | sed 's/.*Slug:\*\*[[:space:]]*//' | sed 's/`//g' | sed 's/[[:space:]]*$//')
fi

# No project detected = no filtering possible, exit silently
[ -z "$MY_PROJECT" ] && exit 0

# Only read OUR project's inbox file
f="$INBOX_DIR/agent_inbox_${MY_PROJECT}.json"
[ -f "$f" ] || exit 0

# Read file content, strip BOM if present
content=$(sed '1s/^\xEF\xBB\xBF//' "$f" 2>/dev/null) || exit 0
[ -z "$content" ] && exit 0

# Output the raw JSON for Claude to parse (Claude is better at JSON than bash)
echo "[Agent-Inbox] Messages for ${MY_PROJECT}:"
echo "$content"
echo "Act on these as their content requires, then: mx_agent_ack"
echo "A reply is NOT the default. Send one only if the sender needs a decision, an answer, or a correction from you. Acknowledging without replying is the normal case and ends the exchange."
echo "When YOU send: silence back means 'handled, nothing needed'. If you need confirmation that it was processed, ask for it in the message itself - there is no read receipt."

# Delete file after reading
rm -f "$f"
