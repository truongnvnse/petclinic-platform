#!/usr/bin/env bash
# Hook: block-mcp-destroy.sh (PreToolUse on MCP Terraform tools)
# Purpose: Blocks 'destroy' invoked through any MCP Terraform tool. HARD BLOCK.
# Why: block-destroy.sh catches 'terraform destroy' in Bash commands, but an MCP
#      server exposing terraform execution has its own command path that bypasses
#      Bash entirely. This hook closes that gap.
# Note: The current server (hashicorp/terraform-mcp-server) exposes only read-only
#      registry lookups, so this hook is a no-op today — those tools carry no
#      'command' field. The matcher is deliberately broad so any future
#      execute-capable terraform MCP tool is covered without further changes.
# How: Reads the tool input JSON from stdin, checks the 'command' field for destroy.

set -euo pipefail

INPUT=$(cat)

# Extract the command field from the MCP tool input
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# No command field -> read-only tool call, nothing to block
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Block destroy in any form: 'destroy', 'destroy -auto-approve', 'apply -destroy'
if echo "$COMMAND" | grep -qE '(^|[[:space:]])destroy([[:space:]]|$)|-destroy'; then
  echo "BLOCKED: 'destroy' via an MCP Terraform tool is not allowed."
  echo ""
  echo "Destroying infrastructure must be done manually with explicit human oversight."
  echo "Run 'terraform destroy' directly in your terminal (not via Claude Code)."
  exit 2
fi

exit 0
