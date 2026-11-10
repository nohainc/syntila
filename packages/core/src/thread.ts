/**
 * Current Thread domain vocabulary.
 *
 * Threads are Space-owned units of collaboration and execution. This
 * module intentionally contains no UI, D1, transport, or provider types.
 */

import type { TurnExecutionConfig } from "./conversation.js";
import { DomainInvariantError } from "./domain-error.js";
import type { SpaceKind, SpaceMembership, SpaceRole } from "./space.js";

export type ThreadStatus =
  "active" | "paused" | "blocked" | "completed" | "archived";

export interface ThreadAccessPolicy {
  readonly allowedUserIds: readonly string[];
  readonly allowedSpaceRoles: readonly SpaceRole[];
  readonly allowedPermissions: readonly string[];
}

export const THREAD_ACCESS_PERMISSIONS = [
  "view",
  "discuss",
  "execute",
] as const;
export type ThreadAccessPermission = (typeof THREAD_ACCESS_PERMISSIONS)[number];

export const DEFAULT_THREAD_ACCESS_POLICY: ThreadAccessPolicy = {
  allowedUserIds: [],
  allowedSpaceRoles: ["owner", "collaborator", "viewer"],
  allowedPermissions: [...THREAD_ACCESS_PERMISSIONS],
};

export interface ThreadLead {
  readonly userId: string;
  readonly assignedAt: string;
  readonly assignedByUserId: string;
}

