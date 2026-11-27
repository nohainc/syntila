# Tool Profile v1 Specification

**Decision:** [ADR-015](../decisions/ADR-015-first-party-worker-v1-contract.md)
(official Worker Types resolve through signed Profiles). Publication, signing and
delivery are in [Worker Profile V9](WORKER_PROFILE_V9.md); authoring is in
[Profile Lab](PROFILE_LAB.md); the evidence format is the
[Tool Profile evidence contract](TOOL_PROFILE_EVIDENCE_CONTRACT.md).

## Purpose

A Tool Profile is the declarative contract the generic CLI Worker Engine uses to
integrate one approved local CLI tool (one Profile per Worker Type). It is
provider-specific data constrained by a finite schema, never executable code. The
authoritative schema is the TypeScript validator
`packages/tool-profile/src/index.ts` (it exports `TOOL_PROFILE_LIMITS` and a JSON
Schema) with its Dart counterpart in `packages/tool_profile_v1`; the two must stay
semantically aligned. This document explains the semantics. Official Profile files
live in `apps/profile_lab/assets/profiles/` (`chatgpt`, `gemini`, `claude`,
`copilot`, `grok`).

## Design principles

1. Arguments are structured arrays, never shell strings; Profiles never enable shell
   execution.
2. Placeholders come from a closed list; selectors use a bounded property-only
   syntax; match and action rules use a fixed finite set.
3. No loops, expressions, arbitrary file I/O, network access or helper subprocesses.
   The only filesystem read is the typed local JSON config check (see Passive probe).
4. Engine hard limits override Profile values; unknown fields are rejected at every
   Profile object, and payloads over 256 KiB are rejected.
5. Material provider behavior changes should be a new Profile revision, not large
   in-profile branching. Normal users do not edit official Profiles.

**Schema evolution gate.** v1 is closed: no escape hatches, expressions, scripts or
provider-only interpreter branches. An unsupported CLI behavior needs (1) the
concrete provider behavior and the missing primitive, (2) evidence it is generic
across integrations (fixture CLI where practical), (3) justification for any
integration-specific handling, (4) an update to the
[authorization model](AUTHORIZATION_MODEL.md) and this spec with the new authority,
inputs and bounds before implementation, and (5) a schema v2 only when existing finite
primitives cannot express it. A v2 would have its own strict validator and
interpreter; v1 payloads are never reinterpreted, and Connect and the Engine reject
unsupported schema versions before execution. No v2 exists.

## Top-level shape

```json
{
  "schemaVersion": 1,
  "profileDefinitionId": "chatgpt-codex",
  "releaseVersion": 10,
  "logicalWorkerTypeId": "chatgpt",
  "engineFamily": "cli",
  "engineCompatibility": { "min": "1.2.0", "maxExclusive": "2.0.0" },
  "providerTool": {}, "environment": {}, "probe": {}, "execution": {},
  "session": {}, "model": {}, "timeout": {}, "sandbox": {}, "progress": {},
  "activity": {}, "usage": {}, "errors": {}, "context": {}, "capabilities": [],
  "compatibilityOverrides": []
}
```

`activity`, `context` and `capabilities` are optional; `usage` is optional in the
schema but required for publication. `capabilities` (a unique list drawn from
`authorized_context_read`, `thread_write`, `test_execution`,
`independent_verification`) states what the Worker Type can do for a Workflow Step;
a Profile without it makes no claim and Cloud applies no extra filter.

**Identity.** `profileDefinitionId` is a bounded stable ID, `releaseVersion` a
positive monotonic integer (the published revision), `engineFamily` is `cli`, and
`logicalWorkerTypeId` matches the Worker catalog entry (the stable product identity;
a Worker Type can move to a replacement definition).

**Engine compatibility.** Connect and the Engine reject a Profile outside the running
Engine's range, using full SemVer precedence (prerelease ordered, build metadata
ignored) through the shared comparator.

