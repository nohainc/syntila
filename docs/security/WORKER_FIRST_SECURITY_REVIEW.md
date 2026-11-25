# Worker-first security review checklist (P11)

Status: **checklist only; no item has been reviewed yet.** Each line names what to check and where the code or tests live. Mark it with the date, the reviewer and the evidence when done.

## Tickets (human realtime)
- [ ] Single use, short expiry, bound to the user; replay refused. (`routes/realtime*`, `realtime-gateway.ts`, tests `realtime-*`)
- [ ] A ticket cannot open a Worker scope, and a Worker key cannot open a human scope (`messaging/principal.ts`, `test/messaging.test.ts`).

## Worker keys and pairing (ADR-034)
- [ ] Pairing challenge: single use, 10-minute expiry, only its digest is stored (`worker-agents.ts`, `test/domain/worker-pairing*`).
- [ ] The private key never leaves the host; every request signs a server nonce; nonces are consumed in their own statement (replay refused even after a failed attempt).
- [ ] Revoking a Worker closes its sessions and assignments immediately, on every node (`assignment-revocation.ts`, `messaging/session.ts`). Revocation outside space events is still open (see P9 status).
- [ ] Rotating the credential invalidates the old key.

## Session fencing
- [ ] Writes from an older session epoch are rejected everywhere an Agent can write (`agent-session-fence.ts`); list every Agent write path and confirm each calls it.
- [ ] A cloned installation (copied key) is detected or its blast radius is documented (open item from P4).

## Rate limits and abuse budgets
- [ ] Per-principal limits for human, Worker and system scopes are separate (`messaging/principal.ts`); a noisy Worker cannot starve humans.
- [ ] Frame size, queue length, subscription count and artifact quota budgets are enforced before work is done, not after.
- [ ] Artifact upload: size, checksum, quota and retention; download grants are scoped to the step's Agent and expire after 15 minutes (`artifacts.ts`).

## Files and folders
- [ ] An Agent never reads or writes outside granted folders, including through symlinks and `..` (`folders.dart`, `test/folders_artifacts_test.dart`).
- [ ] No local path is stored in or sent to Cloud (grep the payloads and `worker_assignments`).

## Cutover
- [ ] After `close-gateway`, no Worker credential still authorizes anything (`legacy-cutover.ts`; check the runtime routes that remain: inputs, outputs, ownership).
