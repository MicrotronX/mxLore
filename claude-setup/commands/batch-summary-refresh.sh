#!/bin/bash
# Batch Summary-Refresh via claude --bare
# Usage: bash ~/.claude/commands/batch-summary-refresh.sh [project-slug]
PROJECT="${1:-mxLore}"
claude -p --bare "Rufe mx_refresh_summaries(project='$PROJECT') auf und melde das Ergebnis."
