import { afterAll, beforeAll, describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { space, user, workspace } from "./helpers/seed";
import { queryOf } from "../../src/platform/data.js";
import { transitionAssignment } from "../../src/domain/assignment-transitions.js";
import { grantStartPermit } from "../../src/domain/assignment-start-permit.js";
import { finalizeAssignmentRevocation } from "../../src/domain/assignment-revocation.js";
import { handleWorkspaceGatewayConnect } from "../../src/domain/routes/workspaces-runtime.js";
import { recordAssignmentError, recordAssignmentResult } from "../../src/domain/assignment-dispatcher.js";
import { agentFenceIsCurrent } from "../../src/domain/agent-session-fence.js";
import {
  AgentLeaseKeeper,
  LEASE_RENEW_MIN_MS,
  actionMessage,
  authenticateAgentSession,
  claimPairing,
  connectSession,
  createPairingChallenge,
  expireLapsedSessions,
  issueNonce,
  pairingMessage,
  revokeWorkerCredential,
  rotateCredential,
  toBase64Url,
} from "../../src/domain/worker-agents.js";
import {
  HttpError,
  handleClaimWorkerPairing,
  handleConnectWorkerSession,
  handleWorkerCredential,
  handleWorkerNonce,
  handleWorkerPairing,
  handleWorkerTransfer,
  type SecurityEnv,
} from "../../src/domain/routes/handlers.js";

// Worker pairing, credentials and session fencing (ADR-034, P3).

const savedFlags = process.env.SYNTILA_FEATURE_FLAGS;
beforeAll(() => { process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect"; });
afterAll(() => {
  if (savedFlags === undefined) delete process.env.SYNTILA_FEATURE_FLAGS;
  else process.env.SYNTILA_FEATURE_FLAGS = savedFlags;
});

const W1 = "worker-agent-01";
const W2 = "worker-agent-02";

async function status(call: Promise<unknown>): Promise<number> {
  try { await call; return 200; } catch (error: any) { return error.status ?? 500; }
}

/** An Agent's key pair. The private key stays in this object, like on a host. */
async function keys() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const publicKey = toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey)));
  const sign = async (message: string) =>
    toBase64Url(new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, pair.privateKey, new TextEncoder().encode(message))));
  return { publicKey, sign };
}
type Keys = Awaited<ReturnType<typeof keys>>;

async function fixture() {
  const { sqlite, db } = await pgD1();
  await sqlite.exec(`
    ${user("alice")} ${user("bob")} ${space("sp", "alice")} ${workspace("WS", "alice")}
    INSERT INTO workspace_runtime_identities(id,workspace_id,credential_token_hash,installation_id,created_at) VALUES('RT','WS','h','inst',now());
    INSERT INTO workspace_worker_inventory (worker_id, workspace_id, owner_user_id, worker_type_id, activation_state, readiness_state,
      local_concurrency_limit, revision, created_at, updated_at, last_seen_at)
    VALUES ('${W1}', 'WS', 'alice', 'chatgpt', 'enabled', 'ready', 1, 1, now(), now(), now()),
           ('${W2}', 'WS', 'alice', 'chatgpt', 'enabled', 'ready', 1, 1, now(), now(), now());`);
  const env = { SYNTILA_DB: db };
  const one = async (text: string) => (await sqlite.prepare(text).all()) as Record<string, any>[];

  const pair = async (workerId = W1, key?: Keys) => {
    const k = key ?? (await keys());
    const challenge = await createPairingChallenge(env, { ownerUserId: "alice", workerId, kind: "pair" });
    const claim = await claimPairing(env, {
      challengeId: challenge.challengeId, secret: challenge.secret, publicKey: k.publicKey,
      signature: await k.sign(pairingMessage(challenge.challengeId, workerId, k.publicKey)),
    });
    return { key: k, challenge, claim };
  };
  const login = async (key: Keys, workerId = W1) => {
    const n = await issueNonce(env, workerId);
    return connectSession(env, {
      workerId, nonceId: n.nonceId,
      signature: await key.sign(actionMessage("session", workerId, n.nonceId, n.nonce)),
      clientVersion: "test",
    });
  };
  const seedAssignment = async (id: string, workerId = W1, status = "dispatched") => {
    await sqlite.exec(`INSERT INTO worker_assignments
      (id,space_id,execution_workspace_id,runtime_identity_id,worker_type_id,workspace_worker_id,status,permission_snapshot_json,session_policy,attempt_id,created_at,updated_at)
      VALUES ('${id}','sp','WS','RT','chatgpt','${workerId}','${status}','{}','stateless','att-${id}',now(),now())`);
  };
  return { sqlite, db, env, one, pair, login, seedAssignment };
}

