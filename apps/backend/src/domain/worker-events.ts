import { createEventPublisher, type EventPublisherEnv } from "./event-publisher.js";

/**
 * Tells the owner's open pages that one of their Workers changed, so the
 * Workers page updates without a reload. The kind says what changed:
 * `connection` (online/offline), `models` (models or CLI version reported),
 * `updated` (name, enabled, paired, created, removed). The page only needs to
 * re-read the Worker list, so no payload beyond the Worker id travels.
 * A missed signal only delays the page; it never fails the action.
 */
export type WorkerChangeKind = "connection" | "models" | "updated";

export async function publishWorkerChanged(
  env: unknown,
  ownerUserId: string,
  workerId: string,
  kind: WorkerChangeKind,
): Promise<void> {
  try {
    await createEventPublisher(env as EventPublisherEnv).publish({
      type: `worker.instance.${kind}`,
      stream: { kind: "user", id: ownerUserId },
      payload: { entityId: workerId },
    });
  } catch {
    /* see above */
  }
}

/**
 * Pushes a notice to the Worker's connected Agent at once (a new name, "removed",
 * "refresh your models"), so the device does not wait for its next heartbeat.
 * The Agent reads it like a heartbeat answer. An offline Agent simply gets the
 * same facts with its next heartbeat or connection.
 */
export async function notifyWorkerAgent(
  env: unknown,
  workerId: string,
  notice: { workerName?: string; removed?: boolean; refreshModels?: boolean },
): Promise<void> {
  try {
    const gateways = (env as { SYNTILA_WORKER_GATEWAY?: DurableObjectNamespace }).SYNTILA_WORKER_GATEWAY;
    if (!gateways) return;
    await gateways.get(gateways.idFromName(`worker:${workerId}`)).fetch("http://gateway/notice", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(notice),
    });
  } catch {
    /* see above */
  }
}
