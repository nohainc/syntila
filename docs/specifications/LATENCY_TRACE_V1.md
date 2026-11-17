# Latency Trace v1

Latency Trace extends [Diagnostic Events v1](DIAGNOSTIC_EVENTS_V1.md) so one
Work request can be followed from Web submission to Web receipt of the outcome
and any delay attributed to a single stage. It adds no logging system: trace
points are ordinary diagnostic events with `stage: "trace"` and a closed
`context.traceStage`.

## Stages

| Stage | `traceStage`                | Emitted by                          | Meaning                                               |
| ----- | --------------------------- | ----------------------------------- | ----------------------------------------------------- |
| T1    | `web_submitted`             | Web `ax_work_latency_trace.dart`    | User submits the Work request                         |
| T2    | `cloud_accepted`            | `routes/work-creation.ts`           | Submission durably persisted                          |
| T3    | `workflow_dispatch_started` | `workflow.ts`                       | Workflow step begins dispatching the task             |
| T4    | `gateway_queued`            | `workspace-gateway.ts`              | `assignment.start` written to WebSocket or HTTP queue |
| T5    | `service_received`          | `cloud_connection.dart`             | Service reads the command off the transport           |
| T6    | `service_accepted`          | `cloud_connection.dart`             | Admission `assignment.ack` written                    |
| T7    | `profile_resolved`          | `workspace_runtime.dart`            | Tool Profile resolved and its execution file located  |
| T8    | `slot_reserved`             | `workspace_runtime.dart`            | Local Worker execution slot reserved                  |
| T9    | `engine_process_created`    | `cli_worker_engine_supervisor.dart` | Engine OS process exists                              |
| T10   | `provider_started`          | `cloud_connection.dart`             | Provider CLI start evidence                           |
| T11   | `terminal_persisted`        | `workspace-gateway.ts`              | Terminal outcome written to D1                        |
| T12   | `web_received`              | Web `ax_work_latency_trace.dart`    | Web receives the final update                         |

Auxiliary stages are not numbered: `cloud_ack_received` (command round trip
and the Service's reported load), `workflow_observed_terminal` (lag between
the terminal row and the Workflow poll noticing it), and `probe_sent` /
`probe_acknowledged`.

T5 is stamped when the message is read from the transport, before any
synchronization deferral, so time spent waiting for the Service to reach
`ready` is attributed to T5→T6 rather than hidden.

## Timing rules

- Durations within one component use a monotonic timer (`durationMs`,
  `monotonicMs`). Cloudflare Workers freeze `performance.now()` between I/O, so
  Cloud-side durations are coarse; rely on wall-clock timestamps taken at I/O
  boundaries for Cloud intervals.
  Workers use the Unix epoch as `performance.timeOrigin`; absolute readings
  beyond the bounded `monotonicMs` field are omitted without dropping the
  event. Elapsed `durationMs` and wall-clock `timestamp` remain available.
- Service trace context includes a bounded `traceEpochId`, generated once per
  process. Compare local monotonic endpoints only within the same epoch and
  runtime/attempt; a restart preserves runtime identity but resets the clock.
- Cross-machine intervals use event `timestamp` values corrected by
  `clockOffsetMs` (Cloud minus Service). The Service estimates it NTP-style
  from `workspace.hello` and `workspace.heartbeat` acknowledgements
  (`serverTime`), keeping the lowest-round-trip sample of the last eight.
  `clockRttMs` bounds the error at half its value. Never subtract Mac and
  Cloud timestamps directly.
- Trace emission is synchronous at the call site and detached from the work it
  measures. Failures are swallowed. Existing awaited diagnostics on the
  acknowledgement and spawn paths are deliberately unchanged until the
  baseline is captured.

## Delivery probe

The Workspace Gateway's `diagnostic-probe` (the public route
`POST /api/workspaces/:workspaceId/delivery-probe` was removed in the backend
cleanup) sends `diagnostic.probe` over the Workspace's live
transport and waits up to 5 s for `diagnostic.probe.ack`. No assignment,
Worker, Engine or provider process is involved. The response reports the
transport, round trip, Service receive/acknowledge times, clock offset, sync
state, local queue length and active assignment count. A Service that does not
implement probes never answers and the route returns `outcome: "timeout"`.

Both message types are additive within Workspace protocol 5.1: an older Cloud
never sends a probe, and a newer Service only answers one.

## Histograms and privacy

The Service keeps fixed-bucket histograms per stage interval
(`from->to` and `since_received:stage`) and exports p50/p95/p99/max/mean under
`cloud.latency` in the Workspace diagnostics report. Percentiles are bucket
upper bounds clamped to the observed maximum. Only numeric durations, closed
stage names and bounded labels are retained; no prompts, output, paths or
credentials.

## Web trace (T1 / T12)

The Web client keeps a bounded (128) in-memory record per Work request:
T1 is stamped before the submit `POST`, the submit response and the realtime
`work_request.created` / `started` events are auxiliary marks, and T12 is
stamped when the terminal `work_request.completed|failed|cancelled` event
arrives, before the cache is patched, so UI work is excluded. Marks are
milliseconds from a monotonic stopwatch on the device; the wall-clock submit
time is used for ordering only. One line per finished request is printed to
the browser console as `[syntila.latency] {json}`. Prompts, attachments and
Idempotency-Keys are never recorded. A request whose terminal state is only
seen through the polling fallback has no T12.

Web and Cloud clocks are never subtracted. The report instead shows the Web
monotonic submit round trip, the Web-observed total, and an approximate
residual (`web total - submit response - Cloud T2->T11`) for result delivery.

## Baseline gate

Capture a baseline with the current system before changing delivery or
startup behavior, and record it with the build under test.

1. Run 20-30 Work requests: a mix against an idle Service and against one with
   an active assignment, plus a few gateway `diagnostic-probe` calls.
2. Collect Cloud logs (`wrangler tail --format json > cloud.log`), the
   Service `worker.jsonl*` files, and the browser console lines.
3. Run `pnpm latency:baseline -- --cloud cloud.log --service worker.jsonl
--web console.txt --json baseline.json`.

The report lists p50/p95/p99/max per stage interval, the phase holding the
largest interval for each trace (before delivery, transport, Service
admission, queueing, after Engine launch, result delivery), and warnings for
traces that had to use an uncorrected Service clock.

## Phase 5 addendum

Auxiliary startup milestones (worker_resolved, profile_ready, waiting_for_space, queued_for_slot, engine_initialized) are recorded without renumbering T1-T12. T7 is stamped after any Space wait. See SERVICE_STARTUP_V9.md.

## Phase 6 addendum

`workflow_observed_terminal` now measures the lag between the terminal row and the Workflow's wake-up by `assignment-terminal` event (or, on a lost event, the reconciliation timeout), not a 2 s poll. See WORKFLOW_TERMINAL_EVENTS_V9.md.

## Release performance gate

`scripts/execution-latency-acceptance.mjs` evaluates the five proposed targets
using a build-pinned capture manifest, separate idle/burst interval tables,
strict stage/identity/clock validation and explicit incomplete results. It
reuses this parser and existing traces; it introduces no logging or command
path. See [V9 acceptance](../acceptance/EXECUTION_RELIABILITY_V9.md#performance-evidence).
The original baseline tool remains an exploratory report and can report partial
traces; its successful exit does not certify release acceptance.
