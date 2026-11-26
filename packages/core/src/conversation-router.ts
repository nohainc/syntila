import type {
  Conversation,
  TurnExecutionConfig,
  WorkerSession,
  WorkflowDefinition,
} from "./conversation.js";
import {
  validateWorkerExecutionSelection,
  type WorkerExecutionOptions,
} from "./worker-execution-options.js";

export type ConversationRouteAction =
  | "CONTINUE_SESSION"
  | "SYNC_AND_CONTINUE"
  | "BOOTSTRAP_SESSION"
  | "RECONSTRUCT_SESSION"
  | "STATELESS_EXECUTION";

/** Local runtime receives these session facts from its verified Profile. */
export interface ConversationSessionCapabilities {
  readonly durableSessions: boolean;
  readonly incrementalContextSync: boolean;
  /** Explicitly compatible releases, including the selected release. */
  readonly compatibleProfileVersions: readonly number[];
}

/** Native handles stay on the Worker computer; the router needs only logical metadata. */
export type RoutableWorkerSession = Omit<WorkerSession, "nativeSessionId"> & {
  readonly nativeSessionAvailable: boolean;
};

export interface ConversationRouteRequest {
  readonly conversation: Conversation;
  readonly workflow: WorkflowDefinition;
  readonly turn: TurnExecutionConfig;
  readonly executionOptions: WorkerExecutionOptions;
  readonly sessionCapabilities: ConversationSessionCapabilities;
  readonly sessions: readonly RoutableWorkerSession[];
  /** Frozen canonical context revision for this turn. */
  readonly contextRevision: number;
  readonly sessionPolicy: "durable" | "stateless";
}

export interface ConversationRoutePlan {
  readonly schemaVersion: 1;
  readonly action: ConversationRouteAction;
  readonly modelAction:
    "UNCHANGED_MODEL" | "KEEP_SESSION_WITH_NEW_MODEL" | "NEW_SESSION_FOR_MODEL";
  readonly workerSessionId: string | null;
  readonly context: {
    readonly transfer: "none" | "delta" | "full";
    readonly fromRevision: number;
    readonly toRevision: number;
  };
}

/** Pure planning only. Never marks context synchronized or mutates sessions. */
export function routeConversation(
  request: ConversationRouteRequest,
): ConversationRoutePlan {
  const {
    conversation,
    workflow,
    turn,
    executionOptions,
    sessionCapabilities,
    contextRevision,
  } = request;
  if (
    conversation.workflowId !== workflow.id ||
    conversation.workflowVersion !== workflow.version ||
    turn.workflowId !== workflow.execution.workflowId ||
    turn.workflowVersion !== workflow.execution.workflowVersion
  ) {
    throw new Error(
      "Conversation, Workflow, and turn execution identities do not match",
    );
  }
  if (
    !Number.isSafeInteger(contextRevision) ||
    contextRevision < 0 ||
    contextRevision > conversation.contextRevision ||
    !Number.isSafeInteger(turn.profileReleaseVersion) ||
    turn.profileReleaseVersion < 1 ||
    !turn.workerId ||
    !turn.profileId ||
    turn.schemaVersion !== 1 ||
    !Number.isSafeInteger(conversation.contextRevision) ||
    conversation.contextRevision < 0 ||
    !sessionCapabilities.compatibleProfileVersions.includes(
      turn.profileReleaseVersion,
    )
  ) {
    throw new Error("Invalid turn scope or context revision");
  }
  const invalidSelection = validateWorkerExecutionSelection(
    executionOptions,
    turn.modelId,
    turn.effort,
  );
  if (invalidSelection) throw new Error(invalidSelection);
  const plan = (
    action: ConversationRouteAction,
    modelAction: ConversationRoutePlan["modelAction"],
    session: RoutableWorkerSession | null,
    transfer: ConversationRoutePlan["context"]["transfer"],
    fromRevision = 0,
  ): ConversationRoutePlan => ({
    schemaVersion: 1,
    action,
    modelAction,
    workerSessionId: session?.id ?? null,
    context: { transfer, fromRevision, toRevision: contextRevision },
  });
  if (
    request.sessionPolicy === "stateless" ||
    !sessionCapabilities.durableSessions
  ) {
    return plan(
      "STATELESS_EXECUTION",
      "UNCHANGED_MODEL",
      null,
      contextRevision > 0 ? "full" : "none",
    );
  }
  const scoped = request.sessions.filter(
    (session) =>
      session.conversationId === conversation.id &&
      session.workerId === turn.workerId &&
      session.profileId === turn.profileId,
  );
  for (const session of scoped) {
    if (
      !Number.isSafeInteger(session.synchronizedContextRevision) ||
      session.synchronizedContextRevision < 0 ||
      session.synchronizedContextRevision > conversation.contextRevision ||
      !Number.isFinite(Date.parse(session.lastUsedAt)) ||
      !Number.isSafeInteger(session.profileVersion) ||
      session.profileVersion < 1 ||
      !["active", "requires_synchronization"].includes(session.status)
    ) {
      throw new Error("Invalid Worker Session routing metadata");
    }
  }
  // Never resume a session ahead of the frozen turn: it contains future context.
  const candidates = scoped.filter(
    (session) => session.synchronizedContextRevision <= contextRevision,
  );
  const compatible = candidates.filter((session) =>
    sessionCapabilities.compatibleProfileVersions.includes(
      session.profileVersion,
    ),
  );
  const newest = (sessions: readonly RoutableWorkerSession[]) =>
    [...sessions].sort(
      (a, b) =>
        Date.parse(b.lastUsedAt) - Date.parse(a.lastUsedAt) ||
        a.id.localeCompare(b.id),
    )[0] ?? null;
  const session = newest(compatible) ?? newest(candidates);
  if (!session) {
    return plan(
      scoped.length ? "RECONSTRUCT_SESSION" : "BOOTSTRAP_SESSION",
      "UNCHANGED_MODEL",
      null,
      contextRevision > 0 ? "full" : "none",
    );
  }
  const modelChanged = session.lastModelId !== turn.modelId;
  const modelAction = modelChanged
    ? executionOptions.modelSwitch.supported
      ? "KEEP_SESSION_WITH_NEW_MODEL"
      : "NEW_SESSION_FOR_MODEL"
    : "UNCHANGED_MODEL";
  if (
    modelAction === "NEW_SESSION_FOR_MODEL" ||
    !session.nativeSessionAvailable ||
    !sessionCapabilities.compatibleProfileVersions.includes(
      session.profileVersion,
    )
  ) {
    return plan(
      "RECONSTRUCT_SESSION",
      modelAction,
      session,
      // Even revision zero can have canonical message history before context
      // materialization exists. A model replacement always needs a snapshot.
      modelAction === "NEW_SESSION_FOR_MODEL" || contextRevision > 0
        ? "full"
        : "none",
    );
  }
  if (
    session.synchronizedContextRevision < contextRevision ||
    session.status === "requires_synchronization"
  ) {
    return sessionCapabilities.incrementalContextSync &&
      session.synchronizedContextRevision < contextRevision
      ? plan(
          "SYNC_AND_CONTINUE",
          modelAction,
          session,
          "delta",
          session.synchronizedContextRevision,
        )
      : plan(
          "RECONSTRUCT_SESSION",
          modelAction,
          session,
          contextRevision > 0 ? "full" : "none",
        );
  }
  return plan(
    "CONTINUE_SESSION",
    modelAction,
    session,
    "none",
    contextRevision,
  );
}
