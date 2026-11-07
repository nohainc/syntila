# MCP Protocol Golden Vectors

Transcripts for MCP JSON-RPC 2.0 framing and session exchanges ([MCP_HOST_V1.md](../MCP_HOST_V1.md)).
One frame per line; `→` lines are host-to-server and `←` lines are server-to-host in the `.transcript` files.
Strip the two-character prefix (`→ ` or `← `) to get the standard JSON-RPC 2.0 frame.
The `.expect` file beside each transcript states the expected outcome an implementation must reach.

| Vector | Description | Expected Outcome |
| --- | --- | --- |
| `valid-handshake-tools` | Standard initialize handshake, notifications/initialized, and tools/list query | `ok` |
| `valid-call-progress` | tools/call request with progressToken, notifications/progress event, and terminal result | `ok` |
| `valid-cancelled` | tools/call interrupted by notifications/cancelled, answered with error code | `cancelled` |
| `invalid-two-results` | Two terminal result frames for the same request ID: protocol violation | `mcp_protocol_violation` |
| `invalid-unknown-method` | Server correctly answers unknown method with standard JSON-RPC -32601 error | `method_not_found` |
| `invalid-stdout-noise` | Non-JSON text frame emitted by server: protocol violation (parse error) | `mcp_protocol_violation` |