describe("pairing", () => {
  it("claims a challenge with the Agent's public key, once, and audits both steps", async () => {
    const f = await fixture();
    const { key, challenge, claim } = await f.pair();
    expect(claim).toMatchObject({ workerId: W1, kind: "pair" });
    const [credential] = await f.one("SELECT public_key, revoked_at FROM worker_credentials");
    expect(credential.public_key).toBe(key.publicKey);
    expect(credential.revoked_at).toBeNull();
    // Only a digest of the secret is stored.
    const [stored] = await f.one("SELECT secret_digest FROM worker_pairing_challenges");
    expect(stored.secret_digest).not.toBe(challenge.secret);
    expect(stored.secret_digest).toMatch(/^[0-9a-f]{64}$/);
    // The same challenge cannot be claimed again (replay), even with a valid signature.
    const again = await keys();
    expect(
      await status(
        claimPairing(f.env, {
          challengeId: challenge.challengeId, secret: challenge.secret, publicKey: again.publicKey,
          signature: await again.sign(pairingMessage(challenge.challengeId, W1, again.publicKey)),
        }),
      ),
    ).toBe(410);
    const actions = (await f.one("SELECT action FROM worker_audit_log ORDER BY created_at, id")).map((r) => r.action);
    expect(actions).toContain("pairing.created");
    expect(actions).toContain("pairing.claimed");
    expect(actions).toContain("pairing.refused");
  });

  it("refuses an expired challenge, a wrong secret and an unknown challenge", async () => {
    const f = await fixture();
    const k = await keys();
    const challenge = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" });
    const claim = async (id: string, secret: string) =>
      claimPairing(f.env, { challengeId: id, secret, publicKey: k.publicKey, signature: await k.sign(pairingMessage(id, W1, k.publicKey)) });
    expect(await status(claim(challenge.challengeId, `${challenge.secret}x`))).toBe(403);
    expect(await status(claim("wpc-unknown", challenge.secret))).toBe(403);
    await f.sqlite.exec("UPDATE worker_pairing_challenges SET expires_at = now() - interval '1 second'");
    expect(await status(claim(challenge.challengeId, challenge.secret))).toBe(410);
    expect(await f.one("SELECT 1 FROM worker_credentials")).toHaveLength(0);
  });

  it("refuses a claim made as another user, and a challenge for another user's Worker", async () => {
    const f = await fixture();
    const k = await keys();
    expect(await status(createPairingChallenge(f.env, { ownerUserId: "bob", workerId: W1, kind: "pair" }))).toBe(404);
    const challenge = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" });
    const input = {
      challengeId: challenge.challengeId, secret: challenge.secret, publicKey: k.publicKey,
      signature: await k.sign(pairingMessage(challenge.challengeId, W1, k.publicKey)),
    };
    expect(await status(claimPairing(f.env, { ...input, claimingUserId: "bob" }))).toBe(403);
    expect(await f.one("SELECT 1 FROM worker_credentials")).toHaveLength(0);
    // The refusal did not burn the challenge: the owner's own Agent can still claim it.
    await claimPairing(f.env, { ...input, claimingUserId: "alice" });
    expect(await f.one("SELECT 1 FROM worker_credentials")).toHaveLength(1);
  });

  it("does not consume the challenge when the signature is wrong", async () => {
    const f = await fixture();
    const k = await keys();
    const other = await keys();
    const challenge = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" });
    const input = { challengeId: challenge.challengeId, secret: challenge.secret, publicKey: k.publicKey };
    expect(await status(claimPairing(f.env, { ...input, signature: await other.sign(pairingMessage(challenge.challengeId, W1, k.publicKey)) }))).toBe(401);
    // A signature made for another worker id does not verify either (the message binds the Worker).
    expect(await status(claimPairing(f.env, { ...input, signature: await k.sign(pairingMessage(challenge.challengeId, W2, k.publicKey)) }))).toBe(401);
    await claimPairing(f.env, { ...input, signature: await k.sign(pairingMessage(challenge.challengeId, W1, k.publicKey)) });
    expect(await f.one("SELECT 1 FROM worker_credentials")).toHaveLength(1);
  });

  it("starts a new challenge only when it makes sense, and only the newest challenge is valid", async () => {
    const f = await fixture();
    expect(await status(createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "transfer" }))).toBe(409); // not paired
    const first = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" });
    const second = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" });
    const k = await keys();
    const claim = (c: { challengeId: string; secret: string }) =>
      claimPairing(f.env, { challengeId: c.challengeId, secret: c.secret, publicKey: k.publicKey, signature: undefined as never });
    expect(await status(claim(first))).toBe(410); // superseded (checked before the signature)
    expect(second.challengeId).not.toBe(first.challengeId);
    const paired = await f.pair(W1);
    expect(paired.claim.workerId).toBe(W1);
    expect(await status(createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "pair" }))).toBe(409); // already paired
  });

  it("refuses a code from another account while this computer has that account's paired Workers", async () => {
    const f = await fixture();
    await f.sqlite.exec(`INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name)
      VALUES ('worker-bob','','bob','chatgpt','Bob')`);
    await f.pair(W1);
    const k = await keys();
    const claimAsBob = async () => {
      const c = await createPairingChallenge(f.env, { ownerUserId: "bob", workerId: "worker-bob", kind: "pair" });
      return claimPairing(f.env, {
        challengeId: c.challengeId, secret: c.secret, publicKey: k.publicKey,
        signature: await k.sign(pairingMessage(c.challengeId, "worker-bob", k.publicKey)),
        pairedWorkerIds: [W1],
      });
    };
    await expect(claimAsBob()).rejects.toMatchObject({ status: 409, message: expect.stringContaining("another Syntila account") });
    expect(await f.one("SELECT 1 FROM worker_credentials WHERE worker_instance_id = 'worker-bob'")).toHaveLength(0);
    // The same account is never blocked by its own Workers.
    const own = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W2, kind: "pair" });
    const k2 = await keys();
    await claimPairing(f.env, {
      challengeId: own.challengeId, secret: own.secret, publicKey: k2.publicKey,
      signature: await k2.sign(pairingMessage(own.challengeId, W2, k2.publicKey)), pairedWorkerIds: [W1],
    });
    // Once Alice's Workers are unpaired here, Bob may pair.
    await f.sqlite.exec(`UPDATE worker_credentials SET revoked_at = now(), revoked_reason = 'revoked' WHERE worker_instance_id IN ('${W1}', '${W2}')`);
    expect((await claimAsBob()).workerId).toBe("worker-bob");
  });

  it("does not let one key serve two Workers", async () => {
    const f = await fixture();
    const shared = await keys();
    await f.pair(W1, shared);
    expect(await status(f.pair(W2, shared))).toBe(409);
  });
});

