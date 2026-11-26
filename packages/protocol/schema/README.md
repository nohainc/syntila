# Syntila protocol schema

This directory contains the canonical, language-neutral JSON Schema for the
product message envelope, execution error vocabulary, Connect message
metadata, and realtime event metadata. It does not define Agent, IPC, Worker
Plugin, or Local Worker Protocol messages.

Protocol versions use `major.minor.patch`:

- a different major is incompatible and must be rejected during handshake;
- a higher minor may add optional fields and remains readable by older peers;
- patch changes do not alter the contract.

TypeScript and Dart bindings are generated from this schema by
`scripts/generate-protocol-bindings.mjs` and checked by
`scripts/verify-protocol-bindings.mjs`. Local Worker Protocol 4.0 is defined
and validated only in `packages/syntila_worker_protocol`.
