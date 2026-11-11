# MCP provider acceptance evidence — 2026-11-06

Runs on macOS with the installed CLIs: Claude Code 2.1.308, `codex-cli 0.160.0`,
`agy 1.5.2`. The reference server is the repository's `echo_server.dart`
fixture compiled to a stdio MCP server (`echo`, `slow`, `mutate` tools). The
commands used the exact flags the Profiles emit, but were **not** run through
the Syntila Engine, Workspace or Cloud; Engine behavior is covered by the
fixture-provider tests listed at the end. Results are observations from one
machine, not a certification of every CLI version.

## Correction to the earlier version of this file

The first Claude run above this revision passed `--allowedTools mcp__ref__echo`
by hand. The Profile did not pass it, and under the Profile's real permission
modes the call is **denied**: `acceptEdits` ("restricted") answered
"Claude requested permissions to use mcp__ref__echo, but you haven't granted it
yet", and `plan` ("provider_default") blocks MCP tools outright. Likewise Codex
runs with `--ask-for-approval never`, which refuses every MCP call ("MCP tool
call requires approval, but approval policy is never"). Release 3 as first
committed therefore could not call a tool except in full-access mode. This is
fixed below, and the results here come from runs that use the Profiles'
real flags.

## Claude (Profile release 4: `--mcp-config`, `--strict-mcp-config`, per-server `--allowedTools`)

Selecting a server on a Step is the approval, so the Profile pre-approves
exactly those servers with the new `forEachMcpServer` slot
(`--allowedTools mcp__<server>`, one per selected server, nothing for an empty
selection). `plan` mode still blocks MCP tools; that is the read-only default
and is left as is.

| Check | Result |
| --- | --- |
| Reference tool call under `--permission-mode acceptEdits` with the selected server pre-approved | Passed (`perm-test` returned). |
| Same call without the pre-approval | Denied, as above. |
| Empty selection (empty strict config, no allow rule) | Passed: no `mcp__` tool exists in the session. |
| Empty selection with an ambient project `.mcp.json` in the working directory | Passed: `mcp_servers: []`. |
| Subset | Passed: only configured servers connect, and only those are pre-approved. |
| Session continuity | Passed with `--resume` (run before the permission fix, with the same config). |
| User configuration untouched | Passed: `~/.claude.json` has no `mcpServers`. |
| Not tested | A user-scope ambient server; live cancellation and timeout; through the Syntila Engine (flags were issued directly). |

## Codex (Profile release 3: `--ignore-user-config -c mcp_servers=<table>`)

OpenAI usage was reset, so these are **live model runs** with the Profile's
real command shape (`codex --ask-for-approval never --sandbox workspace-write
exec --json --skip-git-repo-check --ignore-user-config -c mcp_servers=<table>`),
the table rendered by the Engine's `McpInlineToml`, and a user `config.toml`
that defines an `ambient` server.

| Check | Result |
| --- | --- |
| Reference tool call, fresh session | Passed: the MCP call completed and the model returned `fresh-ok`. |
| Reference tool call, resumed session (`exec resume` with the same flags) | Passed: same thread id, `resume-ok` returned. |
| Empty selection (`mcp_servers={}`) | Passed: the model reported no MCP tool available, although the user's config defines one. |
| Subset | Passed (earlier, model-free): only the selected server starts. |
| Approval | Without a per-server approval the call fails with `approval policy is never`; `default_tools_approval_mode="approve"` is now emitted per selected server (`auto`, `prompt` and `writes` were also tried and still failed). |
| Isolation facts | `-c 'mcp_servers={}'` alone does not remove a user-config server; `--ignore-user-config` does. Secrets travel by `env_vars` name only. |
| Not tested | Live cancellation and timeout; the 0.180.x vector (binary not installed); a trusted project's `.codex/config.toml`; through the Syntila Engine. |

Consequence, approved by the owner: this Profile ignores the user's whole Codex
`config.toml` on every execution. Auth still comes from `CODEX_HOME`.

## Copilot (Profile release 11)

Copilot CLI 1.0.109 accepts the generated MCP JSON via
`--additional-mcp-config @<path>`. A model-free `copilot mcp list --json`
check confirmed that the generated stdio server is loaded. The profile grants
permission to each supplied server with `--allow-tool <server>`. A live model
call and session resume have not been verified. Copilot merges its own user,
project, plugin and built-in servers; Syntila does not isolate those separately
configured servers. Syntila's servers are supplied only to owner-authorized runs.

## Grok (no slot; unsupported)

The installed Grok Build CLI 1.0.67 exposes persistent MCP configuration but
no per-run MCP configuration argument. Syntila does not inject its servers
into Grok or modify the user's configuration.

## agy / Gemini (no slot; unsupported)

`--settings` rejects `mcpServers`, `mcp`, `mcpConfig`, `mcp_servers`,
`enabledMcpServers` and `disabledMcpServers` as unknown settings, and `agy mcp
add/enable/disable` edit permanent configuration. There is no per-execution
mechanism, so the Gemini Profile keeps no slot: any non-empty selection fails
with `mcp_unsupported`, and Syntila cannot hide servers a user added to agy.

## Automated coverage added or relied on

- `engines/cli_worker/test/mcp_inline_toml_test.dart`: table rendering,
  escaping, secrets kept off the command line, conflicting variables refused,
  stale config directory sweep.
- `engines/cli_worker/test/engine_mcp_config_test.dart`: private 0600 config,
  empty and selected configurations, deletion after the run (existing).
- `packages/tool-profile/test/interpreter.test.ts`: `{{mcpServersToml}}`
  expansion, empty table, no emission without MCP; `forEachMcpServer`
  repetition per server and nothing when empty.
- `apps/workspace/test/mcp_service_test.dart`: Claude and Codex assets carry
  the slot in every vector; Gemini does not.
- `provider_activity_adapter_test.dart` (existing): Claude `mcp__*` and Codex
  `mcp_tool_call` activity map to "connected tool" rows.

## Known gaps

- Config directories are deleted in a `finally`; an Engine killed outright
  leaves the owner-only directory until the next MCP execution sweeps
  `syntila-mcp-*` entries older than 24 hours.
- Timeout and cancellation of a live provider call with MCP active were not
  exercised.
