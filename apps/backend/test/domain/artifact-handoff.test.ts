import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { hashToken } from "@syntila/security";
import {
  assertHandoffAvailable, expireArtifacts, handleDownloadArtifact, MissingArtifactError,
} from "../../src/domain/artifacts.js";

const A1 = "art-11111111-1111-4111-8111-111111111111";
const A2 = "art-22222222-2222-4222-8222-222222222222";

async function fixture() {
  const f = await pgD1();
  const stored: Record<string, string> = { "work-request-inputs/wrf-1": "hello" };
  const bucket = {
    get: async (key: string) => (key in stored ? { body: new Blob([stored[key]!]).stream() } : null),
    delete: async (keys: string[]) => { for (const k of keys) delete stored[k]; },
  };
  const env = { SYNTILA_DB: f.db, SYNTILA_ARTIFACTS: bucket } as never;
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES
      ('worker-mac','','alice','chatgpt','Mac'), ('worker-linux','','alice','chatgpt','Linux');
    INSERT INTO artifacts(id,space_id,thread_id,content_digest,storage_key,created_at,name,media_type,size_bytes,state,expires_at)
      VALUES ('${A1}','sp','th','sha256:${"a".repeat(64)}','work-request-inputs/wrf-1',now(),'report.txt','text/plain',5,'available',now()+interval '1 day'),
             ('${A2}','sp','th','sha256:${"b".repeat(64)}','work-request-inputs/wrf-2',now(),'old.txt','text/plain',5,'available',now()-interval '1 minute')`);
  return { ...f, env, stored };
}

describe("artifact handoff", () => {
  it("accepts artifact IDs and rejects paths, unknown and expired artifacts", async () => {
    const f = await fixture();
    await assertHandoffAvailable(f.env, { artifactIds: [A1], spaceId: "sp" });
    for (const ref of ["/Users/alice/report.txt", "../x", "report.txt", A2, "art-33333333-3333-4333-8333-333333333333"])
      await expect(assertHandoffAvailable(f.env, { artifactIds: [ref], spaceId: "sp" })).rejects.toBeInstanceOf(MissingArtifactError);
    await expect(assertHandoffAvailable(f.env, { artifactIds: [A1], spaceId: "other" })).rejects.toBeInstanceOf(MissingArtifactError);
    await f.sqlite.close();
  });

  it("downloads only with the grant, as the granted Worker, before it expires", async () => {
    const f = await fixture();
    const token = "grant-token-1";
    await f.sqlite.exec(`INSERT INTO artifact_download_grants(id,artifact_id,worker_instance_id,token_digest,expires_at)
      VALUES ('g1','${A1}','worker-linux','${await hashToken(token)}',now()+interval '5 minutes')`);
    const agent = async (workerId: string, grant?: string) => {
      const key = workerId === "worker-linux" ? "a" : "b";
      await f.sqlite.exec(`INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('c-${workerId}','${workerId}','${key.repeat(43)}','${key.repeat(64)}') ON CONFLICT DO NOTHING;
        INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at)
        VALUES ('${workerId}','s-${workerId}',1,'c-${workerId}','${await hashToken("sess")}',now()+interval '5 minutes') ON CONFLICT DO NOTHING`);
      return new Request(`https://x/api/worker-agent/artifacts/${A1}/content`, {
        headers: { authorization: "Bearer sess", "x-worker-id": workerId, "x-worker-session-id": `s-${workerId}`, ...(grant ? { "x-artifact-grant": grant } : {}) },
      });
    };
    const prior = process.env.SYNTILA_FEATURE_FLAGS;
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect,artifact_handoff";
    try {
      const ok = await handleDownloadArtifact(await agent("worker-linux", token), f.env, A1);
      expect(await ok.text()).toBe("hello");
      await expect(handleDownloadArtifact(await agent("worker-linux"), f.env, A1)).rejects.toMatchObject({ status: 404 });
      await expect(handleDownloadArtifact(await agent("worker-mac", token), f.env, A1)).rejects.toMatchObject({ status: 404 });
      await f.sqlite.exec("UPDATE artifact_download_grants SET expires_at = now() - interval '1 second'");
      await expect(handleDownloadArtifact(await agent("worker-linux", token), f.env, A1)).rejects.toMatchObject({ status: 404 });
    } finally {
      if (prior === undefined) delete process.env.SYNTILA_FEATURE_FLAGS; else process.env.SYNTILA_FEATURE_FLAGS = prior;
      await f.sqlite.close();
    }
  });

  it("retention expires due artifacts and removes their bytes", async () => {
    const f = await fixture();
    f.stored["work-request-inputs/wrf-2"] = "bye";
    expect(await expireArtifacts(f.env)).toBe(1);
    expect(f.stored["work-request-inputs/wrf-2"]).toBeUndefined();
    expect((await f.sqlite.prepare("SELECT state FROM artifacts WHERE id = ?").get(A2))?.state).toBe("expired");
    expect((await f.sqlite.prepare("SELECT state FROM artifacts WHERE id = ?").get(A1))?.state).toBe("available");
    await f.sqlite.close();
  });
});