describe("authentication by signed nonce", () => {
  it("connects with a valid signature, and refuses a replayed, expired, forged or cross-purpose one", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const n = await issueNonce(f.env, W1);
    const signature = await key.sign(actionMessage("session", W1, n.nonceId, n.nonce));
    const session = await connectSession(f.env, { workerId: W1, nonceId: n.nonceId, signature });
    expect(session.epoch).toBe(1);
    // Replay of the same nonce and signature.
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: n.nonceId, signature }))).toBe(401);
    // Expired nonce.
    const old = await issueNonce(f.env, W1);
    await f.sqlite.exec(`UPDATE worker_auth_nonces SET expires_at = now() - interval '1 second' WHERE id = '${old.nonceId}'`);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: old.nonceId, signature: await key.sign(actionMessage("session", W1, old.nonceId, old.nonce)) }))).toBe(401);
    // A signature made by another key.
    const forger = await keys();
    const forged = await issueNonce(f.env, W1);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: forged.nonceId, signature: await forger.sign(actionMessage("session", W1, forged.nonceId, forged.nonce)) }))).toBe(401);
    // A failed attempt still spends the nonce: the right signature on it no longer works.
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: forged.nonceId, signature: await key.sign(actionMessage("session", W1, forged.nonceId, forged.nonce)) }))).toBe(401);
    // A signature for another purpose (rotate) is not a login.
    const cross = await issueNonce(f.env, W1);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: cross.nonceId, signature: await key.sign(actionMessage("rotate", W1, cross.nonceId, cross.nonce)) }))).toBe(401);
    // A nonce of one Worker cannot be used for another.
    expect(await status(issueNonce(f.env, W2))).toBe(404); // not paired
  });

  it("stores no long-lived secret: the session token is kept as a digest", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    const [row] = await f.one("SELECT token_digest FROM worker_agent_sessions");
    expect(row.token_digest).not.toBe(session.sessionToken);
    const everything = JSON.stringify(await f.one("SELECT * FROM worker_audit_log"));
    expect(everything).not.toContain(session.sessionToken);
  });

  it("limits open nonces per Worker", async () => {
    const f = await fixture();
    await f.pair();
    for (let i = 0; i < 8; i++) await issueNonce(f.env, W1);
    expect(await status(issueNonce(f.env, W1))).toBe(429);
  });
});

