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
| CLI | `cli.dart` | `status`, `pair --pairing-code`, `unpair --yes`, `run`, `service`, `folders`, `mcp-worker`, `config`, `logs`, `rotate-credential`, `version`. |

## Pairing code

`syntila-pair:v1:<base64url(json)>` with `{s: serverUrl, w: workerId, c: challengeId, k: secret}`. It is shown once by the owner's device (the P6 Workers page; until then it can be assembled from `POST /api/workers/:id/pairing`). The secret is never put in a URL or printed by the CLI. The code must name an `https` server (plain `http` only for loopback). `pair` generates the key pair, signs `pairingMessage(challengeId, workerId, publicKey)`, and claims. If the claim fails nothing stays on disk; a crash leaves a `pairing.pending` marker that the next `pair` cleans up.

## Reconnect sequence

1. **Claim the epoch:** request a nonce, sign `actionMessage('session', …)`, create the session (the server increments the epoch).
2. Open `/api/workspace-gateway/connect?workerId=…&workerSessionId=…` with `Authorization: Bearer <sessionToken>`. With `worker_target_dispatch` enabled the server routes the Agent to its own Worker gateway; otherwise it uses the mapped Workspace compatibility gateway. Send `workspace.hello` and wait for `workspace.hello.ack`.
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

Every Agent gets its own service (name and data directory per Worker id). **Auto-start is opt-in** (`pair --auto-start` or `config set autoStart true`): launchd `RunAtLoad`, `systemctl enable`, a Task Scheduler logon trigger. Without it the unit is installed and does nothing at boot. Windows values travel only as environment variables, never spliced into script text. The provider CLI is started by the Engine on demand, never by the service.

## Signed updates

`update stage --manifest M --artifact A`: the manifest signature (domain `syntila-worker-update/v1`) must verify against a compiled-in release key (`--define=SYNTILA_UPDATE_KEYS=k1,k2`; none configured means every update is refused), the artifact must match `sha256`, the version must be a newer three-part version, and the URL must use HTTPS without credentials or a fragment. Verified bytes and the signed manifest are staged under `engine/updates/`. `readVerifiedStaged` checks the signature and digest again before any future activation and rejects symlink artifacts. Older pending metadata without a signed manifest must be staged again. Swapping the running executable is not implemented here.

Staging limits artifacts to 256 MiB, restricts the update directory on POSIX, and refuses existing temporary files instead of following or overwriting them. An interrupted temporary file must be inspected and removed before retrying.

`update prepare` revalidates the staged release and creates a private, version-and-digest-named executable under `engine/updates/releases/`. Repeated preparation verifies the existing file before reuse. Preparation does not change service registration or start the new executable; activation, restart and rollback remain open.

## Separate OS user (isolation limits)

`pair --separate-user NAME` installs a system-scope service that runs as that user and prints the commands an administrator runs to create it. The Agent never elevates itself. Windows needs an administrator-created task and is not automated.

Agents under the same OS user can read each other's data directories and share the provider CLIs' stored logins. A separate user closes that for files and credentials. It does not isolate CPU, memory, the network or folders the Agent is allowed to use. Use containers or VMs for stronger isolation.

## Current implementation and remaining work

- `CliEngineLauncher` uses the pinned snapshot and verified cached Profile file, passes session context to the generic Engine, and sends provider-start evidence only when the Engine reports it. Its controlled-provider test executes the real Engine from source with a locally provisioned fixture Profile. This does not prove signed Profile delivery, real provider execution, or durable-session recovery. Set `config set engineExecutable PATH` (and optionally `folders work-root PATH`); without it the Agent refuses work. Additional folders, MCP servers and progress streaming are not carried over. Work Request files are delivered ahead of the assignment and placed under `.syntila/inputs/` (`inputs.dart`; see `INPUT_DELIVERY_V1.md`). MCP Workers (ADR-041): `mcp-worker import PATH` installs and approves an exact package, `mcp-worker test ID` inspects it through the Engine and records tool pins, and an assignment carrying an approved `plugin` pin runs through the Engine; the Cloud side (inventory, pin, eligibility) is not implemented yet.
- **Profile delivery:** on a cache miss, the Agent downloads its pinned Profile using its current fenced session. Cloud serves published snapshots for that Worker's Type and signs the digest using `SYNTILA_PROFILE_SIGNING_JWK` (an Ed25519 private JWK, supplied as a server secret) and `SYNTILA_PROFILE_SIGNING_KEY_ID`. The CLI verifies proofs using public keys supplied at build time in `SYNTILA_PROFILE_TRUST_ROOTS` (JSON mapping key IDs to unpadded base64url Ed25519 keys). Missing or invalid signing configuration fails the download; absent or invalid Agent roots trust no keys. Each cache entry retains its proof and rechecks it against current trust on every read. Entries without a proof must be downloaded again. The cache uses the canonical hexadecimal digest and accepts `sha256:`-prefixed local pointers.
- **Local development:** `start-local-backend.sh` and `run-worker-agent.sh` provision and reuse a local Ed25519 signing identity under `.development/local-profile-signing`. The private key is owner-only and stays on the local machine; the Agent launcher passes the public root as a Dart build declaration. A mismatched or incomplete identity stops setup without replacing keys. Restart the local backend after updating these scripts. This development identity is not a production key distribution mechanism.
- **Signature verifier:** `SignedProfileVerifier` accepts a version 1 JSON proof with exactly `version`, `keyId`, and `signature` fields. The unpadded base64url Ed25519 signature covers UTF-8 `syntila-worker-profile-v1`, a newline, and the lowercase SHA-256 hex digest of the exact Profile bytes. The verifier receives trusted public keys from the installation, never from the download. Operators must provision the private signing key and distribute trusted public keys independently; key rotation and real deployment evidence remain open.
- **Snapshot admission:** `ProfileCache.putSnapshot` validates a V9 Profile snapshot's Type, schema and canonical digest, compares its revision and digest with the assignment, and verifies its signature before storing it. Cloud retains bounded history; an unavailable pinned historical revision is refused.
- **Platform secret store:** macOS CLI credentials and pending rotation keys use per-installation Keychain entries. Windows uses current-user DPAPI-encrypted files for both active and pending keys. Linux can opt into Secret Service by setting `SYNTILA_WORKER_SECRET_STORE=secret-service` for the first invocation; the choice is then recorded in the Agent identity directory, including for service starts and pending rotations. An unavailable Secret Service stops activation rather than falling back. Existing file credentials migrate only after secure-store readback; conflicting credentials or inaccessible storage preserve the original file. Linux defaults to an owner-only file for headless installations. All platform adapters need real device and service evidence; DPAPI is supported on Windows x64. On POSIX, the identity directory is restricted before a temporary key file is created, and a failed permission change stops the operation.
- **Readiness publication** (`workspace.readiness`, inventory) and MCP, plugins, input delivery, outputs (parity items 7 to 10, 17 of the P0 inventory).
- **Swap of the running binary** for staged updates; Windows separate user.
- On the compatibility path the gateway allows one Agent per Workspace gateway. The standalone Worker gateway is used when Worker-targeted dispatch is enabled.