export interface Thread {
  readonly id: string;
  readonly spaceId: string;
  readonly name: string;
  readonly status: ThreadStatus;
  readonly accessPolicy: ThreadAccessPolicy;
  readonly lead: ThreadLead;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface DiscussionMessage {
  readonly id: string;
  readonly threadId: string;
  readonly authorUserId: string;
  readonly body: string;
  readonly createdAt: string;
  readonly editedAt: string | null;
}

export type WorkRequestStatus =
  "queued" | "running" | "waiting" | "completed" | "failed" | "cancelled";

export type WorkRequestMode = "stateless" | "stateful";

export interface WorkRequest {
  readonly id: string;
  readonly conversationId?: string;
  readonly executionConfig?: TurnExecutionConfig;
  readonly threadId: string;
  readonly requestedByUserId: string;
  readonly mode: WorkRequestMode;
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  /** Immutable copy selected when the Work Request was created. */
  readonly workflowSnapshot: BuiltinWorkflowDefinition;
  /** Immutable execution and prompt inputs captured when submitted. */
  readonly snapshot?: WorkRequestSnapshot;
  readonly status: WorkRequestStatus;
  readonly primaryWorkspaceId: string | null;
  readonly input: Readonly<Record<string, unknown>>;
  readonly createdAt: string;
  readonly updatedAt: string;
}

export interface WorkRequestSnapshot {
  /** Keyed by step-instance ID (the kind for one-per-kind definitions). */
  readonly stepExecutionConfigs?: Readonly<
    Partial<Record<string, TurnExecutionConfig>>
  >;
  readonly turnExecutionConfig?: TurnExecutionConfig;
  readonly schemaVersion: 1;
  readonly originalRequest: string;
  readonly attachmentReferences: readonly unknown[];
  readonly workflowId: WorkflowId;
  readonly workflowVersion: number;
  readonly workflowSnapshot: BuiltinWorkflowDefinition;
  /** Keyed by binding ID: the kind, `direct`, or a Research v2 step instance. */
  readonly resolvedBindings: Readonly<
    Partial<Record<string, WorkflowExecutionBinding>>
  >;
  readonly spaceInstructions: string;
  readonly threadInstructions: string;
  readonly stepAdditionalInstructions: Partial<Record<StepKind, string>>;
  readonly promptProfileVersions: Partial<Record<StepKind, string>>;
}

/**
 * Hard cap for one Work step's provider execution. The declared step timeout
 * (15 minutes) is the baseline; a long goal-style task may run up to this cap
 * as long as the agent is alive. The Engine stops a stuck agent much sooner
 * (no output and nothing running), so this is only the outer bound.
 *
 * It is applied when the step is dispatched, not stored in the built-in
 * Workflow definition, because existing Work Request snapshots must keep
 * matching their canonical definition.
 */
export const STEP_HARD_CAP_MS = 8 * 60 * 60 * 1000;

export function effectiveStepTimeoutMs(declaredMs: number): number {
  return Math.max(declaredMs, STEP_HARD_CAP_MS);
}

export const STEP_KINDS = [
  "chat",
  "research",
  "plan",
  "implement",
  "test",
  "verify",
  "synthesis",
  "tool_call",
] as const;
export type StepKind = (typeof STEP_KINDS)[number];

/**
 * Syntila-owned transport for a completed Workflow Step. Workers return plain
 * text; structured fields here are attribution or metadata Syntila can verify.
 */
export interface StepResult {
  readonly text: string;
  readonly status: "completed" | "failed" | "cancelled";
  readonly startedAt: string;
  readonly completedAt: string;
  readonly workerId: string | null;
  readonly workerTypeId: string | null;
  readonly engineVersion: string | null;
  readonly profileDefinitionId: string | null;
  readonly profileReleaseVersion: number | null;
  readonly providerToolVersion: string | null;
  readonly model: string | null;
  readonly reasoningEffort?: string | null;
  readonly artifacts?: readonly string[];
  readonly changedFiles?: readonly string[];
  readonly testStatus?: "passed" | "failed" | "blocked" | "not_run";
}

export const WORKFLOW_IDS = [
  "chat",
  "direct",
  "plan_implement",
  "research",
] as const;
export type WorkflowId = (typeof WORKFLOW_IDS)[number];
export const THREAD_BINDING_IDS = ["direct", ...STEP_KINDS] as const;
export type ThreadBindingId = (typeof THREAD_BINDING_IDS)[number];

/** Frozen resolved execution input; global preferences are stored separately. */
export interface WorkflowExecutionBinding {
  readonly workerId?: string;
  readonly model?: string;
  readonly reasoningEffort?: string;
  readonly catalogRevision?: string;
  readonly additionalInstructions?: string;
  /** Frozen MCP server IDs for this Step; absent = Workspace bindings alone. */
  readonly mcpTools?: readonly string[];
}

/** Thread-authored context. Execution preferences belong to the user. */
export interface ThreadWorkConfig {
  readonly defaultWorkflowId: WorkflowId;
  readonly threadInstructions?: string;
  readonly bindings: Readonly<
    Partial<
      Record<ThreadBindingId, { readonly additionalInstructions?: string }>
    >
  >;
}

export type WorkflowExecutionMode = "stateless_read" | "stateful_thread";
export type WorkflowExecutionClass = "analysis" | "workspace_action";
export const WORKFLOW_CAPABILITIES = [
  "authorized_context_read",
  "thread_write",
  "test_execution",
  "independent_verification",
] as const;
export type WorkflowCapability = (typeof WORKFLOW_CAPABILITIES)[number];
export type WorkflowReadWritePolicy = "read_only" | "write_thread";
export type WorkflowResultSemantics =
  | "conversation_response"
  | "evidence_summary"
  | "implementation_plan"
  | "thread_changes"
  | "test_report"
  | "verification_report"
  /** One independent researcher's report (Research v2). */
  | "research_report"
  /** The synthesized Research outcome built from all researcher reports. */
  | "research_synthesis"
  /** The recorded outcome of one MCP tool call; never a Worker answer. */
  | "tool_result";

export interface BuiltinWorkflowStep {
  /**
   * Stable step-instance ID, unique within a definition. Present when a
   * definition repeats a semantic kind (Research v2 runs several `research`
   * steps). Older definitions omit it and use their kind; see
   * [stepInstanceId].
   */
  readonly id?: string;
  readonly kind: StepKind;
  readonly order: number;
  readonly executionMode: WorkflowExecutionMode;
  readonly executionClass: WorkflowExecutionClass;
  readonly requiredCapabilities: readonly WorkflowCapability[];
  readonly readWritePolicy: WorkflowReadWritePolicy;
  readonly timeoutMs: number;
  readonly promptProfileVersion: string;
  /** Fixed by the built-in definition; users cannot author dependencies. */
  readonly dependsOn: readonly StepKind[];
  /** Results from these fixed upstream steps are included as inputs. */
  readonly inputsFrom: readonly StepKind[];
  /** Step-instance dependencies; overrides [dependsOn] when present. */
  readonly dependsOnSteps?: readonly string[];
  /** Step-instance inputs; overrides [inputsFrom] when present. */
  readonly inputsFromSteps?: readonly string[];
  readonly resultSemantics: WorkflowResultSemantics;
}

/** The step's identity in its definition: its `id`, or its kind. */
export function stepInstanceId(
  step: Pick<BuiltinWorkflowStep, "id" | "kind">,
): string {
  return step.id ?? step.kind;
}

/** Instance IDs this step waits for. */
export function stepDependencyIds(
  step: BuiltinWorkflowStep,
): readonly string[] {
  return step.dependsOnSteps ?? step.dependsOn;
}

/** Instance IDs whose results this step receives as input. */
export function stepInputIds(step: BuiltinWorkflowStep): readonly string[] {
  return step.inputsFromSteps ?? step.inputsFrom;
}

export interface BuiltinWorkflowDefinition {
  readonly id: WorkflowId;
  readonly version: number;
  readonly name: string;
  readonly description: string;
  readonly steps: readonly BuiltinWorkflowStep[];
}

const builtinStep = (
  kind: StepKind,
  order: number,
  dependsOn: readonly StepKind[] = [],
  inputsFrom: readonly StepKind[] = dependsOn,
): BuiltinWorkflowStep => ({
  kind,
  order,
  executionMode:
    kind === "chat" || kind === "research" || kind === "plan"
      ? "stateless_read"
      : "stateful_thread",
  executionClass:
    kind === "chat" || kind === "research" || kind === "plan"
      ? "analysis"
      : "workspace_action",
  requiredCapabilities:
    kind === "chat" || kind === "research"
      ? ["authorized_context_read"]
      : kind === "plan"
        ? ["authorized_context_read"]
        : kind === "implement"
          ? ["thread_write"]
          : kind === "test"
            ? ["authorized_context_read", "test_execution"]
            : ["authorized_context_read", "independent_verification"],
  readWritePolicy: kind === "implement" ? "write_thread" : "read_only",
  timeoutMs: 15 * 60 * 1000,
  promptProfileVersion: `${kind}:v1`,
  dependsOn,
  inputsFrom,
  resultSemantics: (
    {
      chat: "conversation_response",
      research: "evidence_summary",
      plan: "implementation_plan",
      implement: "thread_changes",
      test: "test_report",
      verify: "verification_report",
      synthesis: "research_synthesis",
      tool_call: "tool_result",
    } satisfies Record<StepKind, WorkflowResultSemantics>
  )[kind],
});

const builtin = (
  id: WorkflowId,
  name: string,
  description: string,
  kinds: readonly StepKind[],
  version = 1,
): BuiltinWorkflowDefinition => ({
  id,
  version,
  name,
  description,
  steps: kinds.map((kind, order) => {
    const preceding = kinds.slice(0, order);
    const inputsFrom = preceding.filter((prior) => {
      switch (kind) {
        case "chat":
        case "research":
          return false;
        case "plan":
          return prior === "research";
        case "implement":
          return prior === "research" || prior === "plan";
        case "test":
          return prior === "plan" || prior === "implement";
        case "verify":
          return true;
        case "synthesis":
          return prior === "research";
        case "tool_call":
          return false;
      }
    });
    return builtinStep(
      kind,
      order,
      order === 0 ? [] : [kinds[order - 1]!],
      inputsFrom,
    );
  }),
});

/**
 * Research v2 researcher count. Operational bounds live here only: at least
 * two independent researchers (model diversity is the point), at most four
 * (each one is a full provider execution and its report must fit synthesis).
 */
export const RESEARCH_RESEARCHER_LIMITS = {
  min: 2,
  max: 4,
  default: 2,
} as const;

/** Step-instance ID of researcher `index` (1-based) in Research v2. */
export function researcherStepId(index: number): string {
  return `research-${index}`;
}
export const RESEARCH_SYNTHESIS_STEP_ID = "synthesis";

/**
 * A failed researcher need not end the request: after the failure the user may
 * explicitly ask for a synthesis of the reports that succeeded. At least one
 * report is required, and the result is always labelled as completed with gaps.
 */
export const RESEARCH_PARTIAL_SYNTHESIS_MIN_REPORTS = 1;

/**
 * Research v2: independent researchers that share no session or output,
 * followed by one synthesis step that receives every report. All steps are
 * read-only analysis. The researcher count is part of the accepted snapshot.
 */
export function researchWorkflowV2(
  researcherCount: number = RESEARCH_RESEARCHER_LIMITS.default,
): BuiltinWorkflowDefinition {
  if (
    !Number.isInteger(researcherCount) ||
    researcherCount < RESEARCH_RESEARCHER_LIMITS.min ||
    researcherCount > RESEARCH_RESEARCHER_LIMITS.max
  ) {
    throw new DomainInvariantError(
      `Research needs ${RESEARCH_RESEARCHER_LIMITS.min} to ${RESEARCH_RESEARCHER_LIMITS.max} researchers`,
    );
  }
  const analysis = {
    executionMode: "stateless_read",
    executionClass: "analysis",
    requiredCapabilities: ["authorized_context_read"],
    readWritePolicy: "read_only",
    timeoutMs: 15 * 60 * 1000,
  } as const;
  const researchers = Array.from({ length: researcherCount }, (_, index) => ({
    id: researcherStepId(index + 1),
    kind: "research" as const,
    order: index,
    ...analysis,
    promptProfileVersion: "research:v2",
    dependsOn: [],
    inputsFrom: [],
    dependsOnSteps: [],
    inputsFromSteps: [],
    resultSemantics: "research_report" as const,
  }));
  const ids = researchers.map((step) => step.id);
  return {
    id: "research",
    version: 2,
    name: "Research",
    description:
      "Independent researchers on different models investigate the request; a synthesis compares their reports.",
    steps: [
      ...researchers,
      {
        id: RESEARCH_SYNTHESIS_STEP_ID,
        kind: "synthesis",
        order: researcherCount,
        ...analysis,
        promptProfileVersion: "synthesis:v1",
        dependsOn: ["research"],
        inputsFrom: ["research"],
        dependsOnSteps: ids,
        inputsFromSteps: ids,
        resultSemantics: "research_synthesis",
      },
    ],
  };
}

/** Step-instance IDs of Tool Chat: one tool call, then a chat about it. */
export const TOOL_CHAT_TOOL_STEP_ID = "tool";
export const TOOL_CHAT_CHAT_STEP_ID = "chat";

/**
 * Tool Chat (`chat:v2`): one MCP tool call whose recorded outcome is given to a
 * read-only chat answer. The call is a Syntila-executed step with no Worker;
 * its target and arguments are part of the accepted request, not of this
 * definition. An unknown outcome stops the Workflow: it is never retried.
 */
export function toolChatWorkflowV2(): BuiltinWorkflowDefinition {
  return {
    id: "chat",
    version: 2,
    name: "Chat with tool",
    description:
      "Call one consented MCP tool, then discuss its recorded result.",
    steps: [
      {
        id: TOOL_CHAT_TOOL_STEP_ID,
        kind: "tool_call",
        order: 0,
        executionMode: "stateless_read",
        executionClass: "workspace_action",
        requiredCapabilities: [],
        readWritePolicy: "read_only",
        timeoutMs: 15 * 60 * 1000,
        promptProfileVersion: "tool_call:v1",
        dependsOn: [],
        inputsFrom: [],
        dependsOnSteps: [],
        inputsFromSteps: [],
        resultSemantics: "tool_result",
      },
      {
        id: TOOL_CHAT_CHAT_STEP_ID,
        kind: "chat",
        order: 1,
        executionMode: "stateless_read",
        executionClass: "analysis",
        requiredCapabilities: ["authorized_context_read"],
        readWritePolicy: "read_only",
        timeoutMs: 15 * 60 * 1000,
        promptProfileVersion: "chat:v1",
        dependsOn: ["tool_call"],
        inputsFrom: ["tool_call"],
        dependsOnSteps: [TOOL_CHAT_TOOL_STEP_ID],
        inputsFromSteps: [TOOL_CHAT_TOOL_STEP_ID],
        resultSemantics: "conversation_response",
      },
    ],
  };
}

const RESEARCH_V1 = builtin(
  "research",
  "Research",
  "Gather evidence relevant to the request.",
  ["research"],
);

const DIRECT_V1 = builtin("direct", "Direct", "Implement the requested work.", [
  "implement",
]);

/**
 * Implement v2 (ADR-030): An interactive, phased implementation workflow.
 * Step 1 prepares a structured plan partitioned into implementation phases.
 * Upon user approval and verification configuration, phases execute via the
 * Thread Request Queue.
 */
export const IMPLEMENT_WORKFLOW_ROLES = [
  "plan",
  "implement",
  "verify",
] as const;
export type ImplementWorkflowRole = (typeof IMPLEMENT_WORKFLOW_ROLES)[number];

export function implementWorkflowV2(): BuiltinWorkflowDefinition {
  return {
    id: "plan_implement",
    version: 2,
    name: "Implement",
    description:
      "Plan in phases, review the approach, and execute step-by-step with verification.",
    steps: [
      {
        id: "plan",
        kind: "plan",
        order: 0,
        executionMode: "stateless_read",
        executionClass: "analysis",
        requiredCapabilities: ["authorized_context_read"],
        readWritePolicy: "read_only",
        timeoutMs: 15 * 60 * 1000,
        promptProfileVersion: "plan:v2",
        dependsOn: [],
        inputsFrom: [],
        dependsOnSteps: [],
        inputsFromSteps: [],
        resultSemantics: "implementation_plan",
      },
    ],
  };
}

export const ACTIVE_WORKFLOW_IDS = WORKFLOW_IDS;
export type ActiveWorkflowId = WorkflowId;

/** Current version for each active built-in ID; immutable history is below. */
export const BUILTIN_WORKFLOWS: Readonly<
  Record<WorkflowId, BuiltinWorkflowDefinition>
> = {
  chat: builtin(
    "chat",
    "Chat",
    "Discuss the request using read-only Thread context.",
    ["chat"],
  ),
  direct: builtin(
    "direct",
    "Work",
    "Implement the requested work.",
    ["implement"],
    2,
  ),
  plan_implement: implementWorkflowV2(),
  research: researchWorkflowV2(),
};

/**
 * Authoritative immutable definitions keyed by stable release reference.
 */
export const BUILTIN_WORKFLOW_CATALOG: Readonly<
  Record<string, BuiltinWorkflowDefinition>
> = {
  "chat:v1": BUILTIN_WORKFLOWS.chat,
  "chat:v2": toolChatWorkflowV2(),
  "direct:v1": DIRECT_V1,
  "direct:v2": BUILTIN_WORKFLOWS.direct,
  "plan_implement:v2": BUILTIN_WORKFLOWS.plan_implement,
  "research:v1": RESEARCH_V1,
  "research:v2": BUILTIN_WORKFLOWS.research,
};

export function builtinWorkflowReference(
  definition: Pick<BuiltinWorkflowDefinition, "id" | "version">,
): string {
  return `${definition.id}:v${definition.version}`;
}

export interface ThreadExecutionPolicy {
  readonly mode: WorkRequestMode;
  readonly primaryWorkspaceId: string | null;
}

export type ThreadExecutionLeaseStatus = "active" | "released" | "expired";

export interface ThreadExecutionLease {
  readonly id: string;
  readonly threadId: string;
  readonly workRequestId: string;
  readonly workspaceId: string;
  readonly fencingToken: number;
  readonly status: ThreadExecutionLeaseStatus;
  readonly acquiredAt: string;
  readonly expiresAt: string;
  readonly releasedAt: string | null;
}

function required(value: string, field: string): void {
  if (!value || value.trim().length === 0) {
    throw new DomainInvariantError(`${field} is required`);
  }
}

function positive(value: number, field: string): void {
  if (!Number.isInteger(value) || value <= 0) {
    throw new DomainInvariantError(`${field} must be a positive integer`);
  }
}

export function validateThread(
  thread: Thread,
  spaceMemberships: readonly SpaceMembership[],
): void {
  required(thread.id, "Thread id");
  required(thread.spaceId, "Thread spaceId");
  required(thread.name, "Thread name");
  required(thread.lead.userId, "Thread lead userId");
  const lead = spaceMemberships.find(
    (membership) =>
      membership.spaceId === thread.spaceId &&
      membership.userId === thread.lead.userId,
  );
  if (!lead || lead.role === "viewer") {
    throw new DomainInvariantError(
      "Thread lead must be a Space owner or collaborator",
    );
  }
  validateThreadAccessPolicy(thread.accessPolicy, spaceMemberships);
}

/** A Thread policy may only remove Space permissions, never add them. */
export function validateThreadAccessPolicy(
  policy: ThreadAccessPolicy,
  spaceMemberships: readonly SpaceMembership[],
  spacePermissionsByUser: Readonly<Record<string, readonly string[]>> = {},
): void {
  const members = new Map(
    spaceMemberships.map((membership) => [membership.userId, membership]),
  );
  for (const userId of policy.allowedUserIds) {
    const membership = members.get(userId);
    if (!membership || !policy.allowedSpaceRoles.includes(membership.role)) {
      throw new DomainInvariantError(
        "Thread access cannot expand Space membership or contradict its role",
      );
    }
  }
  for (const [userId, permissions] of Object.entries(spacePermissionsByUser)) {
    if (
      policy.allowedUserIds.includes(userId) &&
      policy.allowedPermissions.some(
        (permission) => !permissions.includes(permission),
      )
    ) {
      throw new DomainInvariantError(
        "Thread permissions must be a subset of Space permissions",
      );
    }
  }
}

function canAccessThreadPermission(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
  permission: ThreadAccessPermission,
): boolean {
  if (!membership || membership.spaceId !== thread.spaceId) return false;
  if (membership.role === "owner") return true;
  if (permission !== "view") {
    if (membership.permissions) {
      if (permission === "discuss" && !membership.permissions.chat)
        return false;
      if (
        permission === "execute" &&
        !membership.permissions.chat &&
        !membership.permissions.work
      )
        return false;
    } else if (membership.role === "viewer") return false;
  }
  if (
    thread.accessPolicy.allowedUserIds.length > 0 &&
    !thread.accessPolicy.allowedUserIds.includes(userId)
  ) {
    return false;
  }
  if (
    thread.accessPolicy.allowedSpaceRoles.length > 0 &&
    !thread.accessPolicy.allowedSpaceRoles.includes(membership.role)
  ) {
    return false;
  }
  return thread.accessPolicy.allowedPermissions.includes(permission);
}

/** Space membership is always re-evaluated before Thread access. */
export function canViewThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "view");
}

