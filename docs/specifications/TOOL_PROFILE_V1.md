# Tool Profile v1 Specification

**Status:** Architecture v8 normative profile contract  
**Architecture:** [Architecture v8](../architecture/ARCHITECTURE_V8.md)  
**Decision:** [ADR-018](../decisions/ADR-018-generic-cli-worker-engine-and-tool-profiles.md)

## 1. Purpose

Tool Profile v1 is the declarative contract used by the generic Syntila CLI
Worker Engine to integrate one approved local CLI tool.

A Profile release is immutable, signed, independently versioned, provider/tool
specific, and constrained by a finite schema. It is never arbitrary executable
code.

## 2. Design principles

1. Arguments are structured arrays, never shell command strings.
2. Profiles never enable shell execution.
3. Placeholders come from a closed list.
4. Selectors use a bounded JSON-path-like syntax implemented by the Engine.
5. Match/action rules use a fixed finite operation set.
6. Profiles cannot define loops, arbitrary expressions, arbitrary file I/O,
   network access, or helper subprocesses. The sole bounded filesystem read is
   the typed local JSON config check defined in section 9.1.
7. Engine hard limits override Profile values.
8. Material provider behavior changes should prefer a new Profile release over
   large in-profile branching.
9. Profile releases are tested like code.
10. Normal users do not edit official Profiles.

## 3. Top-level shape

Conceptual JSON:

~~~json
{
  "schemaVersion": 1,
  "profileDefinitionId": "chatgpt-codex",
  "releaseVersion": 10,
  "logicalWorkerTypeId": "chatgpt",
  "engineFamily": "cli",
  "engineCompatibility": {
    "min": "1.2.0",
    "maxExclusive": "2.0.0"
  },
  "providerTool": {},
  "environment": {},
  "probe": {},
  "execution": {},
  "session": {},
  "model": {},
  "timeout": {},
  "sandbox": {},
  "progress": {},
  "errors": {},
  "compatibilityOverrides": []
}
~~~

Unknown fields are rejected unless a later schema version explicitly permits
extensions. The former top-level `capabilities` field is retired; v1 no longer
accepts or interprets it. Development databases must apply the destructive
release reset migration before authoring new releases.

The canonical v1 validator and inferred TypeScript model are maintained
together in [`packages/tool-profile/src/index.ts`](../../packages/tool-profile/src/index.ts).
The same source exports a JSON Schema representation. Its engine-owned bounds
are published as `TOOL_PROFILE_LIMITS`; the validator rejects payloads over
256 KiB and rejects unknown fields at every Profile-defined object.

The ChatGPT development starter is maintained in
[`chatgpt-codex.v1.json`](../../packages/tool-profile/test/fixtures/chatgpt-codex.v1.json).
The Cloud starter after ordered migrations must contain the same payload; the
provisioning test checks equality and the acceptance manifest's canonical
reference. The immutable baseline retains its original seed;
`0007_chat_profile_starter_attestation.sql` updates only that unchanged template.
`0008_codex_compatibility_approval_policy.sql` preserves explicit
`--ask-for-approval never` in the compatibility argument layout, updating only
the unchanged official starter from the preceding migration.
Profile Lab clones the optional Cloud starter rather than maintaining another
provider payload. Published releases and historical acceptance evidence remain
immutable when a development starter changes.

Chat's generic `provider_default` policy expands to `--sandbox read-only`;
Work's `restricted` policy expands to `--sandbox workspace-write`. Argument
expansion tests cover the default and all compatibility override layouts, both
fresh and resumed conversations, and preserve the existing full-access mapping.

Workflow policy is resolved by Cloud and carried in the assignment. Workspace
does not require a Worker or Profile capability declaration for Chat or Work.
The Profile's signed sandbox mapping still determines the provider arguments;
the web app owns which workflows and Workers may be selected.

