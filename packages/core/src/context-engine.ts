import type { ConversationHistoryKind } from "./conversation.js";

/** A valid canonical snapshot cannot fit the supported context transport. */
export class ContextLimitError extends Error {
  constructor(message = "Context exceeds the byte limit") {
    super(message);
    this.name = "ContextLimitError";
  }
}

export interface ContextFact<T = string> {
  readonly revision: number;
  readonly sequence: number;
  readonly value: T;
}
export interface ContextArtifact {
  readonly id: string;
  readonly contentDigest: string | null;
}
export interface ContextWorkflowState {
  readonly workflowId: string;
  readonly workflowVersion: number;
  readonly workRequestId: string;
  readonly status: string;
  readonly steps: readonly {
    readonly workflowStepRunId?: string;
    readonly role?: string;
    readonly id: string;
    readonly kind: string;
    readonly status: string;
    readonly attempt: number;
  }[];
}
/** Execution facts are separate from persistent Conversation facts. */
export interface WorkflowExecutionContext {
  readonly schemaVersion: 1;
  readonly workflowRunId: string;
  readonly workflowId: string;
  readonly workflowVersion: number;
  readonly workRequestId: string;
  readonly status: string;
  readonly activeStepId: string;
  readonly steps: readonly {
    readonly workflowStepRunId?: string;
    readonly role?: string;
    readonly id: string;
    readonly kind: string;
    readonly status: string;
    readonly attempt: number;
    readonly workerId: string | null;
    readonly dependsOn: readonly string[];
    readonly result: string | null;
  }[];
  readonly environment: {
    readonly spaceId: string;
    readonly threadId: string;
    readonly spaceInstructions: string;
    readonly threadInstructions: string;
  } | null;
  readonly artifacts: readonly ContextArtifact[];
}
export interface SelectedWorkflowContext extends WorkflowExecutionContext {
  /** Only transitive prerequisite results are handed to the receiving step. */
  readonly prerequisiteResults: readonly {
    stepId: string;
    workerId: string | null;
    text: string;
  }[];
}

export function selectWorkflowContext(
  input: WorkflowExecutionContext,
): SelectedWorkflowContext {
  const steps = new Map(input.steps.map((step) => [step.id, step]));
  if (
    input.schemaVersion !== 1 ||
    !input.workRequestId ||
    !input.workflowRunId ||
    !input.workflowId ||
    !Number.isSafeInteger(input.workflowVersion) ||
    input.workflowVersion < 1 ||
    steps.size !== input.steps.length ||
    input.steps.length > 1000 ||
    !steps.has(input.activeStepId)
  )
    throw new Error("Invalid Workflow execution context");
  const ancestors = new Set<string>();
  const visiting = new Set<string>();
  const visited = new Set<string>();
  function visit(id: string): void {
    if (visiting.has(id)) throw new Error("Cyclic Workflow dependencies");
    if (visited.has(id)) return;
    const step = steps.get(id);
    if (!step) throw new Error("Unknown Workflow dependency");
    visiting.add(id);
    for (const dependency of step.dependsOn) visit(dependency);
    visiting.delete(id);
    visited.add(id);
  }
  for (const step of input.steps) visit(step.id);
  function collect(id: string): void {
    for (const dependency of steps.get(id)!.dependsOn) {
      if (!ancestors.has(dependency)) {
        ancestors.add(dependency);
        collect(dependency);
      }
    }
  }
  collect(input.activeStepId);
  return structuredClone({
    ...input,
    steps: input.steps.map((step) => ({
      ...step,
      result:
        ancestors.has(step.id) && step.status === "completed"
          ? step.result
          : null,
    })),
    prerequisiteResults: input.steps
      .filter(
        (step) =>
          ancestors.has(step.id) &&
          step.status === "completed" &&
          step.result !== null,
      )
      .map((step) => ({
        stepId: step.id,
        workerId: step.workerId,
        text: step.result!,
      })),
  });
}

export interface ContextState {
  readonly objective: ContextFact<string | null> | null;
  readonly importantDecisions: Readonly<
    Record<string, ContextFact<string | null>>
  >;
  readonly constraints: Readonly<Record<string, ContextFact<string | null>>>;
  readonly currentState: ContextFact<string | null> | null;
  readonly openIssues: Readonly<Record<string, ContextFact<string | null>>>;
  readonly artifacts: Readonly<
    Record<string, ContextFact<ContextArtifact | null>>
  >;
  readonly workflowState: ContextFact<ContextWorkflowState> | null;
  readonly summary: ContextFact<string | null> | null;
}
export type ConversationContext = Omit<ContextState, "workflowState">;

