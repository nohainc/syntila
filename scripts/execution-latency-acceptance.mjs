#!/usr/bin/env node
// Release evidence gate over existing Latency Trace v1 captures; no traffic is generated.
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  buildTraces,
  eventsFromText,
  report,
  summarize,
  webRecordsFromText,
} from "./latency-baseline.mjs";

export const TARGETS = {
  gatewayToService: 500,
  webToAdmission: 1000,
  serviceAdmission: 250,
  slotToEngine: 2000,
  terminalToWeb: 1000,
};

function elapsed(trace, from, to, crossHost = false) {
  const a = trace.marks[from];
  const b = trace.marks[to];
  if (!a || !b) return null;
  let ms = b.ts - a.ts;
  if (
    !crossHost &&
    SERVICE_COMPONENTS.includes(a.event.component) &&
    SERVICE_COMPONENTS.includes(b.event.component)
  ) {
    const start = a.event.context.monotonicMs;
    const end = b.event.context.monotonicMs;
    if (
      !Number.isFinite(start) ||
      !Number.isFinite(end) ||
      !a.event.context.traceEpochId ||
      a.event.context.traceEpochId !== b.event.context.traceEpochId ||
      a.event.workerId !== b.event.workerId
    )
      return null;
    ms = end - start;
  }
  if (!Number.isFinite(ms) || ms < 0) return null;
  if (crossHost) {
    const { clockOffsetMs, clockRttMs } = b.event.context;
    // Use this sample's uncertainty, never an inferred offset from another trace.
    if (
      !Number.isFinite(clockOffsetMs) ||
      !Number.isFinite(clockRttMs) ||
      clockRttMs < 0
    )
      return null;
    ms += clockRttMs / 2;
  }
  return ms;
}

const SERVICE_COMPONENTS = ["service", "workspace", "connect_service"];
const SERVICE_STAGES = [
  "service_received",
  "service_accepted",
  "profile_resolved",
  "slot_reserved",
  "engine_process_created",
  "provider_started",
];
const CLOUD_STAGES = [
  "cloud_accepted",
  "workflow_dispatch_started",
  "gateway_queued",
  "cloud_ack_received",
  "terminal_persisted",
];

function identityIssue(trace, events, sample) {
  if (typeof sample.evidenceRef !== "string" || !sample.evidenceRef.trim())
    return "missing capture provenance reference";
  if (trace.assignmentIds.length !== 1)
    return "missing or ambiguous assignment identity";
  const local = events.filter(
    (event) =>
      trace.assignmentIds.includes(event.assignmentId) &&
      SERVICE_COMPONENTS.includes(event.component),
  );
  const reference = local[0] ?? trace.marks.terminal_persisted?.event;
  if (!reference?.attemptId || !reference.workerId)
    return "missing execution identity";
  if (
    local.some(
      (event) =>
        !event.context.traceEpochId ||
        event.workerId !== reference.workerId ||
        event.attemptId !== reference.attemptId ||
        event.context.traceEpochId !== reference.context.traceEpochId,
    )
  )
    return "inconsistent assignment attempt, Worker or process epoch";
  for (const stage of CLOUD_STAGES) {
    const event = trace.marks[stage]?.event;
    if (!event) continue;
    if (event.component !== "cloud") return "invalid Cloud emitter";
    if (
      ["gateway_queued", "cloud_ack_received", "terminal_persisted"].includes(
        stage,
      ) &&
      event.assignmentId !== trace.assignmentIds[0]
    )
      return "missing Cloud assignment identity";
    if (
      event.assignmentId &&
      (event.assignmentId !== trace.assignmentIds[0] ||
        event.attemptId !== reference.attemptId ||
        event.workerId !== reference.workerId)
    )
      return "Cloud evidence identity differs from Service/terminal identity";
  }
  for (const stage of SERVICE_STAGES) {
    const event = trace.marks[stage]?.event;
    if (event && !SERVICE_COMPONENTS.includes(event.component))
      return "invalid Service emitter";
    if (
      event &&
      (event.assignmentId !== trace.assignmentIds[0] ||
        event.attemptId !== reference.attemptId ||
        event.workerId !== reference.workerId ||
        event.context.traceEpochId !== reference.context.traceEpochId)
    )
      return "missing or inconsistent Service assignment identity";
  }
  const localTimes = SERVICE_STAGES.filter((stage) => trace.marks[stage]).map(
    (stage) => trace.marks[stage].event.context.monotonicMs,
  );
  if (
    localTimes.some(
      (value, i) =>
        !Number.isFinite(value) ||
        value < 0 ||
        (i > 0 && value < localTimes[i - 1]),
    )
  )
    return "invalid Service monotonic timeline";
  const cloudTimes = [
    "cloud_accepted",
    "workflow_dispatch_started",
    "gateway_queued",
    "terminal_persisted",
  ]
    .filter((stage) => trace.marks[stage])
    .map((stage) => trace.marks[stage].ts);
  if (cloudTimes.some((value, i) => i > 0 && value < cloudTimes[i - 1]))
    return "noncausal Cloud timeline";
  const gateway = trace.marks.gateway_queued;
  const ack = trace.marks.cloud_ack_received;
  if (gateway && ack && ack.ts < gateway.ts)
    return "Cloud ack precedes dispatch";
  const admitted = trace.marks.service_accepted;
  if (
    admitted &&
    ack &&
    Number.isFinite(admitted.event.context.clockRttMs) &&
    ack.ts < admitted.ts - admitted.event.context.clockRttMs / 2
  )
    return "Cloud ack precedes Service admission";
  return null;
}

