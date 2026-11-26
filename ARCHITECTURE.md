# Syntila Architecture

This is the canonical description of the system as built. Decisions and their
reasons are in [docs/decisions](docs/decisions/README.md); detailed contracts
are in [docs/specifications](docs/specifications). When code and this document
disagree, fix one of them in the same change.

```text
Syntila web app ─┐
                 ├─► Syntila Cloud (Bun + PostgreSQL + R2) ◄─── Syntila Connect (one per computer)
Profile Lab ─────┘                                              └─ Workers ─► CLI Worker Engine ─► provider CLI
```

## Applications

| Application | Path | Role |
| --- | --- | --- |
| Syntila (web app) | `apps/app` | Flutter app for people: Spaces, Threads, Chat, Ask AI, Workers, People, Workflows |
| Syntila Cloud | `apps/backend` | Bun HTTP and WebSocket server on PostgreSQL; owns all shared state and every authorization decision |
| Auth edge | `apps/cloud` | Cloudflare Worker for human sign-in and static hosting; issues the tokens the backend verifies |
| Syntila Connect | `apps/connect` (CLI `syntila-connect`), `apps/connect_gui` (desktop app) | Runs a computer's Workers: pairing, sessions, journal, folders, files, Engine supervision |
| CLI Worker Engine | `engines/cli_worker`, `packages/syntila_cli_worker_runtime` | Generic, provider-independent process that interprets a signed Profile and runs a provider CLI |
| Profile Lab | `apps/profile_lab` | Internal macOS app to author, test and publish Worker Profiles |
| Account manager | `apps/account_manager` | Internal macOS operator app for accounts |
| Public site | `apps/site` | Marketing site |

Shared contracts live in `packages/` (`core`, `protocol`, `tool-profile`,
`security`, and their Dart counterparts under `packages/dart`).

## Core model

| Term | Meaning |
| --- | --- |
| **User** | A person with an account. Owns Spaces and Workers. |
| **Actor** | The immutable author of a Thread item: `human` (one per user), `worker` (one per Worker) or `system`. |
| **Worker Type** | A catalog entry such as ChatGPT or Gemini, with one current signed Profile. MCP Worker Types (`plugin-…`) come from the owner's library. |
| **Worker** (Worker Instance) | A user-owned, schedulable AI agent of one Type, with its own ID, name, credential and session. Names need not be unique; everything binds by ID. |
| **Connect installation** | One per computer and OS user, paired to one account. Runs any number of that account's Workers. |
| **Device** | The computer a Connect installation runs on. Folders belong to the device, not to one Worker. |
| **Space / Thread** | Collaboration container and its conversation. |
| **Work Request** | One explicit Ask AI invocation, with a frozen snapshot of Workflow, Workers, Profiles, models and permissions. |
| **Run / Task / Assignment** | Execution of a Work Request: a Workflow Run, its Steps, and the attempt sent to one Worker. |
| **Artifact** | A file a Step hands to later Steps, stored in R2 and referenced by ID. |

A plain message never runs a Worker. Only Ask AI, a mention or an automation
creates a Work Request ([ADR-035](docs/decisions/ADR-035-worker-targeted-execution.md)).

## Cloud

One Bun process serves HTTP and WebSockets in front of PostgreSQL (one EU
region) and R2. Cloud owns state; Workers and clients propose changes and Cloud
validates every transition.

- **Durability.** A state change, its event sequence number, the event row and
  its outbox row commit in one transaction. Sockets are only a delivery
  optimization; the outbox dispatcher delivers what a crash left behind.
  Delivery is at least once, deduplicated by event ID
  ([ADR-033](docs/decisions/ADR-033-durable-events-outbox-and-command-inbox.md),
  [Event streams](docs/specifications/EVENT_STREAMS.md)).
- **Commands to Workers.** An `agent_commands` row exists before any wake-up;
  notifications carry IDs only.
- **Realtime.** People and Workers speak one envelope, `syntila.messaging/1`,
  with different credentials and scopes. People subscribe to user, Space and
  Thread streams; a Worker only to its own inbox and assignments
  ([ADR-038](docs/decisions/ADR-038-unified-realtime-transport.md)).
- **Scaling.** One node today. Every rule above is safe on several nodes; running
  more than one is gated on measured load
  ([ADR-039](docs/decisions/ADR-039-horizontal-scaling.md)).
- Cloud stores no provider credentials and no local paths. Secrets in tables
  are digests or encrypted (provider failure text is encrypted at rest).

## Workers and Connect

**Identity and pairing** ([ADR-032](docs/decisions/ADR-032-worker-instance-and-actor-identity.md),
[ADR-034](docs/decisions/ADR-034-connect-pairing-and-session-fencing.md)).
The owner creates a Worker on the Workers page and gets a single-use pairing
code. Connect generates an Ed25519 key pair; only the public key leaves the
computer. Each login signs a server nonce and bumps the Worker's session epoch;
every acknowledgement and result is checked against the current epoch in the
same database write, so a stale or copied session can never commit a result.

**One account per computer** ([ADR-043](docs/decisions/ADR-043-worker-person-shares-and-one-account-per-computer.md)).
Cloud refuses a pairing while another account still has a Worker paired on the
same Connect installation. Connect installs for the current OS user only; it
never asks for administrator rights.

**What Connect does for each Worker:**

- keeps its credential in the platform store (macOS Keychain, Windows DPAPI,
  Linux Secret Service or an owner-only file), its journal (fsync before
  acknowledging) and its lock under
  `<application data>/Syntila/Workers/<worker-id>/`;
- reports readiness (credential, Profile, folders, Engine) when it connects,
  publishes the models and efforts its provider CLI offers, and answers usage
  requests;
- downloads the pinned Profile, verifies its signature against build-time trust
  roots, and starts the Engine only on demand;