**Policy ownership.** Cloud resolves workflow policy and carries it in the
assignment. A Profile needs no capability declaration for Chat or Work; its signed
sandbox mapping decides provider arguments, and the web app decides which Workflows
and Workers can be selected. Chat's `provider_default` policy expands to
`--sandbox read-only` and Work's `restricted` to `--sandbox workspace-write` for
Codex; AGY uses `--mode plan` for Chat and `--mode accept-edits` for Work. Argument
expansion is tested for the base layout and every override layout, fresh and resumed.

## Provider tool declaration

```json
{
  "providerTool": {
    "name": "Codex CLI",
    "executableCandidates": ["codex"],
    "discovery": { "standardLocations": ["{{home}}/.local/bin"], "allowPathSearch": true },
    "versionProbe": {
      "arguments": ["--version"], "timeoutMs": 10000, "source": "stdout",
      "extract": { "kind": "regex_capture", "patternId": "semver" }
    }
  }
}
```

The Engine runs the discovered executable with `versionProbe.arguments`, bounded by
`timeoutMs`, and extracts only from the configured stream with the declared rule;
pattern IDs are Engine-owned, never user regular expressions. Profile Lab and the
Engine share this interpreter.

The detected version is informational. Profiles declare no support range;
`providerTool.supportedVersions` is accepted for old payloads but never gates
readiness, execution, admission or publication, and new Profiles omit it.
Version-specific overrides select solely by their own `providerVersion` range; other
versions use the base Profile. The probe still requires the CLI to start and answer.

**Discovery restrictions.** Candidate names contain no path separators and no
absolute Profile paths; standard locations use approved placeholders only; the Engine
owns path count and depth and adds generic safe locations (user CLI directories,
`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`). A cached absolute path is
tried first only after re-checking identity, bounds, expected name and executable
status. With `allowPathSearch` the Engine searches the inherited `PATH` independently
of the environment passed to the provider. Grok may also use `{{home}}/.grok/bin`. No
Syntila-specific variable is needed for discovery.

## Placeholders and environment

Allowed placeholders: `{{prompt}}`, `{{model}}`, `{{sessionId}}`, `{{timeoutMs}}`,
`{{timeoutSeconds}}`, `{{workingDirectory}}`, `{{home}}`, `{{workerStateDirectory}}`,
plus `{{reasoningEffort}}` and the slot-scoped `{{additionalDirectory}}`,
`{{mcpConfigPath}}`, `{{mcpServersToml}}` (the same servers as an inline TOML table
for CLIs configured by a `-c` override) and `{{mcpServer}}` (inside a
`forEachMcpServer` slot). Substitution never invokes a shell; unknown placeholders fail
validation; a missing value for a referenced placeholder is a controlled execution
failure. `timeoutMs` is `max(1, assignmentTimeoutMs - providerReserveMs)` and
`timeoutSeconds` its ceiling in seconds (minimum 1).

`environment.passthrough` names must satisfy the Engine policy (no reserved Syntila
or Cloud secrets); `environment.set` holds bounded constants. Whole-environment
inheritance is forbidden and Profiles cannot remove Connect's baseline or safety
values; the Engine builds the final environment.

## Probes

**Passive probe** never invokes a model. Each check runs arguments on the
already-resolved executable (never a second program) with a timeout,
`successExitCodes` and a `failureIssueCode`. A bounded **config check**
(`configChecks`, at most 8) may read one small JSON file below the Engine-approved
home directory: `root: "home"`, a relative path with no `.` or `..`, `format: "json"`,
`maxBytes` at most 64 KiB. The Engine applies property-only selectors and returns only
passed, warning or failed plus a stable issue code, never file contents. Missing,
malformed and oversized files have declared finite outcomes (`onMissing` is not an
authentication failure unless explicitly `failed`); no globbing, directory listing,
symlink traversal or other roots. `requiredEnvironmentAny` checks names for non-empty
values and `whenEnvironmentMissing` decides the result; values are never returned.

