# CI Checks and Evidence

GitHub Actions is the source of truth for repository CI results. The workflow runs the configured TypeScript, Cloud startup, Connect, Flutter, and site checks. GitHub retains each result with its workflow run and commit revision.

Syntila Cloud no longer accepts per-run CI evidence. The former `/api/runs/:runId/ci-evidence` endpoint and its credential are removed because they depended on the pre-v8 run and evidence tables. Do not configure a CI ingest URL or token.

For release reviews, link the GitHub Actions run and its commit SHA in the release record.

## Acceptance ownership

The CI workflow runs eight independent validation domains, followed by the
**Repository Acceptance Gate** aggregation job. Branch protection should require
that stable check name. Configure branch protection in GitHub when adopting this
workflow; changing the workflow does not change repository protection settings.
The gate fails if any dependency fails or is skipped. Superseded runs are
cancelled within the same branch or pull request; different branches remain
independent.

| Domain | Validation owner |
| --- | --- |
| `repo-static` | Branding, schema, architecture, protocol, documentation, security, formatting and lint guards |
| `typescript` | Cloud generated types, TypeScript build, unit/integration tests and explicit fixture acceptance |
| `dart-core` | Five Dart protocol/runtime/Profile/Engine packages plus Flutter design package: format, analysis and tests |
| `app-flutter` | AX format, analysis, tests and release web build |
| `connect-check` | Connect (pure Dart) format, `dart analyze`, `dart test` and the compiled-service one-shot check on Linux, with a freshly compiled fixture Engine |
| `connect-macos-build` | Native macOS bundle build (`dart compile exe` + signing); no repeated analysis/tests |
| `profile-lab-macos` | Profile Lab format, analysis, tests, fixture Engine acceptance and native build |
| `site-astro` | Site check, tests, build and all existing release guards |

The former Windows and macOS Connect analysis matrix is removed. Linux owns
portable validation; macOS owns native build validation. This does not add Windows
or Linux distribution support. Flutter SDK and Pub downloads are cached by OS,
SDK and lockfiles; compiled native Engines are never shared between OS jobs.

`pnpm check` remains the complete local verification command, composed of
`check:static`, `check:typescript`, `check:dart` and `check:apps`. The two explicit
clean-room Cloud acceptance files are excluded only from `pnpm test` and owned by
`check:fixture-e2e`; other acceptance tests retain their existing ownership.

Each app check resolves dependencies once and, where needed, compiles the Engine
once. macOS CI then uses `--prepared` to skip clean, dependency resolution and
Engine recompilation. Prepared builds require existing dependency configuration
and an executable Engine and must follow preparation in the same checkout/job.
Standalone desktop build scripts retain clean release defaults, packaging and
trust-root validation. No database or product contract changes are required.

Compare GitHub job timings and total wall-clock time at the same revision after
rollout. The intended improvement is reduced duplicate work, not a promised
3–4 minute gate. Local verification cannot establish hosted-runner timings or
remote branch-protection behavior. Opt-in live-provider tests remain a separate
release gate.

Implementation verification: the composed `pnpm check` passed locally, with 689
main TypeScript/script tests, 16 separately owned Cloud fixture tests and all
Dart/Flutter package suites passing. Connect passed 332 tests with 10 opt-in
live-provider tests skipped; Profile Lab passed 144 and AX passed 589. Four CI
orchestration tests cover fixture ownership, aggregation failure/skip behavior,
and prepared versus default macOS preparation. `actionlint`, shell syntax,
formatting and whitespace checks passed. Hosted job timing and native build jobs
still need observation on the next GitHub CI run; no speed claim is based on
local results.
