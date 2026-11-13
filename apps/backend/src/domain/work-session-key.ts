import { createHash } from "node:crypto";

export function workStepSessionKey(params: {
  readonly workBindingId?: string;
  readonly threadId: string;
  readonly workRequestId: string;
  readonly stepKind: string;
  readonly retryStepKind?: unknown;
  readonly retrySessionStrategy?: unknown;
  readonly retryNumber?: unknown;
  readonly workSessionGeneration?: number;
}): string {
  // Chat and Work share the Thread Conversation and therefore one native
  // Worker Session key: the same Worker/Profile resumes its session across
  // workflows, and any other Worker starts from the pushed canonical history.
  // Read-only/write permissions are applied per execution, not per session.
  const threadScoped =
    params.workBindingId === "direct" || params.workBindingId === "chat";
  const base = threadScoped
    ? `thread:${params.threadId}:conversation${params.workSessionGeneration ? `:gen-${params.workSessionGeneration}` : ""}`
    : `work-request:${params.workRequestId}:${params.stepKind}`;
  // A fresh retry of the Thread's own Work conversation bumps the Thread's
  // session generation instead (see handleRetryWorkRequest), so later requests
  // keep using the new session. Other scopes isolate the retry by suffix.
  const identity =
    params.retryStepKind === params.stepKind &&
    params.retrySessionStrategy === "fresh" &&
    params.workBindingId !== "direct" &&
    !(params.workBindingId === "chat" && params.workSessionGeneration)
      ? `${base}:retry-fresh-${Number(params.retryNumber) || 1}`
      : base;
  return `work-session-${createHash("sha256").update(identity).digest("hex")}`;
}