- never starts an Engine twice for one attempt; an attempt interrupted by a crash
  ends as a retryable failure.

**Full access** is the owner's local choice (`syntila-connect full-access on`,
or the Connect app); Cloud cannot set it.

**Updates.** Connect is installed and updated manually (download or package
manager). A signed update channel is not built yet.

## Folders and files

```text
USER-OWNED (chosen in Connect)            SYNTILA-OWNED
~/Documents/Syntila/   (Work Root)        <application data>/Syntila/
<any allowed folder>/                     ├── device.json, allowed folders   (per computer)
└── .syntila/inputs/<request>/file-NNN    └── Workers/<worker-id>/          (per Worker)
                                              ├── identity/ commands/ sessions/
                                              ├── profiles/ inputs/ traces/
```

- **Device folders** ([ADR-044](docs/decisions/ADR-044-device-folders-and-space-folders.md)).
  The person allows folders in Connect, read or read-and-write. Connect
  publishes an opaque ID, the folder's own name and the access level, never the
  path. A Space chooses one folder; Work that changes files runs only on a
  Worker on that folder's device, and Connect re-checks the folder right before
  use.
- **Scratch.** A Step without a folder runs in its assignment's own folder under
  the Work Root. A Person Share never sees any folder.
- **Request files.** A person's attachments are uploaded to R2 first. The
  Workflow starts when every file is uploaded; any Worker that runs a Step of
  the request downloads them with its session, checks size and SHA-256, and
  places them at `.syntila/inputs/<request>/file-NNN`
  ([Input Delivery](docs/specifications/INPUT_DELIVERY_V1.md)).
- **Handoff between Steps** uses artifact IDs or Git references only, never a
  local path ([ADR-037](docs/decisions/ADR-037-files-and-artifacts.md)).
- **Output images, audio and video** a Worker produces are uploaded and shown in
  the Thread; audio and video play from short-lived signed links.

## Execution

1. Ask AI sends `workerId` (and optional model and effort) with the request.
2. Admission checks, on the server: the Worker is enabled and online, the
   requester may use it (owner, Space member access or Person Share), the
   Type's Profile declares every capability the Steps need, the model and
   effort are in the Worker's reported catalog and allow-list, and the requester
   may execute in the Thread. A refusal never falls back to another Worker.
3. The Work Request, its `ai_request` timeline item and the frozen snapshot
   commit together.
4. Each Step is bound to a Worker and re-checked when it is dispatched and on
   every retry. Stateful Work holds a Thread lease on one Worker, whose Space
   folder is the checkout ([ADR-040](docs/decisions/ADR-040-stateful-workflows-on-worker-agents.md)).
5. The terminal result, the `ai_answer` item and its event commit in one
   transaction. The answer is authored by the Workflow's answer Step Worker, or
   a System Actor ([ADR-036](docs/decisions/ADR-036-canonical-thread-timeline-and-attribution.md)).

Lifecycle details: [Execution lifecycle](docs/specifications/EXECUTION_LIFECYCLE_V9.md),
[Command delivery and revocation](docs/specifications/COMMAND_DELIVERY_AND_REVOCATION_V9.md),
[Work v1](docs/specifications/WORK_V1_CONTRACT.md),
[Conversation continuity](docs/specifications/CONVERSATION_CONTINUITY_V1.md).

## Sharing

| Who | Can | Decision |
| --- | --- | --- |
| Owner | Everything: configure, pair, revoke, use in any Thread they may execute in | ADR-032, ADR-035 |
| Space member | Use a Worker the owner made available in that Space, with the owner's mode (Chat, Work, Work with shell) and model allow-list | [ADR-042](docs/decisions/ADR-042-worker-space-member-access.md) |
| Person Share | Chat only, read-only, in the person's own Threads and Spaces, with concurrency and monthly run-time limits | ADR-043 |

Space member access and Person Shares need the Plus feature `worker.sharing` on the Worker's owner. Free accounts can still turn access off and revoke; when a plan lapses, shares pause (they are not deleted).

Reading a Thread never grants the right to execute. Direct Spaces never grant
access to the other person's Worker.

## Profiles and the Engine

Each Worker Type has one current, signed Profile
([Worker Profile V9](docs/specifications/WORKER_PROFILE_V9.md),
[Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)). Profile Lab
authors and publishes it ([Profile Lab](docs/specifications/PROFILE_LAB.md)).
The Engine interprets the Profile; Cloud, Connect and the web app have no
provider-specific branches. MCP Workers run through the Engine's plugin host
([ADR-027](docs/decisions/ADR-027-custom-worker-plugins.md),
[ADR-041](docs/decisions/ADR-041-mcp-workers-on-worker-agents.md)).

## Protocol boundaries

```text
web app   <-> Cloud      HTTPS + syntila.messaging/1 (human ticket)
Connect   <-> Cloud      HTTPS + syntila.messaging/1 (signed Worker session)
Connect   <-> Engine     Local Worker Protocol
Engine    <-> provider   Profile-defined invocation
```

Each boundary has its own identity, authorization and versioned schema
([Protocol boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)). Provider
credentials and native provider sessions never leave the computer.

## Web app

The Flutter app keeps typed, cached server state with scoped realtime updates
([AX server state](docs/architecture/AX_SERVER_STATE.md)). The Thread timeline
is server-canonical: one ordered, cursor-paginated list of messages, requests
and answers. The Workers page manages Workers (create, pair, rename, models,
access, shares, usage); the composer's Worker picker lists only Workers the
server says are eligible.

## Validation

See `AGENTS.md` for the testing levels. Backend: `scripts/test-backend.sh`
(real PostgreSQL) and `scripts/test-two-node.sh` (multi-server rules). Connect:
`scripts/test-connect.sh`.
