# MCP Worker latency (ADR-028, plan phase M4)

Measured with `engines/cli_worker/tool/mcp_latency_benchmark.dart`
(`cd engines/cli_worker && dart run tool/mcp_latency_benchmark.dart`, add `--quick` for a
short run). It compiles the Engine, an NDJSON fixture plugin, the MCP echo Worker and
itself to AOT binaries, and runs every path through the production
`LimitedPluginSupervisor`.

**Host:** Apple M5 Pro, 18 cores, macOS 26.6.2, Dart 3.13.7, 2026-11-06. Run on a
working desktop (a browser and the window server were using CPU), one run, n = 40 for
spawning paths.

| Path | n | p50 ms | p95 ms | min ms | max ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| NDJSON plugin, per execute (spawns) | 40 | 209.21 | 225.99 | 190.64 | 229.20 |
| NDJSON assignment (probe + execute = 2 spawns) | 40 | 422.89 | 468.60 | 402.39 | 491.69 |
| MCP cold (spawn + initialize + tools/list + call) | 40 | 207.87 | 223.24 | 189.19 | 227.78 |
| MCP assignment (probe + execute = 1 spawn) | 40 | 204.79 | 218.45 | 191.17 | 223.77 |
| MCP cold, no limits wrapper (diagnostic) | 40 | 130.69 | 140.21 | 119.42 | 143.77 |
| MCP warm, per execute (pooled server) | 500 | 0.07 | 0.14 | 0.06 | 0.32 |
| MCP ping (JSON-RPC round trip) | 2000 | 0.04 | 0.08 | 0.02 | 0.26 |

Two earlier runs of the same tool gave the same picture (spawn paths within ~5%).

## What this shows

1. **The protocol is not the cost.** A warm MCP call is ~0.07 ms end to end and a bare
   JSON-RPC round trip ~0.04 ms, far under the plan's 5 ms target. The extra layer MCP
   adds over a direct pipe is negligible.
2. **Process spawn is the cost** (~210 ms with the limits wrapper). MCP cold and an
   NDJSON execute are equal (208 vs 209 ms): MCP is not slower to start.
3. **MCP saves one spawn per assignment.** The Engine first probes the Worker and then
   executes. The NDJSON host starts the plugin for each call (423 ms for the pair); an MCP
   Worker is started once and both calls share the connection (205 ms). That is about
   half the host overhead of an assignment, ~215 ms.
4. **The limits wrapper is ~77 ms of every spawn** (208 ms with it, 131 ms without). It
   re-executes the Engine binary around the plugin to apply CPU and file-handle limits.
5. **~130 ms of a bare spawn is unexplained.** A tiny AOT binary should start much
   faster. Candidates (not investigated): hashing the artifact, process-tree
   bookkeeping, the resource monitor, and first-exec checks by the OS. Worth a profile
   before anyone optimises the wrapper.

## Correction: the warm pool does not survive between assignments

The pool lives inside the Engine process, and the supervisor starts a new Engine process
for every assignment and ends it afterwards (`CliWorkerEngineSupervisor.execute`). So in
production an MCP Worker is **cold on every assignment**. The 0.07 ms warm figure applies
to calls within one assignment (for example probe, then execute), not across them. An
earlier statement that servers "stay warm between assignments" was wrong for the current
architecture. Cross-assignment reuse would need a long-lived host process; that is an
architecture decision, not part of this phase.

## Limits of this measurement

- Trivial Workers: this isolates host and protocol overhead. A real Worker adds its own
  start-up (a Dart JIT script or a Python interpreter starts slower than this AOT binary)
  and its own work.
- One machine, one session, desktop noise; p95/max for cold paths are indicative only.
- Linux and Windows are unmeasured; Windows process creation is typically slower.
- Throughput under concurrency was not measured (a pooled server serves one call at a
  time by default, `maxConcurrent` = 1).
