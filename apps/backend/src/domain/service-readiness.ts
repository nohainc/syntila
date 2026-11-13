import { type ServiceConnectionState } from "@syntila/workspace-runtime-protocol";

/**
 * Service-level readiness for one authenticated runtime session.
 *
 * Connection liveness ("the Service answered a heartbeat recently") is a
 * different fact from readiness ("the Service finished synchronizing and will
 * handle an `assignment.start` immediately"). Worker eligibility is a third,
 * separate fact (inventory). Scheduling and dispatch use readiness; nothing
 * here looks at Workers.
 */
export interface ServiceReadiness {
  readonly state: ServiceConnectionState;
  readonly readyForAssignments: boolean;
  /** The authenticated runtime identity the state belongs to. */
  readonly workspaceRuntimeId: string;
  /** The session the state belongs to; a replaced session never matches. */
  readonly sessionId: string;
  /** Increases each time the Service completes a synchronization. */
  readonly syncGeneration: number;
  /** Whether Cloud has answered this session's `workspace.sync.request`. */
  readonly syncAnswered: boolean;
  /** Whether this session has delivered a Worker inventory snapshot. */
  readonly inventoryReceived: boolean;
  /**
   * `service`: published by the Service. `inferred`: derived for a Service
   * that does not publish readiness. `cloud`: Cloud-originated transition
   * (new session, disconnect).
   */
  readonly source: "service" | "inferred" | "cloud";
  readonly reason?: string;
  readonly updatedAt: string;
}

export interface ServiceReadinessReport {
  readonly state: ServiceConnectionState;
  readonly readyForAssignments: boolean;
  readonly syncGeneration: number;
  readonly reason?: string;
}

export type ReadinessDecision =
  | { readonly outcome: "applied"; readonly readiness: ServiceReadiness }
  | { readonly outcome: "unchanged"; readonly readiness: ServiceReadiness }
  /** From a replaced session or another runtime identity. */
  | { readonly outcome: "ignored_identity" }
  /** From before the latest synchronization. */
  | { readonly outcome: "ignored_stale" }
  /** Claimed ready before Cloud had answered the Service's sync request. */
  | { readonly outcome: "ignored_unsynchronized" };

/** A freshly authenticated session: connected, nothing synchronized yet. */
export function authenticatedReadiness(input: {
  readonly sessionId: string;
  readonly workspaceRuntimeId: string;
  /** Carried over so the generation never moves backwards across sessions. */
  readonly previousGeneration?: number;
  readonly now: string;
}): ServiceReadiness {
  return {
    state: "authenticated",
    readyForAssignments: false,
    workspaceRuntimeId: input.workspaceRuntimeId,
    sessionId: input.sessionId,
    syncGeneration: input.previousGeneration ?? 0,
    syncAnswered: false,
    inventoryReceived: false,
    source: "cloud",
    updatedAt: input.now,
  };
}

/** The session ended: never ready, whatever it published before. */
export function disconnectedReadiness(
  current: ServiceReadiness,
  now: string,
  reason = "connection_closed",
): ServiceReadiness {
  return {
    ...current,
    state: "disconnected",
    readyForAssignments: false,
    syncAnswered: false,
    inventoryReceived: false,
    source: "cloud",
    reason,
    updatedAt: now,
  };
}

/** The Service asked Cloud to synchronize: not ready until it finishes. */
export function synchronizingReadiness(
  current: ServiceReadiness,
  now: string,
): ServiceReadiness {
  return {
    ...current,
    state: "synchronizing",
    readyForAssignments: false,
    syncAnswered: false,
    // Inventory is session-level data and may legitimately arrive before the
    // sync request is handled; a new sync must not forget it.
    inventoryReceived: current.inventoryReceived,
    source: "cloud",
    reason: "sync_requested",
    updatedAt: now,
  };
}

/** Cloud sent `workspace.sync.result`; a ready claim is now credible. */
export function syncAnsweredReadiness(
  current: ServiceReadiness,
  now: string,
): ServiceReadiness {
  return { ...current, syncAnswered: true, updatedAt: now };
}

export function inventoryReceivedReadiness(
  current: ServiceReadiness,
  now: string,
): ServiceReadiness {
  return { ...current, inventoryReceived: true, updatedAt: now };
}

/**
 * Applies a readiness report from the Service. A report is trusted only for
 * the session and runtime identity it was received on, never moves the sync
 * generation backwards, and cannot claim `ready` before Cloud answered the
 * session's sync request.
 */
export function applyServiceReadiness(
  current: ServiceReadiness | null,
  report: ServiceReadinessReport,
  identity: { readonly sessionId: string; readonly workspaceRuntimeId: string },
  now: string,
): ReadinessDecision {
  if (
    !current ||
    current.sessionId !== identity.sessionId ||
    current.workspaceRuntimeId !== identity.workspaceRuntimeId
  ) {
    return { outcome: "ignored_identity" };
  }
  if (report.syncGeneration < current.syncGeneration) {
    return { outcome: "ignored_stale" };
  }
  if (report.readyForAssignments && !current.syncAnswered) {
    return { outcome: "ignored_unsynchronized" };
  }
  const readyForAssignments =
    report.readyForAssignments && report.state === "ready";
  if (
    current.source === "service" &&
    current.state === report.state &&
    current.readyForAssignments === readyForAssignments &&
    current.syncGeneration === report.syncGeneration
  ) {
    return { outcome: "unchanged", readiness: current };
  }
  return {
    outcome: "applied",
    readiness: {
      ...current,
      state: report.state,
      readyForAssignments,
      syncGeneration: report.syncGeneration,
      source: "service",
      ...(report.reason ? { reason: report.reason } : {}),
      updatedAt: now,
    },
  };
}

/**
 * For a Service that does not publish readiness: it is ready once Cloud has
 * answered its sync request and it has delivered its Worker inventory, which
 * is the point where the Service starts handling assignments immediately.
 */
export function inferLegacyReadiness(
  current: ServiceReadiness,
  now: string,
): ServiceReadiness {
  if (
    current.readyForAssignments ||
    current.source === "service" ||
    !current.syncAnswered ||
    !current.inventoryReceived
  ) {
    return current;
  }
  return {
    ...current,
    state: "ready",
    readyForAssignments: true,
    syncGeneration: current.syncGeneration + 1,
    source: "inferred",
    reason: "sync_and_inventory_complete",
    updatedAt: now,
  };
}

/**
 * Readiness as a scheduler sees it: a ready state counts only while the
 * connection is also live, so a silently dead socket cannot look ready.
 */
export function effectiveReadiness(
  readiness: ServiceReadiness | null,
  live: boolean,
): { readonly state: ServiceConnectionState; readonly ready: boolean } {
  if (!readiness || !live) return { state: "disconnected", ready: false };
  return { state: readiness.state, ready: readiness.readyForAssignments };
}
