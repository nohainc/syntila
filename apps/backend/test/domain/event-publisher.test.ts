import { pgD1 } from "./helpers/pg-d1";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "./helpers/vitest-compat";
import {
  CloudEventPublisher,
  type EventPublisherEnv,
} from "../../src/domain/event-publisher.js";

function createHarness(options: { duplicate?: boolean } = {}) {
  let nextSequence = 0;
  let insertCount = 0;
  let batchCount = 0;
  let fanoutCount = 0;
  let pendingBatch = Promise.resolve();
  const eventRows: Array<Record<string, unknown>> = options.duplicate
    ? [
        {
          event_id: "event-existing",
          workspace_id: "workspace-1",
          space_id: "space-1",
          run_id: null,
          task_id: null,
          attempt_id: null,
          assignment_id: null,
          workspace_runtime_id: null,
          sequence: 7,
          event_type: "work_request.created",
          payload_json: JSON.stringify({ entityId: "message-1" }),
          idempotency_key: "message-1",
          occurred_at: "2026-09-23T00:00:00.000Z",
        },
      ]
    : [];
  const db = {
    prepare(query: string) {
      return {
        query,
        args: [] as unknown[],
        bind(...args: unknown[]) {
          this.args = args;
          return this;
        },
        async first<T>() {
          if (query.includes("FROM realtime_events")) {
            const [, workspaceId, eventId, idempotencyKey] = this.args;
            return (eventRows.find(
              (row) =>
                row.workspace_id === workspaceId &&
                (row.event_id === eventId ||
                  row.idempotency_key === idempotencyKey),
            ) ?? null) as T | null;
          }
          return null;
        },
        async all<T>() {
          if (
            query.includes("execution_workspaces") ||
            query.includes("space_memberships")
          ) {
            return {
              results: [{ user_id: "user-1" }, { user_id: "user-2" }],
            } as T;
          }
          return { results: [] } as T;
        },
      };
    },
    async batch(statements: Array<{ query: string; args: unknown[] }>) {
      const operation = pendingBatch.then(() => {
        batchCount += 1;
        const insert = statements[2];
        if (!insert) throw new Error("Expected batched event insert");
        const [
          eventId,
          workspaceId,
          spaceId,
          runId,
          taskId,
          attemptId,
          assignmentId,
          runtimeId,
          eventType,
          payloadJson,
          idempotencyKey,
          occurredAt,
        ] = insert.args;
        const existing = eventRows.find(
          (row) =>
            row.workspace_id === workspaceId &&
            (row.event_id === eventId ||
              row.idempotency_key === idempotencyKey),
        );
        if (existing) return [{}, { results: [] }, { results: [] }];

        nextSequence += 1;
        insertCount += 1;
        const row = {
          event_id: eventId,
          workspace_id: workspaceId,
          space_id: spaceId,
          run_id: runId,
          task_id: taskId,
          attempt_id: attemptId,
          assignment_id: assignmentId,
          workspace_runtime_id: runtimeId,
          sequence: nextSequence,
          event_type: eventType,
          payload_json: payloadJson,
          idempotency_key: idempotencyKey,
          occurred_at: occurredAt,
        };
        eventRows.push(row);
        return [
          {},
          { results: [{ sequence: nextSequence }] },
          { results: [row] },
        ];
      });
      pendingBatch = operation.then(() => undefined);
      return operation;
    },
  } as unknown as D1Database;
  const gateway = {
    getByName() {
      return {
        async fetch() {
          fanoutCount += 1;
          return new Response(null, { status: 200 });
        },
      };
    },
  } as unknown as DurableObjectNamespace;
  return {
    env: {
      SYNTILA_DB: db,
      SYNTILA_REALTIME_GATEWAY: gateway,
    } satisfies EventPublisherEnv,
    get insertCount() {
      return insertCount;
    },
    get batchCount() {
      return batchCount;
    },
    get fanoutCount() {
      return fanoutCount;
    },
  };
}

