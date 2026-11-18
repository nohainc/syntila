# Performance tests

Local latency measurements for real user actions. Nothing here touches production.

## Run

| Command | What it does |
| --- | --- |
| `scripts/perf-local.sh [--probes N] [--users N] [--messages N] [--chats N] [--json f] [--no-thresholds]` | Full runner against `pnpm start:local`. Exit 1 when a p95 limit is exceeded or a scenario had errors. |
| `scripts/test-perf.sh` | Short run (~1 min), writes `_perf/<date>-<commit>.json`, prints a comparison with the previous file (regressions > 25% marked), refreshes `PERFORMANCE_RESULTS.md`. |
| `scripts/test-all.sh --perf` | The normal checks, then `test-perf.sh` as last step. Never runs by default. |
| `bun scripts/perf-report.mjs` | Rebuilds [PERFORMANCE_RESULTS.md](PERFORMANCE_RESULTS.md) (last 10 runs, p95 per metric). |

## Scenarios

- **A transport**: delivery probe (backend -> live Workspace Service -> backend) on the developer account's Workspace, with payloads 0, 1024 and 32768 bytes. Skipped with a warning if the Workspace is offline or its Service does not answer probes (an old Service build; restart it with the current build).
- **B messages**: synthetic users post messages with a live realtime socket; REST latency, post -> socket fan-out, throughput.
- **C workflows**: concurrent Chat requests through an in-process FakeWorkspace (total latency and the Service receive-to-accept interval), plus one Free account submitting serially. Serial overhead is an estimate: total time less the fake Service receive-to-start interval. Other Latency Trace v1 stages are omitted when their events are unavailable.

## Reading the numbers

p50 is the typical request; p95 means 95% of requests were at least this fast; p99 and max show the tail. With small samples (n < 20) p95, p99 and max are nearly the same value. Compare runs on a quiet machine; small absolute differences can be timer jitter. The comparison flags all increases above 25%.

## Thresholds

`scripts/perf-thresholds.json` holds p95 limits in ms. Measured limits use twice the highest p95 of three earlier runs; transport limits are provisional until a responsive Workspace can be measured. The file explains the choices. A limit is a failure gate, not a target. Change one only with the reason in the commit message.

## Safety

No real AI is involved. Only the local backend is used. WebSocket probes are held in memory; HTTP long-poll currently persists the gateway session snapshot, including the queued probe, to PostgreSQL. Synthetic `perf-<runid>` users, Spaces and workspaces are removed at the end of every run (cleanup is restricted to the current run, and its remaining row count must be 0). Tokens, keys and message bodies are never printed. `_perf/` is git-ignored.
