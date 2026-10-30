# Syntila CLI Worker Engine

Standalone Dart console process implementing the generic Protocol 4.1 runtime.
The Engine loads one immutable Tool Profile payload and verifies its runtime
structure, Engine compatibility, and payload SHA-256 digest during initialize.
Workspace remains responsible for official release signature verification and
canonical Tool Profile v1 schema admission before launch.

For local development, launch with absolute paths:

~~~sh
dart run bin/syntila_cli_worker.dart \
  --profile /absolute/path/to/profile.v1.json \
  --engine-version 1.3.1 \
  --state-directory /absolute/path/to/worker-state
~~~

The Engine reads Protocol 4.1 NDJSON from stdin and writes frames to stdout.
Structured arguments are passed directly to the resolved provider CLI with
shell execution disabled. Logs are written to stderr.

Provider CLI discovery uses Profile executable names and approved Profile
locations first, then Engine-owned OS baseline locations, then the inherited
`PATH` when the Profile allows PATH search. The Engine keeps a bounded cached
path in its state directory and verifies the expected executable name and
executable status again before reuse. Discovery uses standard OS home variables;
it does not require Syntila-specific environment variables.

The Engine admits bounded Profile payloads and rejects unsafe discovery paths,
reserved Syntila/cloud environment names, oversized rule and selector sets,
and unsupported sandbox policy names. The provider process receives only
declared environment variables, with 64 variables, 64 KiB per value, and 256
KiB total limits. Provider stdout/stderr, stdin, session identifiers, and
execution deadlines are capped by Engine-owned limits. Session keys and stored
provider session IDs are validated, and session files are confined to the
Engine state directory. Provider credentials such as `OPENAI_API_KEY` can be
passed through only when an official Profile explicitly declares them.
The provider working directory is fixed to the Engine's assigned Thread
directory; Profile data cannot select an arbitrary working directory.

Model discovery is Profile-declared. TSV discovery is suitable for providers
that expose a bounded listing command. ChatGPT/Codex Profiles may instead use
`format: "codex_app_server"`; the Engine starts `codex app-server`, performs
the `initialize` and `model/list` JSON-RPC exchange, and stores only sanitized
model and reasoning-effort metadata. The app-server is terminated after the
probe and is not used as a second execution runtime.

The host process supervisor owns cancellation of the Engine process. Within an
assignment, the Engine enforces an outer provider deadline and terminates the
provider process if its output consumer fails or the deadline expires.

The Workspace release supervisor still uses the migration-only v2 Worker
identity path; wiring Workspace launch to the Engine is a later integration
step.

Protocol 4.1 adds a catalog revision pin to execution requests. Legacy 4.0 frames
remain readable without that field; native model identifiers remain local to the
Engine and are never accepted as client-supplied invocation arguments.

### Provider usage-limit classification

Profiles opt into the existing `quota_exhausted` mapping. The shared error-channel
matcher recognizes quota exhaustion, rate-limit identifiers, and explicit usage
or session-limit messages, including Claude's “You've hit your session limit”.
Claude's starter also maps structured assistant `rate_limit`, `rate_limit_error`,
and `usage_limit_reached` errors through a terminal status, so a terminal result
with an empty error string does not hide the earlier limit signal. Informational
rate-limit events and successful answers discussing limits are not failures.

The local Syntila/Engine request `work-request-144a4fdf-f00f-40aa-9a53-57d4c946bdaf`
failed on 2026-10-21 with a Claude usage-limit error; its stored assignment was
previously normalized to `execution_failed`. This change does not rewrite past
requests, retry automatically, clear sessions, or bypass provider limits.

Updated starter JSON is a candidate: existing published/signed Profiles remain
immutable. Apply the mappings to the Worker's current Profile through Profile
Lab and publish a new signed revision, then use the updated Engine for expanded
text classification. No protocol/schema migration is needed.

### Context overflow and compaction

A Profile's optional `context` block describes how its CLI handles a full
context window:

- `overflow.markers`: case-insensitive text the CLI reports when the
  conversation no longer fits. It is matched against stderr, the provider error
  and the terminal status of a failed run only, never against an answer, and
  fails the run with `context_limit_exceeded`. The native session is kept.
- `autoCompaction.arguments`: arguments that keep the CLI's own automatic
  compaction on, placed by an `autoCompactionArguments` execution argument.
- `compaction.prompt` (and optional `compaction.arguments`): how to compact the
  resumed native session on demand. When an execution request carries
  `compactContext`, the Engine first sends this prompt to the prior session and
  then runs the step prompt; a failed compaction stops with
  `context_limit_exceeded` before the prompt runs.

Starter support, checked against the installed CLIs on 2026-10-31:

| Worker | Overflow text | Auto-compaction | On-demand compaction |
| --- | --- | --- | --- |
| Claude Code 2.1.308 | `Prompt is too long` | `--autocompact auto` | `/compact` (verified) |
| Codex 0.160.0 | `ran out of room in the model's context window` | CLI default | not supported: `codex exec` sends `/compact` to the model |
| Copilot CLI 1.0.105 | generic markers | CLI default (about 80%) | `/compact` (verified) |
| Grok 1.0.67 | `context_length_exceeded` | CLI default (85%, `config.toml` only) | `/compact` (verified) |
| agy 1.4.12 | generic Gemini markers | CLI default | `/compact` without `--disable-slash-commands` (accepted; not verified end to end) |

Engines before this change reject a Profile with a `context` block. Publish
such a Profile only after Workspaces run an Engine that understands it.

Cloud no longer fails a turn because the canonical history exceeds its own
bootstrap budget (1000 entries, 256 KB): older history is left out instead, and
only the CLI's own overflow report stops a run.

### Per-prompt execution

An assignment sends the prompt straight to the provider CLI. The Engine runs no
version, readiness or discovery command per prompt: it reads the model catalog
that Workspace readiness saved for the Profile and runs version and discovery
only when no catalog exists at all. Workspace checks the CLI before it is used;
if the user changes or updates the CLI without restarting Workspace, keeping it
compatible is the user's responsibility. Retries after an empty answer or an
unavailable session are the only additional CLI runs.

### Live probe

A live probe runs the Profile's `usage` command and never calls a model, so a
limit on one model does not mark the whole Worker as failing. It passes when
the command succeeds and prints something. A Profile without a `usage` command
fails the live probe; `probe.live` is deprecated and ignored.