export function canDiscussThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "discuss");
}

export function canExecuteThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
): boolean {
  return canAccessThreadPermission(userId, membership, thread, "execute");
}

/** Management is Space-owner or assigned Thread-lead authority.
 * In a Direct Space, each participant can only manage Threads they created. */
export function canManageThread(
  userId: string,
  membership: SpaceMembership | null | undefined,
  thread: Thread,
  spaceKind: SpaceKind = "group",
): boolean {
  if (!membership || membership.spaceId !== thread.spaceId) return false;
  if (spaceKind === "direct") {
    return thread.lead.userId === userId;
  }
  if (membership.role === "owner") return true;
  return (
    (membership.permissions?.manageOwnThreads ??
      membership.role === "collaborator") &&
    thread.lead.userId === userId
  );
}

export function validateWorkRequest(
  request: WorkRequest,
  policy: ThreadExecutionPolicy,
): void {
  required(request.id, "WorkRequest id");
  required(request.threadId, "WorkRequest threadId");
  required(request.requestedByUserId, "WorkRequest requestedByUserId");
  required(request.workflowId, "WorkRequest workflowId");
  positive(request.workflowVersion, "WorkRequest workflowVersion");
  if (
    request.workflowSnapshot.id !== request.workflowId ||
    request.workflowSnapshot.version !== request.workflowVersion
  ) {
    throw new DomainInvariantError(
      "WorkRequest workflow snapshot must match its selected version",
    );
  }
  validateBuiltinWorkflowDefinition(request.workflowSnapshot);
  if (request.snapshot) {
    if (
      request.snapshot.schemaVersion !== 1 ||
      request.snapshot.workflowId !== request.workflowId ||
      request.snapshot.workflowVersion !== request.workflowVersion ||
      request.snapshot.workflowSnapshot.id !== request.workflowId ||
      request.snapshot.workflowSnapshot.version !== request.workflowVersion
    ) {
      throw new DomainInvariantError(
        "WorkRequest execution snapshot must match its selected Workflow",
      );
    }
    validateBuiltinWorkflowDefinition(request.snapshot.workflowSnapshot);
    for (const step of request.snapshot.workflowSnapshot.steps) {
      // A tool call is run by Syntila itself and has no Worker binding.
      if (step.kind === "tool_call") continue;
      const bindingId =
        request.workflowId === "direct"
          ? "direct"
          : request.workflowId === "research" && request.workflowVersion === 2
            ? stepInstanceId(step)
            : step.kind;
      if (
        request.snapshot.promptProfileVersions[step.kind] !==
          step.promptProfileVersion ||
        !Object.prototype.hasOwnProperty.call(
          request.snapshot.resolvedBindings,
          bindingId,
        )
      ) {
        throw new DomainInvariantError(
          "WorkRequest snapshot is missing a resolved Step input",
        );
      }
    }
  }
  if (request.mode === "stateful") {
    if (policy.mode !== "stateful" || !policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest requires a Primary Workspace",
      );
    }
    if (!request.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest requires a Primary Workspace",
      );
    }
    if (request.primaryWorkspaceId !== policy.primaryWorkspaceId) {
      throw new DomainInvariantError(
        "Stateful WorkRequest must use the Thread Primary Workspace",
      );
    }
  }
}