describe("session fencing", () => {
  it("rejects a superseded session's revocation confirmation and start permit", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    await f.seedAssignment("cancel", W1, "revocation_pending");
    await f.seedAssignment("permit", W1, "acknowledged");
    const old = await f.login(key);
    const current = await f.login(key);
    expect(await finalizeAssignmentRevocation(f.db, "cancel", "att-cancel", old)).not.toBe("finalized");
    expect((await f.one("SELECT status FROM worker_assignments WHERE id='cancel'"))[0]!.status).toBe("revocation_pending");
    expect(await grantStartPermit(queryOf(f.db), { assignmentId: "permit", attemptId: "att-permit", agent: old })).toEqual({ granted: false, reason: "stale" });
    expect((await f.one("SELECT start_permit_issued_at FROM worker_assignments WHERE id='permit'"))[0]!.start_permit_issued_at).toBeNull();
    expect(await finalizeAssignmentRevocation(f.db, "cancel", "att-cancel", current)).toBe("finalized");
    expect((await grantStartPermit(queryOf(f.db), { assignmentId: "permit", attemptId: "att-permit", agent: current })).granted).toBe(true);
  });

  it("routes an authenticated Agent session to its mapped Workspace gateway", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const old = await f.login(key);
    const current = await f.login(key);
    const forwarded: string[] = [];
    const env = { ...f.env, SYNTILA_WORKSPACE_GATEWAY: { getByName(name: string) { forwarded.push(name); return { fetch: async () => new Response("forwarded") }; } } } as never;
    const connect = (session: typeof old, token = session.sessionToken) => handleWorkspaceGatewayConnect(new Request(`https://test/api/workspace-gateway/connect?workerId=${W1}&workerSessionId=${session.sessionId}`, { headers: { upgrade: "websocket", authorization: `Bearer ${token}` } }), env);
    expect((await connect(old)).status).toBe(401);
    expect((await connect(current, "wrong")).status).toBe(401);
    expect((await connect(current)).status).toBe(200);
    expect(forwarded).toEqual(["WS"]);
  });

  it("does not grant a permit if the session changes after admission", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    await f.seedAssignment("permit", W1, "dispatched");
    const old = await f.login(key);
    const query = queryOf(f.db);
    let replaced = false;
    const race = {
      ...query,
      async row<T>(strings: TemplateStringsArray, ...values: unknown[]): Promise<T | null> {
        if (!replaced && strings.join("?").includes("SET start_permit_issued_at")) {
          replaced = true;
          await f.login(key);
        }
        return query.row<T>(strings, ...values);
      },
    };
    expect(await grantStartPermit(race, { assignmentId: "permit", attemptId: "att-permit", agent: old })).toEqual({ granted: false, reason: "stale" });
    expect(replaced).toBe(true);
    expect((await f.one("SELECT start_permit_issued_at FROM worker_assignments WHERE id='permit'"))[0]!.start_permit_issued_at).toBeNull();
  });

  it("serializes an Agent write against a concurrent session replacement", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    await f.seedAssignment("a1", W1, "running");
    const old = await f.login(key);
    let locked!: () => void;
    let release!: () => void;
    const ready = new Promise<void>((resolve) => { locked = resolve; });
    const proceed = new Promise<void>((resolve) => { release = resolve; });
    const replace = f.db.sql.begin(async (tx) => {
      await tx`UPDATE worker_agent_sessions SET session_epoch=session_epoch+1, session_id='replacement' WHERE worker_instance_id=${W1}`;
      locked();
      await proceed;
    });
    await ready;
    const result = recordAssignmentResult(f.db, "a1", { output: "late" } as never, "att-a1", old);
    try {
      const deadline = Date.now() + 5000;
      let waiting = false;
      while (Date.now() < deadline && !waiting) {
        const [row] = await f.one("SELECT count(*)::int AS n FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%UPDATE worker_assignments%' ");
        waiting = Number(row!.n) > 0;
        if (!waiting) await Bun.sleep(10);
      }
      expect(waiting).toBe(true);
    } finally {
      release();
      await replace;
    }
    expect(await result).toBe(false);
    expect((await f.one("SELECT status FROM worker_assignments WHERE id='a1'"))[0]!.status).toBe("running");
  });
  it("makes the newer login win and rejects the older session's late result", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    await f.seedAssignment("a1");
    const older = await f.login(key);
    const newer = await f.login(key);
    expect([older.epoch, newer.epoch]).toEqual([1, 2]);

    // Only the newer session authenticates and is current.
    expect(await authenticateAgentSession(f.env, { workerId: W1, sessionId: older.sessionId, sessionToken: older.sessionToken })).toBeNull();
    const principal = await authenticateAgentSession(f.env, { workerId: W1, sessionId: newer.sessionId, sessionToken: newer.sessionToken });
    expect(principal).toMatchObject({ workerInstanceId: W1, epoch: 2, executionWorkspaceId: "WS" });
    const q = queryOf(f.db);
    expect(await agentFenceIsCurrent(q, older)).toBe(false);
    expect(await agentFenceIsCurrent(q, newer)).toBe(true);

    // The older session's acknowledgement is stale; the newer one's is applied.
    const stale = await transitionAssignment(q, { to: "acknowledged", fence: { assignmentId: "a1", attemptId: "att-a1", agent: older } });
    expect(stale).toMatchObject({ outcome: "stale", applied: false });
    expect((await f.one("SELECT status FROM worker_assignments WHERE id = 'a1'"))[0]!.status).toBe("dispatched");
    const ack = await transitionAssignment(q, { to: "acknowledged", fence: { assignmentId: "a1", attemptId: "att-a1", agent: newer } });
    expect(ack.applied).toBe(true);
    const run = await transitionAssignment(q, { to: "running", fence: { assignmentId: "a1", attemptId: "att-a1", agent: newer } });
    expect(run.applied).toBe(true);

    // The older session's late terminal result and failure are rejected in the write itself.
    expect(await recordAssignmentResult(f.db, "a1", { output: "late" } as never, "att-a1", older)).toBe(false);
    expect(await recordAssignmentError(f.db, "a1", { error: { code: "execution_failed", message: "x", retryable: false }, failedAt: "now" } as never, "att-a1", { agent: older })).toBe(false);
    expect((await f.one("SELECT status FROM worker_assignments WHERE id = 'a1'"))[0]!.status).toBe("running");
    // The current session's result is recorded.
    expect(await recordAssignmentResult(f.db, "a1", { output: "done" } as never, "att-a1", newer)).toBe(true);
    expect((await f.one("SELECT status FROM worker_assignments WHERE id = 'a1'"))[0]!.status).toBe("completed");
  });

  it("checks the attempt and the Worker as well as the epoch", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const other = await f.pair(W2);
    await f.seedAssignment("a1", W1, "running");
    const session = await f.login(key, W1);
    const otherSession = await f.login(other.key, W2);
    // Right session, wrong attempt.
    expect(await recordAssignmentResult(f.db, "a1", { output: "x" } as never, "att-other", session)).toBe(false);
    // Another Worker's session (current for that Worker) cannot write this Worker's assignment.
    expect(await recordAssignmentResult(f.db, "a1", { output: "x" } as never, "att-a1", otherSession)).toBe(false);
    const stale = await transitionAssignment(queryOf(f.db), { to: "running", fence: { assignmentId: "a1", attemptId: "att-a1", agent: otherSession } });
    expect(stale.applied).toBe(false);
    expect((await f.one("SELECT status FROM worker_assignments WHERE id = 'a1'"))[0]!.status).toBe("running");
    expect(await recordAssignmentResult(f.db, "a1", { output: "ok" } as never, "att-a1", session)).toBe(true);
  });

  it("leaves traffic without an Agent session (Workspace runtimes) unchanged", async () => {
    const f = await fixture();
    await f.seedAssignment("a1", W1, "running");
    expect(await recordAssignmentResult(f.db, "a1", { output: "ok" } as never, "att-a1")).toBe(true);
  });

  it("gives concurrent logins distinct epochs and exactly one current session", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    // Fewer than the open-nonce limit (8), since every login holds a nonce until it connects.
    const sessions = await Promise.all(Array.from({ length: 6 }, () => f.login(key)));
    expect(sessions.map((s) => s.epoch).sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 6]);
    const rows = await f.one("SELECT session_id, session_epoch FROM worker_agent_sessions");
    expect(rows).toHaveLength(1);
    expect(Number(rows[0]!.session_epoch)).toBe(6);
    const current = sessions.filter((s) => s.sessionId === rows[0]!.session_id);
    expect(current).toHaveLength(1);
    expect(current[0]!.epoch).toBe(6);
    const live = await Promise.all(sessions.map((s) => agentFenceIsCurrent(queryOf(f.db), s)));
    expect(live.filter(Boolean)).toHaveLength(1);
  });

  it("closes sessions whose lease lapsed, and they stop being current", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    expect(await expireLapsedSessions(f.env)).toBe(0);
    await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at = now() - interval '1 second'");
    expect(await authenticateAgentSession(f.env, { workerId: W1, sessionId: session.sessionId, sessionToken: session.sessionToken })).toBeNull();
    expect(await expireLapsedSessions(f.env)).toBe(1);
    expect((await f.one("SELECT disconnect_reason FROM worker_agent_sessions"))[0]!.disconnect_reason).toBe("lease_expired");
    expect(await agentFenceIsCurrent(queryOf(f.db), session)).toBe(false);
    // It connects again with a new epoch.
    expect((await f.login(key)).epoch).toBe(2);
  });
});

