# MCP server manifest v1 (draft)

**Status:** Draft. Extends the [plugin manifest](WORKER_PLUGIN_PROTOCOL_V1.md#10-manifest-pluginjson)
(`schemaVersion` 1, strict keys, same canonical-JSON `manifestDigest`).

## Additional / changed fields

| Field | Rule |
| --- | --- |
| `kind` | `"mcp"` (absent = legacy NDJSON plugin) |
| `class` | `"tool"` or `"worker"`; required when `kind` is `mcp` |
| `mcp.transport` | `"stdio"` (packaged local) or `"http"` (remote) |
| `mcp.protocolVersions` | non-empty subset of Syntila's supported list |
| `mcp.endpoint` | `http` only: `https://` URL, no credentials in URL |
| `mcp.auth` | `none`, `bearer` (token from local store), or `oauth` |
| `artifacts` | required for `stdio` (digest-pinned, as for plugins); forbidden for `http` |
| `tools` | optional declared tool names; consent shows them; actual `tools/list` must be a subset |
| `capabilities.worker` | `class: worker` only: `{ "models": bool, "sessionResume": bool, "progress": bool }` |
| `limits` | may lower host defaults in MCP host v1 §3, never raise |

Remote (`http`) servers have no artifact digest; their trust anchor is the
endpoint allowlist entry plus per-tool definition hashes recorded at consent.
The consent document (hashed, `--accept <hash>`) includes endpoint, auth
method, data scope declaration and tool hashes.
