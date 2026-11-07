import type { BuiltinWorkflowDefinition, ThreadBindingId } from "./thread.js";

/** Product controls, independent of Worker/tool capabilities and authorization. */
export interface WorkflowCapabilities {
  readonly userSelectsWorker: boolean;
  readonly userSelectsModel: boolean;
  readonly userSelectsEffort: boolean;
  readonly multiStep: boolean;
  readonly multiWorker: boolean;
  readonly automaticContinuation: boolean;
  readonly requiresApprovalBetweenSteps: boolean;
}

export const MANUAL_WORKFLOW_POLICY: WorkflowCapabilities = {
  userSelectsWorker: true,
  userSelectsModel: true,
  userSelectsEffort: true,
  multiStep: false,
  multiWorker: false,
  automaticContinuation: false,
  requiresApprovalBetweenSteps: false,
};

const GRAPH_WORKFLOW_POLICY: WorkflowCapabilities = {
  ...MANUAL_WORKFLOW_POLICY,
  multiStep: true,
  multiWorker: true,
  automaticContinuation: true,
};

/** Versioned control metadata; future workflows must declare their own policy. */
export const WORKFLOW_CONTROL_POLICIES: Readonly<
  Record<
    string,
    {
      readonly executionPolicy: WorkflowCapabilities;
      readonly composerBindingId: ThreadBindingId | null;
    }
  >
> = {
  "chat:v1": {
    executionPolicy: MANUAL_WORKFLOW_POLICY,
    composerBindingId: "chat",
  },
  "direct:v1": {
    executionPolicy: MANUAL_WORKFLOW_POLICY,
    composerBindingId: "direct",
  },
  "direct:v2": {
    executionPolicy: MANUAL_WORKFLOW_POLICY,
    composerBindingId: "direct",
  },
  "research:v1": {
    executionPolicy: MANUAL_WORKFLOW_POLICY,
    composerBindingId: "research",
  },
  // Graph policy: several researcher executions and a synthesis execution.
  // Each role still selects its own Worker, model and effort.
  "research:v2": {
    executionPolicy: {
      ...GRAPH_WORKFLOW_POLICY,
      userSelectsWorker: false,
      userSelectsModel: false,
      userSelectsEffort: false,
    },
    composerBindingId: "research",
  },
  // One Syntila-executed MCP tool call, then a chat answer. Not a composer
  // workflow: the tool target comes from the request, never from a picker.
  "chat:v2": {
    executionPolicy: {
      ...GRAPH_WORKFLOW_POLICY,
      multiWorker: false,
      automaticContinuation: true,
    },
    composerBindingId: null,
  },
  "plan_implement:v2": {
    executionPolicy: MANUAL_WORKFLOW_POLICY,
    composerBindingId: "plan",
  },
};

/** Metadata projection leaves historical executable snapshots unchanged. */
export function workflowCatalogEntry(
  definition: BuiltinWorkflowDefinition,
): BuiltinWorkflowDefinition & {
  readonly executionPolicy: WorkflowCapabilities;
  readonly composerBindingId: ThreadBindingId | null;
} {
  const controls =
    WORKFLOW_CONTROL_POLICIES[`${definition.id}:v${definition.version}`];
  if (!controls) throw new Error("Workflow control policy is not defined");
  if (controls.executionPolicy.multiStep !== definition.steps.length > 1) {
    throw new Error(
      "Workflow control policy does not match its execution graph",
    );
  }
  return { ...definition, ...controls };
}