export function validateBuiltinWorkflowDefinition(
  definition: BuiltinWorkflowDefinition,
): void {
  if (!definition || typeof definition !== "object") {
    throw new DomainInvariantError("Built-in Workflow must be an object");
  }
  const exactKeys = (value: object, expected: readonly string[]): boolean => {
    const actual = Object.keys(value).sort();
    return (
      actual.length === expected.length &&
      actual.every((key, index) => key === [...expected].sort()[index])
    );
  };
  if (
    !exactKeys(definition, ["id", "version", "name", "description", "steps"])
  ) {
    throw new DomainInvariantError(
      "Built-in Workflow definition has unsupported fields",
    );
  }
  required(definition.id, "BuiltinWorkflowDefinition id");
  required(definition.name, "BuiltinWorkflowDefinition name");
  required(definition.description, "BuiltinWorkflowDefinition description");
  positive(definition.version, "BuiltinWorkflowDefinition version");
  if (!WORKFLOW_IDS.includes(definition.id)) {
    throw new DomainInvariantError("Unsupported built-in Workflow ID");
  }
  const reference = builtinWorkflowReference(definition);
  let canonical: BuiltinWorkflowDefinition | undefined =
    BUILTIN_WORKFLOW_CATALOG[reference];
  if (
    canonical &&
    reference === "research:v2" &&
    Array.isArray(definition.steps)
  ) {
    // The researcher count is chosen at acceptance; validate that shape.
    const researchers = definition.steps.filter(
      (step) => step && (step as BuiltinWorkflowStep).kind === "research",
    ).length;
    try {
      canonical = researchWorkflowV2(researchers);
    } catch {
      canonical = undefined;
    }
  }
  if (!canonical) {
    throw new DomainInvariantError("Unsupported built-in Workflow version");
  }
  if (
    definition.name !== canonical.name ||
    definition.description !== canonical.description ||
    !Array.isArray(definition.steps) ||
    definition.steps.length !== canonical.steps.length
  ) {
    throw new DomainInvariantError(
      "Built-in Workflow definition must match its canonical version",
    );
  }
  for (const [index, step] of definition.steps.entries()) {
    if (
      !step ||
      typeof step !== "object" ||
      // The canonical step decides which optional instance fields exist.
      !exactKeys(step, Object.keys(canonical.steps[index] ?? {}))
    ) {
      throw new DomainInvariantError(
        "Built-in Workflow step has unsupported fields",
      );
    }
    const expected = canonical.steps[index]!;
    const sameList = (
      actual: unknown,
      wanted: readonly string[] | undefined,
    ): boolean =>
      wanted === undefined
        ? actual === undefined
        : Array.isArray(actual) &&
          actual.length === wanted.length &&
          actual.every((value, i) => value === wanted[i]);
    if (
      step.id !== expected.id ||
      !sameList(step.dependsOnSteps, expected.dependsOnSteps) ||
      !sameList(step.inputsFromSteps, expected.inputsFromSteps)
    ) {
      throw new DomainInvariantError(
        "Built-in Workflow definition must match its canonical version",
      );
    }
    if (
      step.kind !== expected.kind ||
      step.order !== index ||
      step.executionMode !== expected.executionMode ||
      step.executionClass !== expected.executionClass ||
      step.readWritePolicy !== expected.readWritePolicy ||
      step.resultSemantics !== expected.resultSemantics ||
      !Array.isArray(step.requiredCapabilities) ||
      step.requiredCapabilities.length !==
        expected.requiredCapabilities.length ||
      step.requiredCapabilities.some(
        (capability: WorkflowCapability, capabilityIndex: number) =>
          capability !== expected.requiredCapabilities[capabilityIndex],
      ) ||
      step.timeoutMs !== expected.timeoutMs ||
      step.promptProfileVersion !== expected.promptProfileVersion ||
      !Array.isArray(step.dependsOn) ||
      step.dependsOn.length !== expected.dependsOn.length ||
      step.dependsOn.some(
        (kind: StepKind, dependencyIndex: number) =>
          kind !== expected.dependsOn[dependencyIndex],
      ) ||
      !Array.isArray(step.inputsFrom) ||
      step.inputsFrom.length !== expected.inputsFrom.length ||
      step.inputsFrom.some(
        (kind: StepKind, inputIndex: number) =>
          kind !== expected.inputsFrom[inputIndex],
      )
    ) {
      throw new DomainInvariantError(
        "Built-in Workflow definition must match its canonical version",
      );
    }
    positive(step.timeoutMs, "BuiltinWorkflowStep timeoutMs");
    required(
      step.promptProfileVersion,
      "BuiltinWorkflowStep promptProfileVersion",
    );
  }
}

export function validateThreadLeases(
  thread: Pick<Thread, "id">,
  leases: readonly ThreadExecutionLease[],
): void {
  const active = leases.filter(
    (lease) => lease.threadId === thread.id && lease.status === "active",
  );
  if (active.length > 1) {
    throw new DomainInvariantError(
      "A Thread can have only one active execution lease",
    );
  }
  for (const lease of leases) {
    required(lease.id, "ThreadExecutionLease id");
    required(lease.threadId, "ThreadExecutionLease threadId");
    positive(lease.fencingToken, "ThreadExecutionLease fencingToken");
  }
}

function sortObject(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortObject);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, entry]) => [key, sortObject(entry)]),
    );
  }
  return value;
}

/** Stable JSON helpers for domain snapshots; persistence remains external. */
export function serializeEntity<T extends object>(entity: T): string {
  return JSON.stringify(sortObject(entity));
}

export function deserializeEntity<T>(serialized: string): T {
  const value: unknown = JSON.parse(serialized);
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DomainInvariantError("Serialized entity must be an object");
  }
  return value as T;
}
