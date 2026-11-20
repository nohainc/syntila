import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user } from "./helpers/seed";
import { hashToken } from "@syntila/security";
import { canonicalJson } from "../../src/domain/canonical-json.js";
import { handleAgentProfile } from "../../src/domain/routes/worker-profile-delivery.js";
import { readFileSync } from "node:fs";

describe("Agent Profile delivery", () => {
  it("authenticates the Agent and signs only the matching published revision", async () => {
    const f = await pgD1();
    const profile = JSON.parse(readFileSync(new URL("../../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json", import.meta.url), "utf8"));
    profile.logicalWorkerTypeId = "chatgpt";
    const digest = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson(profile)))).toString("hex");
    const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    const prior = { flags: process.env.SYNTILA_FEATURE_FLAGS, key: process.env.SYNTILA_PROFILE_SIGNING_JWK, id: process.env.SYNTILA_PROFILE_SIGNING_KEY_ID };
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect";
    process.env.SYNTILA_PROFILE_SIGNING_JWK = JSON.stringify(await crypto.subtle.exportKey("jwk", pair.privateKey));
    process.env.SYNTILA_PROFILE_SIGNING_KEY_ID = "test-key";
    try {
      await f.sqlite.exec(`${user("alice")}
        INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('w','','alice','chatgpt','Worker');
        INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('c','w','${"a".repeat(43)}','${"a".repeat(64)}');
        INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at) VALUES ('w','s',1,'c','${await hashToken("token")}',now()+interval '5 minutes');`);
      await f.sqlite.prepare("INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES ('chatgpt',1,?,1,?,now())").run(JSON.stringify(profile), digest);
      await f.sqlite.prepare("INSERT INTO worker_profile_history(worker_type_id,schema_version,profile_json,revision,digest,published_at) VALUES ('chatgpt',1,?,2,?,now())").run(JSON.stringify(profile), digest);
      const request = (token: string, revision = 1) => new Request(`https://test/api/worker-agent/profile?revision=${revision}&digest=${digest}`, { headers: { authorization: `Bearer ${token}`, "x-worker-id": "w", "x-worker-session-id": "s" } });
      const response = await handleAgentProfile(request("token"), { SYNTILA_DB: f.db } as never);
      const body = await response.json() as { snapshot: { digest: string }; proof: string };
      const proof = JSON.parse(body.proof);
      expect(body.snapshot.digest).toBe(digest);
      expect(await crypto.subtle.verify("Ed25519", pair.publicKey, Buffer.from(proof.signature, "base64url"), new TextEncoder().encode(`syntila-worker-profile-v1\n${digest}`))).toBe(true);
      expect(((await (await handleAgentProfile(request("token", 2), { SYNTILA_DB: f.db } as never)).json()) as { snapshot: { revision: number } }).snapshot.revision).toBe(2);
      await expect(handleAgentProfile(request("wrong"), { SYNTILA_DB: f.db } as never)).rejects.toMatchObject({ status: 401 });
      await expect(handleAgentProfile(request("token", 3), { SYNTILA_DB: f.db } as never)).rejects.toMatchObject({ status: 404 });
    } finally {
      for (const [key, value] of Object.entries({ SYNTILA_FEATURE_FLAGS: prior.flags, SYNTILA_PROFILE_SIGNING_JWK: prior.key, SYNTILA_PROFILE_SIGNING_KEY_ID: prior.id })) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
      await f.sqlite.close();
    }
  });
});