const baseEvent = {
  type: "work_request.created",
  workspaceId: "workspace-1",
  spaceId: "space-1",
  payload: { entityId: "message-1", summary: "hello" },
};

class SqliteD1Statement {
  constructor(
    private readonly database: DatabaseSync,
    private readonly sql: string,
    private readonly values: unknown[] = [],
  ) {}

  bind(...values: unknown[]): SqliteD1Statement {
    return new SqliteD1Statement(this.database, this.sql, values);
  }

  all<T>(): { results: T[] } {
    const statement = this.database.prepare(this.sql);
    if (/\bRETURNING\b|^\s*SELECT\b/i.test(this.sql)) {
      return {
        results: statement.all(...(this.values as SQLInputValue[])) as T[],
      };
    }
    statement.run(...(this.values as SQLInputValue[]));
    return {
      results: [],
    };
  }

  first<T>(): T | null {
    return (
      (this.database
        .prepare(this.sql)
        .get(...(this.values as SQLInputValue[])) as T | undefined) ?? null
    );
  }
}

class SqliteD1 {
  constructor(readonly database: DatabaseSync) {}

  prepare(sql: string): SqliteD1Statement {
    return new SqliteD1Statement(this.database, sql);
  }

  async batch(statements: SqliteD1Statement[]) {
    this.database.exec("BEGIN");
    try {
      const results = statements.map((statement) => statement.all());
      this.database.exec("COMMIT");
      return results;
    } catch (error) {
      this.database.exec("ROLLBACK");
      throw error;
    }
  }
}

