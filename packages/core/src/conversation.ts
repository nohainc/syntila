import {
  MANUAL_WORKFLOW_POLICY,
  type WorkflowCapabilities,
} from "./workflow-policy.js";
import { BUILTIN_WORKFLOW_CATALOG, type WorkflowId } from "./thread.js";

/** Product workflow identity, independent of its versioned execution graph. */
export interface WorkflowDefinition {
  readonly id: string;
  readonly type: "manual";
  readonly version: number;
  readonly capabilities: readonly string[];
  readonly executionPolicy: WorkflowCapabilities;
  readonly configurationSchema: {
    readonly type: "object";
    readonly additionalProperties: false;
    readonly properties: Readonly<Record<string, { readonly type: "string" }>>;
  };
  readonly execution: {
    readonly workflowId: WorkflowId;
    readonly workflowVersion: number;
  };
}

export interface Conversation {
  readonly id: string;
  readonly threadId: string;
  readonly workflowId: string;
  readonly workflowVersion: number;
  /** Accepted requests, including requests that subsequently fail. */
  readonly conversationRevision: number;
  /** Canonical exact-history context version, advanced with accepted requests. */
  readonly contextRevision: number;
  readonly createdAt: string;
  readonly updatedAt: string;
}

const manualWorkflow = (
  id: "chat" | "work",
  executionId: "chat" | "direct",
  executionVersion: number,
): WorkflowDefinition => ({
  id,
  type: "manual",
  executionPolicy: MANUAL_WORKFLOW_POLICY,
  version: 1,
  capabilities: [
    ...new Set(
      BUILTIN_WORKFLOW_CATALOG[
        `${executionId}:v${executionVersion}`
      ]!.steps.flatMap((step) => step.requiredCapabilities),
    ),
  ],
  configurationSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      workerId: { type: "string" },
      model: { type: "string" },
      reasoningEffort: { type: "string" },
    },
  },
  execution: {
    workflowId: executionId,
    workflowVersion: executionVersion,
  },
});

export const CONVERSATION_WORKFLOWS: Readonly<
  Record<string, WorkflowDefinition>
> = {
  chat: manualWorkflow("chat", "chat", 1),
  work: manualWorkflow("work", "direct", 2),
};

export function conversationWorkflowForExecution(
  id: WorkflowId,
  version: number,
): WorkflowDefinition | null {
  return (
    Object.values(CONVERSATION_WORKFLOWS).find(
      (definition) =>
        definition.execution.workflowId === id &&
        definition.execution.workflowVersion === version,
    ) ?? null
  );
}

/** Immutable selection for one accepted manual turn, not Conversation defaults. */
export interface TurnExecutionConfig {
  readonly schemaVersion: 1;
  readonly workerId: string;
  readonly profileId: string;
  readonly profileReleaseVersion: number;
  /** null means provider CLI default, never a guessed resolved provider model. */
  readonly modelId: string | null;
  readonly effort: string | null;
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
}

export interface UserMessage {
  readonly id: string;
  readonly conversationId: string;
  readonly authorUserId: string;
  readonly text: string;
  readonly createdAt: string;
}

/** Stable logical execution; scheduler runs are attempts, WorkerTurns are invocations. */
export interface WorkflowRun {
  readonly schemaVersion: 1;
  readonly id: string;
  readonly conversationId: string;
  readonly userMessageId: string;
  readonly triggerMessageId: string;
  readonly startedAt: string | null;
  readonly completedAt: string | null;
  readonly stepRuns: readonly WorkflowStepRun[];
  readonly executionConfigs?: Readonly<Record<string, TurnExecutionConfig>>;
  readonly workRequestId: string;
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  readonly status: "queued" | "running" | "completed" | "failed" | "cancelled";
  readonly runtimeRunIds: readonly string[];
  readonly workerTurnIds: readonly string[];
  readonly createdAt: string;
  readonly updatedAt: string;
}

