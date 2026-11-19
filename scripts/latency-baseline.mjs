#!/usr/bin/env node
// Joins Latency Trace v1 events (Cloud logs, Service worker.jsonl, Web console
// lines) by request/assignment/run ID and reports per-interval p50/p95/p99.
// See docs/specifications/LATENCY_TRACE_V1.md.
//
// Usage:
//   node scripts/latency-baseline.mjs --cloud cloud.log --service worker.jsonl \
//     [--service worker.jsonl.1] [--web console.txt] [--json out.json]

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const STAGES = [
  "web_submitted",
  "cloud_accepted",
  "workflow_dispatch_started",
  "gateway_queued",
  "service_received",
  "service_accepted",
  "profile_resolved",
  "slot_reserved",
  "engine_process_created",
  "provider_started",
  "provider_first_output",
  "provider_last_output_reported",
  "provider_process_exited",
  "engine_result_received",
  "service_result_persisted",
  "service_result_sending",
  "terminal_persisted",
  "workflow_observed_terminal",
  "workflow_completed",
  "web_received",
];

// Where an interval is attributed when it is the largest in a trace.
const TO_PHASE = {
  workflow_dispatch_started: "before delivery",
  gateway_queued: "before delivery",
  service_received: "transport to Service",
  service_accepted: "Service admission",
  profile_resolved: "queueing / profile",
  slot_reserved: "queueing / slot",
  engine_process_created: "queueing / slot",
  provider_started: "after Engine launch",
  provider_first_output: "provider execution",
  provider_last_output_reported: "provider execution",
  provider_process_exited: "provider execution",
  engine_result_received: "result handling",
  service_result_persisted: "result handling",
  service_result_sending: "result handling",
  terminal_persisted: "result delivery",
  workflow_observed_terminal: "result delivery",
  workflow_completed: "result delivery",
  web_received: "result delivery to Web",
};

// Intervals skip stages that were not observed, so unlisted pairs fall back to
// the phase of their end stage.
const PHASE = {
  "cloud_accepted->workflow_dispatch_started": "before delivery",
  "workflow_dispatch_started->gateway_queued": "before delivery",
  "gateway_queued->service_received": "transport to Service",
  "service_received->service_accepted": "Service admission",
  "service_accepted->profile_resolved": "queueing / profile",
  "profile_resolved->slot_reserved": "queueing / slot",
  "slot_reserved->engine_process_created": "queueing / slot",
  "engine_process_created->provider_started": "after Engine launch",
  "provider_started->terminal_persisted": "after Engine launch",
  "terminal_persisted->web_received": "result delivery to Web",
};

/** Extract diagnostic-event objects from one text line in any supported shape. */
export function eventsFromLine(line) {
  const text = line.trim();
  if (!text) return [];
  const out = [];
  const visit = (value, depth = 0) => {
    if (depth > 16 || value == null) return;
    if (typeof value === "string") {
      const start = value.indexOf("{");
      if (start < 0) return;
      try {
        visit(JSON.parse(value.slice(start)), depth + 1);
      } catch {
        /* not JSON */
      }
      return;
    }
    if (Array.isArray(value)) return value.forEach((v) => visit(v, depth + 1));
    if (typeof value !== "object") return;
    if (value.stage === "trace" && value.context?.traceStage) {
      out.push(value);
      return;
    }
    for (const key of ["logs", "message", "event", "data", "details"]) {
      if (key in value) visit(value[key], depth + 1);
    }
  };
  visit(text);
  return out;
}

/** Read JSONL and concatenated pretty-printed Wrangler JSON objects. */
export function eventsFromText(content) {
  const events = [];
  let start = -1;
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let i = 0; i < content.length; i++) {
    const c = content[i];
    if (start < 0) {
      if (c !== "{") continue;
      start = i;
      depth = 1;
      continue;
    }
    if (quoted) {
      if (escaped) escaped = false;
      else if (c === "\\") escaped = true;
      else if (c === '"') quoted = false;
    } else if (c === '"') quoted = true;
    else if (c === "{") depth++;
    else if (c === "}" && --depth === 0) {
      events.push(...eventsFromLine(content.slice(start, i + 1)));
      start = -1;
    }
  }
  return events;
}

