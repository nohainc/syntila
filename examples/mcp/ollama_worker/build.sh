#!/usr/bin/env bash
# Build the standalone Ollama MCP server for the current machine.
set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [output-directory]" >&2
  exit 2
fi
command -v dart >/dev/null || { echo "Dart SDK is required." >&2; exit 1; }
script_dir="$(cd "$(dirname "$0")" && pwd)"
output="${1:-$script_dir/../../../dist/mcp/ollama-mcp}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
dart compile exe "$script_dir/ollama_worker.dart" -o "$output/ollama-mcp"
printf 'Ollama MCP server: %s\n' "$output/ollama-mcp"
