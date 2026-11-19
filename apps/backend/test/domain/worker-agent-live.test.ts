import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user, workspace } from "./helpers/seed";
import { createPairingChallenge } from "../../src/domain/worker-agents.js";
import { join } from "node:path";

// Exercises the actual Dart Agent and Bun WebSocket adapter together.
describe.skipIf(!Bun.which("dart"))("Agent compatibility gateway", () => {
  it("pairs and completes hello and reconciliation against the real backend", async () => {
    const f = await pgD1();
    await f.sqlite.exec(`${user("alice")} ${workspace("WS", "alice")}
      INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT','WS','h','inst',now());
      INSERT INTO workspace_worker_inventory (worker_id,workspace_id,owner_user_id,worker_type_id,activation_state,readiness_state,local_concurrency_limit,revision,created_at,updated_at,last_seen_at)
      VALUES ('worker-live-01','WS','alice','chatgpt','enabled','ready',1,1,now(),now(),now())`);
    const challenge = await createPairingChallenge({ SYNTILA_DB: f.db }, { ownerUserId: "alice", workerId: "worker-live-01", kind: "pair" });
    const port = 40_000 + Math.floor(Math.random() * 20_000);
    const url = new URL(f.url);
    const server = Bun.spawn(["bun", "src/server.ts"], {
      cwd: join(import.meta.dir, "../.."),
      env: { ...process.env, CREDENTIALS_DIRECTORY: "", SYNTILA_ENVIRONMENT: "test", SYNTILA_FEATURE_FLAGS: "worker_identity,worker_agent_connect", PGHOST: url.hostname, PGPORT: url.port, PGUSER: decodeURIComponent(url.username), PGPASSWORD: decodeURIComponent(url.password) || "test", PGDATABASE: url.pathname.slice(1), PG_POOL_MAX: "5", BIND_HOST: "127.0.0.1", PORT: String(port) },
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
        cwd: join(import.meta.dir, "../../../worker_agent"), stdin: "pipe", stdout: "pipe", stderr: "pipe",
      });
      agent.stdin.write(JSON.stringify({ serverUrl: origin, workerId: challenge.workerId, challengeId: challenge.challengeId, secret: challenge.secret }) + "\n");
      agent.stdin.end();
      const [out, err] = await Promise.all([new Response(agent.stdout).text(), new Response(agent.stderr).text()]);
      expect({ code: await agent.exited, out, err }).toMatchObject({ code: 0, out: expect.stringContaining("AGENT_READY") });
    } finally {
      server.kill();
      await server.exited;
    }
  }, 30_000);
});