function healthyTraceIssue(trace, events, sample) {
  const issue = identityIssue(trace, events, sample);
  if (issue) return issue;
  for (const stage of [...SERVICE_STAGES, ...CLOUD_STAGES])
    if (!trace.marks[stage]) return `missing stage: ${stage}`;
  if (trace.marks.service_received.event.context.syncState !== "ready")
    return "Service was not ready at receipt";
  return null;
}

export function assessLatency(events, webRecords, manifest) {
  if (
    manifest?.schemaVersion !== 1 ||
    !/^[a-f0-9]{7,40}$/i.test(manifest.commit ?? "") ||
    typeof manifest.cloudVersion !== "string" ||
    !manifest.cloudVersion.trim() ||
    typeof manifest.serviceVersion !== "string" ||
    !manifest.serviceVersion.trim() ||
    !Array.isArray(manifest.samples)
  ) {
    throw new Error(
      "Manifest requires schemaVersion 1, commit, cloudVersion, serviceVersion and samples",
    );
  }
  const traces = buildTraces(events, webRecords);
  const byRequest = new Map(traces.map((t) => [t.requestId, t]));
  const seen = new Set();
  const cohorts = {};
  for (const sample of manifest.samples) {
    if (
      !sample.requestId ||
      seen.has(sample.requestId) ||
      ![
        "idle",
        "burst",
        "cold",
        "fallback",
        "queued",
        "failure",
        "slow_provider",
      ].includes(sample.cohort)
    )
      throw new Error(
        "Samples need unique requestId values and an explicit supported cohort",
      );
    seen.add(sample.requestId);
    const bucket = (cohorts[sample.cohort] ??= { samples: [], traces: [] });
    const trace = byRequest.get(sample.requestId);
    bucket.samples.push({ sample, trace });
    if (trace) bucket.traces.push(trace);
  }
  // Idle/burst are mandatory. Other conditions are reported separately, never blended.
  for (const cohort of ["idle", "burst"])
    cohorts[cohort] ??= { samples: [], traces: [] };
  let failed = false;
  let incomplete = false;
  const results = {};
  for (const [name, bucket] of Object.entries(cohorts)) {
    const healthy = name === "idle" || name === "burst";
    const invalid = [];
    const values = Object.fromEntries(
      Object.keys(TARGETS).map((key) => [key, []]),
    );
    for (const { sample, trace } of bucket.samples) {
      if (!trace) {
        invalid.push({ requestId: sample.requestId, reason: "missing trace" });
        incomplete = true;
        continue;
      }
      if (!healthy) {
        const conditionStages =
          name === "failure"
            ? ["cloud_accepted", "terminal_persisted"]
            : [
                "gateway_queued",
                "service_received",
                "terminal_persisted",
                ...(name === "slow_provider"
                  ? ["engine_process_created", "provider_started"]
                  : []),
              ];
        const issue = identityIssue(trace, events, sample);
        if (
          issue ||
          conditionStages.some((stage) => !trace.marks[stage]) ||
          (name === "fallback" &&
            trace.marks.gateway_queued?.event.context.transport !==
              "http_long_poll") ||
          !["completed", "failed", "cancelled"].includes(sample.status)
        ) {
          invalid.push({
            requestId: sample.requestId,
            reason:
              issue ??
              "exceptional-condition delivery/outcome evidence missing",
          });
          incomplete = true;
        }
        continue;
      }
      const transport = trace.marks.gateway_queued?.event.context.transport;
      if (
        sample.ready !== true ||
        sample.cachedProfile !== true ||
        sample.status !== "completed" ||
        transport !== "websocket" ||
        trace.assignmentIds.length !== 1 ||
        trace.uncorrected ||
        trace.web?.terminalStatus !== "completed"
      ) {
        invalid.push({
          requestId: sample.requestId,
          reason:
            "healthy ready/cached/WebSocket/single-attempt completion evidence missing",
        });
        continue;
      }
      const issue = healthyTraceIssue(trace, events, sample);
      if (issue) {
        invalid.push({ requestId: sample.requestId, reason: issue });
        continue;
      }
      if (
        trace.marks.service_received &&
        trace.marks.gateway_queued &&
        trace.marks.service_received.ts < trace.marks.gateway_queued.ts
      ) {
        invalid.push({
          requestId: sample.requestId,
          reason: "clock-corrected receipt precedes dispatch",
        });
        continue;
      }
      const ms = {
        gatewayToService: elapsed(
          trace,
          "gateway_queued",
          "service_received",
          true,
        ),
        serviceAdmission: elapsed(
          trace,
          "service_received",
          "service_accepted",
        ),
        slotToEngine: elapsed(trace, "slot_reserved", "engine_process_created"),
      };
      const web = trace.web?.marksMs;
      const roundTrip = web?.web_submit_response;
      const total = web?.web_received;
      const ack = elapsed(trace, "cloud_accepted", "cloud_ack_received");
      const execution = elapsed(trace, "cloud_accepted", "terminal_persisted");
      // Conservative bounds: no Web/Cloud wall-clock subtraction. Exceeding a
      // bound is inconclusive for the actual leg, not evidence that it failed.
      ms.webToAdmission =
        Number.isFinite(roundTrip) && roundTrip >= 0 && ack !== null
          ? roundTrip + ack
          : null;
      ms.terminalToWeb =
        Number.isFinite(total) &&
        total >= 0 &&
        execution !== null &&
        total >= execution
          ? total - execution
          : null;
      for (const [metric, value] of Object.entries(ms))
        if (value !== null) values[metric].push(value);
    }
    const metrics = {};
    if (name === "burst") {
      const spans = bucket.traces
        .filter(
          (trace) =>
            trace.marks.service_accepted && trace.marks.terminal_persisted,
        )
        .map((trace) => [
          trace.marks.service_accepted.ts,
          trace.marks.terminal_persisted.ts,
        ]);
      const overlap = spans.some(([start, end], i) =>
        spans.some(
          ([otherStart, otherEnd], j) =>
            i !== j && Math.max(start, otherStart) < Math.min(end, otherEnd),
        ),
      );
      if (!overlap)
        invalid.push({
          reason: "burst capture has no overlapping admitted assignments",
        });
    }
    if (healthy) {
      for (const [metric, targetMs] of Object.entries(TARGETS)) {
        const stats = summarize(values[metric]);
        const upperBound = [
          "gatewayToService",
          "webToAdmission",
          "terminalToWeb",
        ].includes(metric);
        const enough =
          stats.count >= 10 &&
          stats.count === bucket.samples.length &&
          invalid.length === 0;
        const status = !enough
          ? "incomplete"
          : stats.p95 < targetMs
            ? "pass"
            : upperBound
              ? "incomplete"
              : "fail";
        if (status === "fail") failed = true;
        if (status === "incomplete") incomplete = true;
        metrics[metric] = { ...stats, targetMs, upperBound, status };
      }
    }
    results[name] = {
      sampleCount: bucket.samples.length,
      invalid,
      metrics,
      intervals: report(bucket.traces),
    };
  }
  return {
    schemaVersion: 1,
    commit: manifest.commit,
    cloudVersion: manifest.cloudVersion,
    serviceVersion: manifest.serviceVersion,
    status: failed ? "fail" : incomplete ? "incomplete" : "pass",
    cohorts: results,
    notes: [
      "Minimum 10 complete samples per healthy idle/burst cohort; small-sample percentiles are exploratory.",
      "Gateway delivery includes half the observed clock RTT as uncertainty.",
      "Web legs are conservative duration bounds; an over-target bound is inconclusive.",
      "Manifest readiness, cache and build labels must be retained with operator capture evidence.",
    ],
  };
}