**Live probe** is an explicit test with a Syntila-controlled prompt (`Reply with exactly
the word OK. Do not use tools.`), a stateless session and a 30-second ceiling; the
final text must equal `OK` after trimming. It may consume quota.
`probe.live.requiredForReadiness` ties scheduling readiness to a successful live test
for the current Profile digest and CLI version (passive discovery does not
authenticate the account).

## Execution

```json
{
  "execution": {
    "arguments": [
      "--ask-for-approval", "never", {"sandboxPolicyMapping": true},
      "exec", "--json", "--cd", "{{workingDirectory}}",
      {"modelArguments": true}, {"sessionResumeArguments": true},
      {"ifAbsent": "sessionId", "ifSessionPolicy": "stateless", "values": ["--ephemeral"]},
      {"providerTimeoutArguments": true}, "-"
    ],
    "stdin": { "mode": "raw_text", "value": "{{prompt}}" },
    "output": { "mode": "jsonl" }
  }
}
```

Conditional argument forms are fixed constructs, not expressions. Allowed conditions:
a known field present, absent, equal, not equal, one of bounded constants or of a
JSON type; session-policy equality; the bounded Engine execution policy. Every
argument list has exactly one `{"sandboxPolicyMapping": true}` slot and one
`{"providerTimeoutArguments": true}` slot, one `{"modelArguments": true}` slot when
model arguments are declared, and one `{"sessionResumeArguments": true}` slot when
sessions are supported; each inserts the matching section's fixed vector at that
position.

- **Additional folders.** At most one `{"forEachAdditionalDirectory": [...]}` slot
  (1–8 values, one containing `{{additionalDirectory}}`) repeats once per
  Connect-verified folder in `execute.request.additionalDirectories`. When an
  assignment has additional folders, the base list and every override that replaces it
  must contain the slot, otherwise Connect fails the assignment rather than run
  without them.