export function webRecordsFromText(content) {
  const records = [];
  for (const line of content.split(/\r?\n/)) {
    const at = line.indexOf("[syntila.latency]");
    if (at < 0) continue;
    try {
      records.push(JSON.parse(line.slice(line.indexOf("{", at))));
    } catch {
      /* skip */
    }
  }
  return records;
}

class UnionFind {
  parent = new Map();
  find(x) {
    if (!this.parent.has(x)) this.parent.set(x, x);
    let root = x;
    while (this.parent.get(root) !== root) root = this.parent.get(root);
    this.parent.set(x, root);
    return root;
  }
  union(a, b) {
    this.parent.set(this.find(a), this.find(b));
  }
}

export function percentile(sorted, p) {
  if (sorted.length === 0) return null;
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[Math.min(rank, sorted.length) - 1];
}

export function summarize(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50: percentile(sorted, 50),
    p95: percentile(sorted, 95),
    p99: percentile(sorted, 99),
    max: sorted.length ? sorted[sorted.length - 1] : null,
  };
}

/**
 * Builds one trace per Work request. Service timestamps are shifted onto the
 * Cloud clock with the event's own `clockOffsetMs` (Cloud minus Service); the
 * latest known offset per workspaceRuntimeId is the fallback. Traces that needed
 * an uncorrected Service timestamp are flagged `uncorrected`.
 */
export function buildTraces(events, webRecords = []) {
  const uf = new UnionFind();
  const key = (kind, id) => `${kind}:${id}`;
  for (const e of events) {
    const ids = [
      e.requestId && key("req", e.requestId),
      e.assignmentId && key("asg", e.assignmentId),
      e.runId && e.taskId === undefined && key("run", e.runId),
    ].filter(Boolean);
    ids.forEach((id) => uf.find(id));
    for (let i = 1; i < ids.length; i++) uf.union(ids[0], ids[i]);
  }

  const lastOffset = new Map();
  const ordered = [...events].sort((a, b) =>
    String(a.timestamp).localeCompare(String(b.timestamp)),
  );
  const groups = new Map();
  for (const e of ordered) {
    const ids = [
      e.requestId && key("req", e.requestId),
      e.assignmentId && key("asg", e.assignmentId),
    ].filter(Boolean);
    if (ids.length === 0) continue;
    const root = uf.find(ids[0]);
    if (!groups.has(root)) {
      groups.set(root, {
        requestId: null,
        assignmentIds: new Set(),
        marks: {},
        uncorrected: false,
      });
    }
    const g = groups.get(root);
    if (e.requestId) g.requestId = e.requestId;
    if (e.assignmentId) g.assignmentIds.add(e.assignmentId);
    const stage = e.context.traceStage;
    const runtime = e.workspaceRuntimeId ?? "";
    const isService = ["service", "workspace", "workspace_service"].includes(
      e.component,
    );
    let ts = Date.parse(e.timestamp);
    if (!Number.isFinite(ts)) continue;
    if (isService) {
      const offset = e.context.clockOffsetMs ?? lastOffset.get(runtime);
      if (e.context.clockOffsetMs !== undefined)
        lastOffset.set(runtime, e.context.clockOffsetMs);
      if (offset === undefined) g.uncorrected = true;
      else ts += offset;
    }
    if (!(stage in g.marks)) g.marks[stage] = { ts, event: e };
  }

  const webById = new Map(
    webRecords.filter((r) => r.requestId).map((r) => [r.requestId, r]),
  );
  const traces = [];
  for (const g of groups.values()) {
    const web = g.requestId ? webById.get(g.requestId) : undefined;
    traces.push({ ...g, assignmentIds: [...g.assignmentIds], web });
  }
  return traces;
}

