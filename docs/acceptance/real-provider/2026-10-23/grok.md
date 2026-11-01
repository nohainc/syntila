# Grok candidate verification — 2026-10-23

The bundled `grok-cli` release 1 is an unsigned authoring candidate. The
catalog migration registers a testing Worker; it does not publish a Profile.

## Installed CLI evidence

- `~/.grok/bin/grok --version`: `grok 1.0.67 (2fe064390d07) [stable]`.
- `grok --help`: confirms JSON output, `--model`, `--reasoning-effort`,
  `--resume`, `--sandbox`, `--permission-mode`, and `--always-approve`.
- `grok models`: local grok.com login, default and only model `grok-4.7`.
  This is a reviewed snapshot, not dynamic discovery.
- Live headless runs on the user's Mac (`--output-format json -p ...`, stdin a
  single newline) exited 0 and returned `text`, `stopReason: end_turn`,
  `sessionId`, and `usage`, matching the Profile's `$.text`/`$.sessionId`
  mapping. Each mapped vector ran successfully: restricted
  (`--sandbox workspace --permission-mode dontAsk`), provider default
  (`--sandbox read-only --permission-mode plan`), full access
  (`--sandbox off --always-approve`), `--model grok-4.7`, and
  `--reasoning-effort high`.
- `--resume <sessionId>` continued the session and returned the same
  `sessionId`.
- An unknown model printed `{"type":"error","message":...}` on stdout and
  exited 1, matching the Profile's error mapping.
- **Resume pins the sandbox.** Grok stores the sandbox profile on the session.
  Resuming under a different `--sandbox` fails with exit 1 (`cannot resume this
  session under sandbox profile 'workspace' — it was created with
  'read-only'`). Omitting `--sandbox` keeps the original profile. A Thread whose
  durable Grok session starts as read-only Chat therefore cannot later resume
  as restricted Work. Fixing this needs an Engine/Profile contract decision:
  start a fresh session when the policy changes, or bind sessions to policy.

The candidate maps restricted Work to `--sandbox workspace --permission-mode
 dontAsk`, and provider-default Chat to `--sandbox read-only --permission-mode
 plan`. Device-level sandbox enforcement still requires acceptance evidence.

Reasoning choices follow the [official model documentation](https://docs.x.ai/developers/model-capabilities/text/reasoning).
The [official headless guide](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/14-headless-mode.md)
defines JSON response/error fields. Focused interpreter tests cover argument
expansion, response/session extraction, and the observed error shape.

## Release 2 — streaming, policy-bound sessions, discovery (2026-10-23)

Release 2 switches to `--output-format streaming-json -p -` and uses three
generic Engine/Profile features added for it:

- **Prompt on stdin.** `-p -` reads the prompt from stdin (verified live), so
  prompts are bounded by the 1 MiB stdin limit instead of the 128 KiB argv
  limit.
- **Live activity.** `activity.adapter: "grok-streaming-json"` reports
  thinking, narration and paired tool rows. The answer is built from `text`
  chunks with `append_final_text`, cleared at each `tool_call` by
  `clear_final_text`, so narration before a tool call is not repeated.
  Fixture: `engines/cli_worker/test/fixtures/grok-streaming-tools-1.0.67.jsonl`.
- **Policy-bound sessions.** `session.executionPolicyBound: true`. A live
  two-turn run through the compiled Engine 1.3.1: turn 1 `provider_default`
  replied `OK`; turn 2 `restricted` in the same Worker Session started a fresh
  Grok session from the bootstrap and answered `BANANA` from turn 1's context;
  the stored mapping now records `restricted`.
- **Model discovery.** `grok models` via `format: "indented_list"`; live
  output lists `grok-4.7 (default)`. Efforts `low`, `medium`, `high`, `xhigh`
  were each accepted live; `max` is rejected by the CLI.
- A live single-turn Engine run reading a file reported `Thinking`,
  `Reading files` → `Read files`, the narration, and the final text.

Account quota is not available: `grok usage <SESSION_ID>` reports one
session's token cost only, and `grok -p /usage` is sent to the model (it
started a model turn live). Profile Lab requires a usage command, so the
Profile declares `usage: grok models`. It makes no model call and answers in
under a second. The compiled Engine's live probe passed with it: CLI 1.0.67,
model discovery `grok-4.7` with `low`/`medium`/`high`/`xhigh`, and "Provider
answered the usage command." With no credentials (`GROK_HOME` empty,
`XAI_API_KEY` unset) `grok models` still exits 0 and prints `You are not
authenticated.` plus an offline model list, so the usage check does not prove
sign-in. `auth.json` is keyed by issuer and account ID, which the
property-only config-check selectors cannot address.

## Release 4 — per-model efforts from the CLI (2026-10-24)

The Profile declares no model or effort list. Models come from `grok models`;
each model's efforts come from `discovery.effortProbe`, which runs
`grok --model <id> --reasoning-effort syntila-effort-probe --output-format
json -p x` and reads Grok's rejection. Live checks on CLI 1.0.67:

- `grok-4.7` → `use one of: xhigh, high, medium, low` (exit 1, about 1.1 s).
- `grok-4.6`, `grok-4.5`, unknown IDs → `isn't in the model catalog`, no list:
  the effort check uses the signed-in account's catalog, per model.
- The compiled Engine's live probe passed in about 3 s with
  `grok-4.7 "Grok 4.7" [low, medium, high, xhigh]`.
- Each probe leaves one empty local Grok session (system prompt and probe
  input only; no reply, token usage or trace turn). `--max-turns 0` is
  rejected by the CLI, so it cannot be used as an extra guard; the 5 s probe
  timeout bounds a CLI that someday accepted the value.

## Remaining qualification

Device-level sandbox isolation and Profile Lab qualification/publication remain
open. Account quota is unavailable from the CLI (see above).

Transparent 128px PNGs in AX, Workspace and Profile Lab are rendered from the
existing mirrored Grok SVG. Its LobeHub provenance remains recorded in the icon
README; a first-party downloadable asset has not been verified.

## Automated validation (release 2)

- `engines/cli_worker`: format, analyze and all 101 tests pass, including
  `grok_profile_execution_test.dart` (fixture replay through the Engine,
  provider error, adapter, `indented_list`, policy-bound session store).
- `packages/tool-profile`: 159 tests and the TypeScript check pass.
- `packages/tool_profile_v1` (33) and `packages/syntila_cli_worker_runtime`
  (27) tests pass. `pnpm validate:engine` itself stops at the runtime package
  format check on `test/cli_streaming_runner_test.dart`, which is unformatted at
  HEAD and unrelated to Grok.
- `pnpm validate:profile-lab` passes (68 tests).
- `pnpm validate:cloud`: 147 of 151 files pass; the four failures are
  five-second timeouts in assignment race suites, which pass on a focused
  rerun (53 tests).
- The bundled Engine was rebuilt with `scripts/internal/build-cli-worker-engine.sh`
  (1.3.1) so Profile Lab runs the new adapter, actions and discovery format.