describe("heartbeat and lease renewal", () => {
  it("writes at most once per interval however often the Agent pings", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    let now = 1_000_000;
    const keeper = new AgentLeaseKeeper(f.env, () => now, LEASE_RENEW_MIN_MS);
    keeper.begin(session);
    const outcomes: string[] = [];
    for (let i = 0; i < 90; i++) { // a ping every second for 90 s
      now += 1000;
      outcomes.push(await keeper.touch(session));
    }
    expect(keeper.writes).toBe(0);
    expect(new Set(outcomes)).toEqual(new Set(["skipped"]));
    now += LEASE_RENEW_MIN_MS;
    expect(await keeper.touch(session)).toBe("renewed");
    expect(keeper.writes).toBe(1);
    for (let i = 0; i < 50; i++) { now += 1000; await keeper.touch(session); }
    expect(keeper.writes).toBe(1);
  });

  it("tells a replaced session that it is lost, and extends the lease of the current one", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const older = await f.login(key);
    const newer = await f.login(key);
    let now = 0;
    const keeper = new AgentLeaseKeeper(f.env, () => now, 1000);
    now += 5000;
    expect(await keeper.touch(older)).toBe("lost");
    await f.sqlite.exec("UPDATE worker_agent_sessions SET lease_expires_at = now() + interval '10 seconds'");
    expect(await keeper.touch(newer)).toBe("renewed");
    const [row] = await f.one("SELECT lease_expires_at > now() + interval '200 seconds' AS extended FROM worker_agent_sessions");
    expect(Boolean(row!.extended)).toBe(true);
  });
});

