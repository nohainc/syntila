# Execution migration and acceptance — V9 Phase 8

This is the Phase 8 completion contract for the consolidated execution path.
The external activity stream is `assignment.activity`; the removed
`assignment.progress` message is not a compatibility transport. The generic
Engine may still emit a private milestone frame so the Service can record
provider startup.

## Cross-component execution trace

The Service and Cloud diagnostic records use bounded metadata and the existing
assignment correlation tuple. A trace is complete when it can be followed with
the same assignment ID and attempt ID through these stages:

| Stage | Owner | Evidence |
| --- | --- | --- |
| `dispatch` | Cloud | Assignment selected and command sent |
| `accepted` | Service/Cloud | Envelope validated, journal entry written, admission acknowledged |
| `slot_reservation` | Service | Local capacity reserved, or queue/deadline diagnostic |
| `engine_startup` | Service | Engine process ownership record and initialization result |
| `provider_execution` | Service/Cloud | Engine/provider startup evidence; only then is the assignment running |
| `activity_forwarding` | Service/Cloud | Normalized activity accepted, coalesced or safely skipped |
| `terminal_recorded` | Service | Durable local terminal journal record |
| `terminal_acknowledgement` | Cloud/Service | Cloud persisted the outcome and acknowledged delivery |

Every record includes a schema version, event ID, timestamp and the available
Connect, runtime, Worker, run, task, assignment and attempt identities.
Diagnostic metadata is bounded and excludes prompts, credentials, provider
content, unrestricted tool input/output and internal reasoning.

## Automated acceptance matrix

The focused contract, Cloud, Service, Engine and AX suites must cover the
following behaviors. Provider names identify the adapter fixture; the lifecycle
assertions are provider-independent.

| Scenario | Required result |
| --- | --- |
| Normal Codex execution | Complete lifecycle, normalized activity and one terminal result |
| Normal agy execution | Complete lifecycle, normalized activity and one terminal result |
| Normal Claude execution | Complete lifecycle when the adapter is enabled; otherwise explicit unsupported-profile result |
| Provider produces no activity | Correct terminal state; no indefinite Running state |
| Provider exits nonzero | Failed outcome, safe error classification and released capacity |
| Engine killed during work | Failure or explicit reconciliation state; no phantom slot |
| Service restart | Journal reconciliation without duplicate execution |
| Web reconnect | Authoritative status plus retained activity history are restored |
| Browser reload | Active Worker and terminal status come from Cloud state |
| Cloud disconnects mid-execution | Local execution continues when safe; terminal outcome is retried after reconnect |
| Duplicate terminal delivery | One final outcome, idempotent acknowledgement |
| Late activity after completion | History may accept a valid retained event; lifecycle remains terminal |
| Independent concurrent requests | Separate Engine processes, activity streams and outcomes |
| Queue timeout | Explicit timeout/recoverable result and correct capacity accounting |
| Cancel active assignment | Only the intended process terminates |
| Cancel queued assignment | No Engine process launches and no slot leak |
| Rapid submission burst | No duplicate, missing or permanently queued assignments |

## Migration and cleanup rules

Migration history, Cloud assignment rows needed for recovery and published Tool
Profile revision contracts are retained. Cleanup removes only obsolete active
protocol code, generated bindings, compatibility adapters and redundant tests.
The migration is considered complete only after the normalized activity path is
verified end to end and the external progress message has no producers or
consumers.

