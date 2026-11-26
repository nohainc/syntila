// End-to-end smoke test against a running backend (/api):
// health, JWT session, Space + Thread, idempotent message post, browser
// realtime fan-out. Worker execution is not covered by this smoke.
// The Space it creates is archived afterwards.
//
// bun scripts/smoke.ts <baseUrl> <privateJwkFile>
// (PG* env from backend.env lets it find the published Tool Profile.)
import { User, tokenMinter, type Jwk } from "./lib/clients";

const [base, jwkFile] = Bun.argv.slice(2);
if (!base || !jwkFile) { console.error("usage: bun scripts/smoke.ts <baseUrl> <privateJwkFile>"); process.exit(2); }
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const check = (ok: unknown, label: string) => { if (!ok) { console.error(`FAIL ${label}`); process.exit(1); } console.log(`ok   ${label}`); };
const sub = "smoke-user";
const user = new User(base, await mint(sub));
let spaceId = "";

try {
  check((await fetch(`${base}/health/ready`)).ok, "health/ready");
  check((await user.api("GET", "/api/spaces")).status === 200 && (await fetch(`${base}/api/spaces`)).status === 401, "JWT required and accepted");
  const created = await user.spaceWithThread(`Smoke ${run}`);
  spaceId = created.spaceId;
  const { threadId } = created;
  check(threadId, "space + thread created");

  const live = user.realtime([spaceId]);
  await live.waitFor("subscription", (f) => f.type === "subscription.ready");
  check(true, "browser realtime (ticket) subscribed");

  const key = `smoke-${run}-1`;
  const m1 = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "hello" }, { "idempotency-key": key });
  const m2 = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: "hello" }, { "idempotency-key": key });
  check(m1.status < 300 && m2.status === m1.status && JSON.stringify(m2.body) === JSON.stringify(m1.body), "idempotent message post");
  await live.waitFor("message event", (f) => JSON.stringify(f).includes(threadId) && f.type !== "subscription.ready");
  check(true, "realtime fan-out received");

  console.log("Worker execution is not covered by this smoke");
  live.close();
  console.log("SMOKE PASSED");
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  process.exitCode = 1;
} finally {
  if (spaceId) await user.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }).catch(() => undefined);
  process.exit(process.exitCode ?? 0);
}