describe("rotate, revoke and transfer", () => {
  async function rotateWith(f: Awaited<ReturnType<typeof fixture>>, current: Keys, next: Keys, workerId = W1) {
    const n = await issueNonce(f.env, workerId);
    return rotateCredential(f.env, {
      workerId, nonceId: n.nonceId, newPublicKey: next.publicKey,
      signature: await current.sign(actionMessage("rotate", workerId, n.nonceId, n.nonce, next.publicKey)),
      newKeySignature: await next.sign(actionMessage("rotate-new", workerId, n.nonceId, n.nonce, next.publicKey)),
    });
  }

  it("rotates the key: the old key stops working and the session ends", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    const next = await keys();
    const rotated = await rotateWith(f, key, next);
    expect(rotated.credentialId).toMatch(/^wcr-/);
    const credentials = await f.one("SELECT public_key, revoked_reason FROM worker_credentials ORDER BY created_at");
    expect(credentials.map((c) => c.revoked_reason)).toEqual(["rotated", null]);
    expect(await agentFenceIsCurrent(queryOf(f.db), session)).toBe(false);
    const n = await issueNonce(f.env, W1);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: n.nonceId, signature: await key.sign(actionMessage("session", W1, n.nonceId, n.nonce)) }))).toBe(401);
    expect((await f.login(next)).epoch).toBe(2);
    expect((await f.one("SELECT action FROM worker_audit_log WHERE action = 'credential.rotated'"))).toHaveLength(1);
  });

  it("refuses a rotation the new key did not sign, or the current key did not sign", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const next = await keys();
    const bystander = await keys();
    const n = await issueNonce(f.env, W1);
    const good = {
      workerId: W1, nonceId: n.nonceId, newPublicKey: next.publicKey,
      signature: await key.sign(actionMessage("rotate", W1, n.nonceId, n.nonce, next.publicKey)),
    };
    expect(await status(rotateCredential(f.env, { ...good, newKeySignature: await bystander.sign(actionMessage("rotate-new", W1, n.nonceId, n.nonce, next.publicKey)) }))).toBe(401);
    const n2 = await issueNonce(f.env, W1);
    expect(await status(rotateCredential(f.env, {
      workerId: W1, nonceId: n2.nonceId, newPublicKey: next.publicKey,
      signature: await bystander.sign(actionMessage("rotate", W1, n2.nonceId, n2.nonce, next.publicKey)),
      newKeySignature: await next.sign(actionMessage("rotate-new", W1, n2.nonceId, n2.nonce, next.publicKey)),
    }))).toBe(401);
    expect((await f.one("SELECT 1 FROM worker_credentials WHERE revoked_at IS NULL"))).toHaveLength(1);
    expect((await f.one("SELECT public_key FROM worker_credentials WHERE revoked_at IS NULL"))[0]!.public_key).toBe(key.publicKey);
  });

  it("revokes a credential for the owner only, closes the session and is idempotent", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    expect(await status(revokeWorkerCredential(f.env, { ownerUserId: "bob", workerId: W1 }))).toBe(404);
    expect(await agentFenceIsCurrent(queryOf(f.db), session)).toBe(true);
    expect(await revokeWorkerCredential(f.env, { ownerUserId: "alice", workerId: W1 })).toEqual({ revoked: true });
    expect(await revokeWorkerCredential(f.env, { ownerUserId: "alice", workerId: W1 })).toEqual({ revoked: false });
    expect(await agentFenceIsCurrent(queryOf(f.db), session)).toBe(false);
    expect(await status(issueNonce(f.env, W1))).toBe(404);
    expect((await f.one("SELECT disconnect_reason FROM worker_agent_sessions"))[0]!.disconnect_reason).toBe("credential_revoked");
    expect((await f.one("SELECT action FROM worker_audit_log WHERE action = 'credential.revoked'"))).toHaveLength(1);
    // The Worker can be paired again afterwards.
    await f.pair(W1);
  });

  it("transfers a paired Worker: the old host is locked out and the new one takes over", async () => {
    const f = await fixture();
    const { key: hostA } = await f.pair();
    const sessionA = await f.login(hostA);
    const challenge = await createPairingChallenge(f.env, { ownerUserId: "alice", workerId: W1, kind: "transfer" });
    const hostB = await keys();
    const claim = await claimPairing(f.env, {
      challengeId: challenge.challengeId, secret: challenge.secret, publicKey: hostB.publicKey,
      signature: await hostB.sign(pairingMessage(challenge.challengeId, W1, hostB.publicKey)),
    });
    expect(claim.kind).toBe("transfer");
    expect(await agentFenceIsCurrent(queryOf(f.db), sessionA)).toBe(false);
    const n = await issueNonce(f.env, W1);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: n.nonceId, signature: await hostA.sign(actionMessage("session", W1, n.nonceId, n.nonce)) }))).toBe(401);
    const sessionB = await f.login(hostB);
    expect(sessionB.epoch).toBe(2); // the epoch keeps counting across hosts
    expect((await f.one("SELECT revoked_reason FROM worker_credentials WHERE revoked_at IS NOT NULL"))[0]!.revoked_reason).toBe("transferred");
    expect((await f.one("SELECT action FROM worker_audit_log WHERE action IN ('transfer.requested','transfer.completed')")).map((r) => r.action).sort()).toEqual(["transfer.completed", "transfer.requested"]);
  });

  it("closes the credential and session of a removed Worker", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    const session = await f.login(key);
    await f.sqlite.exec(`UPDATE worker_instances SET revoked_at = now(), enabled = false WHERE id = '${W1}'`);
    expect(await agentFenceIsCurrent(queryOf(f.db), session)).toBe(false);
    expect((await f.one("SELECT revoked_reason FROM worker_credentials"))[0]!.revoked_reason).toBe("worker_removed");
    expect(await status(issueNonce(f.env, W1))).toBe(404);
  });

  it("does not let a disabled Worker connect", async () => {
    const f = await fixture();
    const { key } = await f.pair();
    await f.sqlite.exec(`UPDATE worker_instances SET enabled = false WHERE id = '${W1}'`);
    const n = await issueNonce(f.env, W1);
    expect(await status(connectSession(f.env, { workerId: W1, nonceId: n.nonceId, signature: await key.sign(actionMessage("session", W1, n.nonceId, n.nonce)) }))).toBe(403);
  });
});