- **MCP configuration.** At most one `{"mcpConfigArguments": ["--mcp-config",
  "{{mcpConfigPath}}"]}` slot (1–8 values). With the slot, the Engine always writes a
  per-execution file `{"mcpServers": {name: {command, args, env}}}` (empty map when
  the request has none) from the servers the user consented to for that Step, in a
  fresh owner-only directory deleted afterwards, and emits the slot arguments;
  Profiles must use the CLI's isolation flags so other MCP configuration is not merged.
  If servers exist and the Profile has no slot, execution fails ("Worker Profile does
  not support MCP servers"); servers are never dropped silently. Bounds: 8 servers,
  names `[a-z0-9][a-z0-9_-]{0,63}`, absolute command, 32 arguments, 16 environment
  entries, no `SYNTILA_*` names. CLIs that only read a global settings file are not
  covered ([ADR-028](../decisions/ADR-028-mcp-integration.md),
  [authorization model](AUTHORIZATION_MODEL.md#mcp-server-configuration)).
- **Stdin.** `raw_text`, or `json_object` with a template the Engine serializes
  (`appendNewline` optional); raw JSON strings are never interpolated.
- **Output modes.** `plain_text`, `single_json`, `jsonl` (blank lines ignored; a
  malformed non-empty line or output over the limits is a controlled provider
  failure). Bounds: prompt and stdin 1 MiB, expanded argv 128 KiB, total output 4
  MiB, JSONL line 512 KiB, 10,000 events, normalized final text 512 KiB, session ID
  256 characters.
- **Sandbox mapping.** `sandbox.mappings` define finite vectors for `restricted`,
  `provider_default` and `full_access`. Connect assignments (protocol 4.0+) select
  only `restricted` or `provider_default` (default `restricted`); `full_access` is a
  schema-level mapping for a separate explicit authorization path and is not
  representable in normal assignments. A Profile cannot broaden local permissions.
- **Timeouts.** `timeout.providerArguments` maps the assignment timeout (for example
  `["--print-timeout", "{{timeoutSeconds}}s"]`) and `providerReserveMs` is
  subtracted; the Engine's own hard deadline and cleanup grace always win.

## Selectors, events and results

Selectors (`$.type`, `$.item.text`) start at the root, traverse object properties
only, address own data properties (no prototype properties), and have bounded depth
(16) and length (256); no filters, recursive descent or scripts.

Event rules map provider events to Engine semantics; progress rules are evaluated in
source order and the **first matching rule wins** (put specific rules before
fallbacks), and actions in a matched event rule run in order. Actions are fixed:
`set_session`, `set_final_text`, `append_final_text`, `clear_final_text`,
`set_terminal_status`, `set_provider_error`, `emit_progress`, `mark_success`,
`mark_failure`.

- `append_final_text` supports providers that stream the answer in chunks;
  `clear_final_text` (no selector) discards what was built so far, so text written
  before a tool call stays narration (Grok clears on each `tool_call`). Both share the
  512 KiB limit.
- `set_provider_error` accepts a selector yielding a list: a non-empty list means the
  provider refused actions (for example AGY `denied_actions`) and is reported as
  `permission_denied` even if the turn says success.
- Optional `execution.failureExtraction` selectors (`nativeErrorCode`,
  `providerErrorText`, `failedRunResponse`, optional `source`) extract the provider's
  own failure details from the failing event; native codes never come from exit codes.
  Profiles without it produce canonical-only failures. The details contract and
  encryption are in [Work v1](WORK_V1_CONTRACT.md#run-details-and-provider-failures).

**Terminal result.** Structured output succeeds only with exit code zero, a
`mark_success` action and non-empty final text; `mark_failure`, a provider error,
cancellation or an Engine timeout fails it. `plain_text` needs non-empty text and
exit zero. A failed result uses the first matching error mapping, except Engine
cancellation and deadline outcomes, which take precedence. The interpreter returns
one bounded shape: terminal success or failure, final text, observed session ID,
terminal status, Engine message-key progress and an optional issue code.

**Progress.** `progress` rules pick Engine-owned safe message keys (with an optional
percentage); raw provider content is never forwarded. JSONL Profiles may declare
`activity.mappings`: strict bounded conditions (`equals`, `not_equals`, `one_of`,
`type_is`, `exists`) producing a normalized activity type (`execution.*`,
`model.*`, `message.updated`, `tool.started|completed|failed`), status, title,
optional ID and safe scalar details. Unknown fields, unsafe extractors and executable
transforms are invalid, and Profile Lab replays a sanitized fixture bound to the
candidate digest ([Worker activity](WORKER_ACTIVITY_V1.md)).

**Errors.** `errors.mappings` map bounded evidence (exit code, terminal status value,
an Engine-approved stderr pattern, missing terminal result, or a structured
provider-error selector) to stable codes: `provider_authentication_required`,
`provider_tool_unavailable`, `unsupported_provider_tool_version`,
`model_not_supported`, `permission_denied`, `quota_exhausted`, `provider_unavailable`,
`deadline_exceeded`, `cancelled`, `session_resume_failed`, `context_limit_exceeded`,
`provider_failure`. The first matching mapping wins; the Engine may still report its
own deadline or protocol-integrity failure. Stderr pattern IDs are a finite enum. The
`session_unavailable` pattern mapped to `session_resume_failed` is what permits the
Engine to invalidate a rejected native handle and reconstruct once
([Conversation continuity](CONVERSATION_CONTINUITY_V1.md#local-session-safety)); it
needs an updated Engine and a newly published Profile. `context.overflow.markers`
(case-insensitive text matched against stderr, provider error and terminal status)
identify a context-window overflow, `context.autoCompaction` arguments (placed by an
`autoCompactionArguments` slot) keep the CLI's own compaction on, and
`context.compaction` sends an on-demand prompt such as `/compact` to a resumed
session.

## Sessions

```json
{ "session": { "supported": true, "formatId": "codex-thread-v1",
  "compatibleFormatIds": ["codex-thread-v1"], "extract": "$.thread_id",
  "resumeArguments": ["resume", "{{sessionId}}"], "requireObservedIdMatch": true } }
```

For a durable session an observed provider session ID must exist, and a resumed ID
must equal the stored one; a mismatch is a hard `session_resume_failed`. `formatId`
identifies the provider's local session format and a Profile must list its own format
in `compatibleFormatIds` (older formats only when declared safe). The Engine
partitions records by logical Worker, Profile definition, provider tool and logical
`sessionKey`, resumes a stored ID only when the active Profile declares the stored
format compatible, and otherwise starts fresh and replaces the mapping after
success. `session.executionPolicyBound` (default false) declares that the provider
fixes its sandbox at creation and refuses to resume under another (Grok Build):
the Engine stores the policy with each session and, on a mismatch, rebuilds from the
canonical bootstrap or fails with `session_resume_failed`; records without a stored
policy count as different. Ownership, last model and effort, and synchronized
revisions are in [Worker sessions](CONVERSATION_CONTINUITY_V1.md#worker-sessions).

## Model, effort and discovery

```json
{ "model": { "supported": true, "arguments": ["--model", "{{model}}"],
  "unknownModelPolicy": "pass_through" } }
```

`unknownModelPolicy` is `pass_through` or `profile_allowlist`; there is no silent
model substitution. Optional `model.selectionMode` (`separate` default, or
`combined`), `model.executionOptions` (`discovery: "profile_catalog"`,
`modelSwitchSupported`, `effortSupported`, `defaultModelId`, `effortMapping`) and
`model.selectionMapping` (Engine 1.2.0) shape what is offered; see
[Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md) and
[Provider discovery and normalization](MODEL_DISCOVERY_NORMALIZATION.md). When
`modelSwitchSupported` is false, a different model needs a new native session
bootstrapped from canonical history, and a failed attempt keeps the previous mapping.

`model.discovery` (schema 1: `arguments`, `timeoutMs` 100–10000, `format`,
`idPrefix`, optional `excludeIds`) runs on the resolved CLI without a shell. For a
discovery-backed Profile the runtime catalog is the only source of choices; the
Profile carries no fallback catalog or guessed effort rules, except where noted.

| `format` | Source | Notes |
| --- | --- | --- |
| `tsv` | `id<TAB>label<TAB>efforts<TAB>default` rows | Last two fields optional. With `effortVariants` (`label_parenthesized_suffix` + `separator`, requires `selectionMode: combined`, Engine 1.3.0, excludes `selectionMapping`) families and efforts are derived from the rows (Gemini). |
| `codex_app_server` | JSON-RPC `initialize`, then `model/list` | `id` is the logical selection, `model` the native ID kept locally. |
| `clap_possible_values` | `[possible values: a, b]` from a flag run without a value | IDs only; efforts come from `model.catalog` / `supportedReasoningEfforts`. |
| `indented_list` | One model per indented stdout line | Grok; optional bullet and `(default)` note. |
| `copilot_sdk_rpc` | `auth.getStatus` then `models.list` over Content-Length JSON-RPC | Fails with `provider_authentication_required` when signed out; skips `disabled` models; adds no `auto` entry. |
| `claude_models_api` | Anthropic `GET /v1/models` | Credential from `ANTHROPIC_API_KEY` or the Claude Code sign-in, sent only to `api.anthropic.com`; skips retired models. |

`discovery.effortProbe` (`use_one_of`) runs `arguments` per discovered model (at most
32, `{{model}}` replaced) with an effort the CLI rejects before any model request, and
reads the list after `use one of:`; a model whose output names no efforts, or whose
probe fails, is offered without an effort choice. Results are cached per Profile
digest and CLI version. Discovered IDs in `excludeIds` are never offered, and a
catalog entry never adds a model the CLI did not list. Discovery needs no model call.

## Version-specific overrides

At most 16 bounded `compatibilityOverrides` with non-overlapping `providerVersion`
ranges (a CLI version matching none runs the base Profile; overrides never reject a
version). Only `executionArguments`, `versionProbeArguments`, `progress`,
`errorMappings` and `activity` may be overridden, each with fixtures. Materially
different behavior should be a new revision.

## Usage command

Optional `usage: { "arguments": [...], "timeoutMs": 1000-60000 }` (optionally
`jsonRpc: { "method", "framing" }`, where framing is `newline`, the default with an
`initialize` handshake, or `content_length`, LSP-style with no handshake and 64 KiB
frames). The Engine runs the declared provider executable, answers a `usage.request`
frame with `usage.result` (`output`, `errorOutput`, `exitCode`, `truncated`), strips
terminal escapes and caps each stream at 64 KiB. Cloud, Connect and the Engine never
parse the report: the Profile owns how usage is read and the text travels unchanged;
only the app normalizes it for display (`worker_usage_parser.dart`), showing the
original text whenever a report does not match a known format exactly. A Profile
without `usage` reports `unavailable`. Cloud relays on demand through
`/api/workers/:workerId/usage` (Connect owner only), never storing the result. Pick a
command that spends no model credits: Copilot uses `account.getQuota` over
`content_length` (its `-p /usage` would be an ordinary prompt), and Grok uses
`grok models`, which proves the CLI runs but not that it is signed in.

## Signing, immutability and validation

A published Profile revision is immutable: its payload, revision and digest never
change, and any change is a new sequential revision. Cloud keeps one current Profile
and retained history; there are no channels, promotion or rollback pointers
([Worker Profile V9](WORKER_PROFILE_V9.md)). The digest is the lowercase SHA-256 of the
canonical JSON of the complete validated Profile. Cloud signs that digest when it
delivers a Profile and Connect verifies the proof against build-time trust roots, then
rechecks the digest, schema, Worker identity and Engine compatibility
([Connect CLI and services](CONNECT_CLI_AND_SERVICES.md)). Revocation invalidates a
digest everywhere.

An unsigned local candidate (Profile Lab) runs only in Profile Lab's isolated sandbox
and never enters Connect's trusted Profile store or Cloud scheduling, apart from the
explicit loopback development path in [Profile Lab](PROFILE_LAB.md#development-access-and-unsigned-execution).
Editing a candidate changes its digest and invalidates earlier evidence.

Validation levels:

- **Static:** exact schema, bounds, identifiers, placeholders, selectors, actions,
  compatibility ranges, forbidden environment names and shell constructs.
- **Fixture:** version parsing, probes, result extraction, errors, progress, session
  start and resume, version-specific variations.
- **Real acceptance (opt-in):** the installed provider CLI, passive and live probes, a
  representative assignment and Thread write, durable session start and resume, and
  bounded timeout and cancellation through the Connect supervisor. Run from
  `apps/connect` with `SYNTILA_TEST_REAL_PROFILE_<CHATGPT|GEMINI>=1` and
  `SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR=<path>` for
  `test/tool_profile_real_acceptance_test.dart`, or the
  `SYNTILA_TEST_ASSIGNMENT_PROFILE_*=1` variables for
  `test/tool_profile_assignment_acceptance_test.dart`. Artifacts hold versions and
  scenario results only, never credentials, prompts, output or file contents. Normal
  CI never enables real acceptance.

## Limits

`TOOL_PROFILE_LIMITS` is the exact list. Highlights: 256 KiB payload, 4,096
characters per general string, 256 per short label, 64 items per general array, 128
arguments, 128 event rules, 64 progress and error rules, 16 selector conditions per
rule, selector depth 16 and length 256, JSON template depth 16, 64 environment names,
8 config checks, 128 activity mappings, 16 compatibility overrides. Specific fields
may be tighter.

## Non-goals

Tool Profile v1 is not a shell script format, a Workflow language, a prompt-template
product, user-editable functionality, an arbitrary third-party extension mechanism,
a permission bypass, or a replacement for future non-CLI Engine families. If a
provider cannot be represented safely, a generic concept belongs in a new schema
version; a provider-specific one belongs in a specialized driver, not in a schema that
becomes a programming language.
