# Worker Agent: CLI, local state, reconnect and services

Implements the client side of ADR-034 (Worker-first P4). Package: `apps/worker_agent` (`syntila_worker_agent`, binary `syntila-worker`). Server side: `WORKER_PAIRING_AND_SESSIONS.md`. Runtime design: `WORKER_AGENT_RUNTIME_V1.md`.

## What is in the package

| Piece | File | Notes |
| --- | --- | --- |
| Data directory | `paths.dart` | `<application-data>/Syntila/Workers/<worker-id>/` with `identity/ config/ profiles/ registry/ commands/ sessions/ traces/ engine/` |
| Local lock | `lock.dart` | Exclusive file lock plus an in-process registry (POSIX locks are per process). A second owner is refused before the server's fence is reached. |
| Key store | `identity.dart` | Ed25519 key in `identity/key.json` (0600, atomic write). The private key never leaves the host. `KeyStore` is an interface for a platform secret-store adapter. |
| Journal | `journal.dart` | JSON lines, `flush()` (fsync) on every record. States `received → accepted → starting → running → terminal → acknowledged`; only forward moves. A partial last line is repaired, any other damage fails closed. |
| Profile cache | `profile_cache.dart` | Content-addressed, re-hashed on read, last-known-good pointer; a bad update never replaces a good one. The signature check is an injected `ProfileVerifier`. |
| Readiness | `readiness.dart` | Named checks; a throwing check is a failure. Reason codes only. |
| Allowed folders | `folders.dart` | Canonical paths, opaque ids, refuses roots, home, its parents and Syntila application data. |
| Engine supervisor | `engine.dart` | Bounded slots per Agent; an assignment is launched at most once; the start is recorded before the launch call. |
| Connection | `connection.dart` | Reconnect sequence below; jittered exponential delay; stops on 401/404/410. |
| Runtime | `runtime.dart` | Admission, replay, cancel intents, start permits, terminal delivery, crash recovery. |
| Pairing | `pairing.dart` | `install`, `rotateCredential` (+ recovery), `uninstall`. |
| Services | `services.dart` | launchd, systemd, Windows Task Scheduler (ADR-021) adapters; separate OS user plan. |
| Updates | `update.dart` | Signed manifest + hash check, no downgrade, no http, atomic staging. |
| CLI | `cli.dart` | `install --pairing-code`, `run`, `status`, `logs`, `config`, `permissions`, `rotate-credential`, `update stage`, `uninstall`. |

## Pairing code

`syntila-pair:v1:<base64url(json)>` with `{s: serverUrl, w: workerId, c: challengeId, k: secret}`. It is shown once by the owner's device (the P6 Workers page; until then it can be assembled from `POST /api/workers/:id/pairing`). The secret is never put in a URL or printed by the CLI. The code must name an `https` server (plain `http` only for loopback). `install` generates the key pair, signs `pairingMessage(challengeId, workerId, publicKey)`, and claims. If the claim fails nothing stays on disk; a crash leaves a `pairing.pending` marker that the next `install` cleans up.

## Reconnect sequence

1. **Claim the epoch:** request a nonce, sign `actionMessage('session', …)`, create the session (the server increments the epoch).
2. Open `/api/workspace-gateway/connect?workerId=…&workerSessionId=…` with `Authorization: Bearer <sessionToken>`; send `workspace.hello`; wait for `workspace.hello.ack`.
3. **Report the journal:** `workspace.sync.request` with `unreconciledAssignmentIds` (every journal entry not yet acknowledged).
4. **Reconcile** with `workspace.sync.result`: an entry the server already ended is closed locally (a running Engine is stopped); an entry unknown to the server is settled without sending.
5. Only then `ready`: commands that arrived meanwhile are released, unacknowledged terminal results are re-sent, and admitted work that never started is started.

A late command for a known assignment is answered from the journal and never starts another Engine.

## Recovery rules

- `received` without acknowledgement → admitted again. `accepted` → started after sync, once.
- `starting` or `running` after a crash → an Engine may exist, so the attempt is **never restarted**. It ends as `failed` (`agent_restarted`, retryable) and the server retries as a new attempt. Orphaned Engines are stopped first (`recoverOrphans`).
- `terminal` not acknowledged → re-sent until acknowledged; the server's terminal write is idempotent.
- A cancel for an unknown assignment is journaled as cancelled, so the command can never run when it arrives later. A cancel while a start permit is pending withdraws the wait.

## Service lifecycle

Every Agent gets its own service (name and data directory per Worker id). **Auto-start is opt-in** (`install --auto-start` or `config set autoStart true`): launchd `RunAtLoad`, `systemctl enable`, a Task Scheduler logon trigger. Without it the unit is installed and does nothing at boot. Windows values travel only as environment variables, never spliced into script text. The provider CLI is started by the Engine on demand, never by the service.

## Signed updates

`update stage --manifest M --artifact A`: the manifest signature (domain `syntila-worker-update/v1`) must verify against a compiled-in release key (`--define=SYNTILA_UPDATE_KEYS=k1,k2`; none configured means every update is refused), the artifact must match `sha256`, the version must be newer, the URL must be `https`. Verified bytes are staged atomically under `engine/updates/`. Swapping the running executable is the service manager's restart step and is not implemented here.

## Separate OS user (isolation limits)

`install --separate-user NAME` installs a system-scope service that runs as that user and prints the commands an administrator runs to create it. The Agent never elevates itself. Windows needs an administrator-created task and is not automated.

Agents under the same OS user can read each other's data directories and share the provider CLIs' stored logins. A separate user closes that for files and credentials. It does not isolate CPU, memory, the network or folders the Agent is allowed to use. Use containers or VMs for stronger isolation.

## Not done in P4

- **Engine adapter is written but unproven.** `CliEngineLauncher` (`cli_engine.dart`) runs assignments through `CliWorkerEngineSupervisor.execute` with the pinned Profile, stateless sessions and `restricted` access; set `config set engineExecutable PATH` (and optionally `workRoot`). It was never compiled or run against a real Engine. Not carried over from the Workspace: durable sessions, additional folders, MCP servers, plugin Workers, input staging, progress and activity streaming. The payload keys that name the Profile (`profileDigest`, `workerTypeId`, `profileRevision`) are provisional until P5 defines the execution snapshot. Without `engineExecutable`, `run` reports `engine_unavailable` and refuses work.
- **Profile delivery:** nothing downloads or verifies a Profile into the cache yet (signed Tool Profile trust roots, refresh from the server). The cache rejects every write from the CLI, so with an empty cache every assignment fails with `worker_not_ready`.
- **Platform secret store** for the key (macOS Keychain, Windows DPAPI, libsecret). The key is a private file today.
- **Readiness publication** (`workspace.readiness`, inventory) and MCP, plugins, input delivery, outputs (parity items 7 to 10, 17 of the P0 inventory).
- **Swap of the running binary** for staged updates; Windows separate user.
- Until P5 the gateway adapter allows one Agent per Workspace gateway.
