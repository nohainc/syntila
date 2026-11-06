import type { StepResult } from "@syntila/core";

/** The tool target accepted with a Chat-with-tool request (`input.toolCall`). */
export interface McpToolStepInput {
  executionWorkspaceId: string;
  serverId: string;
  tool: string;
  toolDefinitionHash: string;
  arguments: Record<string, unknown>;
  timeoutMs: number;
}

/**
 * Strict parse: unknown keys are refused. The Gateway validates the full wire
 * contract again before anything is claimed.
 */
export function parseMcpToolStepInput(value: unknown): McpToolStepInput | null {
  if (typeof value !== "object" || value === null || Array.isArray(value))
    return null;
  const v = value as Record<string, unknown>;
  const keys = new Set([
    "executionWorkspaceId",
    "serverId",
    "tool",
    "toolDefinitionHash",
    "arguments",
    "timeoutMs",
  ]);
  if (Object.keys(v).some((key) => !keys.has(key))) return null;
  const timeoutMs = v.timeoutMs === undefined ? 60_000 : v.timeoutMs;
  if (
    typeof v.executionWorkspaceId !== "string" ||
    v.executionWorkspaceId.length < 1 ||
    v.executionWorkspaceId.length > 128 ||
    typeof v.serverId !== "string" ||
    !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(v.serverId) ||
    typeof v.tool !== "string" ||
    v.tool.length < 1 ||
    v.tool.length > 128 ||
    typeof v.toolDefinitionHash !== "string" ||
    !/^[a-f0-9]{64}$/.test(v.toolDefinitionHash) ||
    typeof v.arguments !== "object" ||
    v.arguments === null ||
    Array.isArray(v.arguments) ||
    typeof timeoutMs !== "number" ||
    !Number.isInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 1_800_000
  )
    return null;
  return {
    executionWorkspaceId: v.executionWorkspaceId,
    serverId: v.serverId,
    tool: v.tool,
    toolDefinitionHash: v.toolDefinitionHash,
    arguments: v.arguments as Record<string, unknown>,
    timeoutMs,
  };
}

export type McpToolStepOutcome = {
  state: "completed" | "toolError" | "rejected" | "unknown";
  code: string;
  result?: Record<string, unknown>;
};

interface McpToolStepEnv {
  readonly SYNTILA_DB: D1Database;
  readonly SYNTILA_WORKSPACE_GATEWAY?: DurableObjectNamespace;
}

/**
 * Runs the tool call through the Workspace's gateway, after re-checking that
 * the Space still has an active grant on that Workspace. Every uncertain path
 * answers `unknown`, which the Workflow never retries.
 */
export async function runMcpToolStep(
  env: McpToolStepEnv,
  scope: { workRequestId: string; taskId: string },
  input: McpToolStepInput,
): Promise<McpToolStepOutcome> {
  const grant = await env.SYNTILA_DB.prepare(
    `SELECT 1 AS ok
       FROM work_requests wr
       JOIN threads t ON t.id = wr.thread_id
       JOIN workspace_space_grants g
         ON g.space_id = t.space_id AND g.workspace_id = ?2
      WHERE wr.id = ?1 AND g.status = 'active'
        AND (g.expires_at IS NULL OR g.expires_at > ?3)`,
  )
    .bind(
      scope.workRequestId,
      input.executionWorkspaceId,
      new Date().toISOString(),
    )
    .first();
  const gateways = env.SYNTILA_WORKSPACE_GATEWAY;
  if (!grant || !gateways)
    return { state: "rejected", code: "workspace_not_granted" };
  let response: Response;
  try {
    response = await gateways
      .get(gateways.idFromName(input.executionWorkspaceId))
      .fetch("https://gateway.internal/mcp-tool-call", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          schemaVersion: 1,
          taskId: scope.taskId,
          dispatchKey: `mcp-tool-v1:${scope.taskId}`,
          serverId: input.serverId,
          tool: input.tool,
          toolDefinitionHash: input.toolDefinitionHash,
          arguments: input.arguments,
          timeoutMs: input.timeoutMs,
        }),
      });
  } catch {
    // The call may have been claimed and sent before the failure.
    return { state: "unknown", code: "gateway_unreachable" };
  }
  // Offline or invalid requests are refused before anything is claimed.
  if (response.status === 503)
    return { state: "rejected", code: "workspace_offline" };
  if (response.status === 400)
    return { state: "rejected", code: "invalid_tool_call" };
  if (!response.ok) return { state: "unknown", code: "gateway_error" };
  const body = (await response.json().catch(() => null)) as {
    state?: unknown;
    code?: unknown;
    result?: Record<string, unknown>;
  } | null;
  const states = ["completed", "toolError", "rejected", "unknown"];
  if (
    !body ||
    typeof body.state !== "string" ||
    !states.includes(body.state) ||
    typeof body.code !== "string"
  )
    return { state: "unknown", code: "invalid_gateway_reply" };
  return {
    state: body.state as McpToolStepOutcome["state"],
    code: body.code,
    ...(body.result ? { result: body.result } : {}),
  };
}

/** The Syntila-owned record of a finished tool step (no Worker involved). */
export function toolStepResult(
  input: McpToolStepInput,
  outcome: McpToolStepOutcome,
  startedAt: string,
): StepResult {
  return {
    text: `Tool ${input.tool} on ${input.serverId}: ${outcome.code}`,
    status: outcome.state === "completed" ? "completed" : "failed",
    startedAt,
    completedAt: new Date().toISOString(),
    workerId: null,
    workerTypeId: null,
    engineVersion: null,
    profileDefinitionId: null,
    profileReleaseVersion: null,
    providerToolVersion: null,
    model: null,
  };
}

const FAILURE_MESSAGES: Record<string, string> = {
  toolError: "The tool reported an error.",
  rejected: "The tool call was not made.",
  unknown:
    "The tool call may have run, but its outcome is unknown. It was not retried.",
};

export function toolStepFailure(outcome: McpToolStepOutcome): string {
  return `${FAILURE_MESSAGES[outcome.state] ?? "The tool call failed."} (${outcome.code})`;
}
