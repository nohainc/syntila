# Syntila Worker Protocol

Canonical Dart models and validators for the Local Worker Protocol 4.1 wire
contract shared by Connect and the standalone CLI Worker Engine.

Frames use one JSON object per line. The package validates initialize, probe,
execute, progress, result, and error frames, including bounded fields and strict
field allowlists. Provider credentials, provider session IDs, arbitrary
executable paths, and arbitrary working directories are not part of the
protocol. Provider tool paths may appear in probe results for local diagnostics
and must be excluded from Cloud inventory. This package has no Flutter
dependency.

Execute requests may carry the bounded `executionPolicy` values `restricted`,
`provider_default`, and `full_access`. The field defaults to `restricted` for
older senders. Connect emits `full_access` only for a locally owner-authorized
Worker; remote assignments cannot grant it.

This is the sole Dart package for the Local Worker Protocol in the current
runtime. Older JSON-RPC Worker protocol models have been removed.

Protocol 4.1 adds a catalog revision pin to execution requests. Legacy 4.0 frames
remain readable without that field; native model identifiers remain local to the
Engine and are never accepted as client-supplied invocation arguments.

Protocol 4.1 also supports `activity` frames for provider-neutral live
execution events. Activity frames carry an ordered execution sequence and are
not deduplicated by percentage, so repeated tool calls remain visible. See
`docs/specifications/WORKER_ACTIVITY_V1.md` for field limits, terminal
guarantees, and declarative Tool Profile mappings.

Provider timing is an optional capability negotiated by `provider_timing_v1`
in the Engine's initialize result. A supporting Connect may set
`providerTiming: true` on an execute request; it omits the field otherwise.
The Engine then emits reserved internal progress markers for the first stdout
line, the age of the last stdout line at stream drain, and process exit plus
stream drain. These markers contain no provider output and are consumed by the
Connect rather than shown as user progress. Older senders omit the opt-in;
older Engines do not advertise it. An Engine cannot infer when a provider's
network request was sent or when a model generated its answer from these marks.
