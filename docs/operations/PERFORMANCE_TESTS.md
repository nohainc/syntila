# Local performance tests

`scripts/perf-local.sh` measures local Work requests using a real configured Worker and provider. `--chats N` controls the number of requests, `--workflow chat|work` chooses the workflow, `--model ID` selects a model, `--json FILE` saves a report, and `--no-thresholds` disables threshold enforcement. `SYNTILA_PERF_WORKER_ID` selects a Worker. See the script help and `scripts/perf-thresholds.json` for current options and limits.

The runner reports end-to-end request timing and available persisted admission and dispatch intervals. Historical requests are informational. Percentiles from small samples are not reliable; compare representative runs on a quiet machine. Provider requests may consume quota, and stateful Work can create local files.

The old transport delivery probe is retired: `--probes` is accepted for existing invocations but does not measure Worker transport. Do not treat its absence as a passing latency result. `scripts/test-perf.sh` runs the local test and saves a report; `bun scripts/perf-report.mjs` summarizes saved reports. Temporary resources are cleaned up where possible, and active requests are preserved on timeout.
