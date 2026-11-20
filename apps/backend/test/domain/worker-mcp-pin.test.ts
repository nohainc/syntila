import { afterAll, describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { acceptWorkerTarget } from "../../src/domain/worker-eligibility.js";

// ADR-041: an MCP Worker Type runs on a Worker Agent only under flag
// `worker_plugins`, for an entitled owner, with an owner-set pin that is still a
// version in the owner's own library. The Type has no Profile.
const priorFlags = process.env.SYNTILA_FEATURE_FLAGS;
afterAll(() => {
  if (priorFlags === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
  else process.env.SYNTILA_FEATURE_FLAGS = priorFlags;
});

const REF = "plugin-3fa91c04b2d7";
const DIGEST = "c".repeat(64);

async function fixture(flags = "worker_identity,worker_agent_connect,worker_target_dispatch,worker_plugins") {
  process.env.SYNTILA_FEATURE_FLAGS = flags;
  const f = await pgD1();
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
    INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES ('alice','paid','active','manual',now(),now());
    INSERT INTO account_worker_plugins(plugin_ref,owner_user_id,plugin_id,display_name,created_at,updated_at)
      VALUES ('${REF}','alice','acme-tool','Acme',now(),now());
    INSERT INTO account_worker_plugin_versions(plugin_ref,version,manifest_digest,manifest_json,origin_json,created_at)
      VALUES ('${REF}','1.4.2','${DIGEST}','{}','{}',now()), ('${REF}','1.5.0','${"d".repeat(64)}','{}','{}',now());
    INSERT INTO worker_catalog(worker_type_id,display_name,origin,owner_user_id,created_at,updated_at)
      VALUES ('${REF}','Acme','plugin','alice',now(),now());
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('worker-p','','alice','${REF}','Acme');
    INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('cred-p','worker-p','${"a".repeat(43)}','${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at)
      VALUES ('worker-p','session-p',1,'cred-p','digest',now() + interval '5 minutes')`);
  const pin = (version: string, digest: string) =>
    f.sqlite.exec(`INSERT INTO worker_instance_mcp_pins(worker_instance_id,plugin_ref,version,manifest_digest) VALUES ('worker-p','${REF}','${version}','${digest}')`);
  const accept = () =>
    acceptWorkerTarget(f.read, { workerId: "worker-p", requesterUserId: "alice", spaceId: "sp", threadId: "th", workflowId: "chat", readOnly: true, capabilities: ["authorized_context_read"], requireOnline: true });
  return { ...f, pin, accept };
}

describe("MCP Worker eligibility", () => {
  it("needs a pin, then accepts without a Profile and names the exact MCP Worker", async () => {
    const f = await fixture();
    expect(await f.accept()).toEqual({ ok: false, code: "worker_type_unavailable" });
    await f.pin("1.4.2", DIGEST);
    const accepted = await f.accept();
    if (!accepted.ok) throw new Error(`expected acceptance, got ${accepted.code}`);
    expect(accepted.snapshot.profile).toBeNull();
    expect(accepted.snapshot.mcpWorker).toEqual({ id: "acme-tool", version: "1.4.2", manifestDigest: DIGEST });
    await f.sqlite.close();
  });

  it("refuses when the flag is off, the owner is not entitled, or the pin left the library", async () => {
    const off = await fixture("worker_identity,worker_agent_connect,worker_target_dispatch");
    await off.pin("1.4.2", DIGEST);
    expect(await off.accept()).toEqual({ ok: false, code: "worker_type_unavailable" });
    await off.sqlite.close();

    const f = await fixture();
    await f.pin("1.4.2", DIGEST);
    await f.sqlite.exec("UPDATE account_plans SET tier='free' WHERE user_id='alice'");
    expect(await f.accept()).toEqual({ ok: false, code: "worker_type_unavailable" });
    await f.sqlite.exec("UPDATE account_plans SET tier='paid' WHERE user_id='alice'");
    expect((await f.accept()).ok).toBe(true);
    // Deleting the pinned version removes the pin with it.
    await f.sqlite.exec(`DELETE FROM account_worker_plugin_versions WHERE plugin_ref='${REF}' AND version='1.4.2'`);
    expect(await f.accept()).toEqual({ ok: false, code: "worker_type_unavailable" });
    await f.sqlite.close();
  });

  it("refuses a pin whose digest is not the library version's digest", async () => {
    const f = await fixture();
    await expect(f.pin("1.4.2", "e".repeat(64))).rejects.toThrow();
    await f.sqlite.close();
  });
});
