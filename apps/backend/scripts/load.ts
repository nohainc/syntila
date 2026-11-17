// Load test against a running backend (/api).
// N users each own a Space with a live browser realtime connection; every
// user posts M messages. Reports REST latency, realtime fan-out latency
// (post → event on the socket) and throughput. With a published ChatGPT Tool
// Profile, it also runs C concurrent Chat requests through one Workspace.
//
// A mixed phase follows: every user at once creates Threads and notes,
// renames, edits, and reads (Spaces, messages, notes, notifications).
// Afterwards, with PGHOST or DATABASE_URL set, scripts/check-invariants.sql
// runs against the database and any violation fails the load test.
//
// bun scripts/load.ts <baseUrl> <privateJwkFile> [users=50] [messages=20] [chats=20] [mixed=10]
import { FakeWorkspace, User, completeWith, publishedChatgptProfile, runMessagePosts, tokenMinter, waitFor, type Client, type Jwk } from "./lib/clients";

const [base, jwkFile, usersArg, messagesArg, chatsArg, mixedArg] = Bun.argv.slice(2);
if (!base || !jwkFile) { console.error("usage: bun scripts/load.ts <baseUrl> <privateJwkFile> [users] [messages] [chats]"); process.exit(2); }
const USERS = Number(usersArg ?? 50), MESSAGES = Number(messagesArg ?? 20), CHATS = Number(chatsArg ?? 20), MIXED = Number(mixedArg ?? 10);
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const pct = (xs: number[], p: number) => { const s = [...xs].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))]! : NaN; };
const report = (label: string, xs: number[]) => console.log(`${label.padEnd(28)} n=${String(xs.length).padStart(5)}  p50=${pct(xs, 50).toFixed(0).padStart(5)}ms  p95=${pct(xs, 95).toFixed(0).padStart(5)}ms  p99=${pct(xs, 99).toFixed(0).padStart(5)}ms  max=${Math.max(...xs).toFixed(0).padStart(5)}ms`);

/** scripts/check-invariants.sql against the backend's database; null when not configured. */
async function brokenInvariants(): Promise<string[] | null> {
  if (!process.env.PGHOST && !process.env.DATABASE_URL) return null;
  const { SQL } = await import("bun");
  const sql = process.env.DATABASE_URL ? new SQL(process.env.DATABASE_URL) : new SQL({});
  try {
    const rows: { invariant: string; violations: number | bigint }[] =
      await sql.unsafe(await Bun.file(new URL("./check-invariants.sql", import.meta.url)).text());
    return rows.filter((r) => Number(r.violations) > 0).map((r) => `${r.invariant}: ${r.violations}`);
  } finally { await sql.close(); }
}

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
  const { rest, fanout, errors, throughput } = await runMessagePosts(clients, MESSAGES, `load-${run}`);
  report("POST message (REST)", rest);
  report("post → realtime event", fanout);
  console.log(`throughput ${throughput.toFixed(0)} messages/s, errors ${errors}`);
  if (errors) failed = true;

  if (MIXED > 0) {
    console.log(`mixed: ${USERS} users × ${MIXED} rounds of writes and reads, concurrently`);
    const writes: number[] = [], reads: number[] = [];
    let mixedErrors = 0;
    const timed = async (into: number[], send: () => Promise<{ status: number; body: any }>) => {
      const start = performance.now();
      const r = await send();
      into.push(performance.now() - start);
      if (r.status >= 300) { mixedErrors++; if (mixedErrors <= 5) console.error(`mixed: ${r.status} ${JSON.stringify(r.body).slice(0, 160)}`); }
      return r;
    };
    const t1 = performance.now();
    await Promise.all(clients.map(async (c, i) => {
      for (let round = 0; round < MIXED; round++) {
        const thread = await timed(writes, () => c.user.api("POST", `/api/spaces/${c.spaceId}/threads`, { name: `Mixed ${round}` }));
        const threadId = thread.body?.thread?.id ?? thread.body?.id;
        const note = await timed(writes, () => c.user.api("POST", "/api/notes", { title: `Note ${round}`, body: "draft" }));
        await Promise.all([
          threadId && timed(writes, () => c.user.api("PATCH", `/api/threads/${threadId}`, { name: `Mixed ${round} renamed` })),
          note.body?.note && timed(writes, () => c.user.api("PUT", `/api/notes/${note.body.note.id}`, { body: `edited ${i}`, revision: note.body.note.revision })),
          timed(reads, () => c.user.api("GET", "/api/spaces")),
          timed(reads, () => c.user.api("GET", `/api/threads/${c.threadId}/discussion-messages?limit=50`)),
          timed(reads, () => c.user.api("GET", "/api/notes?limit=50")),
          timed(reads, () => c.user.api("GET", "/api/notifications")),
        ]);
      }
    }));
    const mixedSeconds = (performance.now() - t1) / 1000;
    report("mixed writes", writes);
    report("mixed reads", reads);
    console.log(`throughput ${((writes.length + reads.length) / mixedSeconds).toFixed(0)} requests/s, errors ${mixedErrors}`);
    if (mixedErrors) failed = true;
  }

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
  const broken = await brokenInvariants();
  if (broken === null) console.log("invariants: skipped (set PGHOST or DATABASE_URL to check them)");
  else if (broken.length) { console.error(`invariants BROKEN: ${broken.join("; ")}`); failed = true; }
  else console.log("invariants: all hold");
  console.log(failed ? "LOAD FINISHED WITH ERRORS" : "LOAD PASSED");
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  failed = true;
} finally {
  for (const c of clients) c.live.close();
  await Promise.all(cleanup.map((fn) => fn().catch(() => undefined)));
  process.exit(failed ? 1 : 0);
}
