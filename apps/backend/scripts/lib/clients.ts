// Shared clients for the operational scripts (smoke, resilience, load).
// They talk to a running backend exactly like the real apps do: JWTs from the
// auth Worker, REST under /api, browser realtime with a single-use ticket, and
// a Workspace Service on the runtime protocol over the gateway WebSocket.
import { signToken } from "../../src/auth";

export type Jwk = JsonWebKey & { kid: string };
export const sleep = (ms: number) => Bun.sleep(ms);

export async function waitFor<T>(what: string, probe: () => T | undefined | null | false | Promise<T | undefined | null | false>, ms = 15_000): Promise<T> {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    const value = await probe();
    if (value) return value;
    await sleep(25);
  }
  throw new Error(`timed out waiting for ${what}`);
}

export function tokenMinter(jwk: Jwk) {
  const iss = process.env.AUTH_JWT_ISSUER || "https://syntila.app";
  const aud = process.env.AUTH_JWT_AUDIENCE || "syntila-backend";
  return (sub: string, extra: Record<string, unknown> = {}, ttl = 900) => {
    const now = Math.floor(Date.now() / 1000);
    return signToken(jwk, { iss, aud, sub, typ: "user", email: `${sub}@syntila.invalid`, name: sub, iat: now, exp: now + ttl, sid: `s-${sub}-${now}`, client: "web", ...extra });
  };
}

const ORIGIN = (process.env.ALLOWED_ORIGINS ?? "https://syntila.app").split(",")[0]!.trim();

export class User {
  constructor(readonly base: string, readonly token: string) {}

