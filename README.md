# Syntila

**AI execution and orchestration ecosystem where models and AI tools plan,
delegate, build, review, test, and iterate toward verified outcomes.**

Application: **https://syntila.app** · Public website: **https://conclaveax.com**

## Architecture

Architecture v9 is the current design target; the v8 implementation remains the baseline where v9 work is not yet complete. See the [architecture](ARCHITECTURE.md) and [roadmap](ROADMAP.md) for current contracts and implementation status.

~~~text
Syntila
-> Syntila Cloud
-> Syntila Workspace
-> generic CLI Worker Engine
-> signed Tool Profile
-> provider CLI
~~~

Examples of logical Workers include:

~~~text
ChatGPT -> chatgpt-codex Profile -> Codex CLI
Gemini  -> gemini-antigravity Profile -> agy
~~~

Users continue to interact with ChatGPT/Gemini Workers. Engine/Profile versions
are implementation details shown only in Advanced Diagnostics.

## Applications

- **Syntila** — Flutter Web application for Spaces, Threads, Chat
  (discussion) and Work.
- **Syntila Cloud** — TypeScript/Cloudflare collaboration, scheduling,
  Workspace Gateway, Worker catalog and Profile release control plane.
- **Syntila Workspace** — headless Dart execution/security service and
  management CLI (`syntila`) for macOS, Linux and Windows.
- **Syntila Profile Lab** — internal macOS Flutter/Dart engineering desktop
  application for Worker and Tool Profile authoring, testing, and lifecycle
  management.
- **CLI Worker Engine** — one standalone Dart console executable used for
  supported local CLI Workers.
- **Tool Profiles** — signed immutable official provider integration releases.

## Install Workspace on Ubuntu

Headless Workspace packages for Ubuntu 22.04 and newer are available for amd64
and ARM64 through the [signed APT repository](https://nohainc.github.io/syntila/).
Follow the one-time repository setup there, then install with:

```bash
sudo apt update
sudo apt install syntila
syntila setup
# Existing Cloud email/password; no browser needed on the server.
sudo loginctl enable-linger "$USER"
```

The package includes the service, management CLI and Worker Engine. See the
[Linux operator guide](docs/operations/WORKSPACE_LINUX.md) for user-service setup,
browser login and upgrades. Provider CLIs and their logins are separate.

## Repository checks

Use the focused tests and component validation commands in [AGENTS.md](AGENTS.md) for the area changed. `pnpm check` is a broad repository check reserved for cases that require that scope.

`./scripts/start-local.sh` starts the Syntila frontend on `http://localhost:3000`
and a local API gateway on `http://localhost:8787`. By default the gateway
forwards HTTP and WebSocket requests to production Cloud, using existing
accounts, remote data and Workspace connections. Actions affect live data.
Authentication cookies are adapted to localhost while retaining HttpOnly;
production authentication secrets stay on Cloud. This mode tests local Syntila UI
changes against deployed Cloud behavior, rather than executing local backend changes.
Stop previous frontend/backend processes before restarting the launcher.

For browser acceptance testing, use `./scripts/start-local.sh --web-release`.
This runs the production web rendering path against the same configured API,
without hot reload/restart. Stop the Flutter runner and close its browser window
before switching modes; stop and relaunch to rebuild after code changes. Debug
mode remains the default for development. Flutter web hot restart can leave a
stale view and report “Trying to render a disposed EngineFlutterView”; a fresh
release session helps distinguish that engine failure from application updates.
See [Flutter's tracked web restart issue](https://github.com/flutter/flutter/issues/182377).

Use `./scripts/start-local.sh --isolated` to test local backend changes with
the local v8 D1 database and separate accounts. In this mode the launcher
generates a persistent local authentication secret in the ignored
`apps/cloud/.dev.vars` file, preserving existing settings and limiting file access
to its owner. Local email sign-in uses the local account database, so create a
local account first if needed; hosted accounts are separate. If an already
running backend reports “Authentication is not configured”, run
`node scripts/setup-development-auth.mjs` and restart the local backend.
To sign in with Google or GitHub locally, add `SYNTILA_AUTH_GOOGLE_CLIENT_ID` /
`SYNTILA_AUTH_GOOGLE_CLIENT_SECRET` or `SYNTILA_AUTH_GITHUB_CLIENT_ID` /
`SYNTILA_AUTH_GITHUB_CLIENT_SECRET` to `apps/cloud/.dev.vars`; the OAuth setup is
described in the [Cloudflare deployment guide](docs/deployment/CLOUDFLARE.md#github-sign-in).
Neither mode runs migrations or deploys production code.

## Work v1

Syntila defines fixed canonical Steps:

~~~text
Research
Plan
Implement
Test
Verify
~~~

and built-in Workflows:

~~~text
Direct
Research
Plan & Implement
Implement & Verify
Full Cycle
~~~

Threads bind those Steps to logical Workers. Users do not build arbitrary
Workflow graphs or edit Syntila's internal orchestration prompts in v1.

## Technology stack

- Flutter + Dart for Syntila; pure Dart (no Flutter) for the Syntila Workspace
  service and CLI.
- TypeScript for Syntila Cloud.
- Dart AOT for the generic CLI Worker Engine.
- Cloudflare Workers + Workflows + Durable Objects.
- Cloudflare D1 for structured state.
- Cloudflare R2 where release/artifact payload storage is appropriate.
- Better Auth for human authentication.
- Local Worker Protocol between Workspace and CLI Worker Engine; see [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md) for supported versions.
- Signed Tool Profile v1 releases for provider CLI behavior.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Space** — collaboration/history/authorization boundary.
- **Thread** — persistent unit of work and local working directory.
- **Workspace** — one machine-backed execution environment.
- **Worker Type** — stable product AI/tool identity such as `chatgpt` or
  `gemini`.
- **CLI Worker Engine** — generic local executor/interpreter; not a user-facing
  Worker.
- **Tool Profile** — signed provider integration configuration used by the
  Engine.
- **Provider CLI** — local tool that owns provider authentication/session/billing
  mode.
- **Workspace Grant** — Space authorization to use a Workspace.
- **Assignment** — immutable execution snapshot resolving Space + Thread +
  logical Worker + runtime evidence.

## Runtime trust boundary

Workspace supervises Engine processes but does not implement provider behavior.

The Engine:
- loads a Workspace-admitted signed Profile;
- finds/probes the provider CLI;
- launches it without a shell;
- parses its bounded output;
- enforces session continuity;
- normalizes progress/result/error.

Profiles cannot disable Engine/Workspace security invariants.

Provider secrets never enter Syntila Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Architecture v8](docs/architecture/ARCHITECTURE_V8.md)
- [ADR-018: Generic CLI Worker Engine and Tool Profiles](docs/decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)
- [ADR-019: Syntila Profile Lab Architecture Contract](docs/decisions/ADR-019-syntila-profile-lab.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Worker Profile v9](docs/specifications/WORKER_PROFILE_V9.md)
- [Work v1 contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-party Worker catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Workspace release operations](docs/deployment/WORKSPACE_RELEASES.md)
- [Release trust and rotation](docs/security/RELEASE_TRUST_AND_ROTATION.md)
- [AI Development Rules](AGENTS.md)

New CLI integrations use the generic Engine and official signed Tool Profiles.
See [Architecture](ARCHITECTURE.md) and the [roadmap](ROADMAP.md) for current contracts and release gates.
