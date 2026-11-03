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
