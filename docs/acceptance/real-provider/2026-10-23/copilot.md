# Copilot CLI local verification — 2026-10-23

## First-time Workspace configuration

The Workspace Profile endpoint previously required a matching Cloud inventory
row before returning a published Profile. A new Worker has no inventory row
until configured, but Workspace synchronizes its Profile before configuration.
That ordering reproducibly returned HTTP 404 and produced `Profile error` /
`Profile unavailable` warnings for an otherwise published Worker. Configure
could make the prerequisite appear later, but the initial error was a Cloud
authorization-order defect rather than evidence of an invalid Copilot Profile.

The endpoint now requires a valid, non-revoked Workspace runtime credential
and reads the current catalog Profile without requiring local inventory.
Unknown Workers and missing Profiles still return 404; corrupt Profiles still
fail verification. Download does not enable or configure the Worker.
The Service also distinguishes a successful download awaiting configuration
from an unavailable Profile: it reports `staged` with the label `Downloaded`
and `Setup required`. The payload remains inactive until a configured local
Worker's probe succeeds. Real download, verification and probe errors retain
their error presentation.

The SQLite-backed Cloud bootstrap/authentication tests passed (10 tests across
two files). Workspace's catalog coordinator and Worker view tests passed (17),
including a new case that stages the Profile with an empty registry, displays
`Setup required`, and activates it only after configuration and validation.
This scope exercises the changed HTTP read boundary and the Service's local
setup/presentation path without consuming provider quota.
`pnpm validate:workspace` also passed: analysis, 549 tests (21 skipped), and
`scripts/internal/check-workspace-service.sh`, which compiled the standalone Service,
started it headlessly against temporary state, and stopped it cleanly.

`pnpm validate:cloud` completed type checks; its tests reported 835 passed and
302 failed. The failures reproduce the existing fixture migration-order and
Profile-JSON constraint problems recorded below. `pnpm validate:engine`
stopped at the existing runtime-test formatting difference recorded below.
Neither component gate is claimed as passing.

Rollout requires a Cloud deployment and a rebuilt Workspace Service/client for
the additive `staged` Profile display state. Rebuilding Workspace alone cannot
change the server-side check. No database migration or provider Profile
republishing is required. Deployed application behavior has not been verified
by these source tests.

## Earlier provider probes

Tested macOS arm64, Copilot CLI 1.0.103, candidate Profile revision 6,
and the source CLI Worker Engine advertising version 1.3.0. Sanitized
executable observations are retained in [copilot.json](copilot.json).
This is local provider evidence, not signed application or publication evidence.

## Profile execution

The unmodified candidate initialized and discovered 31 listed models through
the Engine. `claude-haiku-4.5` was excluded. Auto completed a real request;
a durable second request recalled the first request's marker correctly.
Passive readiness is installation/discovery evidence, not authentication or
model availability evidence.

The bare `copilot --model` error contains a static list of possible IDs.
Explicit requests for `gpt-5.4-mini`, `gpt-5.3-codex`,
`claude-sonnet-5.5`, and `gpt-6-luna` failed with `Model ... is not available`.
Auto nevertheless resolved to `gpt-6-luna` and succeeded. The cause of that
discrepancy is unconfirmed; do not equate parser enumeration with account
entitlement. Keep discovered entries `listed` until execution verifies them.

Auto without an effort used `medium` in the captured request. Auto with `none`
succeeded and reported `none`; Auto with `low` or `max` failed before a model
call. Keep Auto's Profile effort list empty. Explicit `gpt-6-luna` requests
with `none`, `low`, or `max` failed at model availability, so these probes
cannot verify that model's effort table. Tiny `OK` prompts establish invocation
behavior, not quality, relative speed, or reasoning performance.

## Session statistics

The installed CLI supports `--usage-output-file`. A minimal reproduction is:

```sh
copilot --model auto --output-format json --stream off \
  --usage-output-file /tmp/copilot-usage.json \
  -p 'Reply with exactly: OK'
```

Run from an empty scratch directory. The recorded probes additionally disabled
custom instructions and built-in MCP servers and denied shell/write tools.

The file includes `modelMetrics.<model>.usage` with input, output, cache-read,
cache-write and reasoning tokens; request counts/costs; API duration;
`totalNanoAiu`; and `aiCreditsStatus`. The successful Auto sample reported
14,274 input tokens, 5 output tokens, 0 cache-read tokens, 14,271 cache-write
tokens, 0 reasoning tokens, and 2,710 ms API duration. Preserve the provider's
token categories and billing units rather than adding overlapping categories
or assuming request cost is a dollar value. A failed preflight also produced
a zero-usage file, so file existence does not establish success.

The JSONL terminal `result.usage` contains request cost, API/session duration
and code-change counts, but no token breakdown in this capture. A
`session.usage_checkpoint` event also carried an `accountingSnapshot` with
the detailed session totals. Raw checkpoint events contain internal tracing
metadata and should not be published wholesale.

GitHub documents interactive `/usage` as session accounting. It is not an
account-quota CLI subcommand. The existing Profile intentionally has no
top-level `usage` command: passing `-p /usage` is an ordinary prompt and must
not be used as a quota query.

## Account quota and structured model discovery

The CLI's experimental SDK transport offers a non-model quota query:

1. Start `copilot --headless --stdio` with the existing local CLI login.
2. Send JSON-RPC method `account.getQuota` with empty parameters.
3. Frame each request as `Content-Length: <UTF-8 byte length>\r\n\r\n<JSON>`;
   read the response using the same framing. This is not newline JSON.
