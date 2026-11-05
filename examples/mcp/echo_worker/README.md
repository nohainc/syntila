# Echo MCP Worker (reference)

A single-file stdio MCP server that implements the Syntila MCP Worker profile
([MCP_WORKER_PROFILE_V1](../../../docs/specifications/MCP_WORKER_PROFILE_V1.md)):
it advertises `_meta["syntila.worker"] = "1"` and provides `syntila.execute` and
`syntila.probe`. Run it with `dart echo_worker.dart [normal|noexecute|badprobe]`.

The prompt selects behaviour for testing (`FAIL`, `BADCODE`, `SLOW`, `BIGTEXT`,
`ART`, `BADART`, `CRASH`); see the header comment. It is the fixture for
`engines/cli_worker/test/mcp_worker_runner_test.dart`. It is a protocol
reference, not an SDK: an SDK mode (`runMcpWorker`) is still open.
