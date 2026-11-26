import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  assessLatency,
  acceptanceMarkdown,
} from "./execution-latency-acceptance.mjs";
import { eventsFromText } from "./latency-baseline.mjs";

function capture() {
  const events = [],
    web = [],
    samples = [];
  for (const cohort of ["idle", "burst"])
    for (let i = 0; i < 10; i++) {
      const requestId = `${cohort}-${i}`;
      const offset = cohort === "idle" ? i * 2000 : 30000;
      samples.push({
        requestId,
        cohort,
        ready: true,
        cachedProfile: true,
        status: "completed",
        evidenceRef: "capture/session-1.json",
      });
      const point = (component, traceStage, ms, context = {}) =>
        events.push({
          stage: "trace",
          component,
          requestId,
          assignmentId: `asg-${requestId}`,
          workerId: `worker-${requestId}`,
          attemptId: `attempt-${requestId}`,
          timestamp: new Date(1791972000000 + offset + ms).toISOString(),
          context: {
            traceStage,
            transport: "websocket",
            ...(component === "service"
              ? {
                  clockOffsetMs: 0,
                  clockRttMs: 20,
                  monotonicMs: offset + ms,
                  traceEpochId: "process-1",
                  syncState: "ready",
                }
              : {}),
            ...context,
          },
        });
      point("cloud", "cloud_accepted", 0);
      point("cloud", "workflow_dispatch_started", 25);
      point("cloud", "gateway_queued", 50);
      point("service", "service_received", 100);
      point("service", "service_accepted", 150);
      point("cloud", "cloud_ack_received", 200);
      point("service", "profile_resolved", 175);
      point("service", "slot_reserved", 200);
      point("service", "engine_process_created", 250);
      point("service", "provider_started", 300);
      point("cloud", "terminal_persisted", 1000);
      web.push({
        requestId,
        terminalStatus: "completed",
        marksMs: { web_submit_response: 100, web_received: 1200 },
      });
    }
  return {
    events,
    web,
    manifest: {
      schemaVersion: 1,
      commit: "abcdef1",
      cloudVersion: "cloud-build",
      serviceVersion: "service-build",
      samples,
    },
  };
}