export function intervalsOf(trace) {
  const present = STAGES.filter((s) => trace.marks[s]);
  const intervals = [];
  for (let i = 1; i < present.length; i++) {
    const from = present[i - 1];
    const to = present[i];
    intervals.push({
      name: `${from}->${to}`,
      ms: Math.max(0, trace.marks[to].ts - trace.marks[from].ts),
      skewed: trace.marks[to].ts < trace.marks[from].ts,
    });
  }
  const web = trace.web?.marksMs;
  if (web) {
    if (web.web_submit_response !== undefined) {
      intervals.push({
        name: "web:submit_round_trip",
        ms: web.web_submit_response,
      });
    }
    if (web.web_received !== undefined) {
      intervals.push({
        name: "web:total_submit_to_final",
        ms: web.web_received,
      });
    }
    const cloud = trace.marks;
    if (
      web.web_received !== undefined &&
      cloud.cloud_accepted &&
      cloud.terminal_persisted
    ) {
      // Approximation: includes the response return leg that overlaps T2->T3.
      intervals.push({
        name: "web:residual_terminal_to_web (approx)",
        ms: Math.max(
          0,
          web.web_received -
            web.web_submit_response -
            (cloud.terminal_persisted.ts - cloud.cloud_accepted.ts),
        ),
      });
    }
  }
  return intervals;
}

export function report(traces) {
  const byName = new Map();
  const dominant = new Map();
  let skewed = 0;
  let uncorrected = 0;
  for (const trace of traces) {
    if (trace.uncorrected) uncorrected++;
    const intervals = intervalsOf(trace);
    for (const { name, ms, skewed: s } of intervals) {
      if (!byName.has(name)) byName.set(name, []);
      byName.get(name).push(ms);
      if (s) skewed++;
    }
    const cloudSide = intervals.filter((i) => !i.name.startsWith("web:"));
    if (cloudSide.length) {
      const top = cloudSide.reduce((a, b) => (b.ms > a.ms ? b : a));
      const phase =
        PHASE[top.name] ?? TO_PHASE[top.name.split("->")[1]] ?? "other";
      dominant.set(phase, (dominant.get(phase) ?? 0) + 1);
    }
  }
  const stages = new Map(STAGES.map((s) => [s, 0]));
  for (const t of traces)
    for (const s of STAGES) if (t.marks[s]) stages.set(s, stages.get(s) + 1);
  return {
    traceCount: traces.length,
    stageCoverage: Object.fromEntries(stages),
    intervals: Object.fromEntries(
      [...byName].map(([k, v]) => [k, summarize(v)]),
    ),
    dominantPhase: Object.fromEntries(dominant),
    warnings: {
      negativeIntervalsClamped: skewed,
      tracesWithUncorrectedServiceClock: uncorrected,
    },
  };
}

export function toMarkdown(result) {
  const lines = [`# Latency baseline`, "", `Traces: ${result.traceCount}`, ""];
  lines.push(
    "| Interval | n | p50 ms | p95 ms | p99 ms | max ms |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const [name, s] of Object.entries(result.intervals)) {
    lines.push(
      `| ${name} | ${s.count} | ${s.p50} | ${s.p95} | ${s.p99} | ${s.max} |`,
    );
  }
  lines.push("", "Largest Cloud/Service interval per trace, by phase:", "");
  for (const [phase, n] of Object.entries(result.dominantPhase))
    lines.push(`- ${phase}: ${n}`);
  lines.push("", `Warnings: ${JSON.stringify(result.warnings)}`);
  return lines.join("\n");
}

function parseArgs(argv) {
  const args = { cloud: [], service: [], web: [], json: null };
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const value = argv[i + 1];
    if (!value || !["--cloud", "--service", "--web", "--json"].includes(flag)) {
      throw new Error(`Unknown or incomplete argument: ${flag}`);
    }
    if (flag === "--json") args.json = value;
    else args[flag.slice(2)].push(value);
  }
  return args;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = parseArgs(process.argv.slice(2));
  const events = [...args.cloud, ...args.service].flatMap((file) =>
    eventsFromText(readFileSync(file, "utf8")),
  );
  const web = args.web.flatMap((file) =>
    webRecordsFromText(readFileSync(file, "utf8")),
  );
  const result = report(buildTraces(events, web));
  if (args.json) writeFileSync(args.json, JSON.stringify(result, null, 2));
  console.log(toMarkdown(result));
}
