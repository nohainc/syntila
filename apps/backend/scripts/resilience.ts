// Resilience test: backend restart or crash with live browser and Workspace
// connections and a Chat request in flight.
// Verifies: both sockets drop and reconnect by themselves, a message posted
// while the browser was away is delivered after it resubscribes, and the
// in-flight request finishes exactly once after the Workspace re-sends its
// result to the new process.
//
// bun scripts/resilience.ts <baseUrl> <privateJwkFile> "<restart command>"
import { $ } from "bun";
import { FakeWorkspace, User, completeWith, publishedChatgptProfile, tokenMinter, waitFor, type Jwk } from "./lib/clients";

const [base, jwkFile, restartCmd] = Bun.argv.slice(2);
if (!base || !jwkFile || !restartCmd) { console.error('usage: bun scripts/resilience.ts <baseUrl> <privateJwkFile> "<restart command>"'); process.exit(2); }
const mint = tokenMinter(JSON.parse(await Bun.file(jwkFile).text()) as Jwk);
const run = Date.now().toString(36);
const t0 = Date.now();
const log = (m: string) => console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${m}`);
const sub = "resilience-user";
const user = new User(base, await mint(sub));
const desktop = await mint(sub, { client: "desktop", client_aud: "syntila.desktop.management" });
let workspace: FakeWorkspace | null = null;
let spaceId = "";
let release = () => {};
const held = new Promise<void>((resolve) => { release = resolve; });

try {
  if (!(await fetch(`${base}/health/ready`).catch(() => null))?.ok) throw new Error("backend not ready");
  const created = await user.spaceWithThread(`Resilience ${run}`);
  spaceId = created.spaceId;
  const { threadId } = created;
  const live = user.realtime([spaceId]);
  await live.waitFor("subscription", (f) => f.type === "subscription.confirmed");

  const profile = await publishedChatgptProfile();
  // The Workspace holds the result until the backend has been restarted.
  workspace = await new FakeWorkspace(base, profile, completeWith("survived", () => held)).register(desktop, `Resilience ${run}`);
  workspace.connect();
  await waitFor("workspace ready", () => workspace!.ready);
  log("browser + workspace connected");

  let workRequestId: string | null = null;
  if (profile) {
    const pick = await user.api("PUT", `/api/spaces/${spaceId}/workflow-workspace`, { workspaceId: workspace.workspaceId, confirmReset: true });
    if (pick.status !== 200) throw new Error(`select workspace: ${pick.status}`);
    const submit = await user.api("POST", `/api/threads/${threadId}/work-requests`, { workflowId: "chat", objective: "survive a restart", executionSelection: { workerId: workspace.workerId } });
    if (submit.status >= 300) throw new Error(`submit: ${submit.status} ${JSON.stringify(submit.body)}`);
    workRequestId = submit.body.workRequest.id;
    await workspace.waitFor("permit", (f) => f.type === "assignment.start.permit.grant");
    log(`chat request running on the workspace (${workRequestId})`);
  } else log("no ChatGPT Tool Profile published: skipping the in-flight request part");

  const opens = { browser: live.state.opens, workspace: workspace.opens };
  log(`running: ${restartCmd}`);
  await $`sh -c ${restartCmd}`.quiet();
  await waitFor("backend ready again", async () => (await fetch(`${base}/health/ready`).catch(() => null))?.ok, 60_000);
  log("backend ready");
  await waitFor("browser reconnect", () => live.state.opens > opens.browser, 30_000);
  await waitFor("workspace reconnect", () => workspace!.opens > opens.workspace && workspace!.ready, 30_000);
  log(`reconnected (browser closes ${live.state.closes.join(",")}; workspace closes ${workspace.closes.join(",")})`);

  const mark = live.state.frames.length;
  const posted = await user.api("POST", `/api/threads/${threadId}/discussion-messages`, { body: `after restart ${run}` });
  if (posted.status >= 300) throw new Error(`post after restart: ${posted.status}`);
  await waitFor("live event after reconnect", () => live.state.frames.slice(mark).find((f) => JSON.stringify(f).includes(threadId) && f.type !== "subscription.confirmed"));
  log("realtime delivery after reconnect");

  if (workRequestId) {
    release();
    const done = await waitFor("request to finish", async () => {
      const r = await user.api("GET", `/api/work-requests/${workRequestId}`);
      return ["completed", "failed", "cancelled"].includes(r.body?.workRequest?.status) ? r.body.workRequest : undefined;
    }, 60_000);
    const results = (done.workflowRun?.stepRuns ?? []).filter((s: any) => s.result === "survived");
    if (done.status !== "completed" || results.length !== 1) throw new Error(`request ended ${done.status} with ${results.length} results`);
    log("in-flight request completed exactly once after the restart");
  }
  live.close();
  console.log("RESILIENCE PASSED");
} catch (error) {
  console.error(`FAIL ${(error as Error).message}`);
  process.exitCode = 1;
} finally {
  release();
  if (workspace) await workspace.release(desktop);
  if (spaceId) await user.api("PATCH", `/api/spaces/${spaceId}`, { archived: true }).catch(() => undefined);
  process.exit(process.exitCode ?? 0);
}