describe("execution latency release gate", () => {
  it("reports separate idle/burst intervals and conservative Web bounds", () => {
    const { events, web, manifest } = capture();
    const result = assessLatency(events, web, manifest);
    expect(result.status).toBe("pass");
    expect(result.cohorts.idle.metrics.gatewayToService.p95).toBe(60);
    expect(result.cohorts.burst.metrics.webToAdmission.p95).toBe(300);
    expect(result.cohorts.burst.metrics.terminalToWeb.p95).toBe(200);
    expect(acceptanceMarkdown(result)).toContain("upper bound");
    expect(acceptanceMarkdown(result)).toContain("## burst intervals");
  });
  it("does not certify empty captures or missing T11/Web events", () => {
    const { events, manifest } = capture();
    expect(assessLatency([], [], manifest).status).toBe("incomplete");
    const noTerminal = events.filter(
      (e) => e.context.traceStage !== "terminal_persisted",
    );
    expect(assessLatency(noTerminal, [], manifest).status).toBe("incomplete");
  });
  it("requires a complete sample count and rejects ambiguous retries", () => {
    const { events, web, manifest } = capture();
    manifest.samples.pop();
    expect(assessLatency(events, web, manifest).status).toBe("incomplete");
    events.push({ ...events[0], assignmentId: "other-attempt" });
    expect(
      assessLatency(events, web, manifest).cohorts.idle.invalid,
    ).toHaveLength(1);
  });
  it("does not blend fallback, cold, queued or failed samples into healthy targets", () => {
    const { events, web, manifest } = capture();
    for (const cohort of ["fallback", "cold", "queued", "failure"])
      manifest.samples.push({ requestId: cohort, cohort });
    const result = assessLatency(events, web, manifest);
    expect(result.status).toBe("incomplete");
    expect(result.cohorts.fallback.metrics).toEqual({});
    expect(result.cohorts.idle.metrics.serviceAdmission.count).toBe(10);
  });
  it("cannot certify missing clock uncertainty, negative intervals or HTTP delivery", () => {
    for (const change of [
      (e) => {
        delete e.context.clockRttMs;
      },
      (e) => {
        e.timestamp = "2026-01-01T00:00:00Z";
      },
      (_, events) => {
        events.find(
          (e) => e.context.traceStage === "gateway_queued",
        ).context.transport = "http_long_poll";
      },
    ]) {
      const { events, web, manifest } = capture();
      change(
        events.find((e) => e.context.traceStage === "service_received"),
        events,
      );
      expect(assessLatency(events, web, manifest).status).toBe("incomplete");
    }
  });
  it("fails measured over-target admission but marks over-target bounds inconclusive", () => {
    const { events, web, manifest } = capture();
    for (const e of events.filter(
      (e) =>
        e.component === "service" &&
        e.context.traceStage !== "service_received",
    )) {
      e.context.monotonicMs += 500;
      e.timestamp = new Date(Date.parse(e.timestamp) + 500).toISOString();
    }
    for (const event of events.filter(
      (event) => event.context.traceStage === "cloud_ack_received",
    ))
      event.timestamp = new Date(
        Date.parse(event.timestamp) + 500,
      ).toISOString();
    expect(assessLatency(events, web, manifest).status).toBe("fail");
    const other = capture();
    for (const record of other.web) record.marksMs.web_received += 2000;
    expect(assessLatency(other.events, other.web, other.manifest).status).toBe(
      "incomplete",
    );
  });
  it("ignores Cloud performance.now readings frozen across I/O", () => {
    const { events, web, manifest } = capture();
    for (const e of events.filter((e) => e.component === "cloud"))
      e.context.monotonicMs = 10;
    expect(
      assessLatency(events, web, manifest).cohorts.idle.metrics.terminalToWeb
        .p95,
    ).toBe(200);
  });
  it("requires unique request identity and pinned builds", () => {
    const { events, web, manifest } = capture();
    manifest.samples.push(manifest.samples[0]);
    expect(() => assessLatency(events, web, manifest)).toThrow(
      "unique requestId",
    );
    expect(() => assessLatency(events, web, {})).toThrow("commit");
  });
  it("rejects mismatched epochs, Workers, emitters and missing launch milestones", () => {
    for (const change of [
      (event) => {
        event.context.traceEpochId = "restarted-process";
      },
      (event) => {
        event.workerId = "replaced-runtime";
      },
      (event) => {
        event.component = "cloud";
      },
      (event) => {
        delete event.context.monotonicMs;
      },
      (_, events) => {
        events.splice(
          events.findIndex(
            (event) => event.context.traceStage === "provider_started",
          ),
          1,
        );
      },
    ]) {
      const { events, web, manifest } = capture();
      change(
        events.find((event) => event.context.traceStage === "service_accepted"),
        events,
      );
      expect(assessLatency(events, web, manifest).status).toBe("incomplete");
    }
  });
  it("cannot hide slow admission by changing clock corrections", () => {
    const { events, web, manifest } = capture();
    for (const event of events.filter(
      (event) =>
        event.component === "service" &&
        event.context.traceStage !== "service_received",
    )) {
      event.timestamp = new Date(
        Date.parse(event.timestamp) + 1000,
      ).toISOString();
      event.context.monotonicMs += 1000;
      event.context.clockOffsetMs = -1000;
    }
    for (const event of events.filter(
      (event) => event.context.traceStage === "cloud_ack_received",
    ))
      event.timestamp = new Date(
        Date.parse(event.timestamp) + 1000,
      ).toISOString();
    expect(assessLatency(events, web, manifest).status).toBe("fail");
  });
  it("uses monotonic time across Service component aliases", () => {
    const { events, web, manifest } = capture();
    for (const event of events.filter(
      (event) =>
        event.component === "service" &&
        event.context.traceStage !== "service_received",
    )) {
      event.context.monotonicMs += 1000;
      event.component = "workspace";
    }
    expect(assessLatency(events, web, manifest).status).toBe("fail");
  });
  it("rejects stale Cloud evidence, early ack and sequential samples labelled burst", () => {
    for (const change of [
      (events) => {
        events.find(
          (event) => event.context.traceStage === "terminal_persisted",
        ).attemptId = "stale";
      },
      (events) => {
        events.find(
          (event) => event.context.traceStage === "cloud_ack_received",
        ).workerId = "stale";
      },
      (events) => {
        const ack = events.find(
          (event) => event.context.traceStage === "cloud_ack_received",
        );
        ack.timestamp = events[0].timestamp;
      },
      (events) => {
        for (const event of events.filter((event) =>
          event.requestId.startsWith("burst"),
        ))
          event.timestamp = new Date(
            Date.parse(event.timestamp) +
              Number(event.requestId.split("-")[1]) * 60000,
          ).toISOString();
      },
    ]) {
      const { events, web, manifest } = capture();
      change(events);
      expect(assessLatency(events, web, manifest).status).toBe("incomplete");
    }
  });
  it("rejects fabricated exceptional-condition emitters and identities", () => {
    const { events, web, manifest } = capture();
    const sample = {
      requestId: "fallback",
      cohort: "fallback",
      status: "completed",
      evidenceRef: "capture",
    };
    manifest.samples.push(sample);
    for (const stage of [
      "gateway_queued",
      "service_received",
      "terminal_persisted",
    ])
      events.push({
        requestId: sample.requestId,
        component: "bogus",
        stage: "trace",
        timestamp: events[0].timestamp,
        context: { traceStage: stage },
      });
    expect(assessLatency(events, web, manifest).status).toBe("incomplete");
  });
  it("requires assignment identity even when a request ID can join the mark", () => {
    for (const stage of [
      "cloud_ack_received",
      "terminal_persisted",
      "provider_started",
    ]) {
      const { events, web, manifest } = capture();
      const mark = events.find((event) => event.context.traceStage === stage);
      delete mark.assignmentId;
      mark.attemptId = "stale";
      expect(assessLatency(events, web, manifest).status).toBe("incomplete");
    }
  });
  it("rejects a declared fallback whose terminal evidence predates delivery", () => {
    const { events, web, manifest } = capture();
    const sample = manifest.samples.find((sample) => sample.cohort === "idle");
    const requestId = "fallback-with-bad-time";
    manifest.samples.push({ ...sample, requestId, cohort: "fallback" });
    for (const original of events.filter(
      (event) => event.requestId === sample.requestId,
    )) {
      const event = {
        ...original,
        requestId,
        assignmentId: "fallback-assignment",
        context: { ...original.context, transport: "http_long_poll" },
      };
      if (event.context.traceStage === "terminal_persisted")
        event.timestamp = "2020-01-01T00:00:00Z";
      events.push(event);
    }
    expect(assessLatency(events, web, manifest).status).toBe("incomplete");
  });
  it("keeps the retained partial baseline incomplete", () => {
    const root = new URL(
      "./fixtures/latency/",
      import.meta.url,
    );
    const events = ["post-fix-cloud.jsonl", "post-fix-service.jsonl"].flatMap(
      (file) => eventsFromText(readFileSync(new URL(file, root), "utf8")),
    );
    const ids = [...new Set(events.map((e) => e.requestId).filter(Boolean))];
    const manifest = {
      schemaVersion: 1,
      commit: "17e611fd",
      cloudVersion: "7c677fa1",
      serviceVersion: "source",
      samples: ids.map((requestId, i) => ({
        requestId,
        cohort: i < 10 ? "idle" : "burst",
        status: "completed",
        ready: true,
        cachedProfile: true,
      })),
    };
    expect(assessLatency(events, [], manifest).status).toBe("incomplete");
  });
});
