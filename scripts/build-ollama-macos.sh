#!/usr/bin/env bash
# Build the standalone Ollama MCP server for macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The Ollama MCP macOS build requires macOS." >&2
  exit 1
fi

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [output-directory]" >&2
  exit 2
fi

exec bash "$ROOT/examples/mcp/ollama_worker/build.sh" "$@"