The Antigravity starter uses `--mode plan` for Chat's provider-default policy
and `--mode accept-edits` for Work's restricted policy. AGY does not expose a
separate Syntila-style chat mode; plan mode is the closest provider mode and
the web app remains responsible for workflow selection. See the official
[sandbox contract](https://www.agy.dev/docs/sandbox/) and
[execution modes](https://www.agy.dev/docs/cli/modes/).

### 3.1 Schema evolution gate

Profile v1 is closed. Do not add optional escape hatches, expressions, scripts,
or provider-only interpreter branches to make one integration fit. For an
unsupported CLI behavior, the proposal must:

1. document the concrete provider behavior and the missing v1 primitive;
2. test whether the behavior is generic across integrations, using at least a
   fixture CLI/Profile where practical;
3. justify any integration-specific handling and explain why bounded Profile
   data cannot represent it safely;
4. update the [authorization model](AUTHORIZATION_MODEL.md) and this
   specification with the new authority, inputs, and resource bounds before
   implementation;
5. add schema v2 only when the behavior needs new Profile semantics that cannot
   be expressed by the existing finite v1 primitives.

When v2 is justified, it must have its own strict versioned validator and
interpreter semantics. v1 payloads continue through the unchanged v1 validator;
they are never reinterpreted as v2, and neither validator accepts unknown
fields. Workspace and Engine reject unsupported schema versions before
execution. Profile releases remain immutable and signed over the schema
version and complete behavior payload. No schema v2 is defined by this
specification.

## 4. Identity

Required:

~~~text
schemaVersion
profileDefinitionId
releaseVersion
logicalWorkerTypeId
engineFamily
~~~

Constraints:
- identifiers are bounded stable IDs;
- releaseVersion is a positive monotonic integer within one definition;
- engineFamily v1 is `cli`;
- logicalWorkerTypeId matches the admitted Worker catalog entry.

The logical Worker Type ID is the stable product identity from
`worker_catalog`; `profileDefinitionId` identifies its implementation
binding. A Worker can move to a replacement Profile Definition without
changing its product identity. Releases remain versioned within one Profile
Definition, and Cloud allows at most one active Definition per Worker.

## 5. Engine compatibility

~~~json
{
  "engineCompatibility": {
    "min": "1.2.0",
    "maxExclusive": "2.0.0"
  }
}
~~~

Workspace/Engine rejects a Profile outside the running Engine version range.
Semantic-version checks use full SemVer precedence, including prerelease
ordering; build metadata does not affect compatibility. Both Engine and
Workspace use the shared Tool Profile v1 comparator.

## 6. Provider tool declaration

Conceptual:

~~~json
{
  "providerTool": {
    "name": "Codex CLI",
    "executableCandidates": ["codex"],
    "discovery": {
      "standardLocations": [
        "{{home}}/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin"
      ],
      "allowPathSearch": true
    },
    "versionProbe": {
      "arguments": ["--version"],
      "timeoutMs": 10000,
      "source": "stdout",
      "extract": {
        "kind": "regex_capture",
        "patternId": "semver"
      }
    }
  }
}
~~~

The Engine executes `providerTool.executableCandidates`' discovered executable
with the declared `versionProbe.arguments`, bounded by `versionProbe.timeoutMs`.
It extracts only from the configured `source` stream and applies the declared
`extract` rule. The CLI Worker Engine and Profile Lab use the same shared
runtime interpreter for this operation.

The detected CLI version is informational. Profiles do not declare provider CLI
support ranges. Bundled Profile files and new Profile Lab drafts omit
`providerTool.supportedVersions`; both Dart and TypeScript validators accept its
absence without adding a default field or changing the candidate digest.
Existing payloads that contain the field remain readable, but its values never
gate readiness, execution, admission, or publication. Version-specific overrides
are selected solely by their own `providerVersion` ranges (section 23); versions
outside those ranges use the base Profile.

The version probe still requires the CLI to start and answer its version command.
Profile Lab records the exact tested version as evidence, without inferring
support limits from that test. Publication continues to require fresh evidence
for the exact candidate digest; removing ranges changes the digest and requires
retesting before publication. Engine compatibility bounds remain enforced.

### 6.1 Discovery restrictions

- executable candidate names cannot contain path separators;
- arbitrary Profile absolute executable paths are forbidden;
- standard locations may use approved path placeholders only;
- Engine owns maximum path count/search depth;
- Workspace/Engine may add generic safe OS locations;
- a cached absolute path may be tried first only after checking its identity,
  path bounds, expected executable name, and executable status again;
- when `allowPathSearch` is true, Engine searches the inherited OS `PATH`
  independently of the environment keys passed through to the provider;
- no Syntila-specific environment variable is required for discovery.

Engine generic locations include the common user CLI directories under the OS
home directory and standard system locations such as `/opt/homebrew/bin`,
`/usr/local/bin`, `/usr/bin`, and `/bin` on macOS. These are added by Engine;
Profiles do not need to enumerate every normal installation location.

## 7. Closed placeholders

Tool Profile v1 may use only approved placeholders:

~~~text
{{prompt}}
{{model}}
{{sessionId}}
{{timeoutMs}}
{{timeoutSeconds}}
{{workingDirectory}}
{{home}}
{{workerStateDirectory}}
~~~

The Engine performs substitution without invoking a shell.

Unknown placeholders fail Profile validation.

No nested expressions or function calls exist.

At execution time a missing value for a referenced placeholder is a controlled
Profile execution failure. `timeoutMs` expands to
`max(1, assignmentTimeoutMs - providerReserveMs)`; `timeoutSeconds` is the
ceiling of that value in seconds, with a minimum of one.

## 8. Environment

Conceptual:

~~~json
{
  "environment": {
    "passthrough": [
      "CODEX_HOME",
      "XDG_CONFIG_HOME"
    ],
    "set": {
      "NO_COLOR": "1"
    }
  }
}
~~~

Rules:
- passthrough names must satisfy Engine environment policy;
- reserved Syntila/Cloud secret variables cannot be requested;
- complete parent environment inheritance is forbidden;
- constant values are bounded;
- approved placeholders may be used where the schema permits;
- Profiles cannot remove Workspace-enforced baseline/safety values.

The Engine constructs the final provider environment.

## 9. Passive probe

A passive probe must not invoke a provider model.

Conceptual:

~~~json
{
  "probe": {
    "passive": {
      "checks": [
        {
          "id": "authentication",
          "arguments": ["login", "status"],
          "timeoutMs": 10000,
          "successExitCodes": [0],
          "failureIssueCode": "provider_authentication_required"
        }
      ]
    }
  }
}
~~~

The already-resolved provider executable is always used. A Profile cannot
execute a second arbitrary program for probes.

### 9.1 Bounded local config check

A passive probe may read a small JSON file below the Engine-approved local home
directory through `configChecks`. A check must declare `root: "home"`, a
relative path with no `.`/`..` segments, `format: "json"`, and a `maxBytes`
value no greater than 64 KiB. The Engine opens only that file, parses bounded
JSON, applies the same property-only selectors as event rules, and returns
only a passed/warning/failed state and stable issue code. It never exposes file
contents to Cloud or the UI. Missing, malformed, and oversized files are
handled by declared finite outcomes. No globbing, directory listing, symlink
traversal, arbitrary roots, or other file reads are permitted. Required
environment variables can be checked by name for non-empty values using
`requiredEnvironmentAny`; if none are present, the rule's explicit
`whenEnvironmentMissing` result applies. A missing file or home directory uses
`onMissing` and does not imply an authentication failure unless that outcome
is explicitly `failed`. The conditions and no-match result make the config
decision exhaustive. Values are never returned.

## 10. Live probe

Live probe uses normal Profile execution with a Syntila-controlled test
request and a hard 30-second timeout ceiling:

~~~text
Reply with exactly the word OK. Do not use tools.
~~~

The Engine owns the prompt and exact expected final text `OK`. Profiles cannot
change either. The Engine runs the Profile's normal transport and output parser
with a stateless session, applies the remaining request deadline, and fails
closed when the final text does not exactly match `OK` after trimming.

Live tests are explicit because they may consume provider quota.

## 11. Execution arguments

Conceptual Codex-like Profile:

~~~json
{
  "execution": {
    "arguments": [
      "--ask-for-approval", "never",
      {"sandboxPolicyMapping": true},
      "exec",
      "--json",
      "--color", "never",
      "--skip-git-repo-check",
      "--cd", "{{workingDirectory}}",
      {"modelArguments": true},
      {"sessionResumeArguments": true},
      {"ifAbsent": "sessionId", "ifSessionPolicy": "stateless",
       "values": ["--ephemeral"]},
      {"providerTimeoutArguments": true},
      "-"
    ],
    "stdin": {
      "mode": "raw_text",
      "value": "{{prompt}}"
    },
    "output": {
      "mode": "jsonl"
    }
  }
}
~~~

Conditional argument forms are fixed schema constructs, not expressions.
Every execution argument list has exactly one
`{"sandboxPolicyMapping": true}` slot. The Engine replaces it with the
arguments mapped for the authorized execution policy, preserving provider CLI
argument position. It also contains one `{"providerTimeoutArguments": true}`
slot and contains one `{"modelArguments": true}` slot when model arguments are
declared, plus one `{"sessionResumeArguments": true}` slot when sessions are
supported. These markers insert the corresponding section's fixed argument
vector at that position. The profile's `sandbox.mappings` define finite vectors
for `restricted`, `provider_default`, and `full_access`.

An execution argument list may contain at most one
`{"forEachAdditionalDirectory": ["--add-dir", "{{additionalDirectory}}"]}`
slot (1–8 values, at least one containing `{{additionalDirectory}}`). The
Engine repeats the values once per Workspace-verified additional folder from
`execute.request` `additionalDirectories`, in order, and emits nothing when
there are none. `{{additionalDirectory}}` is invalid anywhere else. When an
assignment has additional folders, the base argument list and every
compatibility override that replaces it must contain the slot; otherwise the
Workspace fails the assignment instead of running without the folders.

Workspace Local Worker Protocol 4.0 assignments can select only `restricted`
or `provider_default`; omitted values default to `restricted`. `full_access`
remains a schema-level profile mapping for products with a separate explicit
authorization path and is not representable in normal assignments.

Allowed v1 conditions are limited to:
- known field present/absent, equals/not-equals, one-of bounded constants, or
  has a JSON value type;
- session policy equality;
- bounded Engine-defined execution policy.

### 11.1 MCP configuration slot (ADR-028)

An execution argument list may contain at most one
`{"mcpConfigArguments": ["--mcp-config", "{{mcpConfigPath}}"]}` slot (1-8
values, at least one containing `{{mcpConfigPath}}`). `{{mcpConfigPath}}` is
invalid anywhere else. Per [section 3.1](#31-schema-evolution-gate):

1. **Provider behaviour / missing primitive.** Official CLIs can load MCP
   servers from a config file given on the command line (for example
   `claude --mcp-config <file> --strict-mcp-config`). v1 has no way to pass a
   per-execution, Engine-generated file path. This is generic across CLIs that
   take a file-path flag; CLIs that only read a global settings file or use a
   different file format are **not** covered and need a later, separately
   justified primitive.
2. **Generic.** The slot names no provider; the Engine knows only the
   `{"mcpServers": {name: {command, args, env}}}` file shape.
3. **Authority.** The Engine writes the file only from `mcpServers` in
   `execute.request`, which the Workspace Service populates solely from servers
   the user consented to and enabled for that Step. See the
   [authorization model](AUTHORIZATION_MODEL.md#mcp-server-configuration).
4. **Semantics.** When the request carries no `mcpServers`, the slot emits
   nothing. When it does and the Profile has no slot, the execution fails
   with "Worker Profile does not support MCP servers"; servers are never
   dropped silently. The file lives in a fresh owner-only directory (mode 700,
   file 600 on POSIX) and is deleted when the execution ends; the user's own
   CLI configuration is never read or modified.
5. **Bounds.** At most 8 servers; names `[a-z0-9][a-z0-9_-]{0,63}`; command an
   absolute path; at most 32 arguments and 16 environment entries; no
   `SYNTILA_*` environment names.

No schema version change: the slot is an additive fixed construct like
`forEachAdditionalDirectory`, and existing signed releases are unaffected.
Official Profile releases adopt the slot only through a normal new release
with acceptance evidence.

## 12. JSON stdin template

For tools requiring structured stdin:

~~~json
{
  "stdin": {
    "mode": "json_object",
    "value": {
      "event": "user",
      "message": {
        "content": "{{prompt}}"
      }
    },
    "appendNewline": true
  }
}
~~~

The Engine serializes JSON. Profiles do not interpolate raw JSON strings.

## 13. Output modes

Tool Profile v1 supports:

~~~text
plain_text
single_json
jsonl
~~~

For `jsonl`, each bounded line is decoded as one JSON value.
Blank lines are ignored. A malformed non-empty line or output exceeding Engine
limits is a controlled provider failure. The v1 interpreter bounds prompt and
stdin at 1 MiB, expanded argv bytes at 128 KiB, total output at 4 MiB, each
JSONL line at 512 KiB, event count at 10,000, and normalized final text at 512
KiB. Session IDs are limited to 256 characters.

Required structured output that cannot be decoded is a controlled execution
failure.

## 14. Selectors

Profiles use a bounded selector syntax such as:

~~~text
$.type
$.thread_id
$.item.type
$.item.text
$.result.status
$.result.response
~~~

v1 selectors:
- begin at root;
- allow object-property traversal only;
- address own JSON data properties only and reject prototype properties;
- have bounded depth/length;
- do not support filters;
- do not support recursive descent;
- do not support script expressions.

## 15. Event rules

Finite rules map provider events into Engine semantics.

Progress rules are evaluated in source order and the first matching rule
wins. Profiles must put specific rules before a broader fallback. This makes
the Gemini `agent_response` mapping deterministic.

Conceptual:

~~~json
{
  "events": [
    {
      "when": [
        {"kind": "equals", "selector": "$.type", "value": "thread.started"}
      ],
      "actions": [
        {"type": "set_session", "selector": "$.thread_id"}
      ]
    },
    {
      "when": [
        {"kind": "equals", "selector": "$.type", "value": "item.completed"},
        {"kind": "equals", "selector": "$.item.type", "value": "agent_message"}
      ],
      "actions": [
        {"type": "set_final_text", "selector": "$.item.text"}
      ]
    }
  ]
}
~~~

Allowed actions v1:

~~~text
set_session
set_final_text
append_final_text
clear_final_text
set_terminal_status
set_provider_error
emit_progress
mark_success
mark_failure
~~~

No arbitrary state mutation is permitted.

`append_final_text` appends the selected string to the final text, for
providers that stream the answer only as chunks (Grok Build `streaming-json`
`text` events). `clear_final_text` takes no selector and discards the text
built so far; the Grok Profile clears on each `tool_call` so text written
before a tool call stays narration and the final text is the answer after the
last tool call. The appended text has the same 512 KiB result limit as
`set_final_text`.

`set_provider_error` also accepts a selector that yields a list. A non-empty list
is a list of actions the provider refused to run (for example AGY's
`denied_actions`) and is reported as `permission_denied` even when the provider
turn says success; an empty list is ignored.

## 16. Terminal result contract

A Profile makes terminal success/failure unambiguous.

Examples:

~~~text
success:
event=result AND result.status=SUCCESS
~~~

or:

~~~text
success:
turn.completed observed AND final text exists
~~~

The Engine requires one bounded final result for successful execution.
For structured output, success requires exit code zero, a `mark_success` action,
and non-empty final text. `mark_failure`, a provider error, cancellation, or an
Engine timeout makes the terminal result fail. For `plain_text`, a non-empty
text result and exit code zero are sufficient. A failed result uses the first
matching Profile error mapping, except Engine cancellation/deadline outcomes,
which take precedence.

The interpreter returns the same bounded result shape for each output mode:
terminal success/failure, final text, observed session ID, terminal status,
Engine message-key progress entries, and an optional stable issue code.

## 17. Progress mapping

Conceptual:

~~~json
{
  "progress": [
    {
      "when": [{"kind": "equals", "selector": "$.type", "value": "turn.started"}],
      "percentage": 10,
      "messageKey": "provider_working"
    }
  ]
}
~~~

Profiles select Engine-owned safe message keys. Raw provider event content is
not forwarded as user-visible progress.

### Structured activity mapping

JSONL Profiles may also declare an `activity.mappings` array. Each mapping uses
only bounded declarative predicates and selectors to produce a normalized
activity type, status, title, optional activity identifier, and safe scalar
details. Conditions are strict (`equals`, `not_equals`, `one_of`, `type_is`, or
`exists`); unknown mapping fields, unsupported selectors, unsafe content or
execution extractors, and executable transforms are invalid. The optional
percentage is compatibility metadata only. Profile Lab replays a sanitized
provider fixture for this mapping and binds the result to the candidate digest.

## 18. Session rules

Conceptual:

~~~json
{
  "session": {
    "supported": true,
    "formatId": "codex-thread-v1",
    "compatibleFormatIds": ["codex-thread-v1"],
    "extract": "$.thread_id",
    "resumeArguments": ["resume", "{{sessionId}}"],
    "requireObservedIdMatch": true
  }
}
~~~

The Engine implements continuity validation.

When durable session is requested:
- an observed provider session ID must exist;
- resumed observed ID must equal the stored expected ID;
- mismatch is a hard session-resume failure.

`session.executionPolicyBound` (optional, default `false`) declares that the
provider fixes its sandbox when a native session is created and refuses to
resume it under another one. Grok Build does this: resuming a `--sandbox
read-only` session with `--sandbox workspace` exits 1 with `cannot resume this
session under sandbox profile`. The Engine records the execution policy
(`provider_default`, `restricted`, `full_access`) with each stored session.
For a bound Profile, a turn whose policy differs from the stored one does not
resume: when the request carries a canonical Conversation bootstrap the Engine
starts a fresh native session from the full bootstrap and replaces the stored
mapping; without a bootstrap it fails with `session_resume_failed`. Records
without a stored policy count as different. Unbound Profiles resume across
policy changes as before.

`formatId` identifies the provider's local session-ID format. A Profile Release
must include its own format in `compatibleFormatIds`; it may include an older
format only when it declares that ID safe to resume. The Engine partitions
session records by logical Worker, Profile definition, provider tool identity,
and logical Syntila `sessionKey`. It resumes a stored provider ID only when
the active Profile declares that stored format compatible. Otherwise it starts
without the stored provider ID and replaces the local mapping after a
successful new durable session. Profile release metadata never changes the
signed compatibility declaration. Session files written by the unpartitioned
development Engine are ignored by this format and will begin a fresh provider
session on first use.

Conversation-associated mappings also record explicit Conversation/Worker ownership,
last successful model/effort, and synchronized context revision. Model/effort are
not part of the session partition. Native handles stay in local state and are never
returned in protocol results. See [Worker Sessions](CONVERSATION_CONTINUITY_V1.md#phase-6--workspace-owned-worker-sessions)
for format versions, Profile compatibility, and synchronization limits.

## 19. Model mapping

Conceptual:

~~~json
{
  "model": {
    "supported": true,
    "arguments": ["--model", "{{model}}"],
    "unknownModelPolicy": "pass_through"
  }
}
~~~

v1 may support:
- `pass_through`;
- `profile_allowlist`.

No silent model substitution is permitted.

Optional `model.selectionMode` declares `separate` (default) or `combined`
selection metadata. Native resolution stays inside the Profile/Engine boundary;
it does not authorize inferred effort combinations. See the additive
[Worker execution options v2 contract](WORKER_EXECUTION_OPTIONS_V2.md).

Optional `model.executionOptions` declares version 1 generic capabilities:
`discovery: "profile_catalog"`, `modelSwitchSupported`, `effortSupported`, optional
nullable `defaultModelId`, and optional `effortMapping`. Catalog and global/model
reasoning values remain in their existing fields. Provider-specific effort names
are mapped into `{{reasoningEffort}}` locally while persisted selection metadata
retains the requested value. Explicitly unsupported model switches fail resume;
they do not silently replace the native session. See
[Worker execution options](CONVERSATION_CONTINUITY_V1.md#phase-7--generic-worker-execution-options)
for normalization, validation, discovery limits, and rollout.


## 20. Timeouts

A Profile may map the assignment timeout to a provider argument:

~~~json
{
  "timeout": {
    "providerArguments": ["--print-timeout", "{{timeoutSeconds}}s"],
    "providerReserveMs": 1500
  }
}
~~~

For `{{timeoutSeconds}}`, the Engine supplies
`max(1, ceil((assignmentTimeoutMs - providerReserveMs) / 1000))`. The provider
reserve is independent from the Engine's own hard process deadline and cleanup
grace. The Engine deadline always wins if the CLI ignores its provider timeout.
The Engine owns the cleanup grace; Profiles cannot change it.

## 21. Sandbox/permission mapping

Profile maps an Engine-approved execution policy:

~~~text
restricted
provider_default
full_access
~~~

to bounded provider arguments.

`full_access` is usable only when Workspace/product policy explicitly permits
it. Normal v8 assignment execution does not permit it. A Profile cannot
independently broaden local permissions.

## 22. Error mappings

Profiles may map bounded provider evidence to stable Syntila issue codes.

The approved `session_unavailable` stderr matcher identifies a missing or
unavailable session/thread/conversation. Mapping it to `session_resume_failed`
allows the Engine to invalidate a rejected native handle and reconstruct once
from canonical context within the same assignment. Generic error mappings do not
authorize reconstruction; final response/success or work-progress evidence also
prevents automatic replay. This additive schema-v1 matcher requires an updated
Engine and a newly signed Profile release; existing releases remain immutable.

Evidence types v1:
- exit code;
- terminal status value;
- Engine-approved bounded stderr matcher/pattern;
- missing terminal result;
- structured provider-error selector.

Stable codes include:

~~~text
provider_authentication_required
provider_tool_unavailable
unsupported_provider_tool_version
model_not_supported
permission_denied
quota_exhausted
provider_unavailable
deadline_exceeded
cancelled
session_resume_failed
provider_failure
~~~

## 23. Version-specific overrides

A release may contain small bounded compatibility overrides.

Requirements:
- bounded number;
- non-overlapping provider-version ranges (a CLI version that matches no
  override runs the base Profile; overrides never reject a version);
- only `executionArguments`, `versionProbeArguments`, `progress`, and
  `errorMappings` may be overridden in v1;
- fixtures for every range.

Materially different behavior should become a new Profile release instead.

## 24. Retired capability metadata

The former top-level `capabilities` array is not part of Tool Profile v1.
Strict readers reject it. The development cutover migration deletes releases,
channel pointers, and evidence created with that field, so there is no legacy
release compatibility path. Workflow enablement, Worker selection,
model/effort choices, and product restrictions are owned by the web app and
Cloud workflow policy.

## 25. Profile release envelope

Workspace verifies a Tool Profile Release v1 envelope before passing the
payload to the generic CLI Worker Engine. The payload digest is lowercase
hexadecimal SHA-256 over the canonical JSON encoding of the complete validated
Profile v1 object. The Ed25519 signature is over UTF-8 bytes of:

~~~text
syntila-tool-profile-release-v1\n<canonical envelope JSON>
~~~

The canonical envelope JSON has exactly these signing claims:

~~~text
domain = syntila-tool-profile-release-v1
publisher
signingKeyId
payloadDigest
profileDefinitionId
releaseVersion
logicalWorkerTypeId
engineFamily
schemaVersion
engineCompatibility
providerToolName
providerCompatibility
~~~

`providerCompatibility` is the signed payload's
`providerTool.supportedVersions`. Workspace recomputes the payload digest,
compares every repeated envelope claim against the payload and Cloud release
metadata, then checks the publisher/key ID against its Ed25519 trust roots.
Changing behavior, identity, release version, logical Worker binding, Engine
compatibility, provider compatibility, publisher, or key ID invalidates
admission.

Lifecycle state, channel, promotion pointers, audit fields, display name, and
timestamps are registry metadata outside the signed envelope. Workspace may
accept a trusted signed release at a permitted channel, but those fields cannot
change signed behavior or compatibility claims. Workspace also rejects a
revoked payload digest, `<profileDefinitionId>@<releaseVersion>`, publisher, or
signing key ID. Key rotation adds a new key ID and public key to the Workspace
trust roots before signing with it; key IDs cannot be relabeled after signing.

## 26. Immutability and Lifecycle

The complete lifecycle state machine and promotion rules are defined by the
[Tool Profile Lifecycle Specification](TOOL_PROFILE_LIFECYCLE.md).

Once a Profile release is published beyond draft:
- payload bytes, version, and digest do not change;
- compatibility claims do not mutate in place;
- any modification produces a new sequential release version;
- lifecycle promotion changes channel pointers and lifecycle state only, never the payload;
- rollback moves a channel pointer to an earlier valid release;
- revocation permanently invalidates the release across Cloud and Workspaces.

## 27. Validation levels

### Static validation

- exact schema;
- bounds;
- identifiers;
- placeholders;
- selectors;
- actions;
- compatibility ranges;
- forbidden environment names;
- forbidden shell constructs.

### Fixture validation

- version parsing;
- passive probe;
- normal result extraction;
- errors;
- progress;
- session start/resume;
- version-specific variations.

### Real acceptance

- real installed provider CLI;
- passive probe and explicit live probe;
- representative assignment and Thread write where the Profile can write
  local files;
- durable session start and resume when the Profile supports sessions;
- bounded timeout and assignment cancellation through the Workspace process
  tree supervisor.

### Draft testing lifecycle & signed-release invariant

The profile testing workflow incorporates an iterative draft testing lifecycle inside **Syntila Profile Lab** (`apps/profile_lab`) without weakening production signed-release guarantees:

1. **Unsigned Local Draft Candidate (`LocalDraftProfileCandidate`):**
   - Represents a mutable, in-development draft profile stored locally in Profile Lab.
   - Evaluates `isSigned => false`.
   - Executed **strictly** within Profile Lab's isolated test sandbox via `PlatformProcessSupervisor`.
   - **MUST NOT** enter Syntila Workspace's trusted profile store (`ToolProfileReleaseStore`), local worker registry, or Cloud scheduling.

2. **Admitted Cryptographic Release (`ToolProfileReleaseAdmission`):**
   - Represents an immutable, published release signed by Syntila Cloud Ed25519 private key.
   - Evaluates `isSigned => true`.
   - Syntila Workspace strictly requires `isSigned => true` for admission. Unsigned draft objects are rejected by static types and runtime verifiers (`WorkerTrustPolicy`).

3. **Evidence-Bound Transition:**
   - The supported Profile Lab sandbox emits an execution-contract result after applicable Engine scenarios pass. Cloud checks the submitted contract's identity, canonical digest, reported version ranges, freshness, and scenario map, then stores it for lifecycle gating. This is an authenticated client assertion, not remote attestation that a local provider binary executed the scenarios; see the [evidence contract](TOOL_PROFILE_EVIDENCE_CONTRACT.md).
   - Any edit to a draft payload recalculates its SHA-256 `payloadDigest` and immediately invalidates all accumulated evidence.
   - Cloud verifies evidence completeness and signs the payload upon publication (`POST /api/admin/workers/definitions/:id/releases`).

Stable promotion for first-party official Profiles requires all applicable
levels. The controlled acceptance runner records a JSON evidence artifact bound
to the exact Profile digest, release identity, Engine version, provider CLI
version, and required scenario results. Evidence must be no older than 90 days
and must use Engine/provider versions allowed by the signed Profile. The stable
promotion API requires this artifact and retains it as immutable release
evidence. Normal CI must not enable real acceptance or consume provider
allowance.

Run one controlled profile from `apps/workspace` with:

~~~sh
SYNTILA_TEST_REAL_PROFILE_CHATGPT=1 \
SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR=/secure/path/profile-evidence \
flutter test test/tool_profile_real_acceptance_test.dart
~~~

Use `SYNTILA_TEST_REAL_PROFILE_GEMINI=1` for the Gemini Profile. Live
assignment acceptance (`test/tool_profile_assignment_acceptance_test.dart`) uses
separate `SYNTILA_TEST_ASSIGNMENT_PROFILE_CHATGPT=1` and
`SYNTILA_TEST_ASSIGNMENT_PROFILE_GEMINI=1` opt-in variables. The evidence
artifact contains version and scenario metadata only; it does not retain
credentials, prompts, provider output, or Thread file contents.

## 28. Initial official Profiles

Architecture v8 starts with:

~~~text
chatgpt-codex
gemini-antigravity
~~~

They must reproduce the already-passing provider-specific Dart Worker behavior
before those provider-specific binaries are removed.

## 29. Non-goals

Tool Profile v1 is not:
- a shell script format;
- a Workflow language;
- a prompt-template product;
- user-editable v8 functionality;
- arbitrary third-party executable extensions;
- a permission bypass mechanism;
- a replacement for future non-CLI Engine families.

## 30. Evolution rule

If Profile v1 cannot represent a provider safely:

1. If the missing concept is generic across multiple CLI tools, add a typed
   Engine/Profile execution option in a new schema version.
2. If it is provider-specific, prefer a specialized driver/engine rather than
   making the Profile schema a programming language.

## 31. Machine bounds

The canonical validator publishes the exact hard limits in
`TOOL_PROFILE_LIMITS`. In v1 these include: 256 KiB serialized payload; 4,096
characters per general string; 256 characters per short label; 64 items per
general array; 128 arguments; 128 event rules; 64 progress and error rules;
16 selector conditions per rule; selector depth 16 and selector length 256;
JSON template nesting depth 16;
64 environment names; 8 config checks with a 64 KiB maximum file size; and
16 compatibility overrides. More specific schema fields may have tighter
limits. Pattern IDs are finite Engine-owned enum values, not user-provided
regular expressions.

## 32. Deterministic rule processing

Event rules and progress rules are evaluated in Profile source order. Event
actions within a matched rule execute in source order. A progress event emits
the action from the first matching progress rule only. Stable failure mappings
are ordered; the Engine uses the first matching mapping. An Engine may still
report its own hard deadline or protocol-integrity failure regardless of
Profile mappings.


When `model.executionOptions.modelSwitchSupported` is false, a different selected
model requires a new native session bootstrapped from bounded canonical Syntila
history. The generic Engine uses the Profile's existing first-invocation argument
layout, without resume arguments; successful execution replaces the local native
mapping while retaining the Conversation scope. Failure preserves the previous
mapping. No provider-specific executable or Profile schema addition is introduced.
See [Conversation Continuity Phase 14](CONVERSATION_CONTINUITY_V1.md#phase-14--same-worker-different-model).

## Generic CLI model discovery (Engine 1.1.0)

Optional `model.discovery` declares version 1 provider discovery:
`schemaVersion`, `arguments` (1–32), `timeoutMs` (100–10000), `format`, and
`idPrefix`. It runs without a shell on the Profile's resolved provider CLI.
`format: "tsv"` parses bounded rows of
`model-id<TAB>label<TAB>effort1,effort2<TAB>default-effort` (the last two
fields are optional). `format: "codex_app_server"` starts the declared Codex
app-server command, performs the JSON-RPC `initialize` handshake, then calls
`model/list`; its `displayName`, `id`, `supportedReasoningEfforts`, and
`defaultReasoningEffort` fields become the sanitized catalog. Codex `id` is the
logical selection identity; `model` is retained as nativeId locally for CLI
invocation (falling back to id when absent). Engine catalog v2 is stripped of
nativeId before Workspace inventory publication; its public projection follows
[Worker execution options v2](WORKER_EXECUTION_OPTIONS_V2.md). Runtime inventory
supplies the matching versioned catalog; it cannot widen a Profile without that
declaration. For discovery-backed Profiles, the runtime catalog is the only
source of model and effort choices: the Profile must not contain a fallback
catalog or guessed effort rules. The one exception is
`format: "clap_possible_values"`, which runs a value-taking flag without a value
(for example `copilot --model`), ignores the expected non-zero exit, and reads
the `[possible values: a, b, c]` list from stdout and stderr. That list carries
IDs only, so the Profile supplies efforts: a `model.catalog` entry gives a known
model's name and `supportedReasoningEfforts` (an empty list means no effort
choice), every other listed ID gets `model.supportedReasoningEfforts` and a name
derived from its ID (`gpt-5.3-codex` -> `GPT-5.3 Codex`). Discovered IDs in
`discovery.excludeIds` are never offered. A catalog entry never adds a model the
CLI did not list. The starter Copilot Profile no longer uses this format: the
`--model` list is what the CLI recognizes, not what the account may select
(Free plans allow Auto only, so explicit IDs fail with "model is not
available").

`format: "indented_list"` (starter Grok Profile, `arguments: ["models"]`)
reads a human model list from stdout with one model per indented line,
optionally bulleted with `*` or `-` and followed by a parenthesized note such
as `(default)`. Unindented lines (headings, sign-in notes) and stderr are
ignored. Names and efforts come from `model.catalog` for known IDs and
otherwise from `model.supportedReasoningEfforts`, exactly as for
`clap_possible_values`; `excludeIds` is honored. An empty list fails
discovery.

`discovery.effortProbe` (optional, `format: "use_one_of"`) discovers each
model's efforts from the CLI itself instead of a Profile list. For each
discovered model (at most 32) the Engine runs the declared `arguments` with
`{{model}}` replaced by the model ID, within `timeoutMs`, and reads the list
after `use one of:` in stdout or stderr, for example Grok Build's
`unknown effort level 'syntila-effort-probe'; use one of: xhigh, high,
medium, low`. Efforts are ordered lowest first. A model whose output names no
efforts (Grok: `grok-4.6 isn't in the model catalog`), or whose probe fails or
times out, is offered without an effort choice. The arguments must pass an
effort the CLI rejects before any model request; Grok 1.0.67 does so in about
one second and records only an empty local session (system prompt and probe
input, no model turn). Results are cached with the discovered catalog per
Profile digest and CLI version. The TypeScript reference interpreter skips the
static effort check when a Profile declares discovery and no effort list; the
Engine validates against the discovered catalog.

`format: "copilot_sdk_rpc"` (starter Copilot Profile, `arguments:
["--headless", "--stdio"]`) asks the CLI's own SDK server, over
Content-Length-framed JSON-RPC, for the signed-in account's models. The Engine
calls `auth.getStatus`; when it is not authenticated discovery fails with
`provider_authentication_required` and the message "Run `copilot login`, or
sign in with `gh auth login`" (a sign-in failure is never hidden behind a stale
cached list). It then calls `models.list`; each model's `id`, `name`,
`supportedReasoningEfforts` and `defaultReasoningEffort` become the catalog,
and models whose `policy.state` is `disabled` are skipped. No `auto` entry is
added: Copilot run without `--model` already picks a model automatically, which
is exactly the client's own provider-default "Auto" choice. A Free account
(empty `models.list`) therefore offers only that Auto. The Profile
carries no catalog or effort rules for this format. Model Auto remains the provider default;
explicit discovered IDs and per-model efforts are checked locally and by Cloud
with no substitution. The app-server protocol is used only for discovery;
execution remains generic CLI Worker Engine behavior.

Optional `probe.live.requiredForReadiness` binds scheduling readiness to a
successful explicit live test for the current Profile digest and CLI version.
Passive discovery does not authenticate the account. See
[Gemini/AGY implementation contract](../architecture/GEMINI_AGY_PROFILE.md)
for cache ownership, wire metadata, availability states, security and release gates.

Optional signed `model.selectionMapping` schema version 1 requires Engine 1.2.0.
Optional `model.discovery.effortVariants` (`source: label_parenthesized_suffix`, one-character `separator`) derives families and efforts from discovery output instead; it requires `selectionMode: combined`, Engine 1.3.0 and excludes `selectionMapping`.
Its exact native rows, effort/default rules and provider version gates are defined
in [Provider discovery and normalization](MODEL_DISCOVERY_NORMALIZATION.md).

## Optional `usage` command

A Profile may declare a top-level `usage` object:

~~~json
"usage": { "arguments": ["-p", "/usage"], "timeoutMs": 30000 }
~~~

- `arguments` are templated provider CLI arguments (same placeholders as other
  commands); `timeoutMs` is 1000-60000. The only other allowed field is
  `jsonRpc`.
- Optional `jsonRpc: { "method": "..." }` marks `arguments` as a stdio JSON-RPC
  server (for example `codex app-server --listen stdio://`). The Engine sends
  `initialize`, calls the one parameterless method, and returns the raw result
  as pretty-printed JSON in `output`. The starter ChatGPT Profile uses
  `account/rateLimits/read`. The result is still never interpreted.
- Optional `jsonRpc.framing` selects the transport: `newline` (default) is the
  Codex newline-JSON transport with the `initialize` handshake above;
  `content_length` uses LSP-style `Content-Length: <n>\r\n\r\n<JSON>` framing,
  sends no handshake, calls the method with empty `params`, skips unrelated
  messages, and caps each frame at 64 KiB.
- The generic Engine runs the declared provider executable with these arguments
  on a `usage.request` frame and answers with `usage.result` (`output`,
  `errorOutput`, `exitCode`, `truncated`). Terminal escape sequences are removed
  and each stream is capped at 64 KiB; nothing else is changed.
- **Cloud, Workspace and the Engine never parse the report.** Providers
  calculate usage differently, so the Profile owns how usage is read and the
  text travels unchanged. AX alone may normalize it for display
  (`worker_usage_parser.dart`): the format is detected from the text (Claude
  `Current session/week` lines, Codex `rateLimits` JSON, Copilot
  `quotaSnapshots` JSON, Gemini tab-separated rows) and shown as per-window
  used percent and a live reset countdown. Gemini rows marked `disabled` are
  retained as notes; exhausted rows with `0%` remaining display as `100% used`.
  Session/5-hour windows use `Resets in 1 hr 29 min`; weekly windows use
  `Resets in 2 d 2 hr 30 min`, as does any reset two or more days away.
  Copilot shows chat and completion allowances as used/entitled requests;
  unlimited or plan-excluded allowances (for example premium requests on
  Free) become notes. Its `resetDate` has been observed equal to the snapshot
  time, so only a future reset is shown. Countdown minutes round up; elapsed resets
  prompt a usage refresh. Claude named-zone reset text is resolved with the
  bundled IANA timezone database against the report fetch date (next occurrence
  when the year or date is omitted); unrecognized reset text stays as printed.
  Missing reset times stay unlabelled. Summary notes omit Claude's local
  seven-day request statistics and Codex's plan; the Original view retains both.
  Usage bars use the theme-aware brand foreground fill and a neutral track in
  light/dark themes. Original/Summary is a keyboard-accessible text link styled
  like the adjacent fetch timestamp. A report that does
  not match a known format exactly is never partially shown; AX displays the
  original text, and `Original` always shows it for a normalized report.
- A Profile without `usage` yields status `unavailable`. The starter Claude
  Profile declares `-p /usage`; Gemini declares `-p /usage` (agy) and ChatGPT
  uses the Codex app-server rate-limit call. Copilot calls `account.getQuota`
  on `copilot --headless --stdio` with `content_length` framing (CLI 1.0.103
  answers `-p /usage` as an ordinary prompt, which would spend credits).
  Grok declares `grok models`: Grok Build has no account quota command
  (`grok usage <SESSION_ID>` reports one session's spend, and `-p /usage` is
  sent to the model), so its report shows the sign-in state and available
  models, with no model call. `grok models` exits 0 even when signed out
  (it prints `You are not authenticated.`), so this check proves the CLI
  runs, not that it is signed in.
  See the [local Copilot verification](../acceptance/real-provider/2026-10-23/copilot.md)
  for captured statistics, model/effort limits, and the framing distinction.
- Cloud relays on demand: `POST /api/workspaces/:workspaceId/workers/:workerId/usage`
  (Workspace owner only) sends `worker.usage.request`; the Service replies with
  `worker.usage.result`. Results are never stored in Cloud or posted to a Thread.
- AX exposes it as `Usage` in the composer `+` menu and as the `/usage` command.

Grok CLI discovery additionally permits the reviewed home-relative installation
location `{{home}}/.grok/bin`; executable selection still uses the generic Engine
discovery path.
