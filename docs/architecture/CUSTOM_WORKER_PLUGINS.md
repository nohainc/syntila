# Custom Worker plugins: architecture, entitlement and trust

MCP Workers run local packages through the generic CLI Worker Engine plugin host. Connect imports the package and records the owner's approval of the exact ID, version and manifest digest. Connect probes the package through the Engine, records tool pins and admits an assignment only when the installed package, approval and pins match. See [ADR-041](../decisions/ADR-041-mcp-workers-on-worker-agents.md) and the [plugin protocol](../specifications/WORKER_PLUGIN_PROTOCOL_V1.md).

Cloud stores account library metadata and the pin associated with a Worker. The Worker reports readiness through Connect. During eligibility Cloud checks the owner's entitlement and the selected pin; the assignment snapshots the pin. A changed package requires fresh local approval. Cloud does not install the package or receive provider credentials.

## 3. Entitlement design

Library management is available on all plans; execution of custom MCP Workers requires the owner's entitlement. Eligibility is checked on Cloud before dispatch. Local approval is independently required and does not grant Cloud authorization.

## Security boundary

Plugin output is untrusted. A package runs under the local user's permissions and must not be described as isolated from that user's files or credentials. Platform isolation and service claims need device evidence. Direct MCP tool calls for other Workers are a separate deferred capability; see [ADR-028](../decisions/ADR-028-mcp-integration.md).
