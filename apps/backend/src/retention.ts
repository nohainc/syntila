import type { Db } from "./db";

/**
 * Daily retention for operational tables that only ever grow. Domain data
 * with its own retention rules (realtime events, worker activity, issue
 * reports, orphan files) is pruned by the domain's scheduled handler.
 *
 * Deletes run in bounded batches so a large backlog never holds one long
 * transaction or a long lock.
 */
export const RETENTION = {
  /** Sent or failed email; pending rows are never deleted. */
  emailOutboxDays: 30,
  /** Idempotency receipts: a client retries within minutes, never weeks. */
  mutationReceiptDays: 30,
  /** Finished workflow instances with their steps and events (cascade). */
  finishedWorkflowDays: 90,
} as const;

const BATCH = 5000;
const MAX_BATCHES = 200;

export async function pruneOperationalTables(db: Db, now = new Date()): Promise<Record<string, number>> {
  const cutoff = (days: number) => new Date(now.getTime() - days * 86_400_000);
  return {
    email_outbox: await batched(db,
      `DELETE FROM email_outbox WHERE id IN (
         SELECT id FROM email_outbox WHERE status <> 'pending' AND created_at < $1 LIMIT ${BATCH})`,
      cutoff(RETENTION.emailOutboxDays)),
    mutation_receipts: await batched(db,
      `DELETE FROM mutation_receipts WHERE (user_id, scope, idempotency_key) IN (
         SELECT user_id, scope, idempotency_key FROM mutation_receipts WHERE created_at < $1 LIMIT ${BATCH})`,
      cutoff(RETENTION.mutationReceiptDays)),
    workflow_instances: await batched(db,
      `DELETE FROM workflow_instances WHERE id IN (
         SELECT id FROM workflow_instances
         WHERE status IN ('complete', 'errored', 'terminated') AND updated_at < $1 LIMIT ${BATCH})`,
      cutoff(RETENTION.finishedWorkflowDays)),
  };
}

async function batched(db: Db, statement: string, before: Date): Promise<number> {
  let total = 0;
  for (let i = 0; i < MAX_BATCHES; i++) {
    const result: any = await db.unsafe(statement, [before]);
    const count = Number(result?.count ?? 0);
    total += count;
    if (count < BATCH) break;
  }
  return total;
}
