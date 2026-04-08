#!/bin/bash
# Batch Save via claude --bare (kein Hook/Plugin-Overhead)
# Usage: bash ~/.claude/commands/batch-save.sh [project-slug]
PROJECT="${1:-mxLore}"
claude -p --bare "Fuehre /mxSave --loop fuer Projekt $PROJECT aus. Skip wenn nichts geaendert."