/** One logical workflow step, independent of retry/Worker invocation count. */
export interface WorkflowStepRun {
  readonly executionConfig?: TurnExecutionConfig;
  readonly profileId?: string | null;
  readonly profileReleaseVersion?: number | null;
  readonly schemaVersion: 1;
  readonly id: string;
  readonly workflowRunId: string;
  readonly taskId: string;
  readonly stepId: string;
  readonly role: string;
  readonly workerId: string | null;
  readonly modelId: string | null;
  readonly effort: string | null;
  readonly workerSessionId: string | null;
  readonly baseContextRevision: number;
  readonly status:
    "queued" | "running" | "waiting" | "completed" | "failed" | "cancelled";
  readonly result: string | null;
  readonly startedAt: string | null;
  readonly completedAt: string | null;
  readonly workerTurnIds: readonly string[];
}

/** One actual worker invocation. Retries are separate turns of the same message. */
export interface ConversationTurn {
  readonly id: string;
  readonly workflowRunId: string;
  readonly workflowStepRunId: string;
  readonly runtimeRunId: string | null;
  readonly conversationId: string;
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  readonly userMessageId: string;
  readonly workRequestId: string;
  readonly assignmentId: string;
  readonly taskId: string;
  readonly stepKind: string;
  readonly workerId: string;
  readonly workerTypeId: string;
  readonly workerDisplayName: string;
  /** Display name of the person whose Workspace ran the turn, when known. */
  readonly workerOwnerName?: string | null;
  readonly profileId: string;
  readonly profileVersion: number;
  readonly modelId: string | null;
  readonly modelName?: string | null;
  readonly catalogRevision?: string | null;
  readonly effort: string | null;
  /** Opaque logical scope reference, never a provider-native session handle. */
  readonly workerSessionId: string | null;
  readonly baseContextRevision: number;
  readonly status: "queued" | "running" | "completed" | "failed" | "cancelled";
  readonly startedAt: string | null;
  readonly completedAt: string | null;
  readonly resultText: string | null;
  readonly createdAt: string;
  /** Images the Worker produced; downloaded through the Thread file route. */
  readonly images?: readonly ConversationTurnImage[];
}

export interface ConversationTurnImage {
  readonly kind: "file";
  readonly fileId: string;
  readonly name: string;
  readonly mediaType: string;
  readonly sizeBytes: number;
}

export const CONVERSATION_HISTORY_KINDS = [
  "user_message",
  "worker_response",
  "workflow_event",
  "execution_event",
  "artifact_event",
  "context_event",
] as const;
export type ConversationHistoryKind =
  (typeof CONVERSATION_HISTORY_KINDS)[number];

/** Syntila-owned canonical facts; provider session state is never history. */
export interface ConversationHistoryEntry {
  readonly id: string;
  readonly conversationId: string;
  readonly sequence: number;
  readonly schemaVersion: 1;
  readonly kind: ConversationHistoryKind;
  readonly eventType: string;
  readonly actorType: "user" | "worker" | "syntila";
  readonly actorId: string | null;
  readonly workRequestId: string | null;
  readonly turnId: string | null;
  readonly artifactId: string | null;
  readonly sourceId: string;
  readonly text: string | null;
  /** Versioned, allowlisted source metadata, not raw CLI/session/event payloads. */
  readonly metadata: Readonly<Record<string, unknown>>;
  readonly occurredAt: string;
  readonly recordedAt: string;
}
export interface ConversationHistoryCursor {
  readonly afterSequence: number;
  readonly throughSequence: number;
}
export interface ConversationHistoryPage {
  readonly conversationId: string;
  readonly historyRevision: number;
  readonly throughSequence: number;
  readonly entries: readonly ConversationHistoryEntry[];
  readonly nextCursor: ConversationHistoryCursor | null;
}

/** Workspace-owned execution state; never a Cloud/Human Product response DTO. */
export interface WorkerSession {
  readonly id: string;
  readonly conversationId: string;
  readonly workerId: string;
  readonly profileId: string;
  readonly profileVersion: number;
  /** Opaque provider handle persisted only inside Workspace/Engine local state. */
  readonly nativeSessionId: string | null;
  readonly synchronizedContextRevision: number;
  /** Local exact-history watermark, separate from accepted-request revision. */
  readonly synchronizedHistorySequence?: number;
  readonly status: "active" | "requires_synchronization";
  readonly lastModelId: string | null;
  readonly lastEffort: string | null;
  readonly createdAt: string;
  readonly lastUsedAt: string;
}

/** Explicit execution name; ConversationTurn remains the canonical history DTO. */
export type WorkerTurn = ConversationTurn;
