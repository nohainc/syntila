import {
  ContextEngine,
  ContextLimitError,
  emptyContextState,
  projectContextState,
  type ContextHistoryFact,
  type ContextWorkflowState,
  type WorkflowExecutionContext,
} from "@syntila/core";
/** Transport budget for one bootstrap, not a model context limit: the
 * Worker's CLI reports a real overflow itself. Older history that does not
 * fit is left out instead of failing the turn. */
const MAX_BOOTSTRAP_ENTRIES = 1000;
const MAX_BOOTSTRAP_BYTES = 256 * 1024;

/** Syntila canonical history only. This contains no provider-native state. */
export interface ConversationBootstrap {
  readonly schemaVersion: 1;
  readonly conversationId: string;
  readonly contextRevision: number;
  readonly throughSequence: number;
  readonly text: string;
  readonly turnRevision: number;
}

export async function loadConversationBootstrap(
  db: D1Database,
  conversationId: string,
  workRequestId: string,
  contextRevision: number,
  mode: "bootstrap" | "stateless" = "bootstrap",
  activeStepId?: string,
): Promise<ConversationBootstrap> {
  // Freeze a high-water mark at dispatch, including late results from older
  // requests while excluding the current and future accepted requests.
  const boundary = await db
    .prepare(
      `SELECT conversation_revision AS revision FROM conversation_work_requests
    WHERE conversation_id = ?1 AND work_request_id = ?2`,
    )
    .bind(conversationId, workRequestId)
    .first<{ revision: number }>();
  if (!boundary)
    throw new Error("Canonical Conversation request boundary is missing");
  if (contextRevision !== boundary.revision - 1)
    throw new Error("Canonical context revision does not match this turn");
  const highWater = await db
    .prepare(
      `SELECT COALESCE(MAX(sequence),0) AS sequence FROM conversation_history_entries WHERE conversation_id = ?1`,
    )
    .bind(conversationId)
    .first<{ sequence: number }>();
  const throughSequence = highWater?.sequence ?? 0;
  // A cleared AI History leaves its exchanges readable but out of context.
  const floor = await db
    .prepare(
      "SELECT context_floor_sequence AS floor FROM conversations WHERE id = ?1",
    )
    .bind(conversationId)
    .first<{ floor: number }>();
  const floorSequence = floor?.floor ?? 0;
  const result = await db
    .prepare(
      `SELECT sequence, kind, event_type AS eventType, actor_type AS actorType,
    actor_id AS actorId, text, source_id AS sourceId, artifact_id AS artifactId, metadata_json AS metadataJson,
    COALESCE((SELECT cr.conversation_revision FROM conversation_work_requests cr WHERE cr.work_request_id = h.work_request_id AND cr.conversation_id = h.conversation_id),0) AS contextRevision
    FROM conversation_history_entries h
    WHERE conversation_id = ?1 AND sequence <= ?2 AND sequence > ?4 AND (h.work_request_id IS NULL OR EXISTS
      (SELECT 1 FROM conversation_work_requests cr WHERE cr.conversation_id = h.conversation_id AND cr.work_request_id = h.work_request_id AND cr.conversation_revision <= ?3 AND EXISTS
          (SELECT 1 FROM work_requests wr JOIN threads t ON t.id = wr.thread_id
           WHERE wr.id = cr.work_request_id AND wr.ai_context_generation = t.ai_context_generation)))
    ORDER BY sequence DESC LIMIT ?5`,
    )
    .bind(
      conversationId,
      throughSequence,
      contextRevision,
      floorSequence,
      MAX_BOOTSTRAP_ENTRIES,
    )
    .all<{
      sequence: number;
      contextRevision: number;
      kind: string;
      eventType: string;
      actorType: string;
      actorId: string | null;
      text: string | null;
      metadataJson: string;
    }>();
  // Newest first: keep the most recent entries that fit the byte budget.
  const encoder = new TextEncoder();
  const entries: NonNullable<typeof result.results> = [];
  let entryBytes = 0;
  for (const entry of result.results ?? []) {
    entryBytes +=
      encoder.encode(entry.text ?? "").byteLength +
      encoder.encode(entry.metadataJson).byteLength;
    if (entryBytes > MAX_BOOTSTRAP_BYTES) break;
    entries.unshift(entry);
  }
  const history = entries.map(({ metadataJson, ...entry }) => ({
    ...entry,
    metadata: JSON.parse(metadataJson) as Record<string, unknown>,
  })) as ContextHistoryFact[];
  const current = await db
    .prepare(
      `SELECT wr.workflow_id AS workflowId, wr.workflow_version AS workflowVersion,
    wfr.id AS workflowRunId, wr.status, wr.snapshot_json AS snapshotJson, ws.space_id AS spaceId, wr.thread_id AS threadId, wr.primary_workspace_id AS workspaceId FROM work_requests wr
    JOIN conversation_workflow_runs wfr ON wfr.work_request_id = wr.id
    JOIN threads ws ON ws.id = wr.thread_id
    JOIN conversation_work_requests cr ON cr.work_request_id = wr.id WHERE cr.conversation_id = ?1 AND wr.id = ?2`,
    )
    .bind(conversationId, workRequestId)
    .first<{
      workflowRunId: string;
      workflowId: string;
      workflowVersion: number;
      status: string;
      snapshotJson: string;
      spaceId: string;
      threadId: string;
      workspaceId: string | null;
    }>();
  if (!current) throw new Error("Conversation workflow state is missing");
  const tasks = await db
    .prepare(
      `SELECT t.id, t.step_kind AS kind, t.status, t.attempt, t.output_json AS outputJson,
      s.id AS workflowStepRunId,s.role,
      (SELECT worker_id FROM conversation_turns WHERE workflow_step_run_id=s.id ORDER BY rowid DESC LIMIT 1) AS actualWorkerId
      FROM workflow_tasks t JOIN conversation_workflow_step_runs s ON s.task_id=t.id WHERE t.work_request_id = ?1 ORDER BY t.id LIMIT 1001`,
    )
    .bind(workRequestId)
    .all<
      ContextWorkflowState["steps"][number] & {
        outputJson: string | null;
        actualWorkerId: string | null;
        workflowStepRunId: string;
        role: string;
      }
    >();
  if ((tasks.results?.length ?? 0) > 1000)
    throw new Error("Workflow context exceeds the step limit");
  const snapshot = JSON.parse(current.snapshotJson) as Record<string, unknown>;
  const fact = <T>(value: T) => ({
    revision: contextRevision,
    sequence: throughSequence,
    value,
  });
  const seed = {
    ...emptyContextState(),
    objective:
      typeof snapshot.originalRequest === "string"
        ? fact(snapshot.originalRequest)
        : null,
    constraints: Object.fromEntries(
      ["spaceInstructions", "threadInstructions"].flatMap((key) =>
        typeof snapshot[key] === "string" && snapshot[key]
          ? [[key, fact(snapshot[key] as string)]]
          : [],
      ),
    ),
    currentState: fact(current.status),
    workflowState: fact({
      workflowId: current.workflowId,
      workflowVersion: current.workflowVersion,
      workRequestId,
      status: current.status,
      steps: (tasks.results ?? []).map(
        ({ outputJson: _output, actualWorkerId: _worker, ...step }) => step,
      ),
    }),
  };
  const dependencies = await db
    .prepare(
      `SELECT d.task_id AS taskId, d.depends_on_task_id AS dependencyId
    FROM workflow_task_dependencies d JOIN workflow_tasks t ON t.id = d.task_id WHERE t.work_request_id = ?1 LIMIT 10001`,
    )
    .bind(workRequestId)
    .all<{ taskId: string; dependencyId: string }>();
  if ((dependencies.results?.length ?? 0) > 10000)
    throw new Error("Workflow dependency limit exceeded");
  const taskRows = tasks.results ?? [];
  if (activeStepId && !taskRows.some((step) => step.id === activeStepId))
    throw new Error("Receiving Workflow step is outside this request");
  const selectedStepId =
    activeStepId ?? (taskRows.length === 1 ? taskRows[0]!.id : undefined);
  const artifacts = await db
    .prepare(
      `SELECT id, content_digest AS contentDigest FROM artifacts WHERE work_request_id = ?1 AND space_id = ?2 ORDER BY id LIMIT 1001`,
    )
    .bind(workRequestId, current.spaceId)
    .all<{ id: string; contentDigest: string }>();
  if ((artifacts.results?.length ?? 0) > 1000)
    throw new Error("Workflow artifact limit exceeded");
  const bindings = snapshot.resolvedBindings as
    Record<string, { workerId?: string }> | undefined;
  const workflowExecution: WorkflowExecutionContext | undefined = selectedStepId
    ? {
        schemaVersion: 1,
        workflowRunId: current.workflowRunId,
        workflowId: current.workflowId,
        workflowVersion: current.workflowVersion,
        workRequestId,
        status: current.status,
        activeStepId: selectedStepId,
        steps: taskRows.map(({ outputJson, actualWorkerId, ...step }) => {
          const output = outputJson
            ? (JSON.parse(outputJson) as Record<string, unknown>)
            : null;
          const nested = output?.output as { text?: unknown } | undefined;
          return {
            ...step,
            workerId:
              actualWorkerId ??
              (typeof output?.workerId === "string"
                ? output.workerId
                : (bindings?.[
                    current.workflowId === "direct" ? "direct" : step.kind
                  ]?.workerId ?? null)),
            dependsOn: (dependencies.results ?? [])
              .filter((d) => d.taskId === step.id)
              .map((d) => d.dependencyId),
            result:
              step.status === "completed"
                ? typeof output?.text === "string"
                  ? output.text
                  : typeof nested?.text === "string"
                    ? nested.text
                    : null
                : null,
          };
        }),
        environment:
          current.workflowId === "chat"
            ? null
            : {
                spaceId: current.spaceId,
                threadId: current.threadId,
                workspaceId: current.workspaceId,
                spaceInstructions:
                  typeof snapshot.spaceInstructions === "string"
                    ? snapshot.spaceInstructions
                    : "",
                threadInstructions:
                  typeof snapshot.threadInstructions === "string"
                    ? snapshot.threadInstructions
                    : "",
              },
        artifacts:
          current.workflowId === "chat" ? [] : (artifacts.results ?? []),
      }
    : undefined;
  const engine = new ContextEngine();
  // The engine refuses a document over the budget (recent turns repeat the
  // newest history): null means it did not fit.
  const render = (facts: ContextHistoryFact[]) => {
    const input = {
      conversationId,
      contextRevision,
      throughSequence,
      history: facts,
      state: projectContextState(facts, seed),
      workflowExecution,
      maxBytes: MAX_BOOTSTRAP_BYTES,
    };
    try {
      return JSON.stringify(
        mode === "stateless"
          ? engine.stateless(input)
          : engine.bootstrap(input),
      );
    } catch (error) {
      if (error instanceof ContextLimitError) return null;
      throw error;
    }
  };
  // Drop the oldest half of the history until the context fits. Only the
  // current Workflow's own state can still be too large on its own.
  let kept = history;
  let text = render(kept);
  while (text === null && kept.length > 0) {
    kept = kept.slice(Math.ceil(kept.length / 2));
    text = render(kept);
  }
  if (text === null)
    throw new ContextLimitError(
      "Conversation bootstrap exceeds the byte limit",
    );
  return {
    schemaVersion: 1,
    conversationId,
    contextRevision,
    throughSequence,
    text,
    turnRevision: boundary.revision,
  };
}
