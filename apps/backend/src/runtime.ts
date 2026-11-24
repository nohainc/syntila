import { handleInternal, isInternalPath } from "./internal";
import { identityVerifier } from "./domain/auth/identity-service";
/**
 * Wires the ported domain to the in-process platform: PostgreSQL-backed
 * Durable Objects and Workflows, background tasks, and Bun WebSocket upgrades.
 * Used by the server and by integration tests.
 */
import type { Server } from "bun";
import { executionContext } from "./platform/background";
import {
  DurableObjectNamespaceHost,
  hostedWebSocketHandlers,
  installWebSocketGlobals,
  upgradeContext,
  type UpgradeData,
} from "./platform/durable-objects";
import { Data, type Db } from "./platform/data";
import { WorkflowHost } from "./platform/workflows";
import { OutboxDispatcher } from "./domain/outbox-dispatcher";
import worker, { RealtimeGateway, SyntilaRunWorkflow, ThreadExecutionCoordinator, WorkerGateway } from "./domain/index";

type Sql = ConstructorParameters<typeof WorkflowHost>[1] & { begin(fn: (tx: any) => Promise<unknown>): Promise<unknown> };

export function createRuntime(sql: Sql, db: Db, bindings: Record<string, unknown>) {
  installWebSocketGlobals();
  // SYNTILA_DATA: the data layer that replaces the adapter module by module.
  const env: Record<string, unknown> = { SYNTILA_DB: db, SYNTILA_DATA: new Data(db.sql as any), ...bindings };
  const getEnv = () => env;
  const workerGateway = new DurableObjectNamespaceHost("WorkerGateway", sql, (s, e) => new WorkerGateway(s as any, e as any) as any, getEnv);
  const realtimeGateway = new DurableObjectNamespaceHost("RealtimeGateway", sql, (s, e) => new RealtimeGateway(s as any, e as any) as any, getEnv);
  const threadCoordinator = new DurableObjectNamespaceHost("ThreadExecutionCoordinator", sql, (s, e) => new ThreadExecutionCoordinator(s as any, e as any) as any, getEnv);
  const runWorkflow = new WorkflowHost("syntila-run", sql, (e) => new SyntilaRunWorkflow({} as any, e as any) as any, getEnv);
  Object.assign(env, {
    SYNTILA_WORKER_GATEWAY: workerGateway,
    SYNTILA_REALTIME_GATEWAY: realtimeGateway,
    SYNTILA_THREAD_COORDINATOR: threadCoordinator,
    SYNTILA_RUN_WORKFLOW: runWorkflow.binding(),
  });

  // Delivers durable events the committing process did not finish (ADR-033).
  const outbox = new OutboxDispatcher(env as never);

  /** Runs the domain worker; a 101 from a Durable Object becomes a Bun upgrade. */
  async function fetch(request: Request, server: Server<UpgradeData>): Promise<Response | undefined> {
    if (isInternalPath(new URL(request.url).pathname)) return handleInternal(request, env as any, identityVerifier());
    const scope = { pairs: [] as { client: unknown; server: any }[] };
    const response = await upgradeContext.run(scope as any, () => worker.fetch(request as any, env as any, executionContext()));
    if (response.status !== 101) return response;
    const pair = scope.pairs.at(-1);
    if (!pair) return new Response("Upgrade failed", { status: 500 });
    const protocol = request.headers.get("sec-websocket-protocol")?.split(",")[0]?.trim();
    const ok = server.upgrade(request, { data: { hosted: pair.server }, headers: protocol ? { "Sec-WebSocket-Protocol": protocol } : undefined });
    if (ok) return undefined;
    pair.server.close(1011, "upgrade failed");
    return new Response("Expected WebSocket upgrade", { status: 426 });
  }

  return {
    env: env as unknown as Env,
    fetch,
    websocket: {
      ...hostedWebSocketHandlers,
      idleTimeout: 120,
      maxPayloadLength: 16 * 1024 * 1024,
      backpressureLimit: 8 * 1024 * 1024,
      sendPings: true,
    },
    hosts: { workerGateway, realtimeGateway, threadCoordinator, runWorkflow },
    outbox,
    async start() {
      await Promise.all([workerGateway.restoreAlarms(), realtimeGateway.restoreAlarms(), threadCoordinator.restoreAlarms()]);
      runWorkflow.start();
      outbox.start();
    },
    async stop() {
      await outbox.stop();
      await runWorkflow.stop(2_000);
      for (const h of [workerGateway, realtimeGateway, threadCoordinator]) { await h.flush(); h.stop(); }
    },
  };
}
