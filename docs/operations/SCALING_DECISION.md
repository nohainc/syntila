# Scaling decision (P11, ADR-039 activation gate)

Decides whether one backend node is enough. **Status: single node; revisit when load grows (ADR-039).** Nothing has been measured yet. Fill in the tables from a run on the production VPS size, then record the decision at the bottom.

## Targets (ADR-039, decision 6)

| Measure | Target |
| --- | --- |
| API p99 (REST post) | under 150 ms |
| Fan-out p99 (post to event on a socket) | under 250 ms at 2,000 sockets |
| Idle sockets | 1,000 and 5,000 stay open with 0 unexpected closes |
| Reconnect storm | every socket back and subscribed, no thundering-herd failures |
| Outbox | oldest pending row stays under 30 s during the active scenario (suggested) |
| Memory | no drift over 25% in a 24-hour soak |

## How to measure

Run on the VPS size (not a laptop), backend started with rate limits off, `SERVER_PID` set, and the database credentials in `PG*`:

```bash
SERVER_PID=<pid> scripts/test-scale.sh idle active storm --sockets 1000 --senders 100 --messages 20 --json _perf/scale-1k.json
SERVER_PID=<pid> scripts/test-scale.sh idle active storm --sockets 2000 --senders 500 --json _perf/scale-2k.json
SERVER_PID=<pid> scripts/test-scale.sh idle storm --sockets 5000 --json _perf/scale-5k.json
SERVER_PID=<pid> scripts/test-scale.sh soak --sockets 1000 --soak-minutes 1440 --json _perf/scale-soak.json
```

`scripts/test-scale.sh` fails (exit 1) when REST p99 or fan-out p99 miss the targets or the soak drifts. 

Not covered by the script, so measure them another way and add them below: Agent sockets at 1 to 2 events per second (needs a unified-protocol Agent client; none exists yet), 50 concurrent streams, slow readers, lease writes per second, event-loop lag (from the server's own metrics), top queries (`apps/backend/scripts/db-report.sql`).

## Results

| Run | Sockets | REST p99 | Fan-out p99 | Memory per idle socket | Outbox oldest | Unexpected closes |
| --- | --- | --- | --- | --- | --- | --- |
| 1k | | | | | | |
| 2k | | | | | | |
| 5k | | | | | | |
| soak 24 h | | | | | | |

## Decision record

- Date:
- Result: one node meets the targets / one node misses the targets
- Decision: defer P12 (keep `scripts/test-two-node.sh` guarding the rules) / start P12
- Also decide: whether a zero-downtime rolling deploy is required (that alone starts P12).