describe("Cloud event publisher", () => {
  it("persists failure events with requester attribution", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      type: "work_request.failed",
      payload: {
        entityId: "request-1",
        workRequestId: "request-1",
        threadId: "thread-1",
        requestedByUserId: "user-1",
        status: "failed",
      },
    });
    expect(result.persisted).toBe(true);
    expect(result.event.payload.requestedByUserId).toBe("user-1");
    expect(harness.insertCount).toBe(1);
  });

  it("allocates a sequence and inserts the durable event in one D1 batch", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      idempotencyKey: "message-1",
    });

    expect(result.persisted).toBe(true);
    expect(result.event.sequence).toBe(1);
    expect(result.deliveredSubscribers).toBe(2);
    expect(harness.batchCount).toBe(1);
    expect(harness.insertCount).toBe(1);
    expect(harness.fanoutCount).toBe(2);
  });

  it("does not write ephemeral events but still attempts fanout", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      type: "assignment.activity",
      durable: false,
      workspaceRuntimeId: "runtime-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      payload: {
        entityId: "assignment-1",
        workerId: "worker-1",
        sourceEventId: "source-1",
        executionId: "execution-1",
        activitySequence: 1,
        activityType: "model.status",
        activityStatus: "running",
        title: "Working",
      },
    });

    expect(result.persisted).toBe(false);
    expect(result.event.sequence).toBe(0);
    expect(harness.batchCount).toBe(0);
    expect(harness.insertCount).toBe(0);
    expect(harness.fanoutCount).toBe(2);
  });

  it("persists replayable Worker Activity with assignment correlation", async () => {
    const harness = createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      type: "assignment.activity",
      durable: true,
      eventId: "activity-1",
      idempotencyKey: "activity-1",
      workspaceId: "workspace-1",
      attemptId: "attempt-1",
      assignmentId: "assignment-1",
      workspaceRuntimeId: "runtime-1",
      payload: {
        entityId: "assignment-1",
        workerId: "chatgpt",
        sourceEventId: "source-1",
        executionId: "execution-1",
        activitySequence: 1,
        activityType: "tool.started",
        activityStatus: "running",
        title: "Running tool",
      },
    });

    expect(result.persisted).toBe(true);
    expect(result.event.type).toBe("assignment.activity");
    expect(result.event.sequence).toBe(1);
    expect(result.event.attemptId).toBe("attempt-1");
  });

  it("returns safely when a subscriber is disconnected", async () => {
    const harness = createHarness();
    const namespace = harness.env.SYNTILA_REALTIME_GATEWAY as unknown as {
      getByName: () => { fetch: () => Promise<Response> };
    };
    let calls = 0;
    namespace.getByName = () => ({
      fetch: async () => {
        calls += 1;
        if (calls === 1) throw new Error("socket closed");
        return new Response(null, { status: 200 });
      },
    });

    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
    });
    expect(result.deliveredSubscribers).toBe(1);
  });

  it("reuses an existing durable event for duplicate idempotency keys", async () => {
    const harness = createHarness({ duplicate: true });
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      eventId: "event-existing",
      idempotencyKey: "message-1",
    });
    expect(result.persisted).toBe(false);
    expect(harness.batchCount).toBe(1);
    expect(harness.insertCount).toBe(0);
    expect(result.event.eventId).toBe("event-existing");
  });

  it("serializes concurrent idempotent publishes without consuming a second sequence", async () => {
    const harness = createHarness();
    const publisher = new CloudEventPublisher(harness.env);
    const input = {
      ...baseEvent,
      eventId: "event-concurrent",
      idempotencyKey: "idem-concurrent",
    };

    const [first, second] = await Promise.all([
      publisher.publish(input),
      publisher.publish(input),
    ]);

    expect([first.event.sequence, second.event.sequence]).toEqual([1, 1]);
    expect([first.persisted, second.persisted].sort()).toEqual([false, true]);
    expect(harness.insertCount).toBe(1);
  });

  it("uses the real schema to atomically deduplicate and advance workspace sequences", async () => {
    const database = (pgD1().sqlite as unknown as DatabaseSync);
    database.exec(
      "" /* D1 migration: schema is final in PostgreSQL */,
    );
    const db = new SqliteD1(database);
    const publisher = new CloudEventPublisher({
      SYNTILA_DB: db as unknown as D1Database,
    });
    const input = {
      ...baseEvent,
      eventId: "event-sqlite-idempotent",
      idempotencyKey: "idem-sqlite-idempotent",
    };

    try {
      const [first, duplicate] = await Promise.all([
        publisher.publish(input),
        publisher.publish(input),
      ]);
      const next = await publisher.publish({
        ...baseEvent,
        eventId: "event-sqlite-next",
        idempotencyKey: "idem-sqlite-next",
      });
      const count = database
        .prepare("SELECT COUNT(*) AS count FROM realtime_events")
        .get() as { count: number };

      expect(first.event.sequence).toBe(1);
      expect(duplicate.event.sequence).toBe(1);
      expect([first.persisted, duplicate.persisted].sort()).toEqual([
        false,
        true,
      ]);
      expect(next.event.sequence).toBe(2);
      expect(count.count).toBe(2);

      database
        .prepare(
          `INSERT INTO realtime_events
           (event_id, workspace_id, sequence, event_type, payload_json,
            idempotency_key, occurred_at)
           VALUES ('event-retained', 'workspace-retained', 12,
                   'work_request.created', '{}', 'idem-retained',
                   '2026-09-01T00:00:00.000Z')`,
        )
        .run();
      const afterCursorLoss = await publisher.publish({
        ...baseEvent,
        spaceId: undefined,
        workspaceId: "workspace-retained",
        eventId: "event-after-retained",
        idempotencyKey: "idem-after-retained",
      });
      expect(afterCursorLoss.event.sequence).toBe(13);

      await expect(
        publisher.publish({
          ...baseEvent,
          spaceId: undefined,
          workspaceId: "workspace-failed",
          eventId: "event-after-retained",
          idempotencyKey: "idem-failed-global-event-id",
        }),
      ).rejects.toThrow();
      const afterRollback = await publisher.publish({
        ...baseEvent,
        spaceId: undefined,
        workspaceId: "workspace-failed",
        eventId: "event-after-rollback",
        idempotencyKey: "idem-after-rollback",
      });
      expect(afterRollback.event.sequence).toBe(1);
    } finally {
      database.close();
    }
  });
});
