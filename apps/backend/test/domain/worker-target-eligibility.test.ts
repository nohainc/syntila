import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread, member, user } from "./helpers/seed";
import { acceptWorkerTarget, declaredProfileCapabilities } from "../../src/domain/worker-eligibility.js";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import { resolveWorkerTargetBindings, recheckWorkerTarget } from "../../src/domain/routes/worker-target-bindings.js";
import { handleListEligibleWorkers, handleValidateWorkRequest } from "../../src/domain/routes/work-creation.js";

async function fixture() {
  const f = await pgD1();
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })} ${user("bob")} ${member("sp", "bob", "viewer")}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES
      ('worker-alice','','alice','chatgpt','Writer'), ('worker-bob','','bob','chatgpt','Writer');
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

    // Unlisted member (carol) is rejected.
    expect(await f.accept({ requesterUserId: "carol" })).toEqual({ ok: false, code: "worker_not_found" });

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
      expect(await carolEligible.json()).toEqual({ workflowId: "chat", workerIds: [] });

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
