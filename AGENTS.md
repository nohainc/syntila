# Syntila AI Development Instructions

These rules are canonical for AI-assisted development in this repository.

## Working method
1. Read `ARCHITECTURE.md`, `ROADMAP.md`, and relevant ADRs/specifications before changing architecture or public contracts.
2. Work in small, independently reviewable phases. Do not combine unrelated refactors with feature work.
3. Prefer explicit domain types and interfaces over provider-specific logic.
4. Treat Syntila Core as provider-independent. Provider, local-model, coding-agent, and CI integrations execute through the CLI Worker Engine and signed Tool Profiles; humans contribute through product workflows.
5. Follow the v8 contract in `docs/architecture/ARCHITECTURE_V8.md`: logical Workers resolve through signed Tool Profiles to provider CLIs under the generic CLI Worker Engine. Do not introduce provider-specific Worker executables, browser-based provider access, managed provider credentials, legacy runtime entities, or compatibility APIs for unreleased architectures.
6. AI models may propose state changes; Syntila owns persistent state and validates transitions.
7. Do not trust natural-language claims such as "tests pass". Where possible, collect executable evidence.
8. Never store API keys or credentials in plaintext application tables.

## Development validation policy

Use the smallest validation scope that provides meaningful executable evidence for the change.

1. **Do not run `pnpm check` or `pnpm validate:full` as routine completion validation.**
2. **Do not build unrelated applications.** For example:
   - Do not compile Flutter apps when editing Cloud or Public Site.
   - Do not run macOS Workspace or Profile Lab `.app` builds (`pnpm workspace:build:macos`, `pnpm profile-lab:build:macos`) unless the change directly affects native embedding, packaging, codesigning, entitlements, or build scripts.
3. **Use 3-Level Testing Hierarchy:**
   - **Level 1 (Focused)**: Run targeted unit/widget test files while implementing (e.g., `flutter test test/spaces_pages_test.dart` or `vitest run apps/cloud/test/auth.test.ts`).
   - **Level 2 (Component)**: Run the dedicated component validation command upon completing a task phase:
     - Syntila Web App: `pnpm validate:app`
     - Workspace: `pnpm validate:workspace`
     - Profile Lab: `pnpm validate:profile-lab`
     - Cloud / API: `pnpm validate:cloud`
     - Public Site: `pnpm validate:site`
     - Worker Engine: `pnpm validate:engine`
   - **Level 3 (Full Regression)**: `pnpm validate:full` is reserved for release preparation, shared protocol/schema cutovers affecting all applications, or explicit user requests.
4. **Dependency-Aware Escalation**: If modifying a shared package (`packages/*` or `engines/*`), escalate validation only to that package and its direct downstream consumers according to the architecture dependency map.

## Required completion report
Every implementation task must report:
- what changed;
- tests/checks executed, their results, and **why that verification scope was sufficient** for the change;
- documentation changed;
- remaining risks, assumptions, or unresolved issues;
- migrations or compatibility impact.

## Quality
- Add or update tests for behavior changes.
- Keep schemas/contracts versioned. The v8 D1 schema is a fresh-start baseline,
  not a compatibility migration chain.
- Cloud route/service modules own D1 access. Keep Syntila Core independent of
  D1 bindings and raw SQL; add persistence interfaces only for a concrete
  boundary or testing need, not for a hypothetical database replacement.
- Workspace owns local registry, Profile/Engine state, sessions, logs, and Work
  Root data. Do not treat Cloud persistence as the source of local runtime
  state.
- Avoid premature infrastructure: add Durable Objects, Queues, vector databases, or extra providers only when a concrete requirement exists.
- Update documentation whenever architecture, data model, protocol, workflow behavior, security, or public API changes.

## Workspace Service architecture

- The authoritative architecture is
  [docs/architecture/WORKSPACE_ARCHITECTURE.md](docs/architecture/WORKSPACE_ARCHITECTURE.md).
  Use it for current Workspace ownership and runtime decisions.
- One headless Dart Workspace Service owns Cloud connectivity, assignment
  scheduling, Worker Engine processes, sessions, and runtime state. The
  `syntila` CLI is a management client over authenticated versioned
  local IPC; there is no Workspace GUI. Do not reintroduce a second client-owned
  runtime or a direct client Cloud connection.
- The CLI and any management client must not spawn a Worker Engine or provider CLI. The generic
  Worker Engine must not import Cloud, Space, Thread, Workflow, D1, or UI code.
  Keep process supervision inside the service/Engine boundary.
- Migrations must preserve the existing installation ID, Cloud Workspace and
  runtime IDs, secure runtime credential, Work Root, Worker registry, Profiles,
  Engine files, and sessions. Do not create a replacement Cloud Workspace as a
  migration shortcut. On uncertain migration state, preserve files and stop
  activation with a recoverable error.
- Keep the CLI Worker Engine as a separately supervised child. Runtime-owned
  state belongs under Application Support; user work remains under Work Root.
- Keep service registration behind `WorkspaceServiceManager`. Put launchd,
  Service Control Manager/systemd, native IPC, and platform secret-store details
  in platform adapters; the shared Dart runtime must not import Apple
  frameworks. Linux/Windows adapters follow
  `docs/decisions/ADR-021-workspace-service-linux-windows.md` (systemd user
  unit/foreground mode; Windows per-user logon task, not SCM; CLIs run as the
  user who owns their logins).
- For Workspace Service changes, run focused service/runtime tests and
  `scripts/check-workspace-service.sh`; run the Workspace and direct Worker
  Engine component validations when the environment permits. macOS launchd,
  signing, Keychain, and TCC claims require device or release-build evidence.
- Keep the canonical build pipeline explicit: `build-cli-worker-engine.sh`
  produces the Engine artifact, `build-workspace-service.sh` builds the
  unified `syntila` binary, and `build-workspace-macos.sh`
  assembles/signs the macOS bundle.
- `service stop` must leave registration intact; Disconnect Cloud must leave the
  service process running. Preserve the per-installation lock as the duplicate
  owner guard.

## Review principle
Implementation and verification should be independent when practical. A worker must not be considered verified solely because it reviewed its own output.
