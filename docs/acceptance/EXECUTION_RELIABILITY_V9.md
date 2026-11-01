# V9 communication and execution acceptance

This is the release evidence contract for Phases 8 and 9 of the fast
communication and reliable execution plan. Implemented code, deterministic
acceptance, and a completed production rollout are separate claims. A passing
fixture does not establish provider performance or deployed recovery behavior.

## Phase audit

| Phase | Source evidence | Acceptance state |
| --- | --- | --- |
| 1: tracing | `assignment_trace.dart`, Cloud trace emitters, Web recorder, `scripts/latency-baseline.mjs` | Implemented. The retained [baseline](latency/2026-10-14/POST_FIX_BASELINE.md) is partial: no T11 or Web T1/T12. The measurement gate is open. |
| 2: lifecycle | `packages/core/src/execution-lifecycle.ts`, guarded Cloud writers, lifecycle race suites | Implemented. Conditional transitions reject stale attempts and terminal regressions. |
| 3: delivery and revocation | `assignment-delivery.ts`, `assignment-revocation.ts`, start permits, Service journal and cancel handlers | Implemented. Ambiguous stop retains ownership; no automatic retry based on a deadline alone. |
| 4: readiness | Gateway readiness persistence, conditional queue flush, Service readiness publication | Implemented. Transport liveness is separate from readiness. |
| 5: startup | `worker_launch_plan.dart`, pinned admission plans, supervisor slot/session gates, startup milestones | Implemented. Actual cold and warm provider startup still need candidate-build evidence. |
| 6: terminal events | `assignment-workflow-signal.ts`, `workflow-terminal-wait.ts`, Workflow event waits | Implemented. Deployed buffering, hibernation and lost-event recovery need live evidence. |
| 7: Web state | `execution-phase.ts`, `assignment-phase-events.ts`, `ax_execution_phase.dart`, realtime reconciliation and retry controls | Implemented, with additional regression coverage from this audit. |
| 8: acceptance | Existing boundary suites plus repeated execution runner and latency evidence gate | Automated checks implemented; live provider, deployed fault and complete latency gates remain open. |
| 9: rollout/cleanup | Session-bound capability admission, legacy writer cleanup, forward trigger repair, [rollout runbook](../rollouts/EXECUTION_RELIABILITY_V9.md) | Implementation and procedure prepared; production rollout has not been performed by this audit. |

## Repeatable fault and race checks

Run from the repository root on a Mac with resolved dependencies:

```sh
node scripts/execution-acceptance.mjs --suite all --repeat 3 --json /tmp/execution-boundaries.json
```

`--suite cloud,service,engine,web` selects boundaries; `--repeat` accepts 1–25.
The runner uses existing test files, executes each selected suite in every
round, retains failures from earlier rounds, and never retries until green.
Its exit code represents the selected deterministic checks. Its JSON separately
reports `boundaryTestsStatus` and overall `status`; successful fixture tests
leave overall release acceptance `incomplete` while live evidence is missing.

| Requirement | Primary executable evidence |
| --- | --- |
| Late/duplicate ack; stale attempt; competing writers | Cloud `assignment-lifecycle-races` and `assignment-lifecycle-gateway` |
| Cancel/permit race; revoked late delivery; fixed permit expiry | Cloud `assignment-start-permit`, `assignment-revocation`, `assignment-revocation-gateway` |
| Ready queue, reconnect, poll supersession, post-hibernation close | Cloud `service-readiness-gateway`; Service transport and connection suites |
| Runtime replacement and downgrade | Gateway tests with session-bound execution capability and replaced identities |
| Early/duplicate/lost terminal signal; binding/send failure | Cloud `assignment-workflow-signal`, `workflow-terminal-wait` |
| Journal restart, cancel tombstones, terminal replay without execution | Service `assignment_journal` and `cloud_connection` |
| Queue cancellation, slot transfer, independent Workers, immediate exit | Service `cli_worker_engine_supervisor`; CLI runtime package |
| Frozen local Profile plan | Service `worker_launch_plan` |
| Delayed Web events, terminal wins, concurrent request isolation | AX `ax_execution_phase`, `ax_work_realtime_sync` |
| Actual headless executable startup | `bash scripts/internal/check-workspace-service.sh` in an isolated temporary root |

The normal component validations remain required after implementation. This
runner supplements them with repeated race coverage; it does not replace them.

## Performance evidence

