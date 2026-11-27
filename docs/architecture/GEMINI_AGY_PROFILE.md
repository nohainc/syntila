# Gemini / AGY Tool Profile

The Gemini Worker uses the same signed Tool Profile resolver, generic CLI Worker
Engine, Connect-owned readiness and inventory, assignment routing and durable session
store as ChatGPT. There is no Gemini executable or provider branch in Cloud. The
Profile is `apps/profile_lab/assets/profiles/gemini.json` (`gemini-antigravity`).

## Comparison with ChatGPT / Codex

| Boundary | ChatGPT / Codex | Gemini / AGY |
| --- | --- | --- |
| Definition | `chatgpt-codex` | `gemini-antigravity` |
| Executable | `codex` | `agy` |
| Discovery | Standard locations and `PATH` | `~/.local/bin`, `~/.gemini/antigravity-cli/bin`, `PATH` |
| Version | `--version` | `--version` |
| Passive authentication | `login status` | None reliable; an explicit live test is required |
| Live readiness | Exact `OK`, bounded, user initiated | Same Engine-owned check |
| Models | CLI app-server discovery | CLI `models` output, all sanitized IDs; families and efforts derived from it |
| Effort | Per-model metadata from discovery | Derived from the model IDs and labels; no independent effort metadata |
| Input / output | Codex JSONL events | NDJSON `user` input; `init`, `step_update`, `result` events |
| Sessions | Codex thread ID | AGY `conversation_id`, resumed with `--conversation` |
| Cancellation / timeout | Shared process supervision | Same; the Profile also maps `--print-timeout` |
| Chat / Work provider mode | Cloud workflow policy plus sandbox mapping | `--mode plan` for Chat (provider default), `--sandbox` with `--mode accept-edits` for Work (restricted) |
| Authentication | Provider-owned local account | Provider-owned local account; no Syntila-managed credentials |

Cloud's Worker inventory joins the matching published Profile revision and never uses an
authoring template to widen execution options. Cloud resolves frozen workflow selections
to an assignment; Connect admits the signed Profile, resolves the Space directory and
authorized environment, and asks the Engine to execute it. The Engine parses provider
events into generic progress, result and error frames, and native session identifiers
stay local.

## Model discovery

`model.discovery` runs `agy models` on the resolved executable (no shell, no model
request): `{"schemaVersion":1,"arguments":["models"],"timeoutMs":10000,"format":"tsv","idPrefix":""}`.
The Engine accepts bounded tab-separated rows, preserves IDs, rejects malformed or
duplicate IDs and, with an empty prefix, includes every returned model. Limits: 128
models, 128-character IDs, 64 KiB of output. AGY reports the current Gemini effort as part of
each native ID (for example `gemini-3.8-flash-high`), so the Profile declares
`model.discovery.effortVariants` and the Engine groups native IDs into logical families
and resolves a selected family/effort pair back to exactly one native `--model` value;
see [Provider discovery and normalization](../specifications/MODEL_DISCOVERY_NORMALIZATION.md).
Gemini combined families have no model Auto and no effort Auto: the app requires both
selections, no separate `--effort` argument is sent, and a missing or unresolved native
variant stays unavailable rather than guessed. The Engine never invents models or efforts.

The last successful catalog is stored in `model-catalog.json` in the Worker's internal
Engine state directory, bound to the exact Profile digest and CLI version; a different
Profile or CLI cannot reuse it. Execution uses only a matching cache and rediscovers after
a version change. A passive readiness or model refresh updates the list, a failed refresh
keeps the matching cache and reports a warning, and a successful empty result retires all
models. There are no background model probes or polling.

Model status is `listed`, `verified` or `unavailable`. A successful explicit execution
verifies only that ID, and an explicit unsupported-model error marks it unavailable;
network, authentication and quota failures do not. Auto-model success verifies nothing.
Removed IDs disappear from selectable options while stored workflow selections stay and
fail validation, and no fallback model is chosen. A known unavailable ID stays excluded
until the cache, Profile or CLI changes. Connect shows models with status and a refresh
action (also for disabled Workers, without enabling them); model selection stays in the
app's workflow and request controls. The catalog travels as the versioned `modelCatalog`
object; Cloud keeps only bounded public metadata, requires the same published digest and
CLI version, and exposes no CLI arguments, credentials, paths or digests
([Worker execution options v2](../specifications/WORKER_EXECUTION_OPTIONS_V2.md)). The
Profile requires Engine 1.3.0 or newer so it cannot run under an older implementation.

## Readiness and security

`probe.live.requiredForReadiness: true` means passive installation and model checks
cannot enable scheduling alone. A successful live test is tied to the Profile digest and
provider version in the local registry, and a version or Profile change needs a fresh
explicit Test.

AGY documentation says file writes can be auto-allowed in headless mode. `--sandbox`
restricts terminal activity, and `--mode plan` is not an independently verified
filesystem boundary. Syntila therefore treats Chat versus Work as a Cloud workflow
decision and lets the signed Profile choose the provider mode. No Worker or Profile
capability array is required for admission, `--dangerously-skip-permissions` is never
used, provider settings still control which extra tools are permitted, and slash command
expansion is disabled. Reference: [AGY headless documentation](https://www.agy.dev/docs/cli/headless/).

**Denied actions.** AGY ends a turn with `status: SUCCESS` even when it refused an
action (for example a file write under `permission_mode: request-review`); the final
`result` then carries `denied_actions`. The Profile reads that list with a
`set_provider_error` action and the Engine reports a non-empty list as `permission_denied`
("Permission denied for: WriteToFile") instead of a successful answer; an empty or
missing list is not an error. Writes only run under `--dangerously-skip-permissions`
(`permission_mode: always-proceed`), which Syntila does not use, and the `restricted` and
`provider_default` mappings use `--mode`, which has no effect while slash commands are
disabled, so those runs can hit this failure.

## Release

A new Profile revision goes through Profile Lab: test locally against the installed AGY
CLI, then publish ([Profile Lab](../specifications/PROFILE_LAB.md)). Rebuild Connect and
the Engine before relying on a Profile that needs a newer Engine; changing Dart sources
does not update an installed service. Candidates admit only qualified AGY versions
(1.2.16 and 1.3.3 have been qualified); future versions need new discovery and
qualification evidence.

## Verification

Focused tests cover discovery filtering and exact execution, manual refresh, removed IDs,
explicit rejection, verified and unavailable states, cache corruption and version/Profile
invalidation (Engine), persistence and inventory filtering (Connect), and source, digest,
version, effort and privacy checks (Cloud), alongside the shared session, timeout,
cancellation and malformed-output suites. Fixture providers prove routing, not account
entitlement or a signed-release rollout; real AGY runs are opt-in
([First-party Worker testing](FIRST_PARTY_WORKER_TESTING.md)).
