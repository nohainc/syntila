import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread, member, user } from "./helpers/seed";
import { acceptWorkerTarget } from "../../src/domain/worker-eligibility.js";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import { resolveWorkerTargetBindings, recheckWorkerTarget } from "../../src/domain/routes/worker-target-bindings.js";
import { handleValidateWorkRequest } from "../../src/domain/routes/work-creation.js";

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
      expect(await (await handleValidateWorkRequest(request(), env, "th")).json()).toMatchObject({ eligible: true, issues: [] });
      await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at=now()-interval '1 second'");
      expect(await (await handleValidateWorkRequest(request(), env, "th")).json()).toMatchObject({ eligible: false, issues: [{ code: "worker_offline" }] });
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
      else process.env.SYNTILA_FEATURE_FLAGS = prior;
    }
  });
});