export interface ContextHistoryFact {
  readonly sequence: number;
  readonly contextRevision: number;
  readonly kind: ConversationHistoryKind;
  readonly eventType: string;
  readonly actorType: "user" | "worker" | "syntila";
  readonly actorId: string | null;
  readonly text: string | null;
  readonly sourceId?: string;
  readonly artifactId?: string | null;
  readonly metadata: Readonly<Record<string, unknown>>;
}
export interface ContextEngineInput {
  readonly conversationId: string;
  readonly contextRevision: number;
  readonly throughSequence: number;
  readonly state: ContextState;
  readonly history: readonly ContextHistoryFact[];
  readonly maxBytes?: number;
  readonly workflowExecution?: WorkflowExecutionContext;
}
interface ContextDocument {
  readonly schemaVersion: 1;
  readonly kind: "BootstrapContext" | "DeltaContext" | "StatelessContext";
  readonly conversationId: string;
  readonly contextRevision: number;
  readonly throughSequence: number;
  readonly context: ContextState;
  readonly conversationContext: ConversationContext;
  readonly workflowExecutionContext: SelectedWorkflowContext | null;
  readonly recentTurns: readonly ContextHistoryFact[];
  /** Exact canonical evidence; no automatic truncation or generated summary. */
  readonly history: readonly ContextHistoryFact[];
}
export interface BootstrapContext extends ContextDocument {
  readonly kind: "BootstrapContext";
}
export interface StatelessContext extends ContextDocument {
  readonly kind: "StatelessContext";
}
export interface DeltaContext extends ContextDocument {
  readonly kind: "DeltaContext";
  readonly fromRevision: number;
  readonly afterSequence: number;
}

export const emptyContextState = (): ContextState => ({
  objective: null,
  importantDecisions: {},
  constraints: {},
  currentState: null,
  openIssues: {},
  artifacts: {},
  workflowState: null,
  summary: null,
});

/** Only committed, versioned Syntila context facts are projected. Never parse worker prose. */
export function projectContextState(
  history: readonly ContextHistoryFact[],
  seed: ContextState = emptyContextState(),
): ContextState {
  const state = structuredClone(seed);
  const records = state as unknown as Record<string, unknown>;
  for (const entry of history) {
    if (entry.kind === "artifact_event" && entry.artifactId) {
      const artifacts = records.artifacts as Record<
        string,
        ContextFact<ContextArtifact | null>
      >;
      artifacts[entry.artifactId] = {
        revision: entry.contextRevision,
        sequence: entry.sequence,
        value:
          entry.eventType === "artifact.removed"
            ? null
            : {
                id: entry.artifactId,
                contentDigest:
                  typeof entry.metadata.contentDigest === "string"
                    ? entry.metadata.contentDigest
                    : null,
              },
      };
    }
    if (
      entry.kind !== "context_event" ||
      entry.actorType !== "syntila" ||
      entry.eventType !== "context.fact_updated"
    )
      continue;
    const { schemaVersion, section, id, value } = entry.metadata;
    if (
      schemaVersion !== 1 ||
      typeof section !== "string" ||
      (value !== null && typeof value !== "string") ||
      ![
        "objective",
        "importantDecisions",
        "constraints",
        "currentState",
        "openIssues",
        "summary",
      ].includes(section)
    ) {
      throw new Error("Invalid committed context fact");
    }
    const fact = {
      revision: entry.contextRevision,
      sequence: entry.sequence,
      value,
    };
    if (["importantDecisions", "constraints", "openIssues"].includes(section)) {
      if (
        typeof id !== "string" ||
        !id ||
        ["__proto__", "constructor", "prototype"].includes(id)
      )
        throw new Error("Invalid context fact identity");
      (records[section] as Record<string, unknown>)[id] = fact;
    } else {
      records[section] = fact;
    }
  }
  return state;
}

const fresh = (
  fact: ContextFact<unknown>,
  revision: number,
  sequence: number,
) => fact.revision > revision || fact.sequence > sequence;
function deltaState(
  state: ContextState,
  revision: number,
  sequence: number,
): ContextState {
  const output = emptyContextState() as unknown as Record<string, unknown>;
  for (const [key, value] of Object.entries(state)) {
    if (
      ["importantDecisions", "constraints", "openIssues", "artifacts"].includes(
        key,
      )
    ) {
      output[key] = Object.fromEntries(
        Object.entries(value as Record<string, ContextFact<unknown>>).filter(
          ([, fact]) => fresh(fact, revision, sequence),
        ),
      );
    } else
      output[key] =
        value && fresh(value as ContextFact<unknown>, revision, sequence)
          ? value
          : null;
  }
  return output as unknown as ContextState;
}

