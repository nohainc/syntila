import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread, member, space, thread, user } from "./helpers/seed";
import { acceptWorkerTarget, declaredProfileCapabilities } from "../../src/domain/worker-eligibility.js";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import { resolveWorkerTargetBindings, recheckWorkerTarget } from "../../src/domain/routes/worker-target-bindings.js";
import { handleListEligibleWorkers, handleValidateWorkRequest } from "../../src/domain/routes/work-creation.js";
import { handleListSpaceWorkers, handleListWorkersSharedWithMe, memberExecutionOptions } from "../../src/domain/routes/workers.js";
import { handleWorkerPersonShares } from "../../src/domain/routes/worker-space-access.js";

async function fixture() {
  const f = await pgD1();
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })} ${user("bob")} ${member("sp", "bob", "viewer")}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES
      ('worker-alice','','alice','chatgpt','Writer'), ('worker-bob','','bob','chatgpt','Writer');
    INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES ('alice','paid','active','manual',now(),now()) ON CONFLICT DO NOTHING;
    INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at)
      VALUES ('chatgpt',1,'{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex"}',1,'${"a".repeat(64)}',now());
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint)
      VALUES ('cred-a','worker-alice','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at)
      VALUES ('worker-alice','session-a',1,'cred-a','digest',now() + interval '5 minutes')`);
  const base = { workerId: "worker-alice", requesterUserId: "alice", spaceId: "sp", threadId: "th", workflowId: "chat", readOnly: true, capabilities: ["authorized_context_read"], requireOnline: true };
  return { ...f, base, accept: (overrides: Partial<typeof base> = {}) => acceptWorkerTarget(f.read, { ...base, ...overrides }) };
}

describe("Worker-targeted eligibility", () => {
  it("uses immutable IDs, refuses another owner's Worker and preserves the accepted snapshot", async () => {
    const f = await fixture();
    const accepted = await f.accept();
    expect(accepted.ok).toBe(true);
    if (!accepted.ok) throw new Error("expected acceptance");
    expect(accepted.snapshot).toMatchObject({ workerId: "worker-alice", workerName: "Writer", workerTypeId: "chatgpt", profile: { revision: 1, digest: "a".repeat(64) } });
    expect(await f.accept({ workerId: "worker-bob" })).toEqual({ ok: false, code: "worker_not_found" });
    await f.sqlite.exec("UPDATE worker_instances SET name='Renamed' WHERE id='worker-alice'; UPDATE worker_profiles SET revision=2, digest=repeat('b',64) WHERE worker_type_id='chatgpt'");
    expect(accepted.snapshot.workerName).toBe("Writer");
    expect(accepted.snapshot.profile?.revision).toBe(1);
    expect(accepted.snapshot.profile?.digest).toBe("a".repeat(64));
  });

  it("rejects disabled, offline, unauthorized, or disallowed Workers without substituting another", async () => {
    const f = await fixture();
    expect(await f.accept({ workerId: "worker-bob", requesterUserId: "bob" })).toEqual({ ok: false, code: "execute_not_permitted" });
    await f.sqlite.exec("UPDATE worker_instances SET enabled=false WHERE id='worker-alice'");
    expect(await f.accept()).toEqual({ ok: false, code: "worker_disabled" });
    await f.sqlite.exec("UPDATE worker_instances SET enabled=true WHERE id='worker-alice'; UPDATE worker_agent_sessions SET lease_expires_at=now()-interval '1 second'");
    expect(await f.accept()).toEqual({ ok: false, code: "worker_offline" });
    await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at=now()+interval '5 minutes'; INSERT INTO thread_execution_policies(thread_id,mode,allowed_worker_type_ids_json) VALUES('th','stateless','[\"gemini\"]')");
    expect(await f.accept()).toEqual({ ok: false, code: "worker_type_not_allowed" });
  });

  it("accepts only a model and effort the Profile lists", async () => {
    const f = await fixture();
    const profile = JSON.stringify({
      schemaVersion: 1, profileDefinitionId: "chatgpt-codex",
      model: { supported: true, supportedReasoningEfforts: ["low", "high"], catalog: [{ id: "m1", name: "M1", supportedReasoningEfforts: ["low"] }] },
    });
    await f.sqlite.exec(`UPDATE worker_profiles SET profile_json = '${profile}' WHERE worker_type_id = 'chatgpt'`);
    expect((await f.accept({ model: "m1", reasoningEffort: "low" } as never)).ok).toBe(true);
    expect(await f.accept({ model: "other" } as never)).toEqual({ ok: false, code: "model_not_supported" });
    expect(await f.accept({ model: "m1", reasoningEffort: "high" } as never)).toEqual({ ok: false, code: "effort_not_supported" });
    await f.sqlite.close();
  });

  it("enforces required permissions and refuses unknown capabilities", async () => {
    const f = await fixture();
    expect(await f.accept({ capabilities: ["thread_write"], readOnly: true })).toEqual({ ok: false, code: "execute_not_permitted" });
    expect(await f.accept({ capabilities: ["unknown_capability"] })).toEqual({ ok: false, code: "worker_type_unavailable" });
    const tests = await f.accept({ capabilities: ["authorized_context_read", "test_execution"] });
    expect(tests.ok && tests.snapshot.permissions).toContain("shell:execute");
    if (tests.ok) expect(tests.snapshot.permissions).not.toContain("repository:write");
  });

  it("rechecks a frozen Worker on retry and returns a clear offline error", async () => {
    const f = await fixture();
    const env = { SYNTILA_DB: f.db } as never;
    const bindings = await resolveWorkerTargetBindings(env, { userId: "alice", spaceId: "sp", threadId: "th", definition: BUILTIN_WORKFLOWS.chat, request: { workerId: "worker-alice" } });
    expect(bindings.ok).toBe(true);
    if (!bindings.ok) throw new Error("expected bindings");
    const target = (bindings.bindings.chat as { workerTarget: unknown }).workerTarget as import("../../src/domain/worker-eligibility.js").WorkerTargetSnapshot;
    await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at=now()-interval '1 second'");
    const refusal = await recheckWorkerTarget(env, { userId: "alice", spaceId: "sp", threadId: "th", definition: BUILTIN_WORKFLOWS.chat, step: BUILTIN_WORKFLOWS.chat.steps[0]!, target });
    expect(refusal?.status).toBe(409);
    expect(await refusal?.json()).toMatchObject({ error: "worker_offline" });
  });

  it("rejects an unknown step binding instead of silently using the fallback Worker", async () => {
    const f = await fixture();
    await expect(resolveWorkerTargetBindings({ SYNTILA_DB: f.db } as never, {
      userId: "alice", spaceId: "sp", threadId: "th", definition: BUILTIN_WORKFLOWS.chat,
      request: { workerId: "worker-alice", workerBindings: { typo: { workerId: "worker-bob" } } },
    })).rejects.toMatchObject({ status: 400 });
  });

  it("validates Worker preflight against the selected Worker's live session", async () => {
    const f = await fixture();
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch";
    try {
      const env = { SYNTILA_DB: f.db, SYNTILA_ENVIRONMENT: "development", TEST_AUTHENTICATION: async () => ({
        userId: "alice", user: { id: "alice", email: "alice@test", displayName: "alice", status: "active" },
        spaceRoles: { sp: "owner" }, sessionId: "test", clientType: "web",
      }) } as never;
      const request = () => new Request("https://test/api", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ workflowId: "chat", workerId: "worker-alice" }) });
      const eligible = () => handleListEligibleWorkers(new Request("https://test/api?workflowId=chat"), env, "th");
      expect(await (await eligible()).json()).toEqual({ workflowId: "chat", workerIds: ["worker-alice"] });
      expect(await (await handleValidateWorkRequest(request(), env, "th")).json()).toMatchObject({ eligible: true, issues: [] });
      await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at=now()-interval '1 second'");
      expect(await (await eligible()).json()).toEqual({ workflowId: "chat", workerIds: [] });
      expect(await (await handleValidateWorkRequest(request(), env, "th")).json()).toMatchObject({ eligible: false, issues: [{ code: "worker_offline" }] });
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
  });
});

describe("Profile capability declarations", () => {
  it("reads declared capabilities and treats a missing or malformed field as no claim", () => {
    expect(declaredProfileCapabilities(JSON.stringify({ capabilities: ["thread_write"] }))).toEqual(["thread_write"]);
    expect(declaredProfileCapabilities(JSON.stringify({ capabilities: [] }))).toEqual([]);
    expect(declaredProfileCapabilities(JSON.stringify({}))).toBeNull();
    expect(declaredProfileCapabilities(JSON.stringify({ capabilities: [1] }))).toBeNull();
    expect(declaredProfileCapabilities("not json")).toBeNull();
    expect(declaredProfileCapabilities(null)).toBeNull();
  });
});

describe("Per-Space member Worker access enforcement (ADR-042)", () => {
  it("allows enabled Space members within their granted mode, and rejects disabled or unlisted members", async () => {
    const f = await fixture();
    await f.sqlite.exec(`
      ${user("carol")}
      ${member("sp", "carol", "collaborator")}
      UPDATE space_memberships SET role = 'collaborator' WHERE space_id = 'sp' AND user_id = 'bob';
      UPDATE threads SET access_policy_json = '{"allowedPermissions":["execute"]}' WHERE id = 'th';
      INSERT INTO worker_space_members (worker_id, space_id, user_id, enabled, permissions_json)
        VALUES ('worker-alice', 'sp', 'bob', true, '{"mode":"chat"}');
    `);

    // Owner still works unchanged.
    expect((await f.accept({ requesterUserId: "alice" })).ok).toBe(true);

    // An unlisted member (carol) reaches the Space owner's Worker through her
    // Space rights, but never another member's Worker.
    expect((await f.accept({ requesterUserId: "carol" })).ok).toBe(true);
    expect(await f.accept({ requesterUserId: "carol", workerId: "worker-bob" })).toEqual({ ok: false, code: "worker_not_found" });
    const work = { workflowId: "direct", readOnly: false, capabilities: ["authorized_context_read", "thread_write"] };
    expect((await f.accept({ requesterUserId: "carol", ...work })).ok).toBe(true);
    // Chat-only Space rights: Chat still answers, Work is refused.
    await f.sqlite.exec(`UPDATE spaces SET settings_json = '{"memberPermissions":{"carol":{"chat":true,"work":false}}}' WHERE id = 'sp'`);
    expect((await f.accept({ requesterUserId: "carol" })).ok).toBe(true);
    expect(await f.accept({ requesterUserId: "carol", ...work })).toEqual({ ok: false, code: "execute_not_permitted" });
    // No Space rights at all: nothing.
    await f.sqlite.exec(`UPDATE spaces SET settings_json = '{"memberPermissions":{"carol":{"chat":false,"work":false}}}' WHERE id = 'sp'`);
    expect(await f.accept({ requesterUserId: "carol" })).toEqual({ ok: false, code: "execute_not_permitted" });
    await f.sqlite.exec(`UPDATE spaces SET settings_json = '{}' WHERE id = 'sp'`);

    // Enabled member (bob) succeeds on chat, but is rejected for write/work.
    expect((await f.accept({ requesterUserId: "bob", workflowId: "chat" })).ok).toBe(true);
    expect(await f.accept({
      requesterUserId: "bob",
      workflowId: "direct",
      readOnly: false,
      capabilities: ["authorized_context_read", "thread_write"],
    })).toEqual({ ok: false, code: "execute_not_permitted" });

    // Upgrading bob to work allows thread_write, still blocks test_execution.
    await f.sqlite.exec(`
      UPDATE worker_space_members SET permissions_json = '{"mode":"work"}'
       WHERE worker_id = 'worker-alice' AND space_id = 'sp' AND user_id = 'bob';
    `);
    expect((await f.accept({
      requesterUserId: "bob",
      workflowId: "direct",
      readOnly: false,
      capabilities: ["authorized_context_read", "thread_write"],
    })).ok).toBe(true);
    expect(await f.accept({
      requesterUserId: "bob",
      workflowId: "direct",
      readOnly: false,
      capabilities: ["authorized_context_read", "test_execution"],
    })).toEqual({ ok: false, code: "execute_not_permitted" });

    // Eligible workers endpoint surfaces shared Worker for enabled bob, not for unlisted carol.
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch";
    try {
      const envFor = (who: string) => ({
        SYNTILA_DB: f.db,
        SYNTILA_ENVIRONMENT: "development",
        TEST_AUTHENTICATION: async () => ({
          userId: who,
          user: { id: who, email: `${who}@test`, displayName: who, status: "active" },
          spaceRoles: { sp: "collaborator" },
          sessionId: "test",
          clientType: "web",
        }),
      }) as never;

      const bobEligible = await handleListEligibleWorkers(new Request("https://test/api?workflowId=chat"), envFor("bob"), "th");
      expect(await bobEligible.json()).toEqual({ workflowId: "chat", workerIds: ["worker-alice"] });

      const carolEligible = await handleListEligibleWorkers(new Request("https://test/api?workflowId=chat"), envFor("carol"), "th");
      expect(await carolEligible.json()).toEqual({ workflowId: "chat", workerIds: ["worker-alice"] });

      // Disabling bob rejects execution and removes from eligible list.
      await f.sqlite.exec(`
        UPDATE worker_space_members SET enabled = false
         WHERE worker_id = 'worker-alice' AND space_id = 'sp' AND user_id = 'bob';
      `);
      expect(await f.accept({ requesterUserId: "bob", workflowId: "chat" })).toEqual({ ok: false, code: "execute_not_permitted" });
      const bobDisabled = await handleListEligibleWorkers(new Request("https://test/api?workflowId=chat"), envFor("bob"), "th");
      expect(await bobDisabled.json()).toEqual({ workflowId: "chat", workerIds: [] });
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
  });
});

describe("Worker-wide member model and effort allow-list (ADR-042)", () => {
  it("allows members only the models and efforts the owner ticked", async () => {
    const f = await fixture();
    await f.sqlite.exec(`
      UPDATE space_memberships SET role = 'collaborator' WHERE space_id = 'sp' AND user_id = 'bob';
      UPDATE threads SET access_policy_json = '{"allowedPermissions":["execute"]}' WHERE id = 'th';
      INSERT INTO worker_space_members (worker_id, space_id, user_id, enabled, permissions_json)
        VALUES ('worker-alice', 'sp', 'bob', true, '{"mode":"chat"}');
    `);
    const bob = { requesterUserId: "bob", workflowId: "chat" };
    // Closed by default: no row, no model.
    expect(await f.accept({ ...bob, model: "m1" } as never)).toEqual({ ok: false, code: "model_not_supported" });
    await f.sqlite.exec(`
      INSERT INTO worker_member_model_access (worker_id, allowed_models_json, allowed_efforts_json)
        VALUES ('worker-alice', '["m1"]', '{"m1":["low"]}');
    `);
    expect((await f.accept({ ...bob, model: "m1", reasoningEffort: "low" } as never)).ok).toBe(true);
    expect(await f.accept({ ...bob, model: "m2" } as never)).toEqual({ ok: false, code: "model_not_supported" });
    expect(await f.accept({ ...bob, model: "m1", reasoningEffort: "high" } as never)).toEqual({
      ok: false,
      code: "effort_not_supported",
    });
    // The owner is never limited by the member table.
    expect((await f.accept({ model: "m2" } as never)).ok).toBe(true);
  });
});

describe("Space owner's Workers for members", () => {
  it("lists them to a member with Space rights and offers only allowed models", async () => {
    const f = await fixture();
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch";
    try {
      const envFor = (who: string) => ({
        SYNTILA_DB: f.db, SYNTILA_ENVIRONMENT: "development",
        TEST_AUTHENTICATION: async () => ({
          userId: who, user: { id: who, email: `${who}@test`, displayName: who, status: "active" },
          spaceRoles: { sp: "viewer" }, sessionId: "test", clientType: "web",
        }),
      }) as never;
      const list = async (who: string) =>
        ((await (await handleListSpaceWorkers(new Request("https://test/api"), envFor(who), "sp")).json()) as { workers: { id: string }[] }).workers.map((w) => w.id);
      // A viewer has no Chat or Work right by default; bob owns no Space Workers.
      expect(await list("bob")).toEqual([]);
      await f.sqlite.exec(`UPDATE spaces SET settings_json = '{"memberPermissions":{"bob":{"chat":true}}}' WHERE id = 'sp'`);
      expect(await list("bob")).toEqual(["worker-alice"]);
      expect(await list("alice")).toEqual([]);
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
    const options = {
      schemaVersion: 2,
      models: {
        allowsCustomModel: true, allowedModelIds: ["m1", "m2"], defaultModelId: "m2",
        options: [{ id: "m1", efforts: ["low", "high"], defaultEffort: "high" }, { id: "m2", efforts: [], defaultEffort: null }],
      },
    };
    expect(memberExecutionOptions(options, { allowedModels: ["m1"], allowedEfforts: { m1: ["low"] } })).toEqual({
      schemaVersion: 2,
      models: {
        allowsCustomModel: false, allowedModelIds: ["m1"], defaultModelId: null,
        options: [{ id: "m1", efforts: ["low"], defaultEffort: null }],
      },
    });
  });
});

describe("Person Shares (ADR-043)", () => {
  it("lets the person Chat on a shared Worker in their own Space only, within the owner's limits", async () => {
    const f = await fixture();
    await f.sqlite.exec(`
      ${basicThread({ user: "bob", space: "bob-sp", thread: "bob-th" })}
      ${user("carol")} ${space("carol-sp", "carol")} ${member("carol-sp", "carol")} ${member("carol-sp", "bob", "collaborator")}
      ${thread("carol-th", "carol-sp", "carol")}
    `);
    const bobChat = { requesterUserId: "bob", spaceId: "bob-sp", threadId: "bob-th" };
    // Not shared: invisible.
    expect(await f.accept(bobChat)).toEqual({ ok: false, code: "worker_not_found" });
    await f.sqlite.exec(`INSERT INTO worker_person_shares (worker_id, user_id) VALUES ('worker-alice', 'bob')`);
    const chat = await f.accept(bobChat);
    expect(chat.ok && chat.snapshot.personShare).toBe(true);
    if (chat.ok) expect(chat.snapshot.permissions).not.toContain("shell:execute");
    // Never Work, and never in a Space someone else owns.
    expect(await f.accept({
      ...bobChat, workflowId: "direct", readOnly: false, capabilities: ["authorized_context_read", "thread_write"],
    })).toEqual({ ok: false, code: "execute_not_permitted" });
    expect(await f.accept({ requesterUserId: "bob", spaceId: "carol-sp", threadId: "carol-th" })).toEqual({
      ok: false, code: "worker_not_found",
    });
    // Models stay closed until the owner allows them for members.
    expect(await f.accept({ ...bobChat, model: "m1" } as never)).toEqual({ ok: false, code: "model_not_supported" });

    // One request at a time by default.
    const env = { SYNTILA_DB: f.db } as never;
    const bind = () => resolveWorkerTargetBindings(env, {
      userId: "bob", spaceId: "bob-sp", threadId: "bob-th", definition: BUILTIN_WORKFLOWS.chat,
      request: { workerId: "worker-alice" },
    });
    expect((await bind()).ok).toBe(true);
    await f.sqlite.exec(`INSERT INTO worker_assignments
      (id,space_id,worker_type_id,status,permission_snapshot_json,session_policy,attempt_id,worker_instance_id,requested_by_user_id,worker_snapshot_json,created_at,updated_at)
      VALUES ('asg-bob','bob-sp','chatgpt','running','{}','stateless','att-bob','worker-alice','bob','{}',now(),now())`);
    await expect(bind()).rejects.toMatchObject({ status: 429 });
    // Revoking ends it at once.
    await f.sqlite.exec(`DELETE FROM worker_person_shares WHERE worker_id = 'worker-alice' AND user_id = 'bob'`);
    expect(await f.accept(bobChat)).toEqual({ ok: false, code: "worker_not_found" });
  });

  it("lets the owner share only with their People and lists the share to the person", async () => {
    const f = await fixture();
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,worker_target_dispatch";
    try {
      const envFor = (who: string) => ({
        SYNTILA_DB: f.db, SYNTILA_ENVIRONMENT: "development",
        TEST_AUTHENTICATION: async () => ({
          userId: who, user: { id: who, email: `${who}@test`, displayName: who, status: "active" },
          spaceRoles: {}, sessionId: "test", clientType: "web",
        }),
      }) as never;
      const put = (body: unknown) => handleWorkerPersonShares(
        new Request("https://test/api", { method: "PUT", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }),
        envFor("alice"), "worker-alice");
      await f.sqlite.exec(`${user("carol")}`);
      await expect(put({ userId: "carol" })).rejects.toMatchObject({ status: 422 });
      await f.sqlite.exec(`INSERT INTO people_relationships (user_low_id, user_high_id, established_at) VALUES ('alice', 'bob', now()) ON CONFLICT DO NOTHING`);
      // Sharing is a Plus feature: a Free owner cannot add a share.
      await f.sqlite.exec(`UPDATE account_plans SET tier = 'free' WHERE user_id = 'alice'`);
      await expect(put({ userId: "bob" })).rejects.toMatchObject({ status: 402, code: "paid_plan_required" });
      await f.sqlite.exec(`UPDATE account_plans SET tier = 'paid' WHERE user_id = 'alice'`);
      const shared = (await (await put({ userId: "bob", maxRunSecondsPerMonth: 3600 })).json()) as { shares: unknown[] };
      expect(shared.shares).toEqual([expect.objectContaining({ userId: "bob", maxConcurrentRequests: 1, maxRunSecondsPerMonth: 3600 })]);
      // Another person cannot manage the owner's shares.
      await expect(handleWorkerPersonShares(new Request("https://test/api"), envFor("bob"), "worker-alice")).rejects.toMatchObject({ status: 403 });
      const mine = (await (await handleListWorkersSharedWithMe(new Request("https://test/api"), envFor("bob"))).json()) as {
        workers: { id: string; sharedByName: string }[];
      };
      expect(mine.workers.map((w) => [w.id, w.sharedByName])).toEqual([["worker-alice", "alice"]]);
      // A lapsed plan pauses the share without deleting it; renewing restores it.
      await f.sqlite.exec(`UPDATE account_plans SET tier = 'free' WHERE user_id = 'alice'`);
      const paused = (await (await handleListWorkersSharedWithMe(new Request("https://test/api"), envFor("bob"))).json()) as { workers: unknown[] };
      expect(paused.workers).toEqual([]);
      await f.sqlite.exec(`UPDATE account_plans SET tier = 'paid' WHERE user_id = 'alice'`);
      const restored = (await (await handleListWorkersSharedWithMe(new Request("https://test/api"), envFor("bob"))).json()) as { workers: unknown[] };
      expect(restored.workers).toHaveLength(1);
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
  });
});
