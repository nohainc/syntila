# MCP Worker operations

Connect imports MCP Worker packages on the owner's computer. Use `syntila-connect mcp-worker` to list, import, test, approve or remove a package. Consult `syntila-connect help` for exact arguments. Approval is tied to the package ID, version and manifest digest; changing the package requires approval again.

Cloud checks the Worker's pin and the owner's entitlement before scheduling custom Worker work. Managing the library is available on all plans, while execution requires the custom Worker entitlement. Connect separately checks the installed package, local approval and tool pins. See [ADR-041](../decisions/ADR-041-mcp-workers-on-worker-agents.md) and [architecture](../architecture/CUSTOM_WORKER_PLUGINS.md).

When a Worker cannot run, check its readiness and diagnostics, the Cloud pin and entitlement, and the locally approved package. Do not automatically delete local package data or widen access. Plugin code runs as the local user; resource limits are not a filesystem or network sandbox. Platform isolation, service lifecycle and deployed end-to-end behavior need device evidence.
