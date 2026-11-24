# Syntila AI Development Instructions

These rules are canonical for AI-assisted development in this repository.

## Working method
1. Read `ARCHITECTURE.md`, `ROADMAP.md`, and the relevant ADRs in `docs/decisions` before changing architecture or public contracts.
2. Work in small, independently reviewable phases. Do not combine unrelated refactors with feature work.
3. Prefer explicit domain types and interfaces over provider-specific logic.
4. Syntila Cloud is provider-independent. Providers, local models, coding agents and CI integrations run through the generic CLI Worker Engine and signed Worker Profiles on a person's computer, started by Syntila Connect; humans contribute through product workflows.
5. Workers resolve through their Type's signed Profile to a provider CLI under the generic CLI Worker Engine. Do not add provider-specific Worker executables (MCP Workers run only through the Engine's plugin host, ADR-027 and ADR-041), browser-based provider access, managed provider credentials, or compatibility APIs for unreleased designs.
6. AI models may propose state changes; Syntila owns persistent state and validates transitions.
7. Do not trust natural-language claims such as "tests pass". Where possible, collect executable evidence.
8. Never store API keys or credentials in plaintext application tables.
9. Product vocabulary is **Connect** and **Worker**. Do not introduce "Workspace" in code, UI text or docs.

## Development validation policy

Use the smallest validation scope that provides meaningful executable evidence for the change.

1. **Do not run `pnpm check` or `pnpm validate:full` as routine completion validation.**
2. **Do not build unrelated applications.** For example, do not compile Flutter apps when editing the backend or the public site, and do not build macOS app bundles unless the change affects native embedding, packaging, codesigning, entitlements or build scripts.
3. **Use the 3-level testing hierarchy:**
   - **Level 1 (focused)**: targeted test files while implementing (for example `scripts/test-backend.sh worker-eligibility`, `dart test test/inputs_test.dart` in `apps/connect`).
   - **Level 2 (component)** when a task phase is complete:
     - Web app: `pnpm validate:app`
     - Backend: `pnpm validate:backend` (real PostgreSQL), plus `scripts/test-two-node.sh` when changing durability, outbox, sessions or realtime
     - Connect: `pnpm validate:connect`
     - Profile Lab: `pnpm validate:profile-lab`
     - Auth edge (`apps/cloud`): `pnpm validate:cloud`
     - Public site: `pnpm validate:site`
     - Worker Engine: `pnpm validate:engine`
   - **Level 3 (full regression)**: `pnpm validate:full` only for release preparation, shared protocol or schema changes affecting all applications, or an explicit request.
4. **Dependency-aware escalation**: when changing a shared package (`packages/*` or `engines/*`), validate that package and its direct consumers only.

## Required completion report
Every implementation task must report:
- what changed;
- tests/checks executed, their results, and **why that verification scope was sufficient** for the change;
- documentation changed;
- remaining risks, assumptions, or unresolved issues;
- migrations or compatibility impact.

## Quality
- Prefer functional tests that exercise meaningful user-visible behavior and important failure paths. Add focused unit or contract tests when they protect consequential rules or boundaries that functional tests cannot cover efficiently. Avoid tests that merely repeat implementation details or assert incidental names and constants; update existing coverage when appropriate instead of adding redundant tests.
- Keep schemas and contracts versioned. Backend migrations are forward-only; `migrations/schema.lock` must match them.
- Backend route and domain modules own PostgreSQL access. Keep `packages/core` independent of the database; add persistence interfaces only for a concrete boundary or testing need.
- Avoid premature infrastructure: add queues, caches, extra regions or providers only when a concrete requirement exists (ADR-039 gates multi-node).
- Update documentation in the same change whenever architecture, data model, protocol, workflow behavior, security or public API changes. A replaced decision is deleted, not kept for history.

## Syntila Connect

- Connect (`apps/connect`, CLI `syntila-connect`; desktop app `apps/connect_gui`) runs a computer's Workers. Each Worker has its own credential, session, journal and lock under `<application data>/Syntila/Workers/<worker-id>/`; folders and the device ID are shared by the computer.
- Connect is installed for the current OS user only and never needs administrator rights. Login services are a launchd agent (macOS), a systemd user unit (Linux) and a per-user logon task (Windows).
- The desktop app contains no command logic; it renders what `syntila-connect --gui-manifest=1` describes.
- The generic Worker Engine must not import Cloud, Space, Thread, Workflow, database or UI code. Connect supervises it as a separate child process and never starts an Engine twice for one attempt.
- Never send a local path to Cloud; folders travel as opaque IDs (ADR-044). Request files and handoffs go through R2 (ADR-037).
- Credentials use the platform store (Keychain, DPAPI, Secret Service or an owner-only file). Migrations of local state must preserve the Worker's identity, credential, journal and sessions; on uncertain state, keep files and stop with a recoverable error.
- Claims about launchd, systemd, Windows services, signing or credential stores need device evidence, not only tests.

## Review principle
Implementation and verification should be independent when practical. A worker must not be considered verified solely because it reviewed its own output.