4. Bound the deadline/output and terminate the child after reading the result.

The real call returned `quotaSnapshots` for `chat`, `completions`, and
`premium_interactions`, including entitlement, used requests, remaining
percentage, reset date, quota availability and token-based-billing flags.
All returned reset timestamps were already past at probe time. Treat them as
raw provider observations, not a verified current balance or future reset.
No credential was extracted or supplied in the RPC payload.

`models.list` returned an empty conversation-model array on the same install.
The SDK documents model metadata including capabilities, but this machine
could not supply it. A future account-aware discovery path should prefer
validated structured capabilities over guessed effort defaults when the CLI
actually returns those capabilities. Preserve the present distinction between
listed and verified models.

Syntila's existing `usage.jsonRpc` helper uses a newline transport and a
Codex initialization handshake. Merely setting its method to
`account.getQuota` would not work. Integrating this RPC requires a reviewed,
generic framing/handshake option and matching validators/tests; this
investigation does not introduce a provider-specific runtime branch.

Profile release 9 uses this call as its `usage` command through the new
generic `jsonRpc.framing: "content_length"` option. A real call through the
Engine's reader returned `chat`, `completions` and `premium_interactions`
snapshots in under a second; this time the `chat` reset date was in the future.

`copilot --headless --stdio` resolves the GitHub login through `gh` on
`PATH`. With `PATH=/usr/bin:/bin` (a Finder-launched app) `account.getQuota`
answers "Not authenticated"; adding only a directory containing `gh` fixes it.
The Workspace Service launch agent already puts `/opt/homebrew/bin` on `PATH`;
Profile Lab now adds the same directories when it starts the Engine.

## Activity events

Profile release 7 adds a declarative `activity` mapping (no provider adapter).
A real `copilot --output-format json --stream off --model auto` run that used
`bash` and `create` emitted these events, which the mapping reads:

| Copilot event | Activity |
|---|---|
| `assistant.turn_start` | `model.started` "Thinking" |
| `tool.execution_start` (`data.toolCallId`, `data.toolName`) | `tool.started` "Using a tool" |
| `tool.execution_complete`, `data.success == true` | `tool.completed` |
| `tool.execution_complete`, `data.success == false` | `tool.failed` |
| `assistant.message` with non-empty `data.content` | `message.updated` |

Tool arguments, shell output and message text are not mapped. Tool titles are
generic because Copilot tool names (`bash`, `create`, `view`, ...) are not a
documented closed set; the tool name is passed as a detail.
`copilot_profile_execution_test.dart` replays these events and checks the
emitted `WorkerActivity` frames.

## Validation and limits

- Focused Copilot discovery/Profile replay: 7 passed, including real-format
  authentication and unavailable-model errors.
- TypeScript Tool Profile package: 155 passed; the actual Copilot candidate is
  now included in the canonical publication-schema test.
- `pnpm validate:profile-lab`: analysis and all 64 tests passed.
- `pnpm validate:engine`: protocol (36) and Dart Profile (31) tests passed,
  then stopped on a pre-existing formatting difference in
  `packages/syntila_cli_worker_runtime/test/cli_streaming_runner_test.dart`.
- Separate Engine analysis passed. Its full tests initially had 86 passes,
  2 skips, and 2 fixture-startup timeouts in `activity_execution_harness_test`.
  Both timed-out tests passed on an isolated rerun with `--concurrency=1`.
- `pnpm validate:cloud`: type checks completed; 825 tests passed and 302
  failed. Repeated failures include the SQLite fixture applying
  `0083_copilot_worker.sql` before the V9 catalog identity columns exist;
  other fixtures hit a `profile_json` CHECK constraint. These broader gates
  remain open and are not claimed as passing.

Focused schema/replay tests plus real Engine execution are sufficient to verify
the candidate's observed invocation and session behavior. They do not qualify
every listed model/effort, read-only isolation, deployed Thread execution,
launchd/TCC/Keychain, or publication. No migration, activation or compatibility
contract was changed. Existing unrelated working-tree changes were preserved.

References: [CLI usage](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/overview),
[SDK client](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts),
[SDK RPC definitions](https://github.com/github/copilot-sdk/blob/main/nodejs/src/generated/rpc.ts).

## Account-aware model discovery (Profile release 10)

`copilot --model` lists every model the CLI knows, so a Free account was
offered models that failed with "is not available". Release 10 uses
`format: "copilot_sdk_rpc"` instead: `auth.getStatus`, then `models.list` on
`copilot --headless --stdio`.

On this machine (Free plan, `access_type_sku: free_limited_copilot`, signed in
through `gh`) `models.list` returned an empty list and the probe passed.
Discovery adds no `auto` entry: `copilot -p` without `--model` reported
`session.auto_mode_resolved` and answered, so the client's own Auto (no model)
already means Copilot Auto; an extra entry showed Auto twice in AX. With an empty `HOME` and no `gh` on `PATH`, discovery
reported `provider_authentication_required` with the sign-in instructions.
Paid-plan efforts come from each model's `supportedReasoningEfforts`; this has
only been checked against a replayed SDK response, not a paid account.

`gh` is not required: `auth.getStatus` reports `authType: gh-cli` here, but a
`copilot login` session works the same way. Usage already reads
`account.getQuota` from the same server, so `gh api` adds nothing.
