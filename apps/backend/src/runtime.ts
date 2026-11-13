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
import type { PgD1Database } from "./platform/pg-d1";
import { WorkflowHost } from "./platform/workflows";
import worker, { RealtimeGateway, SyntilaRunWorkflow, ThreadExecutionCoordinator, WorkspaceGateway } from "./domain/index";

type Sql = ConstructorParameters<typeof WorkflowHost>[1] & { begin(fn: (tx: any) => Promise<unknown>): Promise<unknown> };

export function createRuntime(sql: Sql, db: PgD1Database, bindings: Record<string, unknown>) {
  installWebSocketGlobals();
  const env: Record<string, unknown> = { SYNTILA_DB: db, ...bindings };
  const getEnv = () => env;
  const workspaceGateway = new DurableObjectNamespaceHost("WorkspaceGateway", sql, (s, e) => new WorkspaceGateway(s as any, e as any) as any, getEnv);
  const realtimeGateway = new DurableObjectNamespaceHost("RealtimeGateway", sql, (s, e) => new RealtimeGateway(s as any, e as any) as any, getEnv);
  const threadCoordinator = new DurableObjectNamespaceHost("ThreadExecutionCoordinator", sql, (s, e) => new ThreadExecutionCoordinator(s as any, e as any) as any, getEnv);
  const runWorkflow = new WorkflowHost("syntila-run", sql, (e) => new SyntilaRunWorkflow({} as any, e as any) as any, getEnv);
  Object.assign(env, {
    SYNTILA_WORKSPACE_GATEWAY: workspaceGateway,
    SYNTILA_REALTIME_GATEWAY: realtimeGateway,
    SYNTILA_THREAD_COORDINATOR: threadCoordinator,
    SYNTILA_RUN_WORKFLOW: runWorkflow.binding(),
  });

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
    hosts: { workspaceGateway, realtimeGateway, threadCoordinator, runWorkflow },
    async start() {
      await Promise.all([workspaceGateway.restoreAlarms(), realtimeGateway.restoreAlarms(), threadCoordinator.restoreAlarms()]);
      runWorkflow.start();
    },
    async stop() {
      await runWorkflow.stop(2_000);
      for (const h of [workspaceGateway, realtimeGateway, threadCoordinator]) { await h.flush(); h.stop(); }
    },
  };
}
