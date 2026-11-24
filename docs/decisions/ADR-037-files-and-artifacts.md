# ADR-037: Request files and artifact handoff between Workers

- **Status:** Accepted and implemented
- **Date:** 2026-11-19, revised 2026-11-24
- **Depends on:** ADR-034, ADR-035
- **Related:** ADR-044 (device folders), [Input Delivery](../specifications/INPUT_DELIVERY_V1.md)

## Context

Workers in one Thread may run on different computers and share no filesystem.
Files must move between people, Cloud and Workers without Cloud ever seeing a
local path.

## Decision

1. **Request files.** A person's attachments are uploaded to R2 before any Step
   starts. Any Worker that runs a Step of the request downloads them with its
   own session, checks size and SHA-256, keeps a private copy and places them
   at `.syntila/inputs/<work-request-id>/file-NNN` in its working directory.
   A Worker with no Step on the request cannot download them.
2. **Handoff between Steps uses artifacts only.** A Step's declared outputs are
   uploaded to R2 with checksum, size and type limits, retention and a scoped
   owner. Later Steps reference **artifact IDs** (or Git repository, commit and
   branch references) and download with an expiring grant bound to the
   artifact and the Worker.
3. A handoff by local path is refused with a "missing artifact" error.
4. **Output images, audio and video** a Worker made for the user are uploaded
   with the result and shown in the Thread; audio and video play from
   short-lived signed links.
5. Retention: expired artifacts and their objects are removed by the outbox
   sweep; spent download grants are dropped.

## Consequences

- Workflows that span computers (for example macOS to Linux) are correct by
  construction.
- Every transfer is authorized on the server; quotas and size limits are shared
  with Thread files.
