import { describe, expect, it } from "./helpers/vitest-compat";
import {
  applyServiceReadiness,
  authenticatedReadiness,
  disconnectedReadiness,
  effectiveReadiness,
  inferLegacyReadiness,
  inventoryReceivedReadiness,
  syncAnsweredReadiness,
  synchronizingReadiness,
} from "../../src/domain/service-readiness.js";

const identity = { sessionId: "S1", workspaceRuntimeId: "RT" };
const t = (n: number) => `2026-10-14T10:00:${String(n).padStart(2, "0")}.000Z`;
const fresh = () => authenticatedReadiness({ ...identity, now: t(0) });
const synced = () =>
  syncAnsweredReadiness(synchronizingReadiness(fresh(), t(1)), t(2));
const ready = {
  state: "ready",
  readyForAssignments: true,
  syncGeneration: 1,
} as const;

describe("Service readiness", () => {
  it("starts authenticated and not ready", () => {
    expect(fresh()).toMatchObject({
      state: "authenticated",
      readyForAssignments: false,
      syncGeneration: 0,
    });
  });

  it("accepts a ready report only after Cloud answered the sync request", () => {
    expect(applyServiceReadiness(fresh(), ready, identity, t(3)).outcome).toBe(
      "ignored_unsynchronized",
    );
    const decision = applyServiceReadiness(synced(), ready, identity, t(3));
    expect(decision).toMatchObject({
      outcome: "applied",
      readiness: {
        state: "ready",
        readyForAssignments: true,
        source: "service",
      },
    });
  });

  it("ignores reports from another session, runtime or an older generation", () => {
    const current = applyServiceReadiness(synced(), ready, identity, t(3));
    if (current.outcome !== "applied") throw new Error("expected applied");
    expect(
      applyServiceReadiness(
        current.readiness,
        ready,
        { sessionId: "S0", workspaceRuntimeId: "RT" },
        t(4),
      ).outcome,
    ).toBe("ignored_identity");
    expect(
      applyServiceReadiness(
        current.readiness,
        ready,
        { sessionId: "S1", workspaceRuntimeId: "OTHER" },
        t(4),
      ).outcome,
    ).toBe("ignored_identity");
    expect(
      applyServiceReadiness(
        current.readiness,
        { state: "paused", readyForAssignments: false, syncGeneration: 0 },
        identity,
        t(4),
      ).outcome,
    ).toBe("ignored_stale");
    expect(applyServiceReadiness(null, ready, identity, t(4)).outcome).toBe(
      "ignored_identity",
    );
  });

  it("never reports ready for a non-ready state, and reports unchanged repeats", () => {
    const paused = applyServiceReadiness(
      synced(),
      { state: "paused", readyForAssignments: true, syncGeneration: 1 },
      identity,
      t(3),
    );
    expect(paused).toMatchObject({
      outcome: "applied",
      readiness: { state: "paused", readyForAssignments: false },
    });
    if (paused.outcome !== "applied") throw new Error("expected applied");
    expect(
      applyServiceReadiness(
        paused.readiness,
        { state: "paused", readyForAssignments: false, syncGeneration: 1 },
        identity,
        t(4),
      ).outcome,
    ).toBe("unchanged");
  });

  it("infers readiness for a Service that publishes none", () => {
    const afterSync = synced();
    expect(inferLegacyReadiness(afterSync, t(3)).readyForAssignments).toBe(
      false,
    );
    const inferred = inferLegacyReadiness(
      inventoryReceivedReadiness(afterSync, t(3)),
      t(4),
    );
    expect(inferred).toMatchObject({
      state: "ready",
      readyForAssignments: true,
      source: "inferred",
    });
  });

  it("keeps inventory delivered before the sync request is handled", () => {
    const early = inventoryReceivedReadiness(fresh(), t(1));
    const resynced = synchronizingReadiness(early, t(2));
    expect(resynced.inventoryReceived).toBe(true);
    expect(resynced.syncAnswered).toBe(false);
  });

  it("is never ready when disconnected or when the connection is not live", () => {
    const current = applyServiceReadiness(synced(), ready, identity, t(3));
    if (current.outcome !== "applied") throw new Error("expected applied");
    expect(effectiveReadiness(current.readiness, true).ready).toBe(true);
    expect(effectiveReadiness(current.readiness, false)).toEqual({
      state: "disconnected",
      ready: false,
    });
    const gone = disconnectedReadiness(current.readiness, t(5));
    expect(gone).toMatchObject({
      state: "disconnected",
      readyForAssignments: false,
      syncAnswered: false,
    });
    expect(effectiveReadiness(null, true).ready).toBe(false);
  });
});
