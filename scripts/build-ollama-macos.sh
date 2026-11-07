#!/usr/bin/env bash
# Builds the Ollama Local plugin package for macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/examples/mcp/ollama_worker"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Syntila Ollama Local plugin build requires macOS." >&2
  exit 1
fi

if [[ $# -ne 0 ]]; then
  echo "Models are discovered at runtime; build without a model argument." >&2
  exit 2
fi

if ! command -v ollama >/dev/null 2>&1; then
  echo "Ollama is required to build and configure the plugin. Install Ollama first." >&2
  exit 1
fi

if ! command -v dart >/dev/null 2>&1; then
  echo "The Dart SDK is required. Ensure 'dart' is available in PATH." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is required. Ensure 'node' is available in PATH." >&2
  exit 1
fi

exec bash "$PLUGIN_DIR/build.sh" "$@"