export function acceptanceMarkdown(result) {
  const lines = [
    "# Execution latency acceptance",
    "",
    `Status: ${result.status}`,
    "",
    `Commit: ${result.commit}; Cloud: ${result.cloudVersion}; Service: ${result.serviceVersion}`,
    "",
    "| Cohort | Metric | n | p95 ms | Target ms | Evidence | Result |",
    "| --- | --- | ---: | ---: | ---: | --- | --- |",
  ];
  for (const [name, cohort] of Object.entries(result.cohorts)) {
    for (const [metric, stat] of Object.entries(cohort.metrics))
      lines.push(
        `| ${name} | ${metric} | ${stat.count} | ${stat.p95 ?? "missing"} | <${stat.targetMs} | ${stat.upperBound ? "upper bound" : "measured"} | ${stat.status} |`,
      );
  }
  for (const [name, cohort] of Object.entries(result.cohorts)) {
    if (cohort.invalid.length)
      lines.push(
        "",
        `${name}: ${cohort.invalid.length} capture validation issues.`,
        ...[...new Set(cohort.invalid.map((issue) => issue.reason))].map(
          (reason) => `- ${reason}`,
        ),
      );
    lines.push(
      "",
      `## ${name} intervals`,
      "",
      "| Interval | n | p50 ms | p95 ms | p99 ms | max ms |",
      "| --- | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const [interval, stats] of Object.entries(cohort.intervals.intervals))
      lines.push(
        `| ${interval} | ${stats.count} | ${stats.p50} | ${stats.p95} | ${stats.p99} | ${stats.max} |`,
      );
    lines.push(
      "",
      `Exploratory interval warnings: ${JSON.stringify(cohort.intervals.warnings)}`,
    );
  }
  lines.push("", ...result.notes.map((note) => `- ${note}`));
  return lines.join("\n");
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const args = { cloud: [], service: [], web: [] };
    for (let i = 2; i < process.argv.length; i += 2) {
      const flag = process.argv[i]?.replace(/^--/, "");
      const value = process.argv[i + 1];
      if (
        !["cloud", "service", "web", "manifest", "json"].includes(flag) ||
        !value
      )
        throw new Error(
          "Use --manifest capture.json --cloud cloud.log --service worker.jsonl [--web console.txt] [--json result.json]",
        );
      if (Array.isArray(args[flag])) args[flag].push(value);
      else args[flag] = value;
    }
    if (!args.manifest) throw new Error("--manifest is required");
    const result = assessLatency(
      [...args.cloud, ...args.service].flatMap((file) =>
        eventsFromText(readFileSync(file, "utf8")),
      ),
      args.web.flatMap((file) =>
        webRecordsFromText(readFileSync(file, "utf8")),
      ),
      JSON.parse(readFileSync(args.manifest, "utf8")),
    );
    if (args.json)
      writeFileSync(args.json, JSON.stringify(result, null, 2) + "\n");
    console.log(acceptanceMarkdown(result));
    process.exitCode =
      result.status === "pass" ? 0 : result.status === "fail" ? 1 : 2;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
  }
}
