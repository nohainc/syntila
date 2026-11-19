import { describe, expect, it } from "vitest";
import {
  buildTraces,
  eventsFromLine,
  eventsFromText,
  intervalsOf,
  percentile,
  report,
  webRecordsFromText,
} from "./latency-baseline.mjs";

const ev = (component, traceStage, timestamp, extra = {}, context = {}) => ({
  schemaVersion: 1,
  component,
  stage: "trace",
  timestamp,
  workspaceRuntimeId: "rt1",
  context: { traceStage, ...context },
  ...extra,
});

describe("latency baseline", () => {
  it("reports provider and result delivery stages in order", () => {
    const events = [
      ev("service", "provider_started", "2026-10-14T10:00:00.000Z", { requestId: "r1", assignmentId: "a1" }, { clockOffsetMs: 0 }),
      ev("service", "provider_first_output", "2026-10-14T10:00:01.000Z", { assignmentId: "a1" }, { clockOffsetMs: 0 }),
      ev("service", "provider_process_exited", "2026-10-14T10:00:03.000Z", { assignmentId: "a1" }, { clockOffsetMs: 0 }),
      ev("service", "service_result_persisted", "2026-10-14T10:00:03.050Z", { assignmentId: "a1" }, { clockOffsetMs: 0 }),
      ev("cloud", "terminal_persisted", "2026-10-14T10:00:03.080Z", { assignmentId: "a1" }),
      ev("cloud", "workflow_completed", "2026-10-14T10:00:03.100Z", { requestId: "r1" }),
    ];
    const intervals = intervalsOf(buildTraces(events)[0]);
    expect(intervals.map((v) => [v.name, v.ms])).toEqual([
      ["provider_started->provider_first_output", 1000],
      ["provider_first_output->provider_process_exited", 2000],
      ["provider_process_exited->service_result_persisted", 50],
      ["service_result_persisted->terminal_persisted", 30],
      ["terminal_persisted->workflow_completed", 20],
    ]);
  });
  it("parses plain, wrapped and wrangler-tail lines", () => {
    const e = ev("cloud", "cloud_accepted", "2026-10-14T10:00:00.000Z", {
      requestId: "r1",
    });
    expect(eventsFromLine(JSON.stringify(e))).toHaveLength(1);
    expect(
      eventsFromLine(
        JSON.stringify({
          logs: [
            {
              message: [
                JSON.stringify({
                  message: "diagnostic.event",
                  details: { event: e },
                }),
              ],
            },
          ],
        }),
      ),
    ).toHaveLength(1);
    expect(
      eventsFromLine(
        JSON.stringify({ logs: [{ message: [JSON.stringify(e)] }] }),
      ),
    ).toHaveLength(1);
    expect(eventsFromLine("not json")).toEqual([]);
    expect(eventsFromLine(JSON.stringify({ stage: "other" }))).toEqual([]);
  });

  it("reads real structured Cloud logs inside pretty-printed tail output", () => {
    const e = ev("cloud", "cloud_accepted", "2026-10-14T10:00:00.000Z", {
      requestId: "r1",
    });
    const wrapped = {
      logs: [
        {
          message: [
            JSON.stringify({
              message: "diagnostic.event",
              details: { event: e },
            }),
          ],
        },
      ],
    };
    const text = `Wrangler connected\n${JSON.stringify(wrapped, null, 2)}\n${JSON.stringify(e)}\n`;
    expect(eventsFromText(text)).toEqual([e, e]);
  });

  it("applies the clock offset to Service events and attributes the delay", () => {
    // Service clock is 5 s behind Cloud: offset +5000.
    const events = [
      ev("cloud", "cloud_accepted", "2026-10-14T10:00:00.000Z", {
        requestId: "r1",
      }),
      ev("cloud", "gateway_queued", "2026-10-14T10:00:02.000Z", {
        requestId: "r1",
        assignmentId: "a1",
      }),
      ev(
        "service",
        "service_received",
        "2026-10-14T09:59:57.100Z",
        { requestId: "r1", assignmentId: "a1" },
        { clockOffsetMs: 5000 },
      ),
      ev(
        "service",
        "service_accepted",
        "2026-10-14T09:59:57.150Z",
        { assignmentId: "a1" },
        { clockOffsetMs: 5000 },
      ),
      ev("service", "engine_process_created", "2026-10-14T10:00:07.150Z", {
        assignmentId: "a1",
      }),
    ];
    const [trace] = buildTraces(events);
    expect(trace.uncorrected).toBe(false);
    const names = Object.fromEntries(
      intervalsOf(trace).map((i) => [i.name, i.ms]),
    );
    expect(names["gateway_queued->service_received"]).toBe(100);
    expect(names["service_received->service_accepted"]).toBe(50);
    const result = report([trace]);
    expect(Object.keys(result.dominantPhase)).toEqual(["queueing / slot"]);
  });

  it("joins Web records and flags missing offsets", () => {
    const web = webRecordsFromText(
      '[syntila.latency] {"requestId":"r1","submittedAt":"x","terminalStatus":"completed","marksMs":{"web_submitted":0,"web_submit_response":120,"web_received":9000}}',
    );
    const events = [
      ev("cloud", "cloud_accepted", "2026-10-14T10:00:00.000Z", {
        requestId: "r1",
      }),
      ev("cloud", "terminal_persisted", "2026-10-14T10:00:08.000Z", {
        requestId: "r1",
      }),
      ev("service", "service_received", "2026-10-14T10:00:01.000Z", {
        requestId: "r1",
      }),
    ];
    const [trace] = buildTraces(events, web);
    expect(trace.uncorrected).toBe(true);
    const names = Object.fromEntries(
      intervalsOf(trace).map((i) => [i.name, i.ms]),
    );
    expect(names["web:total_submit_to_final"]).toBe(9000);
    expect(names["web:residual_terminal_to_web (approx)"]).toBe(
      9000 - 120 - 8000,
    );
  });

  it("computes nearest-rank percentiles", () => {
    const values = Array.from({ length: 100 }, (_, i) => i + 1);
    expect(percentile(values, 50)).toBe(50);
    expect(percentile(values, 95)).toBe(95);
    expect(percentile(values, 99)).toBe(99);
    expect(percentile([], 50)).toBeNull();
  });
});
