#!/usr/bin/env bash
# Hook: block-dangerous-rm.sh (PreToolUse on Bash)
# Purpose: Blocks 'rm -rf' on critical infrastructure directories.
# Why: Accidentally deleting terraform/, k8s/, or .github/ means
#      losing all infrastructure code. Git can recover it, but the blast radius
#      of an accidental 'rm -rf terraform/' is too high to leave unguarded.
# How: Splits the command line into individual commands, then checks each 'rm'
#      against its own arguments only. Exits 2 to deny execution.
#
# Note: messages are written to stderr. Claude Code reads a blocking hook's
#       explanation from stderr; anything on stdout is discarded and the user
#       only sees "No stderr output" instead of the reason for the block.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Protected directories — these contain all our infrastructure code
PROTECTED_DIRS="terraform k8s helm helm-values .github docs scripts .claude"

# Split the command line into individual commands before matching. Judging the
# whole line at once caused false positives: `rm -rf /tmp/scratch && sed -n 1p
# terraform/main.tf` was blocked even though the rm never touched terraform/.
# The split is textual, so a protected path hidden inside quotes or command
# substitution could still slip through — it is a safety net, not a sandbox.
SEGMENTS=$(printf '%s' "$COMMAND" \
  | tr '\n' ';' \
  | sed -e 's/&&/;/g' -e 's/||/;/g' -e 's/|/;/g' -e 's/;/;\n/g')

while IFS= read -r segment; do
  [ -z "$segment" ] && continue

  # Does THIS command invoke rm with recursive and/or force flags?
  echo "$segment" | grep -qE '(^|[[:space:];&])rm[[:space:]]+(-[a-zA-Z]*[rRfF][a-zA-Z]*[[:space:]]+|--recursive|--force)' || continue

  for dir in $PROTECTED_DIRS; do
    # Match the protected directory as a whole path segment of this rm's
    # arguments: terraform, ./terraform, /path/terraform/, but not
    # terraform-backup/ or terraform.tfstate.
    if echo "$segment" | grep -qE "(^|[[:space:]/])\.?/?${dir}(/|[[:space:]]|$)"; then
      {
        echo "BLOCKED: Cannot 'rm' the '${dir}/' directory."
        echo ""
        echo "This directory contains critical infrastructure code."
        echo "If you need to remove specific files, delete them individually."
        echo "If you need to reset the directory, use 'git checkout -- ${dir}/'."
      } >&2
      exit 2
    fi
  done
done <<< "$SEGMENTS"

# Allow all other commands
exit 0
