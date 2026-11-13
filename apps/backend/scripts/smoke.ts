// End-to-end smoke test against a running backend (/api):
// health, JWT session, Space + Thread, idempotent message post, browser
// realtime fan-out, Workspace registration + gateway connection, and — when a
// ChatGPT Tool Profile is published — a Chat round trip through the Workspace.
// Everything it creates is archived or released afterwards.
//
// bun scripts/smoke.ts <baseUrl> <privateJwkFile>
// (PG* env from backend.env lets it find the published Tool Profile.)
import { FakeWorkspace, User, completeWith, chatRoundTrip, publishedChatgptProfile, tokenMinter, type Jwk } from "./lib/clients";

const [base, jwkFile] = Bun.argv.slice(2);
if (!base || !jwkFile) { console.error("usage: bun scripts/smoke.ts <baseUrl> <privateJwkFile>"); process.exit(2); }
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const check = (ok: unknown, label: string) => { if (!ok) { console.error(`FAIL ${label}`); process.exit(1); } console.log(`ok   ${label}`); };
const sub = "smoke-user";
const user = new User(base, await mint(sub));
const desktop = await mint(sub, { client: "desktop", client_aud: "syntila.desktop.management" });
let workspace: FakeWorkspace | null = null;
let spaceId = "";

try {
  check((await fetch(`${base}/health/ready`)).ok, "health/ready");
  check((await user.api("GET", "/api/spaces")).status === 200 && (await fetch(`${base}/api/spaces`)).status === 401, "JWT required and accepted");
  const created = await user.spaceWithThread(`Smoke ${run}`);
  spaceId = created.spaceId;
  const { threadId } = created;
  check(threadId, "space + thread created");

  const live = user.realtime([spaceId]);
  await live.waitFor("subscription", (f) => f.type === "subscription.confirmed");
  check(true, "browser realtime (ticket) subscribed");

  const key = `smoke-${run}-1`;
  const m1 = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "hello" }, { "idempotency-key": key });
  const m2 = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "hello" }, { "idempotency-key": key });
  check(m1.status < 300 && m2.status === m1.status && JSON.stringify(m2.body) === JSON.stringify(m1.body), "idempotent message post");
  await live.waitFor("message event", (f) => JSON.stringify(f).includes(threadId) && f.type !== "subscription.confirmed");
  check(true, "realtime fan-out received");

  const profile = await publishedChatgptProfile();
  workspace = await new FakeWorkspace(base, profile, completeWith("pong")).register(desktop, `Smoke ${run}`);
  workspace.connect();
  await (await import("./lib/clients")).waitFor("workspace ready", () => workspace!.ready);
  check(true, "workspace registered and connected through the gateway");

  if (!profile) console.log("skip AI round trip (no ChatGPT Tool Profile published, or no database access)");
  else {
    const { request, answer } = await chatRoundTrip(user, spaceId, threadId, workspace, "ping");
    check(request.status === "completed" && answer === "pong", "chat request → workflow → workspace → answer");
  }
  live.close();
  console.log("SMOKE PASSED");
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  process.exitCode = 1;
} finally {
  if (workspace) await workspace.release(desktop);
  if (spaceId) await user.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }).catch(() => undefined);
  process.exit(process.exitCode ?? 0);
}
