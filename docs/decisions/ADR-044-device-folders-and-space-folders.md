# ADR-044: Device folders and the Space folder

- **Status:** Accepted and implemented
- **Date:** 2026-11-24 (records a decision implemented in migration `0042`)
- **Depends on:** ADR-034 (Connect), ADR-040 (stateful Work)
- **Replaces:** the per-Worker Work Root and `spaces/<space-id>/` mapping first proposed in ADR-037

## Context

Work that changes files needs a real folder on a real computer, chosen by the
person who owns that computer. Several Workers on one computer should be able to
use the same project folder, and Cloud must never learn a path.

## Decision

1. **Folders belong to the computer (device), not to one Worker.** The person
   allows folders in Connect, each read-only or read-and-write. Every Worker
   paired on that computer may use them.
2. **Cloud sees only an opaque ID, the folder's own name and the access level**
   (`PUT /api/worker-agent/folders`, table `device_folders`), together with the
   device's display name. Never the path.
3. **A Space chooses one folder** (`space_folders`). The choice disappears when
   the person removes the folder in Connect or the Space is deleted. Removing a
   folder from the web app is allowed only while that computer is offline, and
   lists the Spaces that use it first.
4. **Placement.** Work that changes files requires a Space folder with write
   access, and runs only on a Worker on that folder's device
   (`worker_agent_sessions.device_id`). Read-only Steps use the folder if it is
   available and their own scratch folder otherwise.
5. **Re-checked locally.** Connect canonicalizes the path and re-checks it
   against its allowed folders right before every use; a missing or revoked
   folder fails the Step with `folder_not_approved`. Selecting a Worker in the
   web app never grants folder access.
6. **Work Root.** Connect's own scratch area (default `~/Documents/Syntila`)
   holds each assignment's folder; it is never offered as a project folder.
7. A Person Share (ADR-043) never receives any folder.

## Consequences

- A Space's checkout lives on one computer; moving Work elsewhere starts from
  the Git remote.
- An older Connect that does not report its device is not refused at admission;
  it still checks the folder itself.
