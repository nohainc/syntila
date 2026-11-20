import type { Query } from "../platform/data.js";
import { isFeatureEnabled } from "../feature-flags.js";

/**
 * Canonical timeline items for Work (ADR-036). Both are idempotent in the
 * database (one `ai_request` and one `ai_answer` per Work Request), so a
 * replay, a retry or a second finisher cannot add a duplicate. They run inside
 * the transaction that creates or finishes the Work Request and do nothing
 * until the `canonical_timeline` flag is on.
 */
export async function recordAiRequest(tx: Query, workRequestId: string): Promise<void> {
  if (!isFeatureEnabled("canonical_timeline")) return;
  await tx.row`SELECT record_ai_request(${workRequestId})`;
}

export async function recordAiAnswer(tx: Query, workRequestId: string): Promise<void> {
  if (!isFeatureEnabled("canonical_timeline")) return;
  await tx.row`SELECT record_ai_answer(${workRequestId})`;
}

/** The ended-without-answer item of a failed or cancelled Work Request (a no-op for any other status). */
export async function recordAiOutcome(tx: Pick<Query, "run">, workRequestId: string): Promise<void> {
  if (!isFeatureEnabled("canonical_timeline")) return;
  await tx.run`SELECT record_ai_outcome(${workRequestId})`;
}

/** A retry re-queues the request, so its earlier outcome item no longer describes it. */
export async function clearAiOutcome(tx: Pick<Query, "run">, workRequestId: string): Promise<void> {
  if (!isFeatureEnabled("canonical_timeline")) return;
  await tx.run`SELECT record_ai_outcome_clear(${workRequestId})`;
}
