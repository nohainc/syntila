# Writing a Worker plugin

A plugin is any executable that speaks the
[Worker Plugin Protocol v1](WORKER_PLUGIN_PROTOCOL_V1.md) over stdin and stdout.
This guide is the shortest path from nothing to a plugin that passes the
conformance suite. A plugin runs as the user who installs it, with that user's
files and logins; read the **security notes** before shipping one.

## 1. The package

A package is a directory (or a `.zip`) containing `plugin.json` and the files it
lists:

```text
my-plugin/
  plugin.json
  bin/my-plugin          # the executable for this platform
  plugin.sig             # optional detached Ed25519 signature
```

`plugin.json` (schema in the protocol spec, §10) pins every executable by
SHA-256:

```json
{
  "schemaVersion": 1,
  "pluginId": "my-plugin",
  "version": "1.0.0",
  "displayName": "My Plugin",
  "description": "What it does.",
  "author": { "name": "You" },
  "protocol": { "min": "1.0", "max": "1.0" },
  "artifacts": {
    "linux-x64": {
      "command": "bin/my-plugin",
      "args": [],
      "sha256": "<hex>",
      "size": 123456
    }
  },
  "capabilities": { "progress": true },
  "access": {
    "workRoot": "write",
    "network": { "mode": "none" },
    "subprocess": false,
    "env": []
  }
}
```

Platform keys: `darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`,
`windows-x64`, or `any`. Compute `sha256` and `size` of each artifact with
`shasum -a 256` and `wc -c`. Unknown manifest keys are errors on purpose, so a
typo cannot hide an access declaration. The `access` block is shown to the user
at consent; it is a request, not a sandbox.

## 2. The protocol in ten lines

- Read one JSON object per line from stdin; write one per line to stdout. stdout
  carries protocol frames **only**; log to stderr.
- Answer `hello` with `hello.result` naming your `pluginId` and `version`
  exactly as in the manifest, choosing a protocol the host offered.
- Answer `probe` with `probe.result` (`ready`, `setup_required`,
  `sign_in_required`, `unavailable`, `failed`).
- For `execute`, send optional `progress` frames, then **exactly one** `result`
  or `error` carrying the same `id`.
- On `cancel`, stop and send `error` with code `cancelled` within 5 seconds.
- Answer `ping` with `pong` (any frame you send also counts as liveness).
- On `shutdown` or end of input, exit within 3 seconds.
- Frames are at most 1 MiB; prompt at most 512 KiB; output at most 768 KiB.
- Artifacts in a result are paths relative to the working directory.
- To support sessions, store state under the `dataDir` from `hello`, keyed by the
  `session.key` you receive, and declare `"sessionResume": true`.

## 3. Check it

```sh
dart run syntila_plugin_conformance -- ./my-plugin       # author tool, any language
```

This starts your plugin directly and runs the same 21 cases the Workspace runs
(`packages/syntila_plugin_conformance`). It is free and needs no Syntila
account. A pass means **your plugin speaks the protocol**. It does not mean the
plugin is safe, truthful about its access list or free of malicious behaviour,
and users are never shown it as a security rating.

On a Plus Workspace:

```sh
syntila plugins import ./my-plugin       # copies it into the Workspace store
syntila plugins validate my-plugin       # static checks; runs nothing
syntila plugins test my-plugin           # conformance inside the Engine
syntila plugins register my-plugin       # shows consent, then re-run with --accept <hash>
syntila plugins enable my-plugin         # same, per Workspace
```

Consent is by content: `register` and `enable` print what the user is accepting
and a hash of it; only re-running with that exact `--accept <hash>` proceeds. A
new version or any change to the files changes the digest and needs consent
again. `syntila plugins export my-plugin ./my-plugin.syntila-plugin` writes a
bundle with no credentials, data or logs.

## 4. What Syntila enforces, and what it does not

Enforced by the Engine: the SHA-256 pin (re-checked before every start), a built
environment (only an allow-list plus names the user accepted, never `SYNTILA_*`),
no shell, handshake/heartbeat/cancel/shutdown deadlines, frame-size and
progress-rate limits, redaction of paths and tokens in diagnostics, process-tree
cleanup, and artifact paths that must stay inside the working directory.

**Not enforced:** filesystem, network, memory and CPU limits. A process boundary
is not a sandbox. Today read-only Steps are never routed to plugins because
nothing proves read-only; plugins run Work Steps only.

## 5. Security notes for authors

- Never write secrets to stdout, stderr or files under the working directory.
  Redaction is best effort.
- Treat prompts and files as untrusted input.
- Do not ask users for credentials the plugin does not need; Syntila never stores
  or forwards provider credentials, and your plugin must not either.
- Sign releases if you can. `plugin.sig` is JSON
  `{"alg":"ed25519","keyId":"...","publicKey":"<base64 raw 32 bytes>","signature":"<base64 64 bytes>"}`
  where the signature is over the UTF-8 bytes of the manifest digest (64 hex
  characters). A valid signature proves who built it, not that it is trustworthy.
