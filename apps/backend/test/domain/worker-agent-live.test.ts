import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user } from "./helpers/seed";
import { createPairingChallenge } from "../../src/domain/worker-agents.js";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { canonicalJson } from "../../src/domain/canonical-json.js";

// Exercises the actual Dart Agent and Bun WebSocket adapter together.
describe.skipIf(!Bun.which("dart"))("Agent compatibility gateway", () => {
  it("pairs and reconciles against the real backend", async () => {
    const f = await pgD1();
    await f.sqlite.exec(`${user("alice")}
      INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('worker-live-01','','alice','chatgpt','Worker');`);
    const challenge = await createPairingChallenge({ SYNTILA_DB: f.db }, { ownerUserId: "alice", workerId: "worker-live-01", kind: "pair" });
    const signing = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    const signingPrivate = await crypto.subtle.exportKey("jwk", signing.privateKey);
    const signingPublic = await crypto.subtle.exportKey("jwk", signing.publicKey);
    const profile = JSON.parse(readFileSync(join(import.meta.dir, "../../../../packages/tool-profile/test/fixtures/fixture-cli.v1.json"), "utf8"));
    profile.logicalWorkerTypeId = "chatgpt";
    const profileDigest = Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson(profile)))).toString("hex");
    await f.sqlite.prepare("INSERT INTO worker_profiles(worker_type_id,schema_version,profile_json,revision,digest,updated_at) VALUES ('chatgpt',1,?,1,?,now())").run(JSON.stringify(profile), profileDigest);
    const port = 40_000 + Math.floor(Math.random() * 20_000);
    const url = new URL(f.url);
    const server = Bun.spawn(["bun", "src/server.ts"], {
      cwd: join(import.meta.dir, "../.."),
      env: { ...process.env, CREDENTIALS_DIRECTORY: "", SYNTILA_PROFILE_SIGNING_JWK: JSON.stringify(signingPrivate), SYNTILA_PROFILE_SIGNING_KEY_ID: "test-key", SYNTILA_ENVIRONMENT: "test", PGHOST: url.hostname, PGPORT: url.port, PGUSER: decodeURIComponent(url.username), PGPASSWORD: decodeURIComponent(url.password) || "test", PGDATABASE: url.pathname.slice(1), PG_POOL_MAX: "5", BIND_HOST: "127.0.0.1", PORT: String(port) },
      stdout: "inherit", stderr: "inherit",
    });
    try {
      const origin = `http://127.0.0.1:${port}`;
      const deadline = Date.now() + 15_000;
      // pgD1 applies the schema directly without the migration ledger, so the
      // fixture server's readiness endpoint intentionally reports not ready.
      while (!(await fetch(`${origin}/health/live`).catch(() => null))?.ok) {
        if (Date.now() > deadline) throw new Error("backend did not start");
        await Bun.sleep(50);
      }
      const agent = Bun.spawn(["dart", "run", "test/support/real_server_probe.dart"], {
        cwd: join(import.meta.dir, "../../../connect"), stdin: "pipe", stdout: "pipe", stderr: "pipe",
      });
      agent.stdin.write(JSON.stringify({ serverUrl: origin, workerId: challenge.workerId, challengeId: challenge.challengeId, secret: challenge.secret, profileDigest, profilePublicKey: signingPublic.x }) + "\n");
      agent.stdin.end();
      const [out, err] = await Promise.all([new Response(agent.stdout).text(), new Response(agent.stderr).text()]);
      expect({ code: await agent.exited, out, err }).toMatchObject({ code: 0, out: expect.stringContaining("AGENT_READY") });
      expect(out).toContain("PROFILE_VERIFIED");
    } finally {
      server.kill();
      await server.exited;
    }
  }, 30_000);
});
