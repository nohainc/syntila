// Full product journey on the Bun runtime: a Worker is created, paired with
// Ed25519 and connects to the Worker Gateway, a user sends a Chat request, the
// Workflow dispatches the assignment over the gateway WebSocket, the fake
// Connect answers, and the answer reaches the Thread over realtime.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { PgDb } from "../src/platform/data";
import { createRuntime } from "../src/runtime";
import { pgD1 } from "./domain/helpers/pg-d1";
import { testTokens } from "./domain/helpers/tokens";
import { validateWorkerProfileCandidate } from "../src/domain/worker-profile-registry";
import { actionMessage, pairingMessage, toBase64Url } from "../src/domain/worker-agents";
import { fixtureStatement } from "./domain/helpers/fixture-sql";

let sql: any, base = "", stop = async () => {}, mint: Awaited<ReturnType<typeof testTokens>>, runtime: Awaited<ReturnType<typeof createRuntime>>;
beforeAll(async () => {
  ({ sql } = await pgD1());
  mint = await testTokens();
  runtime = createRuntime(sql as any, new PgDb(sql), { SYNTILA_ENVIRONMENT: "production", BETTER_AUTH_TRUSTED_ORIGINS: "https://syntila.app" });
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: (r, s) => runtime.fetch(r, s as any), websocket: runtime.websocket as any });
  await runtime.start();
  base = `http://127.0.0.1:${server.port}`;
  stop = async () => { server.stop(true); await runtime.stop(); };
});
afterAll(() => stop());

