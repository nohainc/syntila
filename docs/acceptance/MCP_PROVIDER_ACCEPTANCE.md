# MCP provider acceptance evidence — 2026-11-06

Runs on macOS with the installed CLIs: Claude Code 2.1.308, `codex-cli 0.160.0`,
`agy 1.5.2`. The reference server is the repository's `echo_server.dart`
fixture compiled to a stdio MCP server (`echo`, `slow`, `mutate` tools). The
commands used the exact flags the Profiles emit, but were **not** run through
the Syntila Engine, Workspace or Cloud; Engine behavior is covered by the
fixture-provider tests listed at the end. Results are observations from one
machine, not a certification of every CLI version.

## Claude (Profile release 3, `--mcp-config` + `--strict-mcp-config`)

| Check | Result |
| --- | --- |
| Reference tool call | Passed. The init event listed `ref` as connected with `mcp__ref__echo`; the model called it and returned `phase3-ok`. |
| Empty selection with an ambient project `.mcp.json` in the working directory | Passed. `mcp_servers: []`, no `mcp__` tools, the model answered NONE. |
| Subset | Passed. Only the configured server was connected; `mcp__other__echo` was not available. |
| Session continuity | Passed. `--resume <session>` with the same config recalled the earlier result and made a second call. |
| User configuration untouched | Passed. `~/.claude.json` has no `mcpServers` after the runs (Claude updates its own state file as usual). |
| Not tested | A user-scope ambient server (it would need `claude mcp add`, which edits permanent config); cancellation and timeout of a live Claude call. |

## Codex (Profile release 3, `--ignore-user-config -c mcp_servers=<table>`)

The model turn could not run: the account is over its usage limit until the
evening, so **no Codex tool call was made** and resume was not exercised.
Configuration loading was verified without a model by launching the CLI with
logging wrapper commands as the MCP servers and reading which ones started.
The `-c` value was rendered by the Engine's `McpInlineToml`.

| Check | Result |
| --- | --- |
| User `config.toml` defines an `ambient` server, no flags | `ambient` starts (control). |
| `-c 'mcp_servers={}'` alone | `ambient` still starts: overrides merge, so this does not isolate. |
| `--ignore-user-config` with an empty selection | Nothing starts. |
| `--ignore-user-config` with a subset | Only the selected server starts; arguments with spaces, quotes and backslashes arrive intact. |
| Secrets | Passed by `env_vars` names; the value reached the server through the CLI's environment and never appeared on the command line. Servers do not inherit other environment variables. |
| `exec resume` | Accepts the same two flags (`--help`); a real resume was not run. |
| Project `.codex/config.toml` | An untrusted project's config did not load even without the flag; a trusted project was not tested. |
| Not tested | A real tool call, resume with MCP, cancellation, the 0.180.x vector (binary not installed; the slot was added there unverified). |

Consequence: the Codex Profile ignores the user's whole `config.toml` on every
execution it is used for (auth still comes from `CODEX_HOME`). This was
approved by the owner. The Codex release is therefore best published only
after a live tool call is recorded.

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
  expansion, empty table, no emission without MCP.
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