describe("HTTP routes", () => {
  function routes(db: unknown) {
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: db,
      TEST_AUTHENTICATION: async (request: Request) => {
        const userId = request.headers.get("test-user");
        if (!userId) throw new HttpError(401, "Sign in required");
        return {
          userId, user: { id: userId, email: `${userId}@test`, displayName: userId, status: "active" },
          workspaceId: "", spaceRoles: {}, sessionId: "test", clientType: "web",
        };
      },
    } as unknown as SecurityEnv;
    const req = (path: string, method: string, body?: unknown, who?: string) =>
      new Request(`https://test${path}`, {
        method,
        headers: { ...(who ? { "test-user": who } : {}), "content-type": "application/json" },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      });
    return { env, req };
  }

  it("runs the whole flow over HTTP: owner starts, Agent claims, nonce, session, revoke", async () => {
    const f = await fixture();
    const { env, req } = routes(f.db);
    const started = await handleWorkerPairing(req(`/api/workers/${W1}/pairing`, "POST", undefined, "alice"), env, W1);
    expect(started.status).toBe(201);
    expect(started.headers.get("cache-control")).toBe("no-store");
    const { challenge } = (await started.json()) as { challenge: { challengeId: string; secret: string } };
    const k = await keys();
    // The Agent has no browser session.
    const claimed = await handleClaimWorkerPairing(
      req("/api/worker-agent/claim", "POST", {
        challengeId: challenge.challengeId, secret: challenge.secret, publicKey: k.publicKey,
        signature: await k.sign(pairingMessage(challenge.challengeId, W1, k.publicKey)),
      }),
      env,
    );
    expect(claimed.status).toBe(201);
    const nonce = ((await (await handleWorkerNonce(req("/api/worker-agent/nonce", "POST", { workerId: W1 }), env)).json()) as { nonce: { nonceId: string; nonce: string } }).nonce;
    const connected = await handleConnectWorkerSession(
      req("/api/worker-agent/sessions", "POST", {
        workerId: W1, nonceId: nonce.nonceId, signature: await k.sign(actionMessage("session", W1, nonce.nonceId, nonce.nonce)),
      }),
      env,
    );
    expect(connected.status).toBe(201);
    expect(((await connected.json()) as { session: { epoch: number } }).session.epoch).toBe(1);
    expect((await handleWorkerCredential(req(`/api/workers/${W1}/credential`, "DELETE", undefined, "alice"), env, W1)).status).toBe(200);
  });

  it("answers a stranger's Worker 404 and refuses a claim made while signed in as someone else", async () => {
    const f = await fixture();
    const { env, req } = routes(f.db);
    expect(await status(handleWorkerPairing(req(`/api/workers/${W1}/pairing`, "POST", undefined, "bob"), env, W1))).toBe(404);
    expect(await status(handleWorkerTransfer(req(`/api/workers/${W1}/transfer`, "POST", undefined, "alice"), env, W1))).toBe(409); // not paired
    const { challenge } = (await (await handleWorkerPairing(req(`/api/workers/${W1}/pairing`, "POST", undefined, "alice"), env, W1)).json()) as { challenge: { challengeId: string; secret: string } };
    const k = await keys();
    const body = {
      challengeId: challenge.challengeId, secret: challenge.secret, publicKey: k.publicKey,
      signature: await k.sign(pairingMessage(challenge.challengeId, W1, k.publicKey)),
    };
    expect(await status(handleClaimWorkerPairing(req("/api/worker-agent/claim", "POST", body, "bob"), env))).toBe(403);
    expect(await status(handleWorkerCredential(req(`/api/workers/${W1}/credential`, "DELETE", undefined, "bob"), env, W1))).toBe(404);
    expect((await handleClaimWorkerPairing(req("/api/worker-agent/claim", "POST", body), env)).status).toBe(201);
  });

  it("does not exist without its flags, and rejects malformed bodies", async () => {
    const f = await fixture();
    const { env, req } = routes(f.db);
    expect(await status(handleWorkerNonce(req("/api/worker-agent/nonce", "POST", { workerId: "" }), env))).toBe(400);
    process.env.SYNTILA_FEATURE_FLAGS = "worker_identity";
    try {
      expect(await status(handleWorkerNonce(req("/api/worker-agent/nonce", "POST", { workerId: W1 }), env))).toBe(404);
      expect((await handleWorkerPairing(req(`/api/workers/${W1}/pairing`, "POST", undefined, "alice"), env, W1)).status).toBe(201);
    } finally {
      process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect";
    }
    process.env.SYNTILA_FEATURE_FLAGS = "";
    try {
      expect(await status(handleWorkerPairing(req(`/api/workers/${W1}/pairing`, "POST", undefined, "alice"), env, W1))).toBe(404);
    } finally {
      process.env.SYNTILA_FEATURE_FLAGS = "worker_identity,worker_agent_connect";
    }
  });
});