  async api(method: string, path: string, body?: unknown, headers: Record<string, string> = {}) {
    const response = await fetch(this.base + path, {
      method,
      headers: { authorization: `Bearer ${this.token}`, "content-type": "application/json", origin: ORIGIN, "idempotency-key": crypto.randomUUID(), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let parsed: any = text;
    try { parsed = text ? JSON.parse(text) : null; } catch { /* plain text */ }
    return { status: response.status, body: parsed };
  }

  /** Creates a Space and returns it with a Thread to talk in. */
  async spaceWithThread(name: string) {
    const created = await this.api("POST", "/api/spaces", { name });
    if (created.status !== 201) throw new Error(`create space: ${created.status} ${JSON.stringify(created.body)}`);
    const spaceId: string = created.body.space.id;
    const listed = await this.api("GET", `/api/spaces/${spaceId}/threads`);
    let threadId: string | undefined = listed.body?.threads?.[0]?.id;
    if (!threadId) {
      const thread = await this.api("POST", `/api/spaces/${spaceId}/threads`, { name: "General" });
      threadId = thread.body?.thread?.id ?? thread.body?.id;
    }
    if (!threadId) throw new Error("no thread");
    return { spaceId, threadId };
  }

  /** Browser realtime connection that reconnects with a fresh ticket. */
  realtime(subscribeTo: string[]) {
    const state = { frames: [] as any[], opens: 0, closes: [] as number[], socket: null as WebSocket | null, stopped: false };
    const connect = async () => {
      if (state.stopped) return;
      const ticket = await this.api("POST", "/api/realtime/tickets").catch(() => null);
      if (!ticket || ticket.status !== 200) { setTimeout(connect, 500); return; }
      const ws = new WebSocket(`${this.base.replace(/^http/, "ws")}/api/realtime?ticket=${ticket.body.ticket}`, { headers: { origin: ORIGIN } } as any);
      state.socket = ws;
      ws.onmessage = (event) => {
        const frame = JSON.parse(String(event.data));
        state.frames.push(frame);
        if (frame.type === "realtime.ready") {
          state.opens++;
          for (const spaceId of subscribeTo) ws.send(JSON.stringify({ type: "subscribe", scope: { kind: "space", spaceId } }));
        }
      };
      ws.onclose = (event) => { state.closes.push(event.code); if (!state.stopped) setTimeout(connect, 250 + Math.random() * 250); };
      ws.onerror = () => {};
    };
    void connect();
    return {
      state,
      waitFor: (what: string, predicate: (frame: any) => boolean, ms?: number) => waitFor(what, () => state.frames.find(predicate), ms),
      close() { state.stopped = true; state.socket?.close(); },
    };
  }
}

export type AssignmentHandler = (start: any, ws: FakeWorkspace) => Promise<void> | void;

/**
 * A Workspace Service: registers with a desktop token, keeps one ChatGPT
 * Worker in inventory, reconnects after restarts and answers assignments.
 */
export class FakeWorkspace {
  frames: any[] = [];
  opens = 0;
  closes: number[] = [];
  runtimeId = "";
  workspaceId = "";
  private credential = "";
  private installationId = `install_${crypto.randomUUID()}`;
  private socket: WebSocket | null = null;
  private counter = 0;
  private stopped = false;
  ready = false;

  constructor(readonly base: string, readonly profile: { digest: string; releaseVersion: number } | null, readonly onAssignment: AssignmentHandler = completeWith("pong")) {}

  async register(desktopToken: string, name: string) {
    const response = await fetch(`${this.base}/api/workspace-runtime/register`, {
      method: "POST",
      headers: { authorization: `Bearer ${desktopToken}`, "content-type": "application/json" },
      body: JSON.stringify({
        contractVersion: "1.0", installationId: this.installationId, proposedWorkspaceName: name,
        hostname: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"), platform: "macos", architecture: "arm64", appVersion: "1.0.0",
        runtimeCapabilities: { os: "macos", arch: "arm64", appVersion: "1.0.0", supportedRuntimes: ["cli"], maxConcurrentWorkers: 2 },
      }),
    });
    const body = (await response.json()) as any;
    if (response.status >= 300) throw new Error(`register workspace: ${response.status} ${JSON.stringify(body)}`);
    this.runtimeId = body.workspaceRuntimeId;
    this.workspaceId = body.workspaceId ?? body.executionWorkspaceId;
    this.credential = body.runtimeCredential;
    return this;
  }

  /** Releases the registration (removes its Workers) — script cleanup. */
  async release(desktopToken: string) {
    this.stop();
    // Release is refused while the runtime still looks connected.
    for (let attempt = 0; attempt < 40; attempt++) {
      const response = await fetch(`${this.base}/api/workspace-runtime/release`, {
        method: "POST",
        headers: { authorization: `Bearer ${desktopToken}`, "content-type": "application/json" },
        body: JSON.stringify({ installationId: this.installationId, workspaceId: this.workspaceId, runtimeId: this.runtimeId }),
      }).catch(() => null);
      if (response?.ok) return true;
      if (response && response.status !== 409) {
        console.error(`workspace release: ${response.status} ${await response.text()}`);
        return false;
      }
      await sleep(250);
    }
    return false;
  }

  connect() {
    if (this.stopped) return;
    this.ready = false;
    const ws = new WebSocket(`${this.base.replace(/^http/, "ws")}/api/workspace-gateway/connect?workspaceRuntimeId=${encodeURIComponent(this.runtimeId)}`, { headers: { authorization: `Bearer ${this.credential}` } } as any);
    this.socket = ws;
    ws.onopen = () => { this.opens++; void this.handshake(); };
    ws.onmessage = (event) => {
      let frame: any;
      try { frame = JSON.parse(String(event.data)); } catch { return; }
      this.frames.push(frame);
      if (frame.type === "assignment.start") void this.onAssignment(frame, this);
    };
    ws.onclose = (event) => { this.closes.push(event.code); this.ready = false; if (!this.stopped) setTimeout(() => this.connect(), 250 + Math.random() * 250); };
    ws.onerror = () => {};
  }

  stop() { this.stopped = true; this.socket?.close(); }

  send(type: string, payload: Record<string, unknown>, extra: Record<string, unknown> = {}) {
    const at = new Date().toISOString();
    this.socket?.send(JSON.stringify({ protocol: "syntila.workspace-runtime-protocol", protocolVersion: "5.1", messageId: `m-${++this.counter}-${Date.now()}`, timestamp: at, type, executionWorkspaceId: this.workspaceId, workspaceRuntimeId: this.runtimeId, payload, ...extra }));
  }

  waitFor(what: string, predicate: (frame: any) => boolean, ms?: number) {
    return waitFor(what, () => this.frames.find(predicate), ms);
  }

  private async handshake() {
    const mark = this.frames.length;
    const after = (type: string) => waitFor(type, () => this.frames.slice(mark).find((f) => f.type === type));
    this.send("workspace.hello", { capabilities: { customCapabilities: ["assignment.start_permit.v1"] } });
    await after("workspace.hello.ack");
    const now = new Date().toISOString();
    this.send("worker.inventory", {
      fullSnapshot: true,
      workers: [{
        workerId: `worker-${this.workspaceId}`.slice(0, 120), workerTypeId: "chatgpt", activationState: "enabled", readinessState: "ready", revision: 1,
        localConcurrencyLimit: 2, engineVersion: "1.4.0", profileDefinitionId: "chatgpt-codex", profileReleaseVersion: this.profile?.releaseVersion ?? 1,
        providerToolName: "Codex CLI", providerToolVersion: "1.0.0", createdAt: now, updatedAt: now, lastSeenAt: now,
        ...(this.profile ? { modelCatalog: {
          schemaVersion: 2, profileDigest: this.profile.digest, providerToolVersion: "1.0.0", catalogRevision: "b".repeat(64), discoveredAt: now,
          models: [{ id: "gpt-5", name: "GPT-5", status: "verified", selectionMode: "separate", efforts: ["medium"], defaultEffort: "medium" }],
        } } : {}),
      }],
    });
    this.send("workspace.sync.request", {});
    const sync = await after("workspace.sync.result");
    this.send("workspace.readiness", { state: "ready", readyForAssignments: true, syncGeneration: sync.payload?.syncGeneration ?? 1 });
    this.ready = true;
  }

  get workerId() { return `worker-${this.workspaceId}`.slice(0, 120); }
}

/** Runs an assignment like the desktop Service: ack, permit, start, result. */
export function completeWith(text: string, hold?: () => Promise<void>): AssignmentHandler {
  return async (start, ws) => {
    const ids = Object.fromEntries(["workerId", "runId", "taskId", "attemptId", "assignmentId", "idempotencyKey"].map((k) => [k, start[k]]));
    ws.send("assignment.ack", { accepted: true }, ids);
    ws.send("assignment.start.permit.request", {}, ids);
    await ws.waitFor("start permit", (f) => f.type === "assignment.start.permit.grant" && f.assignmentId === start.assignmentId);
    ws.send("assignment.start.ack", {}, ids);
    if (hold) await hold();
    // After a reconnect the Service re-sends its terminal outcome until acked.
    for (let attempt = 0; attempt < 40; attempt++) {
      ws.send("assignment.result", { status: "completed", summary: text, output: { text }, artifactIds: [] }, ids);
      const acked = await waitFor("terminal ack", () => ws.frames.find((f) => f.type === "assignment.ack" && f.payload?.terminal === true && f.assignmentId === start.assignmentId), 1500).catch(() => null);
      if (acked) return;
    }
  };
}

/** Current published ChatGPT Tool Profile, read from the backend database. */
export async function publishedChatgptProfile(): Promise<{ digest: string; releaseVersion: number } | null> {
  if (!process.env.PGHOST && !process.env.DATABASE_URL) return null;
  const { SQL } = await import("bun");
  const sql = process.env.DATABASE_URL ? new SQL(process.env.DATABASE_URL) : new SQL({});
  try {
    const [row] = await sql`SELECT digest, revision FROM worker_profiles WHERE worker_type_id = 'chatgpt'`;
    return row ? { digest: row.digest, releaseVersion: Number(row.revision) } : null;
  } catch { return null; } finally { await sql.close(); }
}

/** Sends a Chat request through the Workspace and waits for its answer. */
export async function chatRoundTrip(user: User, spaceId: string, threadId: string, workspace: FakeWorkspace, text: string, ms = 30_000) {
  const pick = await user.api("PUT", `/api/spaces/${spaceId}/workflow-workspace`, { workspaceId: workspace.workspaceId, confirmReset: true });
  if (pick.status !== 200) throw new Error(`select workspace: ${pick.status} ${JSON.stringify(pick.body)}`);
  const submit = await user.api("POST", `/api/threads/${threadId}/work-requests`, { workflowId: "chat", objective: text, executionSelection: { workerId: workspace.workerId } });
  if (submit.status >= 300) throw new Error(`submit chat: ${submit.status} ${JSON.stringify(submit.body)}`);
  const id: string = submit.body.workRequest.id;
  const done = await waitFor("work request to finish", async () => {
    const r = await user.api("GET", `/api/work-requests/${id}`);
    return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status) ? r.body.workRequest : undefined;
  }, ms);
  return { id, request: done, answer: done.workflowRun?.stepRuns?.[0]?.result as string | undefined };
}
