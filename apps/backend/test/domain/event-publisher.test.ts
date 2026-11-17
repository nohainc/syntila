import { pgD1 } from "./helpers/pg-d1";
import { describe, expect, it } from "./helpers/vitest-compat";
import {
  CloudEventPublisher,
  type EventPublisherEnv,
} from "../../src/domain/event-publisher.js";

async function createHarness(options: { duplicate?: boolean } = {}) {
  const { db, sqlite } = await pgD1();
  let fanoutCount = 0;
  if (options.duplicate)
    (await sqlite.exec(
      `INSERT INTO realtime_events (event_id, workspace_id, space_id, sequence, event_type, payload_json, idempotency_key, occurred_at)
       VALUES ('event-existing', 'workspace-1', 'space-1', 7, 'work_request.created', '{"entityId":"message-1"}', 'message-1', '2026-09-23T00:00:00.000Z')`,
    ));
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
    sqlite,
    async insertCount() {
      return Number(
        (await sqlite.prepare("SELECT COUNT(*) AS n FROM realtime_events").get() as { n: number }).n,
      ) - (options.duplicate ? 1 : 0);
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
  recipientUserIds: ["user-1", "user-2"],
  payload: { entityId: "message-1", summary: "hello" },
};

describe("Cloud event publisher", () => {
  it("persists failure events with requester attribution", async () => {
    const harness = await createHarness();
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
    expect(await harness.insertCount()).toBe(1);
  });

  it("allocates a sequence and inserts the durable event in one D1 batch", async () => {
    const harness = await createHarness();
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      idempotencyKey: "message-1",
    });

    expect(result.persisted).toBe(true);
    expect(result.event.sequence).toBe(1);
    expect(result.deliveredSubscribers).toBe(2);
    expect(await harness.insertCount()).toBe(1);
    expect(harness.fanoutCount).toBe(2);
  });

  it("does not write ephemeral events but still attempts fanout", async () => {
    const harness = await createHarness();
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
    expect(await harness.insertCount()).toBe(0);
    expect(harness.fanoutCount).toBe(2);
  });

  it("persists replayable Worker Activity with assignment correlation", async () => {
    const harness = await createHarness();
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
    const harness = await createHarness();
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
    const harness = await createHarness({ duplicate: true });
    const result = await new CloudEventPublisher(harness.env).publish({
      ...baseEvent,
      eventId: "event-existing",
      idempotencyKey: "message-1",
    });
    expect(result.persisted).toBe(false);
    expect(await harness.insertCount()).toBe(0);
    expect(result.event.eventId).toBe("event-existing");
  });

  it("serializes concurrent idempotent publishes without consuming a second sequence", async () => {
    const harness = await createHarness();
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
    expect(await harness.insertCount()).toBe(1);
  });

  it("deduplicates and advances sequences in the real schema", async () => {
    const h = await createHarness();
    const publisher = new CloudEventPublisher(h.env);
    const input = {
      ...baseEvent,
      eventId: "event-idempotent",
      idempotencyKey: "idem-idempotent",
    };
    const [first, duplicate] = await Promise.all([
      publisher.publish(input),
      publisher.publish(input),
    ]);
    const next = await publisher.publish({
      ...baseEvent,
      eventId: "event-next",
      idempotencyKey: "idem-next",
    });
    expect(first.event.sequence).toBe(1);
    expect(duplicate.event.sequence).toBe(1);
    expect([first.persisted, duplicate.persisted].sort()).toEqual([false, true]);
    expect(next.event.sequence).toBe(2);
    expect(await h.insertCount()).toBe(2);

    await h.sqlite.exec(
      `INSERT INTO realtime_events (event_id, workspace_id, sequence, event_type, payload_json, idempotency_key, occurred_at)
       VALUES ('event-retained', 'workspace-retained', 12, 'work_request.created', '{}', 'idem-retained', '2026-09-01T00:00:00.000Z')`,
    );
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
  });
});
