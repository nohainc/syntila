# Syntila

**AI execution and orchestration ecosystem where models and AI tools plan,
delegate, build, review, test, and iterate toward verified outcomes.**

Application: **https://syntila.app** · Public website: **https://conclaveax.com**

## License

Syntila is proprietary software. This repository is publicly visible, but that
does not grant permission to use, copy, modify, or distribute its source code.
See [LICENSE](LICENSE) for details and exceptions, including applicable
third-party licenses. Product and service access is governed by the applicable
agreement or terms of service.

## Architecture

See the [architecture](ARCHITECTURE.md) and [roadmap](ROADMAP.md) for current contracts and implementation status.

~~~text
Syntila
-> Syntila Cloud
-> Syntila Connect
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
  Worker gateway, Worker catalog and Profile release control plane.
- **Syntila Connect** — headless Dart execution/security service and
  management CLI (`syntila`) for macOS, Linux and Windows.
- **Syntila Profile Lab** — internal macOS Flutter/Dart engineering desktop
  application for Worker and Tool Profile authoring, testing, and lifecycle
  management.
- **CLI Worker Engine** — one standalone Dart console executable used for
  supported local CLI Workers.
- **Tool Profiles** — signed immutable official provider integration releases.

## Install Connect

Connect runs your Workers on a computer. See [Connect onboarding](docs/operations/CONNECT_ONBOARDING.md) for pairing and data locations.

```bash
# Linux (Ubuntu 22.04+, amd64 or arm64): signed APT repository, setup at https://downloads.syntila.app/apt/index.html
sudo apt install syntila-connect
# macOS (Apple silicon)
brew install nohainc/tap/syntila-connect
# Windows: download the installer from the GitHub Release connect-v<version>
```

## Build, test and release

Everything runs on the dev machine; GitHub builds Windows Connect only (see [Environments](docs/operations/ENVIRONMENTS.md)).

```bash
scripts/test-all.sh --quick          # typecheck and backend suite
scripts/test-all.sh                  # full local gate before a commit
scripts/prod-status.sh               # read-only production state
scripts/prod-deploy-all.sh --dry-run # plan a release (backend, web app, optional --site)
scripts/prod-deploy-all.sh           # release; stops at the first failure
```

Connect and the web app share a Git-derived release version. Start a series with `scripts/set-version.sh 0.3`, then build from clean, up-to-date `main`. Windows Connect uses the two GitHub workflows ([GitHub Actions](docs/operations/GITHUB_ACTIONS.md)); see [Test and deploy scripts](docs/operations/TEST_AND_DEPLOY_SCRIPTS.md) for the release rules.

## Repository checks

Use the focused tests and component validation commands in [AGENTS.md](AGENTS.md) for the area changed. `pnpm check` is a broad repository check reserved for cases that require that scope.

`./scripts/local-start.sh` starts the Syntila frontend on `http://localhost:3000`
and a local API gateway on `http://localhost:8787`. By default the gateway runs the isolated local backend, its local PostgreSQL database and the local auth D1 database.
Local state and browser profiles may persist between runs; isolation from production
does not mean a fresh database or browser session. To forward HTTP and WebSocket
requests to production Cloud instead, explicitly use `--proxy`: actions in that
mode affect live accounts, remote data and Connect connections. Authentication
cookies are adapted to localhost while retaining HttpOnly; production authentication
secrets stay on Cloud.
Stop previous frontend/backend processes before restarting the launcher.
To apply both local databases' pending migrations without starting the apps, run
`pnpm db:migrate:local`. It applies auth D1 migrations and backend PostgreSQL
migrations; PostgreSQL must be running with the local development role.

For browser acceptance testing, use `./scripts/local-start.sh --web-release`.
This runs the production web rendering path against the same configured API,
without hot reload/restart. Stop the Flutter runner and close its browser window
before switching modes; stop and relaunch to rebuild after code changes. Debug
mode remains the default for development. Flutter web hot restart can leave a
stale view and report “Trying to render a disposed EngineFlutterView”; a fresh
release session helps distinguish that engine failure from application updates.
See [Flutter's tracked web restart issue](https://github.com/flutter/flutter/issues/182377).

Use `./scripts/local-start.sh --isolated` (the default) to test local backend changes with
the local auth and PostgreSQL databases and separate accounts. In this mode the launcher
generates a persistent local authentication secret in the ignored
`apps/cloud/.dev.vars` file, preserving existing settings and limiting file access
to its owner. Local email sign-in uses the local account database, so create a
local account first if needed; hosted accounts are separate. If an already
running backend reports “Authentication is not configured”, run
`node scripts/local-setup-auth.mjs` and restart the local backend.
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
Chat
Work
Research
Implement
~~~

Threads bind those Steps to logical Workers. Users do not build arbitrary
Workflow graphs or edit Syntila's internal orchestration prompts in v1.

## Technology stack

- Flutter + Dart for Syntila; pure Dart (no Flutter) for the Syntila Connect
  service and CLI.
- TypeScript on Bun with PostgreSQL for Syntila Cloud (`apps/backend`).
- Dart AOT for the generic CLI Worker Engine.
- A Cloudflare Worker with D1 for the human sign-in edge (`apps/cloud`).
- Cloudflare R2 for files and artifacts.
- Better Auth for human authentication.
- Local Worker Protocol between Connect and CLI Worker Engine; see [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md) for supported versions.
- Signed Tool Profile v1 releases for provider CLI behavior.
- GitHub Actions for CI/CD.
- Wrangler for Cloudflare deployment.

## Key concepts

- **Space** — collaboration/history/authorization boundary.
- **Thread** — persistent unit of work and local working directory.
- **Connect** — one machine-backed execution environment.
- **Worker Type** — stable product AI/tool identity such as `chatgpt` or
  `gemini`.
- **CLI Worker Engine** — generic local executor/interpreter; not a user-facing
  Worker.
- **Tool Profile** — signed provider integration configuration used by the
  Engine.
- **Provider CLI** — local tool that owns provider authentication/session/billing
  mode.
- **Connect Grant** — Space authorization to use a Connect.
- **Assignment** — immutable execution snapshot resolving Space + Thread +
  logical Worker + runtime evidence.

## Runtime trust boundary

Connect supervises Engine processes but does not implement provider behavior.

The Engine:
- loads a Connect-admitted signed Profile;
- finds/probes the provider CLI;
- launches it without a shell;
- parses its bounded output;
- enforces session continuity;
- normalizes progress/result/error.

Profiles cannot disable Engine/Connect security invariants.

Provider secrets never enter Syntila Cloud.

## Read first

- [Architecture](ARCHITECTURE.md)
- [Documentation index](docs/README.md)
- [Architecture decisions](docs/decisions/README.md)
- [Tool Profile v1](docs/specifications/TOOL_PROFILE_V1.md)
- [Worker Profile v9](docs/specifications/WORKER_PROFILE_V9.md)
- [Work v1 contract](docs/specifications/WORK_V1_CONTRACT.md)
- [First-party Worker catalog v1](docs/specifications/FIRST_PARTY_WORKER_CATALOG_V1.md)
- [Protocol Boundaries](docs/architecture/PROTOCOL_BOUNDARIES.md)
- [Technology Stack](docs/architecture/TECH_STACK.md)
- [Production provisioning](docs/operations/PRODUCTION_PROVISIONING.md)
- [AI Development Rules](AGENTS.md)

New CLI integrations use the generic Engine and official signed Tool Profiles.
See [Architecture](ARCHITECTURE.md) and the [roadmap](ROADMAP.md) for current contracts and release gates.
