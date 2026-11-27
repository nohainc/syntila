# Worker plugin package and manifest

**Decision:** [ADR-027](../decisions/ADR-027-custom-worker-plugins.md) and
[ADR-028](../decisions/ADR-028-mcp-integration.md). **Architecture and trust:**
[Custom Worker plugins](../architecture/CUSTOM_WORKER_PLUGINS.md). **Host:** the generic
CLI Worker Engine's plugin host (never the `syntila` CLI, never Cloud).

A custom Worker is a local MCP server package. The wire protocol is the
[Syntila MCP Worker profile](MCP_WORKER_PROFILE_V1.md) over the
[MCP host](MCP_HOST_V1.md); the earlier NDJSON stdin/stdout plugin protocol no longer
exists and the Engine does not speak it. This document defines what remains common to
every plugin package: the manifest (`plugin.json`), the environment the host builds,
and redaction. Authoring steps are in the
[author guide](WORKER_PLUGIN_AUTHOR_GUIDE.md); keywords MUST, SHOULD and MAY follow
RFC 2119.

## Package

```text
my-plugin/
  plugin.json
  bin/my-plugin          # the executable for this platform
  plugin.sig             # optional detached Ed25519 signature
```

## Manifest (`plugin.json`)

The manifest is public, small and versioned independently of the Worker profile.

```json
{
  "schemaVersion": 1,
  "kind": "mcp",
  "pluginId": "acme-reviewer",
  "version": "1.4.2",
  "displayName": "Acme Reviewer",
  "description": "Code review against Acme's internal rules.",
  "author": { "name": "Acme Platform Team", "contact": "plugins@acme.example" },
  "protocol": { "min": "1.0", "max": "1.0" },
  "artifacts": {
    "linux-x64":   { "command": "bin/reviewer", "args": [], "sha256": "<64 hex>", "size": 4821032 },
    "darwin-arm64":{ "command": "bin/reviewer", "args": [], "sha256": "<64 hex>", "size": 4790112 }
  },
  "capabilities": { "progress": true, "sessionResume": false },
  "access": {
    "workRoot": "write",
    "network": { "mode": "declared", "hosts": ["api.acme.example"] },
    "subprocess": false,
    "env": ["ACME_ENDPOINT"]
  },
  "limits": { "maxConcurrent": 1, "memoryMiB": 1024 },
  "requires": [],
  "license": "Apache-2.0",
  "homepage": "https://example.com/acme-reviewer"
}
```

Constraints (checked by `plugins validate`):

- `schemaVersion` is `1`. Unknown top-level keys are an error, so a typo cannot hide
  an access declaration. Strings have length caps; `description` is at most 512
  characters. `kind` is `"mcp"`, and `protocol.min`/`max` then bound the Worker-profile
  range (`1.x`).
- Platform keys: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`,
  `windows-x64`, or `any` for a package identical on every platform.
- `command` is a normalised relative path inside the package (no `..`) to a file that
  `artifacts` hashes (`sha256`, `size`). `args` is a fixed array of strings with no
  shell expansion and no template substitution.
- `requires` names external tools the artifact needs (for example `node`, `python3`).
  The host resolves them with the Engine's bounded executable search and shows the
  path and version at consent. The interpreter is not covered by the digest
  (a documented risk).
- `access` is a request shown at consent, not a permission model or a sandbox.
- `manifestDigest` is the digest of the canonical manifest (keys sorted, no
  insignificant whitespace, the repository's canonical-JSON rule), including `kind`
  ([digest vector](worker-plugin-vectors/README.md)). Consent is by content: a new
  version or any file change changes the digest and needs consent again.
- An optional `plugin.sig` is JSON `{"alg":"ed25519","keyId":"…","publicKey":"<base64
  raw 32 bytes>","signature":"<base64 64 bytes>"}` over the UTF-8 bytes of the manifest
  digest (64 hex characters). A valid signature shows who built the package, not that
  it is trustworthy.

## Environment and credentials

The host builds the environment instead of inheriting it: the Engine's provider-neutral
allow-list (a `PATH` subset, `HOME`, locale, temp directory) plus the names in the
manifest `env` that the user accepted at consent, minus every `SYNTILA_*` variable. The
plugin may use the user's own logins in the home directory, as provider CLIs do;
Syntila does not store, forward or manage them, and never sends the plugin a Syntila
credential, the Cloud runtime token or an entitlement lease.

## Redaction

The host redacts before anything leaves the Engine (Service logs, diagnostics,
progress and activity forwarded to Cloud, and error text):

1. Absolute local paths become `<path>` (see [Diagnostic events](DIAGNOSTIC_EVENTS_V1.md)).
2. Every value of an environment variable the host passed to the plugin, and common
   token patterns (bearer and basic headers, API-key prefixes, PEM private-key blocks,
   cloud-provider key shapes), become `<redacted>`.
3. This applies to stderr, progress messages, activity fields, error messages and probe
   messages. It does not apply to a result's output or artifact contents, which are the
   user's work product; the host only counts pattern matches as a diagnostic flag.
4. Redaction is best-effort pattern matching, not a guarantee. Plugins MUST NOT log
   secrets.
