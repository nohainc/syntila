#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

engine_packages=(
  packages/syntila_worker_protocol
  packages/syntila_plugin_protocol
  packages/syntila_plugin_conformance
  packages/syntila_mcp_protocol
  packages/tool_profile_v1
  packages/syntila_cli_worker_runtime
  engines/cli_worker
)

for pkg in "${engine_packages[@]}"; do
  echo "==> Validating $pkg"
  (
    cd "$ROOT/$pkg"
    dart pub get
    FORMAT_TARGETS=()
    if [[ -d lib ]]; then FORMAT_TARGETS+=(lib); fi
    if [[ -d test ]]; then FORMAT_TARGETS+=(test); fi
    if [[ -d bin ]]; then FORMAT_TARGETS+=(bin); fi
    if [[ ${#FORMAT_TARGETS[@]} -gt 0 ]]; then
      dart format --output=none --set-exit-if-changed "${FORMAT_TARGETS[@]}"
    fi
    dart analyze
    if [[ -f tool/prepare_plugin_test_binaries.dart ]]; then
      # Compile the shared plugin test binaries serially, before the tests
      # start, so process-spawning tests are not starved of CPU.
      dart run tool/prepare_plugin_test_binaries.dart
    fi
    if [[ -d test ]] && find test -name "*_test.dart" -print -quit | grep -q .; then
      if [[ "$pkg" == engines/cli_worker ]]; then
        # These tests start real Engine/provider processes with bounded startup
        # deadlines. Parallel JIT startups can starve each other on busy hosts.
        dart test --concurrency=1
      else
        dart test
      fi
    fi
  )
done

echo "==> Engine validation passed."
