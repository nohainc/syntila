import { beforeEach, expect, it, vi } from "./helpers/vitest-compat";
import { pgD1, recordStatements } from "./helpers/pg-d1";
import { basicThread, T0 } from "./helpers/seed";
vi.mock("../../src/domain/routes/thread-policy.js", () => ({
  authorizeThreadAccess: vi.fn(async () => ({
    context: { userId: "U", user: { displayName: "Member" } },
    spaceId: "S",
  })),
}));
vi.mock("../../src/domain/routes/handlers.js", async (importOriginal) => ({
  ...(await importOriginal<object>()),
  validateWorkflowWorkerEligibility: vi.fn(async () => ({ issues: [] })),
}));
const creation = vi.hoisted(() => ({
  createOrGetRun: vi.fn(async () => ({ id: "run", status: "queued" })),
}));
vi.mock("../../src/domain/routes/work-creation.js", () => creation);
const events = vi.hoisted(() => ({ publishCollaborationEvent: vi.fn() }));
vi.mock("../../src/domain/collaboration-events.js", () => events);
import { handleRetryWorkRequest } from "../../src/domain/routes/work-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

const compactingProfile = JSON.stringify({
  schemaVersion: 1,
  context: { compaction: { prompt: "/compact" } },
});

/** A failed Work Request whose Step stopped over the context limit, with the Worker's Profile and latest Run. */
async function database(options: {
  profileJson?: string;
  latestRunPolicy?: Record<string, unknown>;
}) {
  const f = await pgD1();
  const q = (text: string) => `'${text.replace(/'/g, "''")}'`;
  await f.sqlite.exec(`${basicThread({ user: "U", space: "S", thread: "T" })}
    INSERT INTO worker_catalog(worker_type_id, display_name, created_at, updated_at) VALUES ('claude', 'Claude', '${T0}', '${T0}') ON CONFLICT DO NOTHING;
    INSERT INTO worker_instances(id, actor_id, owner_user_id, worker_type_id, name) VALUES ('worker-a', '', 'U', 'claude', 'Claude');
    INSERT INTO worker_credentials(id, worker_instance_id, public_key, key_fingerprint) VALUES ('cred-a', 'worker-a', '${"a".repeat(43)}', '${"a".repeat(64)}');
    INSERT INTO worker_agent_sessions(worker_instance_id, session_id, session_epoch, credential_id, token_digest, lease_expires_at) VALUES ('worker-a', 'sess-a', 1, 'cred-a', 'digest', now() + interval '5 minutes');
    INSERT INTO work_requests(id, thread_id, requested_by_user_id, mode, workflow_id, workflow_version, workflow_snapshot_json, snapshot_json, status, created_at, updated_at)
      VALUES ('R', 'T', 'U', 'stateless', 'direct', 1, ${q(JSON.stringify({ steps: [{ kind: "implement" }] }))}, ${q(JSON.stringify({ resolvedBindings: { implement: { workerId: "worker-a", workerTypeId: "claude" } } }))}, 'failed', '${T0}', '${T0}');
    INSERT INTO workflow_tasks(id, work_request_id, step_kind, execution_mode, timeout_ms, prompt_profile_version, status, error, created_at, updated_at)
      VALUES ('task-1', 'R', 'implement', 'stateful_thread', 60000, 'v1', 'failed', 'context_limit_exceeded', '${T0}', '${T0}');
    INSERT INTO worker_assignments(id, space_id, worker_instance_id, worker_snapshot_json, worker_type_id, task_id, status, created_at, updated_at)
      VALUES ('A1', 'S', 'worker-a', '{}', 'claude', 'task-1', 'failed', '${T0}', '${T0}');`);
  if (options.profileJson)
    (await f.sqlite.exec(`INSERT INTO worker_profiles(worker_type_id, schema_version, profile_json, digest) VALUES ('claude', 1, ${q(options.profileJson)}, '${"a".repeat(64)}')
      ON CONFLICT (worker_type_id) DO UPDATE SET profile_json = EXCLUDED.profile_json`));
  if (options.latestRunPolicy)
    (await f.sqlite.exec(`INSERT INTO runs(id, space_id, thread_id, work_request_id, status, created_at, updated_at, policy_snapshot_json)
      VALUES ('run-1', 'S', 'T', 'R', 'failed', '${T0}', '${T0}', ${q(JSON.stringify(options.latestRunPolicy))})`));
  const recorded = recordStatements(f.db);
  const env = { SYNTILA_DB: recorded.db } as unknown as SecurityEnv;
  const writes = () => recorded.statements.filter((text) => !/^\s*(SELECT|WITH)/i.test(text));
  const requestStatus = async () => (await f.sqlite.prepare("SELECT status FROM work_requests WHERE id = 'R'").get() as { status: string }).status;
  return { env, writes, requestStatus, close: () => f.sqlite.close() };
}

const retry = (env: SecurityEnv, body: Record<string, unknown>) =>
  handleRetryWorkRequest(
    new Request("https://test/retry", {
      method: "POST",
      body: JSON.stringify({ stepKind: "implement", ...body }),
    }),
    env,
    "R",
  );

beforeEach(() => {
  creation.createOrGetRun.mockClear();
  events.publishCollaborationEvent.mockClear();
});

it("refuses to compact for a Worker whose Profile cannot compact", async () => {
  const { env, writes, requestStatus, close } = await database({ profileJson: JSON.stringify({ schemaVersion: 1 }) });
  try {
    const response = await retry(env, { contextResolution: "compact" });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      error: "context_compaction_unavailable",
    });
    expect(writes()).toEqual([]);
    expect(await requestStatus()).toBe("failed");
  } finally {
    await close();
  }
});

it("offers only clearing once a compacting retry still overflowed", async () => {
  const { env, writes, requestStatus, close } = await database({
    profileJson: compactingProfile,
    latestRunPolicy: {
      manualRetry: { stepKind: "implement", contextResolution: "compact" },
    },
  });
  try {
    const response = await retry(env, { contextResolution: "compact" });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      error: "context_compaction_unavailable",
      message: expect.stringContaining("Clear AI History"),
    });
    expect(writes()).toEqual([]);
    expect(await requestStatus()).toBe("failed");
  } finally {
    await close();
  }
});
