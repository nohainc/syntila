// Full product journey on the Bun runtime: a Workspace Service registers and
// connects, a user sends a Chat request, the Workflow dispatches the
// assignment over the gateway WebSocket, the fake Service answers, and the
// answer reaches the Thread over realtime.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { PgD1Database } from "../src/platform/pg-d1";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";
import { testTokens } from "./domain/helpers/tokens";
import { validateWorkerProfileCandidate } from "../src/domain/worker-profile-registry";

let base = "", stop = async () => {}, mint: Awaited<ReturnType<typeof testTokens>>, runtime: ReturnType<typeof createRuntime>;
beforeAll(async () => {
  const { sql } = pgD1();
  mint = await testTokens();
  runtime = createRuntime(sql as any, new PgD1Database(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const api = async (token: string, method: string, path: string, body?: unknown) => {
  const r = await fetch(base + path, { method, headers: { authorization: `Bearer ${token}`, "content-type": "application/json", origin: "https://syntila.app", "idempotency-key": crypto.randomUUID() }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await r.text();
  let parsed: any = text;
  try { parsed = text ? JSON.parse(text) : null; } catch {}
  return { status: r.status, body: parsed };
};
const waitFor = async <T>(what: string, probe: () => T | undefined | Promise<T | undefined>, ms = 15_000): Promise<T> => {
  const until = Date.now() + ms;
  while (Date.now() < until) { const v = await probe(); if (v) return v; await Bun.sleep(25); }
  throw new Error(`timed out waiting for ${what}`);
};

describe("journey", () => {
  test("Chat request → Workflow → Workspace → answer in the Thread", async () => {
    const desktop = await mint("dana", { client: "desktop", client_aud: "syntila.desktop.management" });
    const web = await mint("dana");
    const reg = await api(desktop, "POST", "/api/workspace-runtime/register", {
      contractVersion: "1.0", installationId: `install_${crypto.randomUUID()}`, proposedWorkspaceName: "Dana's Mac",
      hostname: "danas-mac", platform: "macos", architecture: "arm64", appVersion: "1.0.0",
      runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.0.0", supportedRuntimes: ["cli"], maxConcurrentWorkers: 2 },
    });
    expect(reg.status).toBeLessThan(300);
    const runtimeId: string = reg.body.workspaceRuntimeId;
    const workspaceId: string = reg.body.workspaceId ?? reg.body.executionWorkspaceId;

    const frames: any[] = [];
    const ws = new WebSocket(`${base.replace("http", "ws")}/api/workspace-gateway/connect?workspaceRuntimeId=${encodeURIComponent(runtimeId)}`, { headers: { authorization: `Bearer ${reg.body.runtimeCredential}` } } as any);
    ws.onmessage = (e) => { try { frames.push(JSON.parse(String(e.data))); } catch {} };
    await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("gateway socket failed")); });
    let n = 0;
    const send = (type: string, payload: Record<string, unknown>, extra: Record<string, unknown> = {}) => {
      const at = new Date().toISOString();
      ws.send(JSON.stringify({ protocol: "syntila.workspace-runtime-protocol", protocolVersion: "5.1", messageId: `m-${++n}`, timestamp: at,
        type, executionWorkspaceId: workspaceId, workspaceRuntimeId: runtimeId, payload, ...extra }));
    };
    // Operator step (Profile Lab publication): the released ChatGPT Tool Profile.
    const candidate = JSON.parse(await Bun.file(new URL("../../profile_lab/assets/profiles/chatgpt.json", import.meta.url)).text());
    const profile = await validateWorkerProfileCandidate("chatgpt", candidate);
    await runtime.env.SYNTILA_DB.prepare(
      `INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at)
       VALUES ('chatgpt',?1,?2,?3,?4,now()) ON CONFLICT (worker_type_id) DO NOTHING`,
    ).bind(profile.profile.schemaVersion, profile.canonicalJson, candidate.releaseVersion, profile.digest).run();
    const worker = {
      workerId: "worker-codex", workerTypeId: "chatgpt", activationState: "enabled", readinessState: "ready", revision: 1,
      localConcurrencyLimit: 1, engineVersion: "1.4.0", profileDefinitionId: "chatgpt-codex", profileReleaseVersion: candidate.releaseVersion,
      providerToolName: "Codex CLI", providerToolVersion: "1.0.0",
      modelCatalog: {
        schemaVersion: 2, profileDigest: profile.digest, providerToolVersion: "1.0.0", catalogRevision: "b".repeat(64),
        discoveredAt: new Date().toISOString(),
        models: [{ id: "gpt-5", name: "GPT-5", status: "verified", selectionMode: "separate", efforts: ["medium"], defaultEffort: "medium" }],
      },
      createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), lastSeenAt: new Date().toISOString(),
    };
    send("workspace.hello", { capabilities: { customCapabilities: ["assignment.start_permit.v1"] } });
    await waitFor("hello ack", () => frames.find((f) => f.type === "workspace.hello.ack"));
    send("worker.inventory", { fullSnapshot: true, workers: [worker] });
    send("workspace.sync.request", {});
    const sync = await waitFor("sync result", () => frames.find((f) => f.type === "workspace.sync.result"));
    send("workspace.readiness", { state: "ready", readyForAssignments: true, syncGeneration: sync.payload.syncGeneration ?? 1 });
    await waitFor("inventory", async () => (await runtime.env.SYNTILA_DB.prepare("SELECT 1 AS ok FROM workspace_worker_inventory WHERE worker_id=?1").bind("worker-codex").first()) ?? undefined);

    // The user picks this Workspace for Workflows: grants it and enables its Workers.
    const pick = await api(web, "PUT", "/api/user/workflow-workspace", { workspaceId });
    const space = await api(web, "POST", "/api/spaces", { name: "Journey" });
    expect(space.status).toBe(201);
    const spaceId = space.body.space.id;
    const threads = await api(web, "GET", `/api/spaces/${spaceId}/threads`);
    let threadId = threads.body.threads?.[0]?.id;
    if (!threadId) {
      const t = await api(web, "POST", `/api/spaces/${spaceId}/threads`, { name: "General" });
      expect(t.status).toBeLessThan(300);
      threadId = t.body.thread?.id ?? t.body.id;
    }
    const live: any[] = [];
    const ticket = (await api(web, "POST", "/api/realtime/tickets")).body.ticket;
    const browser = new WebSocket(`${base.replace("http", "ws")}/api/realtime?ticket=${ticket}`, { headers: { origin: "https://syntila.app" } } as any);
    browser.onmessage = (e) => live.push(JSON.parse(String(e.data)));
    await waitFor("realtime ready", () => live.find((f) => f.type === "realtime.ready"));
    browser.send(JSON.stringify({ type: "subscribe", scope: { kind: "space", spaceId } }));
    await waitFor("subscribed", () => live.find((f) => f.type === "subscription.confirmed"));
    const pickSpace = await api(web, "PUT", `/api/spaces/${spaceId}/workflow-workspace`, { workspaceId, confirmReset: true });
    expect(pickSpace.status).toBe(200);
    const submit = await api(web, "POST", `/api/threads/${threadId}/work-requests`, {
      workflowId: "chat", objective: "Say hello", executionSelection: { workerId: "worker-codex" },
    });
    expect(submit.status).toBeLessThan(300);
    // The Service runs the assignment the way the desktop Workspace does.
    const start = await waitFor("assignment.start", () => frames.find((f) => f.type === "assignment.start"));
    const ids = Object.fromEntries(["workerId", "runId", "taskId", "attemptId", "assignmentId", "idempotencyKey"].map((k) => [k, start[k]]));
    send("assignment.ack", { accepted: true }, ids);
    send("assignment.start.permit.request", {}, ids);
    const permit = await waitFor("permit", () => frames.find((f) => f.type === "assignment.start.permit.grant"));
    expect(permit.payload.granted).toBe(true);
    send("assignment.start.ack", {}, ids);
    send("assignment.result", { status: "completed", summary: "Hello from the Workspace", output: { text: "Hello from the Workspace" }, artifactIds: [] }, ids);
    const terminal = await waitFor("terminal ack", () => frames.find((f) => f.type === "assignment.ack" && f.payload?.terminal === true));
    expect(terminal.assignmentId).toBe(start.assignmentId);

    // The Workflow completes the Work Request and the answer lands in the Thread.
    const workRequestId = submit.body.workRequest.id;
    const done = await waitFor("work request completed", async () => {
      const r = await api(web, "GET", `/api/work-requests/${workRequestId}`);
      return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status) ? r.body.workRequest : undefined;
    }, 30_000);
    expect(done.status).toBe("completed");
    const history = await api(web, "GET", `/api/work-requests/${workRequestId}`);
    expect(history.body.workRequest.workflowRun.stepRuns[0].result).toBe("Hello from the Workspace");
    // The user's browser saw it live over realtime.
    await waitFor("realtime update", () => live.find((f) => JSON.stringify(f).includes(workRequestId)));
    browser.close();
    ws.close();
  }, 60_000);
});
