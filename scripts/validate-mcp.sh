#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Resolve and validate the protocol and its direct MCP consumers.
for pkg in packages/syntila_mcp_protocol packages/syntila_worker_protocol packages/syntila_cli_worker_runtime packages/syntila_plugin_conformance engines/cli_worker; do
  (
    cd "$pkg"
    dart pub get
    dart analyze
    case "$pkg" in
      packages/syntila_mcp_protocol) dart test ;;
      packages/syntila_worker_protocol) dart test test/execute_mcp_servers_test.dart ;;
      packages/syntila_cli_worker_runtime) dart test test/mcp_tool_call_supervisor_test.dart ;;
      packages/syntila_plugin_conformance) dart test test/mcp_conformance_test.dart ;;
      engines/cli_worker)
        dart run tool/prepare_plugin_test_binaries.dart
        dart test --concurrency=1 test/mcp*_test.dart test/engine_mcp_config_test.dart ;;
    esac
  )
done
(
  cd packages/syntila_plugin_sdk
  dart pub get
  dart analyze
  dart test
)
(
  cd apps/workspace
  dart pub get
  dart test --concurrency=1 test/mcp*_test.dart test/workspace_manager_mcp_test.dart
)
pnpm exec vitest run --maxWorkers=4 packages/workspace-runtime-protocol/test packages/tool-profile/test apps/cloud/test/mcp-tool-call-gateway.test.ts apps/cloud/test/mcp-tool-dispatch-claim.test.ts apps/cloud/test/mcp-tool-step.test.ts apps/cloud/test/workflow-prompts.test.ts apps/cloud/test/execution-engine.test.ts apps/cloud/test/worker-plugins.test.ts