const api = async (token: string | null, method: string, path: string, body?: unknown) => {
  const headers: Record<string, string> = { "content-type": "application/json", origin: "https://syntila.app", "idempotency-key": crypto.randomUUID() };
  if (token) headers.authorization = `Bearer ${token}`;
  const r = await fetch(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
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
  test("Chat request → Workflow → Worker → answer in the Thread", async () => {
    const web = await mint("dana");
    // Operator step (Profile Lab publication): the released ChatGPT Tool Profile.
    const candidate = JSON.parse(await Bun.file(new URL("../../profile_lab/assets/profiles/chatgpt.json", import.meta.url)).text());
    const profile = await validateWorkerProfileCandidate("chatgpt", candidate);
    await fixtureStatement(runtime.env.SYNTILA_DB, `INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at)
       VALUES ('chatgpt',?1,?2,?3,?4,now()) ON CONFLICT (worker_type_id) DO NOTHING`, [profile.profile.schemaVersion, profile.canonicalJson, candidate.releaseVersion, profile.digest]).run();

    // Create a Worker, pair it with Ed25519, open an Agent session, and connect.
    const created = await api(web, "POST", "/api/workers", { workerTypeId: "chatgpt", name: "Dana's Codex" });
    expect(created.status).toBe(201);
    const workerId: string = created.body.worker.id;
    const pairing = await api(web, "POST", `/api/workers/${workerId}/pairing`, {});
    expect(pairing.status).toBe(201);
    const challenge = pairing.body.challenge;
    const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const publicKey = toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)));
    const sign = async (message: string) =>
      toBase64Url(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, new TextEncoder().encode(message))));
    const claimed = await api(null, "POST", "/api/worker-agent/claim", {
      challengeId: challenge.challengeId,
      secret: challenge.secret,
      publicKey,
      signature: await sign(pairingMessage(challenge.challengeId, workerId, publicKey)),
    });
    expect(claimed.status).toBe(201);
    const nonceRes = await api(null, "POST", "/api/worker-agent/nonce", { workerId });
    expect(nonceRes.status).toBe(200);
    const nonce = nonceRes.body.nonce ?? nonceRes.body;
    const sessionRes = await api(null, "POST", "/api/worker-agent/sessions", {
      workerId,
      nonceId: nonce.nonceId,
      signature: await sign(actionMessage("session", workerId, nonce.nonceId, nonce.nonce)),
      clientVersion: "1.0.0",
    });
    expect(sessionRes.status).toBe(201);
    const session = sessionRes.body.session ?? sessionRes.body;

    const frames: any[] = [];
    const ws = new WebSocket(
      `${base.replace("http", "ws")}/api/worker-agent/gateway?workerId=${encodeURIComponent(workerId)}&workerSessionId=${encodeURIComponent(session.sessionId)}`,
      { headers: { authorization: `Bearer ${session.sessionToken}` } } as any,
    );
    ws.onmessage = (e) => { try { frames.push(JSON.parse(String(e.data))); } catch {} };
    await new Promise<void>((resolve, reject) => { ws.onopen = () => resolve(); ws.onerror = () => reject(new Error("worker gateway socket failed")); });
    let n = 0;
    const send = (type: string, payload: Record<string, unknown>, extra: Record<string, unknown> = {}) => {
      const at = new Date().toISOString();
      ws.send(JSON.stringify({ protocol: "syntila.worker-agent-protocol", protocolVersion: "5.1", messageId: `m-${++n}`, timestamp: at,
        type, executionWorkspaceId: workerId, workspaceRuntimeId: session.sessionId, workerId, payload, ...extra }));
    };
    send("workspace.hello", { capabilities: { customCapabilities: ["assignment.start_permit.v1"] } });
    await waitFor("hello ack", () => frames.find((f) => f.type === "workspace.hello.ack"));

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
    browser.send(JSON.stringify({
      protocol: "syntila.messaging/1",
      requestId: "req-1",
      type: "command",
      command: "subscription.subscribe",
      payload: { stream: { kind: "space", id: spaceId }, cursor: 0 },
    }));
    await waitFor("subscribed", () => live.find((f) => f.type === "subscription.ready"));

    const submit = await api(web, "POST", `/api/threads/${threadId}/work-requests`, {
      workflowId: "chat", objective: "Say hello", workerId,
    });
    expect(submit.status).toBeLessThan(300);
    // Connect runs the assignment and sends the result back.
    const start = await waitFor("assignment.start", () => frames.find((f) => f.type === "assignment.start"));
    const ids = Object.fromEntries(["workerId", "runId", "taskId", "attemptId", "assignmentId", "idempotencyKey"].map((k) => [k, start[k]]));
    send("assignment.ack", { accepted: true }, ids);
    send("assignment.start.permit.request", {}, ids);
    const permit = await waitFor("permit", () => frames.find((f) => f.type === "assignment.start.permit.grant"));
    expect(permit.payload.granted).toBe(true);
    send("assignment.start.ack", { started: true, engineStarted: true, providerStarted: true }, ids);
    send("assignment.result", { status: "completed", summary: "Hello from Connect", output: { text: "Hello from Connect" }, artifactIds: [] }, ids);
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
    expect(history.body.workRequest.workflowRun.stepRuns[0].result).toBe("Hello from Connect");
    // Golden Conversation history of one Chat round trip.
    const entries = await sql`
      SELECT h.sequence::int AS sequence, h.kind, h.event_type AS "eventType", h.actor_type AS "actorType"
        FROM conversation_history_entries h JOIN conversations c ON c.id = h.conversation_id
       WHERE c.thread_id = ${threadId} ORDER BY h.sequence`;
    const e = (kind: string, eventType: string, actorType = "syntila") => ({ kind, eventType, actorType });
    expect(entries.map(({ sequence, ...rest }: { sequence: number }) => rest)).toEqual([
      e("context_event", "context.revision_advanced"),
      e("user_message", "message.user_created", "user"),
      e("workflow_event", "workflow.request_accepted"),
      e("workflow_event", "workflow.step_created"),
      e("workflow_event", "workflow.run_created"),
      e("workflow_event", "workflow.request_status_changed"),
      e("workflow_event", "workflow.run_status_changed"),
      e("execution_event", "execution.created"),
      e("execution_event", "execution.started"),
      e("workflow_event", "workflow.step_status_changed"), // queued → running on provider start
      e("execution_event", "execution.completed"),
      e("worker_response", "message.worker_created", "worker"),
      e("workflow_event", "workflow.step_status_changed"), // running → completed
      e("workflow_event", "workflow.run_status_changed"),
      e("workflow_event", "workflow.request_status_changed"),
    ]);
    expect(entries.map((r: { sequence: number }) => r.sequence)).toEqual(entries.map((_: unknown, i: number) => i + 1));
    // The user's browser saw it live over realtime.
    await waitFor("realtime update", () => live.find((f) => JSON.stringify(f).includes(workRequestId)));
    browser.close();
    ws.close();
  }, 60_000);
});
