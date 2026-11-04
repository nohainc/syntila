#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT"

dart_packages=(
  packages/dart/protocol
  packages/syntila_worker_protocol
  packages/syntila_plugin_protocol
  packages/syntila_plugin_conformance
  packages/syntila_plugin_sdk
  examples/plugins/ollama_local
  packages/syntila_cli_worker_runtime
  packages/tool_profile_v1
  engines/cli_worker
)

flutter_packages=(
  packages/syntila_design
)

resolve_dart_package_dependencies() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    dart pub get
  )
}

resolve_flutter_package_dependencies() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    flutter pub get
  )
}

# Resolve every package first so local path dependencies and package configs
# exist before formatting, analysis, or tests validate the repository.
for package_path in "${dart_packages[@]}"; do
  resolve_dart_package_dependencies "$package_path"
done

for package_path in "${flutter_packages[@]}"; do
  resolve_flutter_package_dependencies "$package_path"
done

dart format --output=none --set-exit-if-changed "${dart_packages[@]}" "${flutter_packages[@]}"

check_dart_package() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    dart analyze
    if [[ -d test ]]; then
      dart test
    fi
  )
}

for package_path in "${dart_packages[@]}"; do
  check_dart_package "$package_path"
done

check_flutter_package() {
  local package_path="$1"
  (
    cd "$ROOT/$package_path"
    flutter analyze
    flutter test
  )
}

for package_path in "${flutter_packages[@]}"; do
  check_flutter_package "$package_path"
done
