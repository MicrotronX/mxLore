#!/bin/bash
# Batch Health-Check via claude --bare (kein Hook/Plugin-Overhead)
# Usage: bash ~/.claude/commands/batch-health.sh [project-slug]
PROJECT="${1:-mxLore}"
claude -p --bare "Fuehre /mxHealth --loop fuer Projekt $PROJECT aus. Nur Findings ausgeben, kein Report-Header."
