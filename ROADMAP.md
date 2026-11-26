# Syntila Roadmap

What is still open. The system as built is described in
[ARCHITECTURE.md](ARCHITECTURE.md); decisions are in
[docs/decisions](docs/decisions/README.md). Finished work is removed from this
file, not archived.

## Now

Release setup (the `prod-*.sh` scripts, Windows Connect on GitHub) is done;
what remains before the first release:

1. **Production rehearsal.** Install the Profile signing key on the VPS, run
   `scripts/prod-deploy-all.sh --site`, then the smoke test and the resilience
   test in [Production provisioning](docs/operations/PRODUCTION_PROVISIONING.md#first-release-rehearsal).
2. **Windows Connect check.** Install the release on a Windows computer, pair a
   Worker to production and run a Chat.
3. **Finish the cleanup.** Leftover "Workspace" wording in code and old
   records in `docs/`; no user-facing text says "Workspace".

## Before the first test release

- Device evidence for Connect on macOS, Linux and Windows: login services
  (launchd, systemd user unit, Windows logon task) and credential stores.
- Real provider runs end to end: Chat, Work with a Space folder, files,
  artifact handoff between two computers, crash and reconnect.
- Security review checklist ([Worker-first security review](docs/security/WORKER_FIRST_SECURITY_REVIEW.md)).
- A baseline of idle and active load before production.

## Later

- **Connect updates.** Manual install and update today; a signed update
  channel is a later decision (ADR-034).
- **Horizontal scaling.** Gated on measured load
  ([ADR-039](docs/decisions/ADR-039-horizontal-scaling.md),
  [Scaling decision](docs/operations/SCALING_DECISION.md)).
- **Offline queueing** of requests for a Worker that is offline (rejected
  today, ADR-035).
- **MCP tool calls on Connect.** Direct `tool_call` steps and attaching MCP tool
  servers to official Workers on Syntila Connect (deferred after legacy path
  removal; ADR-028 covers MCP Workers only).

## Planning rules

- Read `ARCHITECTURE.md` and the relevant ADRs before changing a contract.
- A change that alters a decision updates its ADR in the same change; a
  replaced decision is deleted.
- Implementation alone does not close acceptance: record executable evidence.