/** Deterministic, provider-independent assembly. Persistence and transitions remain Syntila-owned. */
export class ContextEngine {
  bootstrap(input: ContextEngineInput): BootstrapContext {
    return this.build(input, "BootstrapContext") as BootstrapContext;
  }
  stateless(input: ContextEngineInput): StatelessContext {
    return this.build(input, "StatelessContext") as StatelessContext;
  }
  delta(
    input: ContextEngineInput,
    fromRevision: number,
    afterSequence: number,
    knownWorkerSessionId?: string,
  ): DeltaContext {
    if (
      !Number.isSafeInteger(fromRevision) ||
      fromRevision < 0 ||
      fromRevision > input.contextRevision ||
      !Number.isSafeInteger(afterSequence) ||
      afterSequence < 0 ||
      afterSequence > input.throughSequence
    )
      throw new Error("Invalid context delta cursor");
    const history = input.history.filter(
      (entry) =>
        entry.eventType !== "context.revision_advanced" &&
        (entry.contextRevision > fromRevision ||
          (entry.sequence > afterSequence &&
            (entry.kind === "context_event" ||
              entry.kind === "artifact_event" ||
              entry.contextRevision === 0 ||
              (entry.kind === "worker_response" &&
                entry.metadata.workerSessionId !== knownWorkerSessionId)))),
    );
    // Validate the complete snapshot before selecting a delta.
    this.build(input, "BootstrapContext");
    const document = {
      ...this.build(
        {
          ...input,
          history,
          state: deltaState(input.state, fromRevision, afterSequence),
        },
        "DeltaContext",
      ),
      fromRevision,
      afterSequence,
    } as DeltaContext;
    this.bound(document, input.maxBytes);
    return structuredClone(document);
  }
  private build(
    input: ContextEngineInput,
    kind: ContextDocument["kind"],
  ): ContextDocument {
    if (
      !input.conversationId ||
      !Number.isSafeInteger(input.contextRevision) ||
      input.contextRevision < 0 ||
      !Number.isSafeInteger(input.throughSequence) ||
      input.throughSequence < 0 ||
      input.history.length > 1000
    )
      throw new Error("Invalid canonical context scope");
    let previous = 0;
    for (const entry of input.history) {
      if (
        !Number.isSafeInteger(entry.sequence) ||
        entry.sequence <= previous ||
        entry.sequence > input.throughSequence ||
        !Number.isSafeInteger(entry.contextRevision) ||
        entry.contextRevision < 0 ||
        entry.contextRevision > input.contextRevision
      )
        throw new Error("Invalid canonical context history");
      previous = entry.sequence;
    }
    const facts: ContextFact<unknown>[] = [];
    for (const [key, value] of Object.entries(input.state)) {
      if (
        [
          "importantDecisions",
          "constraints",
          "openIssues",
          "artifacts",
        ].includes(key)
      )
        facts.push(
          ...Object.values(value as Record<string, ContextFact<unknown>>),
        );
      else if (value) facts.push(value as ContextFact<unknown>);
    }
    for (const fact of facts) {
      if (
        !Number.isSafeInteger(fact.revision) ||
        fact.revision < 0 ||
        fact.revision > input.contextRevision ||
        !Number.isSafeInteger(fact.sequence) ||
        fact.sequence < 0 ||
        fact.sequence > input.throughSequence
      )
        throw new Error("Context fact is outside the frozen snapshot");
    }
    const document: ContextDocument = {
      schemaVersion: 1,
      kind,
      conversationId: input.conversationId,
      contextRevision: input.contextRevision,
      throughSequence: input.throughSequence,
      context: structuredClone(input.state),
      conversationContext: (({
        workflowState: _workflowState,
        ...conversation
      }) => structuredClone(conversation))(input.state),
      workflowExecutionContext: input.workflowExecution
        ? selectWorkflowContext(input.workflowExecution)
        : null,
      recentTurns: structuredClone(
        input.history
          .filter(
            (entry) =>
              entry.kind === "user_message" || entry.kind === "worker_response",
          )
          .slice(-20),
      ),
      history: structuredClone(input.history),
    };
    this.bound(document, input.maxBytes);
    return document;
  }
  private bound(document: unknown, maxBytes = 256 * 1024): void {
    if (
      !Number.isSafeInteger(maxBytes) ||
      maxBytes < 1 ||
      new TextEncoder().encode(JSON.stringify(document)).byteLength > maxBytes
    )
      throw new ContextLimitError();
  }
}
