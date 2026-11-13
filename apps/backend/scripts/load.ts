// Load test against a running backend (/api).
// N users each own a Space with a live browser realtime connection; every
// user posts M messages. Reports REST latency, realtime fan-out latency
// (post → event on the socket) and throughput. With a published ChatGPT Tool
// Profile, it also runs C concurrent Chat requests through one Workspace.
//
// bun scripts/load.ts <baseUrl> <privateJwkFile> [users=50] [messages=20] [chats=20]
import { FakeWorkspace, User, completeWith, publishedChatgptProfile, tokenMinter, waitFor, type Jwk } from "./lib/clients";

const [base, jwkFile, usersArg, messagesArg, chatsArg] = Bun.argv.slice(2);
if (!base || !jwkFile) { console.error("usage: bun scripts/load.ts <baseUrl> <privateJwkFile> [users] [messages] [chats]"); process.exit(2); }
const USERS = Number(usersArg ?? 50), MESSAGES = Number(messagesArg ?? 20), CHATS = Number(chatsArg ?? 20);
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const pct = (xs: number[], p: number) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]! : NaN; };
const report = (label: string, xs: number[]) => console.log(`${label.padEnd(28)} n=${String(xs.length).padStart(5)}  p50=${pct(xs, 50).toFixed(0).padStart(5)}ms  p95=${pct(xs, 95).toFixed(0).padStart(5)}ms  p99=${pct(xs, 99).toFixed(0).padStart(5)}ms  max=${Math.max(...xs).toFixed(0).padStart(5)}ms`);

type Client = { user: User; spaceId: string; threadId: string; live: ReturnType<User["realtime"]> };
const clients: Client[] = [];
const cleanup: Array<() => Promise<unknown>> = [];
let failed = false;

try {
  console.log(`setup: ${USERS} users with a Space and a live realtime connection`);
  await Promise.all(Array.from({ length: USERS }, async (_, i) => {
    const user = new User(base, await mint(`load-${run}-${i}`));
    const { spaceId, threadId } = await user.spaceWithThread(`Load ${run} ${i}`);
    const live = user.realtime([spaceId]);
    await live.waitFor("subscription", (f) => f.type === "subscription.confirmed", 30_000);
    clients.push({ user, spaceId, threadId, live });
    cleanup.push(() => user.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }));
  }));

  console.log(`messages: ${USERS} × ${MESSAGES} posts, concurrently`);
  const rest: number[] = [], fanout: number[] = [];
  let errors = 0;
  const t0 = performance.now();
  await Promise.all(clients.map(async (c) => {
    for (let m = 0; m < MESSAGES; m++) {
      const marker = `load-${run}-${m}-${crypto.randomUUID().slice(0, 8)}`;
      const start = performance.now();
      const mark = c.live.state.frames.length;
      const posted = await c.user.api("POST", `/api/threads/${c.threadId}/discussion-messages`, { body: marker });
      rest.push(performance.now() - start);
      if (posted.status >= 300) { errors++; continue; }
      const id = posted.body?.message?.id ?? posted.body?.id;
      await waitFor("fan-out", () => c.live.state.frames.slice(mark).find((f) => JSON.stringify(f).includes(id ?? c.threadId)), 15_000)
        .then(() => fanout.push(performance.now() - start)).catch(() => { errors++; });
    }
  }));
  const seconds = (performance.now() - t0) / 1000;
  report("POST message (REST)", rest);
  report("post → realtime event", fanout);
  console.log(`throughput ${(rest.length / seconds).toFixed(0)} messages/s, errors ${errors}`);
  if (errors) failed = true;

  const profile = await publishedChatgptProfile();
  if (!profile || CHATS <= 0) console.log("skip chat load (no ChatGPT Tool Profile published, or chats=0)");
  else {
    console.log(`chat: ${CHATS} concurrent Chat requests through one Workspace`);
    const owner = new User(base, await mint(`load-${run}-owner`));
    const desktop = await mint(`load-${run}-owner`, { client: "desktop", client_aud: "syntila.desktop.management" });
    const workspace = await new FakeWorkspace(base, profile, completeWith("ok")).register(desktop, `Load ${run}`);
    cleanup.push(() => workspace.release(desktop));
    workspace.connect();
    await waitFor("workspace ready", () => workspace.ready);
    const { spaceId, threadId } = await owner.spaceWithThread(`Load chat ${run}`);
    cleanup.push(() => owner.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }));
    const pick = await owner.api("PUT", `/api/spaces/${spaceId}/workflow-workspace`, { workspaceId: workspace.workspaceId, confirmReset: true });
    if (pick.status !== 200) throw new Error(`select workspace: ${pick.status}`);
    const total: number[] = [];
    let chatErrors = 0;
    await Promise.all(Array.from({ length: CHATS }, async (_, i) => {
      const start = performance.now();
      const submit = await owner.api("POST", `/api/threads/${threadId}/work-requests`, { workflowId: "chat", objective: `load ${i}`, executionSelection: { workerId: workspace.workerId } });
      if (submit.status >= 300) { chatErrors++; console.error(`chat ${i}: ${submit.status} ${JSON.stringify(submit.body).slice(0, 200)}`); return; }
      const id = submit.body.workRequest.id;
      const done = await waitFor("chat done", async () => {
        const r = await owner.api("GET", `/api/work-requests/${id}`);
        return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status) ? r.body.workRequest : undefined;
      }, 120_000).catch(() => null);
      if (done?.status === "completed") total.push(performance.now() - start); else chatErrors++;
    }));
    report("chat submit → completed", total);
    console.log(`chat errors ${chatErrors}`);
    if (chatErrors) failed = true;
  }
  console.log(failed ? "LOAD FINISHED WITH ERRORS" : "LOAD PASSED");
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  failed = true;
} finally {
  for (const c of clients) c.live.close();
  await Promise.all(cleanup.map((fn) => fn().catch(() => undefined)));
  process.exit(failed ? 1 : 0);
}
