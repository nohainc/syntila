#!/usr/bin/env bash
# Build the Ollama MCP Worker and package it as an External Worker for
# `syntila workers import`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/examples/mcp/ollama_worker"

if [[ $# -gt 1 ]]; then
  echo "Usage: $0 [output-directory]" >&2
  exit 2
fi

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Darwin-x86_64) platform=darwin-x64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64 | Linux-arm64) platform=linux-arm64 ;;
  *) echo "Unsupported platform: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

output="${1:-$ROOT/dist/workers/ollama-mcp}"
rm -rf "$output"
mkdir -p "$output/bin"
output="$(cd "$output" && pwd)"

build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
bash "$SOURCE/build.sh" "$build" >/dev/null
mv "$build/ollama-mcp" "$output/bin/run"
chmod 755 "$output/bin/run"

sha256="$(shasum -a 256 "$output/bin/run" | cut -d' ' -f1)"
size="$(wc -c < "$output/bin/run" | tr -d ' ')"
sed -e "s/__PLATFORM__/$platform/" \
  -e "s/__SHA256__/$sha256/" \
  -e "s/__SIZE__/$size/" \
  "$SOURCE/plugin.json.template" > "$output/plugin.json"

printf 'Ollama External Worker package: %s\n' "$output"
printf 'Next: syntila workers import %s\n' "$output"