Capture at least ten completed idle and ten completed moderate-burst requests
against one identified candidate Cloud/Service build. Retain additional cold,
fallback, queued, failed-connection and slow-provider captures separately.
Record the exact request IDs, runtime/attempt IDs, build revisions and whether
the Service was ready and its Profile cached. Use a dedicated test Space and
normal authorization and scheduling. The installed Workspace UI need not run:
the headless Service owns execution.

Collect the existing Cloud diagnostic events, rotated Service JSONL files and
instrumented Web console records. Store private raw logs outside Git. Preserve
only bounded trace metadata in the evidence bundle; never include credentials,
prompts, provider output or private filesystem paths.

Create a capture manifest with this structure (the empty list deliberately
cannot pass):

```json
{
  "schemaVersion": 1,
  "commit": "f710f9f8",
  "cloudVersion": "candidate-cloud-deployment-id",
  "serviceVersion": "candidate-service-build-id",
  "samples": []
}
```

Each sample has `requestId`, `cohort` (`idle`, `burst`, `cold`, `fallback`,
`queued`, `failure`, or `slow_provider`), and `status`. Healthy samples also
require `ready: true`, `cachedProfile: true`, and `evidenceRef`, a reference to
the retained capture notes proving those build/readiness/cache assertions.
Record any uncommitted source diff digest with the build notes; a HEAD SHA
alone does not identify a dirty build. The evaluator validates consistency of
the supplied trace evidence, not the truth of operator assertions.

```sh
node scripts/execution-latency-acceptance.mjs \
  --manifest capture.json --cloud cloud.log \
  --service worker.jsonl --service worker.jsonl.1 \
  --web console.txt --json /tmp/execution-latency.json
```

The command reports the complete observed interval table per cohort and checks
the five proposed healthy-path p95 targets. Exit codes: 0 pass, 1 measured
failure, 2 incomplete/invalid evidence. Missing stages, ambiguous multi-attempt
traces, mismatched runtime/attempt/process identities, nonmonotonic Service
timings and insufficient sample counts cannot pass. A declared exceptional
sample without its delivery/outcome evidence leaves the report incomplete.

Service-local metrics require monotonic readings from one `traceEpochId`.
This process identity changes on restart, independently of the persisted
Workspace runtime identity. Cloud-local durations use wall time because
Workers monotonic time can freeze across I/O. Cross-host delivery adds half
the measured clock RTT to account conservatively for offset uncertainty.

Web submission-to-admission uses the conservative bound
`Web submit response RTT + Cloud accepted-to-ack duration`. Terminal-to-Web
uses `Web submit-to-final duration - Cloud accepted-to-terminal duration`.
These subtract durations, never unrelated browser/Cloud wall clocks, and
include overlap/extra legs. Passing a bound establishes the target under the
recorded timing assumptions; exceeding it is inconclusive for that individual
leg. The report does not label an approximate residual as a precise latency.
Ten samples per cohort give exploratory percentiles, not a statistical SLO.

## Live release gates

Retain an operator-reviewed evidence bundle tied to the exact candidate:

1. First and second normal requests for each qualified Codex, Gemini/AGY and
   Claude Profile, through the Cloud scheduler and headless Service. A missing
   qualified Profile is a recorded unsupported/test-blocked case, not a pass.
2. Repeated same-Worker saturation and independent-Worker execution, recording
   process IDs, slot counts and durable assignment outcomes.
3. Disconnect during delivery and provider startup; reconnect and journal
   recovery; duplicate start and terminal replay; isolated Service restart with
   active work. Confirm no duplicate provider and no re-execution of a terminal
   record. Never crash or replace an installation doing unrelated user work.
4. Startup deadline immediately before launch, cancellation during slot
   transfer, and immediate Engine/provider exits. Confirm either no launch or
   tracked ownership followed by confirmed stop; unresolved execution stays
   visible and holds capacity.
5. Actual deployed Gateway hibernation/session replacement and Workflow early,
   duplicate and lost terminal notification recovery. Confirm one durable
   outcome and no repeated Workflow step.
6. Complete performance evidence as above, with failures and queueing reported
   separately and all outstanding bottlenecks named.

No automated fixture result fills these rows. Deployment, credentials and a
candidate Service/Engine/Profile identity must be established before running
them. Preserve the pre-fix failed-admission trace and partial baseline; neither
is a successful healthy-path sample for the candidate.

## Audit verification record

The accompanying implementation report records the exact checks executed in
this working tree. This document does not assert that a candidate was deployed,
that the current installed Service runs this source, or that a new production
latency baseline exists. Operational release acceptance remains open until the
live evidence above is attached.
