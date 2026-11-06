# Worker Plugin Protocol golden vectors

Transcripts for [Worker Plugin Protocol v1](../WORKER_PLUGIN_PROTOCOL_V1.md).
One frame per line; `→` lines are host-to-plugin and `←` lines are
plugin-to-host in the `.transcript` files. Strip the two-character prefix to
get the NDJSON. The `.expect` file beside each transcript states the outcome an
implementation must reach. Implementers of non-Dart codecs can replay these
without the conformance runner. They test framing and ordering only, not safety.

| Vector | Outcome |
| --- | --- |
| `valid-minimal` | Handshake, passive probe, one execute with a single result, shutdown |
| `invalid-two-terminals` | Two terminal frames for one execute: host reports `plugin_protocol_violation` |
| `invalid-stdout-noise` | A non-JSON line on stdout: host reports `plugin_protocol_violation` |
| `valid-cancel` | Cancel answered with `error` code `cancelled` inside the grace |

## `manifest-mcp.json` / `manifest-mcp.sha256` (manifest digest, MCP Worker)

A `kind: "mcp"` manifest (ADR-028) and its expected pin. The same manifest without the
`kind` key has the long-standing NDJSON digest `1bb61d41...`, so this vector proves the new
key is part of the canonical form. Cloud (`apps/cloud/test/worker-plugins.test.ts`), the Dart SDK
(`packages/syntila_plugin_sdk/test/manifest_digest_vector_test.dart`) and the Workspace
(`apps/workspace/test/plugin_manifest_digest_vector_test.dart`) each compute the digest and
must equal the file.

