// Resilience test: backend restart or crash with live browser and Connect
// Worker connections.
// Verifies: both sockets drop and reconnect by themselves (with a newer Worker
// session epoch), and a message posted while the browser was away is delivered
// after it resubscribes.
//
// bun scripts/resilience.ts <baseUrl> <privateJwkFile> "<restart command>"
import { $ } from "bun";
import { User, tokenMinter, waitFor, type Jwk } from "./lib/clients";
import { actionMessage, pairingMessage } from "../src/domain/worker-agents.js";

const [base, jwkFile, restartCmd] = Bun.argv.slice(2);
if (!base || !jwkFile || !restartCmd) {
  console.error('usage: bun scripts/resilience.ts <baseUrl> <privateJwkFile> "<restart command>"');
  process.exit(2);
}

const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const t0 = Date.now();
const log = (m: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
const sub = "resilience-user";
const user = new User(base, await mint(sub));

const b64url = (bytes: Uint8Array) =>
  Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function createConnectWorker(owner: User, name: string) {
  const created = await owner.api("POST", "/api/workers", { name, workerTypeId: "chatgpt" });
  const workerId: string | undefined = created.body?.worker?.id ?? created.body?.id;
  if (created.status >= 300 || !workerId) throw new Error(`create worker: ${created.status} ${JSON.stringify(created.body)}`);

  const pair = await owner.api("POST", `/api/workers/${workerId}/pairing`);
  const challenge = pair.body?.challenge;
  if (pair.status >= 300 || !challenge?.challengeId || !challenge?.secret) {
    throw new Error(`start pairing: ${pair.status} ${JSON.stringify(pair.body)}`);
  }

  const keyPair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pubRaw = new Uint8Array(await crypto.subtle.exportKey("raw", keyPair.publicKey));
  const publicKey = b64url(pubRaw);
  const sign = async (msg: string) =>
    b64url(new Uint8Array(await crypto.subtle.sign("Ed25519", keyPair.privateKey, new TextEncoder().encode(msg))));

  const claimRes = await fetch(`${base}/api/worker-agent/claim`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      challengeId: challenge.challengeId,
      secret: challenge.secret,
      publicKey,
      signature: await sign(pairingMessage(challenge.challengeId, workerId, publicKey)),
    }),
  });
  if (!claimRes.ok) throw new Error(`claim pairing: ${claimRes.status} ${await claimRes.text()}`);

  const state = { opens: 0, closes: [] as number[], epoch: 0, ready: false, stopped: false, socket: null as WebSocket | null };
  let seq = 0;
  const envelope = (type: string, payload: Record<string, unknown>) => ({
    protocol: "syntila.worker-agent-protocol",
    protocolVersion: "5.1",
    messageId: `resilience-${Date.now()}-${++seq}`,
    timestamp: new Date().toISOString(),
    type,
    payload,
  });

  const connect = async () => {
    if (state.stopped) return;
    state.ready = false;
    try {
      const nonceRes = await fetch(`${base}/api/worker-agent/nonce`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ workerId }),
      });
      if (!nonceRes.ok) throw new Error(`nonce ${nonceRes.status}`);
      const { nonce } = (await nonceRes.json()) as { nonce: { nonceId: string; nonce: string } };
      const sessionRes = await fetch(`${base}/api/worker-agent/sessions`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          workerId,
          nonceId: nonce.nonceId,
          signature: await sign(actionMessage("session", workerId, nonce.nonceId, nonce.nonce)),
        }),
      });
      if (!sessionRes.ok) throw new Error(`session ${sessionRes.status}`);
      const { session } = (await sessionRes.json()) as { session: { sessionId: string; sessionToken: string; epoch: number } };
      const wsUrl = `${base.replace(/^http/, "ws")}/api/worker-agent/gateway?workerId=${encodeURIComponent(workerId)}&workerSessionId=${encodeURIComponent(session.sessionId)}`;
      const ws = new WebSocket(wsUrl, { headers: { authorization: `Bearer ${session.sessionToken}` } } as any);
      state.socket = ws;
      let helloId = "";
      let syncId = "";
      ws.onopen = () => {
        const hello = envelope("agent.hello", { name: "syntila-connect", connectVersion: "resilience", capabilities: [] });
        helloId = hello.messageId;
        ws.send(JSON.stringify(hello));
      };
      ws.onmessage = (event) => {
        const frame = JSON.parse(String(event.data));
        if (frame.type === "agent.hello.ack" && frame.correlationId === helloId) {
          const sync = envelope("agent.sync.request", {});
          syncId = sync.messageId;
          ws.send(JSON.stringify(sync));
        } else if (frame.type === "agent.sync.result" && frame.correlationId === syncId) {
          state.epoch = session.epoch;
          state.opens++;
          state.ready = true;
        }
      };
      ws.onclose = (event) => {
        state.ready = false;
        state.closes.push(event.code);
        if (!state.stopped) setTimeout(connect, 250 + Math.random() * 250);
      };
      ws.onerror = () => {};
    } catch {
      if (!state.stopped) setTimeout(connect, 500);
    }
  };
  void connect();

  return {
    workerId,
    state,
    close() {
      state.stopped = true;
      state.socket?.close();
    },
  };
}

let spaceId = "";
let worker: Awaited<ReturnType<typeof createConnectWorker>> | null = null;
let live: ReturnType<User["realtime"]> | null = null;

try {
  if (!(await fetch(`${base}/health/ready`).catch(() => null))?.ok) throw new Error("backend not ready");
  const created = await user.spaceWithThread(`Resilience ${run}`);
  spaceId = created.spaceId;
  const { threadId } = created;
  live = user.realtime([spaceId]);
  await live.waitFor("realtime ready", (f) => f.type === "realtime.ready");

  worker = await createConnectWorker(user, `Resilience ${run}`);
  await waitFor("Connect Worker ready", () => worker!.state.ready);
  log(`browser + Connect Worker connected (epoch ${worker.state.epoch})`);

  const before = { browser: live.state.opens, worker: worker.state.opens, epoch: worker.state.epoch };
  log(`running: ${restartCmd}`);
  await $`sh -c ${restartCmd}`.quiet();
  await waitFor("backend ready again", async () => (await fetch(`${base}/health/ready`).catch(() => null))?.ok, 60_000);
  log("backend ready");
  await waitFor("browser reconnect", () => live!.state.opens > before.browser, 30_000);
  await waitFor(
    "Connect Worker reconnect",
    () => worker!.state.opens > before.worker && worker!.state.epoch > before.epoch && worker!.state.ready,
    30_000,
  );
  log(`reconnected (browser closes ${live.state.closes.join(",")}; worker closes ${worker.state.closes.join(",")}; epoch ${before.epoch} -> ${worker.state.epoch})`);

  const mark = live.state.frames.length;
  const posted = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: `after restart ${run}` });
  if (posted.status >= 300) throw new Error(`post after restart: ${posted.status}`);
  await waitFor("live event after reconnect", () => live!.state.frames.slice(mark).find((f) => JSON.stringify(f).includes(threadId)));
  log("realtime delivery after reconnect");
  console.log("RESILIENCE PASSED");
} catch (error) {
  console.error("RESILIENCE FAILED:", error instanceof Error ? error.message : error);
  process.exitCode = 1;
} finally {
  live?.close();
  worker?.close();
  if (worker?.workerId) await user.api("DELETE", `/api/workers/${worker.workerId}`).catch(() => {});
  if (spaceId) await user.api("DELETE", `/api/spaces/${spaceId}`).catch(() => {});
}
