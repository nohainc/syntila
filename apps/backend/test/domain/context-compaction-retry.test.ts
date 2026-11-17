import { chainData } from "./helpers/fake-sql";
import { beforeEach, expect, it, vi } from "./helpers/vitest-compat";
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
import { Data } from "../../src/platform/data.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

const compactingProfile = JSON.stringify({
  context: { compaction: { prompt: "/compact" } },
});

function database(options: {
  profileJson?: string;
  latestRunPolicy?: Record<string, unknown>;
}) {
  const writes: string[] = [];
  const prepare = vi.fn((sql: string) => {
    let row: unknown = null;
    if (sql.startsWith("SELECT thread_id")) row = { threadId: "T" };
    else if (sql.startsWith("SELECT role")) row = { role: "owner" };
    else if (sql.includes("wr.workflow_id"))
      row = {
        threadId: "T",
        mode: "stateless",
        status: "failed",
        workflowId: "direct",
        workflowSnapshotJson: JSON.stringify({
          steps: [{ kind: "implement" }],
        }),
        snapshotJson: "{}",
        inputJson: "{}",
        primaryWorkspaceId: "WS",
        spaceId: "S",
      };
    else if (sql.includes("wt.status"))
      row = {
        status: "failed",
        error: "context_limit_exceeded",
        workerTypeId: "claude",
      };
    else if (sql.includes("FROM worker_profiles"))
      row = options.profileJson
        ? {
            worker_type_id: "claude",
            schema_version: 1,
            profile_json: options.profileJson,
          }
        : null;
    else if (sql.includes('policy_snapshot_json AS "policySnapshotJson"'))
      row = options.latestRunPolicy
        ? { policySnapshotJson: JSON.stringify(options.latestRunPolicy) }
        : null;
    else if (sql.startsWith("SELECT COUNT(*) AS count FROM runs"))
      row = { count: 1 };
    else if (sql.startsWith("UPDATE work_requests SET status = 'queued'"))
      row = { id: "R" };
    if (!sql.trimStart().startsWith("SELECT")) writes.push(sql);
    const statement = {
      bind: () => statement,
      first: async () => row,
      run: async () => ({ meta: { changes: 1 } }),
    };
    return statement;
  });
  const env = {
    SYNTILA_DATA: new Data((async (strings: TemplateStringsArray) =>
      {
      const text = strings.join("?");
      if (text.includes('thread_id AS "threadId" FROM work_requests')) return [{ threadId: "T" }]; // workRequestThread
      if (text.includes("FROM space_memberships")) return [{ role: "owner" }]; // spaceMembership
      return [];
    }) as any),
    SYNTILA_DB: { prepare, batch: vi.fn(async () => []) },
  } as unknown as SecurityEnv;
  return { env: chainData(env), writes };
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
  const { env, writes } = database({ profileJson: "{}" });
  const response = await retry(env, { contextResolution: "compact" });
  expect(response.status).toBe(409);
  expect(await response.json()).toMatchObject({
    error: "context_compaction_unavailable",
  });
  expect(writes).toEqual([]);
});

it("offers only clearing once a compacting retry still overflowed", async () => {
  const { env, writes } = database({
    profileJson: compactingProfile,
    latestRunPolicy: {
      manualRetry: { stepKind: "implement", contextResolution: "compact" },
    },
  });
  const response = await retry(env, { contextResolution: "compact" });
  expect(response.status).toBe(409);
  expect(await response.json()).toMatchObject({
    error: "context_compaction_unavailable",
    message: expect.stringContaining("Clear AI History"),
  });
  expect(writes).toEqual([]);
});
