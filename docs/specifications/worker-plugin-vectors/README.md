# Worker plugin manifest digest vector

`manifest-mcp.json` is a `kind: "mcp"` plugin manifest and `manifest-mcp.sha256` its
expected `manifestDigest` (canonical JSON: keys sorted, no insignificant whitespace).
The same manifest without the `kind` key has a different digest (`1bb61d41…`), so the
vector proves `kind` is part of the canonical form. Any implementation of the digest
(Cloud's `apps/backend/src/domain/plugin-manifest-digest.ts`, the Dart SDK, Connect)
must produce the value in the file. See
[Worker plugin package and manifest](../WORKER_PLUGIN_PROTOCOL_V1.md).
