# ADR-037: Local Files, Allowed Folders and Cross-Worker Artifact Handoff

- **Status:** Proposed
- **Date:** 2026-11-19
- **Split from:** ADR-031 (D6, invariants 4 and 10)
- **Order:** 6 of 8. Depends on ADR-034 and ADR-035.

## Context

Workspace Work Roots and Space folders assume a single shared environment. Once Workers run on different hosts, two Workers in the same Thread do not share a filesystem.

## Decision

1. Each Agent owns a private data directory (`.../Syntila/Workers/<worker-id>/`) and an optional **Work Root** set up by the user, with a stable `spaces/<space-id>/` mapping. Paths are never sent to the Cloud. Only opaque folder-capability IDs are sent.
2. **Allowed Folders** protections move unchanged from Workspace to Agent: paths are canonicalized; root, home and app-data overlaps are rejected; symlinks are checked; read and write are separate; everything is re-checked right before execution. Selecting a Worker in the web app never grants folder access.
3. **Handoff between Workers uses explicit artifacts only.** The Agent uploads to R2 with checksum, size and type limits, retention and scoped rights. Downstream steps reference **artifact IDs** (or Git repo, commit or branch references) and download with an expiring, authorized token to a safe local path chosen locally.
4. Handing off by local path between Workers is rejected with a clear "missing artifact" error.
5. Migration keeps existing Workspace Work Roots and folder markers through explicit mapping. User files are never deleted.

## Consequences

- Workflows that span machines (for example macOS to Linux) are correct by construction.
- R2 artifact service: metadata table, size and retention limits, an authorization check on every transfer.
