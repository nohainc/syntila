import { describe, expect, it } from "./helpers/vitest-compat";
import { pruneExpiredRealtimeEvents } from "../../src/domain/realtime-retention.js";
import { CloudEventPublisher } from "../../src/domain/event-publisher.js";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { publishCollaborationEvent } from "../../src/domain/collaboration-events.js";
import {
  authorizeRealtimeScope,
  eventMatchesScope,
} from "../../src/domain/realtime-gateway.js";
import { parseRealtimeEvent } from "@syntila/protocol";
import {
  handleCreateSpace,
  handleListSpaces,
  handleGetSpace,
  handleUpdateSpace,
  handleDeleteSpace,
  handleCreateThread,
  handleUpdateThread,
  handleDeleteThread,
  handleCreateDiscussionMessage,
  handleEditDiscussionMessage,
  handleGetDiscussionMessage,
  handleCreateWorkspaceSpaceGrant,
  handleUpdateWorkspaceSpaceGrant,
  handleRevokeWorkspaceSpaceGrant,
} from "../../src/domain/routes/handlers.js";
import type { SecurityEnv } from "../../src/domain/routes/handlers.js";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
    ('owner','owner@test','Owner','now','now'), ('member','member@test','Member','now','now'), ('outsider','outsider@test','Outsider','now','now');`);
  const deliveries: { user: string; event: Record<string, unknown> }[] = [];
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    SYNTILA_DB: db,
    SYNTILA_REALTIME_GATEWAY: {
      getByName(user: string) {
        return {
          async fetch(request: Request) {
            deliveries.push({
              user,
              event: (await request.json()) as Record<string, unknown>,
            });
            return new Response("{}");
          },
        };
      },
    },
    TEST_AUTHENTICATION: async () => ({
      userId: "owner",
      user: {
        id: "owner",
        email: "owner@test",
        displayName: "Owner",
        status: "active",
      },
      workspaceId: "",
      spaceRoles: {},
      sessionId: "session",
      clientType: "web",
    }),
  } as unknown as SecurityEnv;
  const request = (body: unknown = {}, method = "POST") =>
    new Request("https://cloud.test/api/resource", {
      method,
      body: JSON.stringify(body),
    });
  const events = () =>
    sqlite
      .prepare("SELECT * FROM realtime_events ORDER BY sequence")
      .all() as Record<string, unknown>[];
  return { sqlite, db, env, deliveries, request, events };
}

describe("collaboration durable signals", () => {
  it("space list preserves the viewer's owner and shared membership roles", async () => {
    const f = fixture();
    try {
      await handleCreateSpace(f.request({ name: "Owned" }), f.env);
      f.sqlite.exec(
        "INSERT INTO spaces(id,name,owner_user_id,created_at,updated_at) VALUES('shared','Shared','member','now','now'); INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('shared-access','shared','owner','collaborator','now','now');",
      );
      const response = await handleListSpaces(
        new Request("https://cloud.test/api/spaces"),
        f.env,
      );
      const body = (await response.json()) as {
        spaces: { name: string; role: string }[];
      };
      expect(body.spaces).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ name: "Owned", role: "owner" }),
          expect.objectContaining({ name: "Shared", role: "collaborator" }),
        ]),
      );
      const detail = await handleGetSpace(
        new Request("https://cloud.test/api/spaces/shared"),
        f.env,
        "shared",
      );
      expect(await detail.json()).toMatchObject({
        space: { role: "collaborator" },
      });
    } finally {
      f.sqlite.close();
    }
  });
  it("delivers a durable recipient signal without granting Space membership", async () => {
    const f = fixture();
    try {
      const response = await handleCreateSpace(
        f.request({ name: "Private space" }),
        f.env,
      );
      const { space } = (await response.json()) as {
        space: { id: string };
      };
      f.deliveries.length = 0;
      await publishCollaborationEvent(
        f.env,
        "space.updated",
        space.id,
        "invitation",
        { additionalRecipientUserIds: ["outsider", "outsider"] },
      );
      const recipient = f.deliveries.filter(
        (item) => item.user === "user:outsider",
      );
      expect(recipient).toHaveLength(1);
      expect(recipient[0]!.event).toMatchObject({
        stream: { kind: "user", id: "outsider" },
        payload: { entityId: "invitation" },
      });
      expect(
        (
          await authorizeRealtimeScope(
            f.db as unknown as D1Database,
            "outsider",
            { kind: "space", spaceId: space.id },
          )
        ).allowed,
      ).toBe(false);
      expect(
        (
          await authorizeRealtimeScope(
            f.db as unknown as D1Database,
            "outsider",
            { kind: "user" },
          )
        ).allowed,
      ).toBe(true);
      expect(
        eventMatchesScope(parseRealtimeEvent(recipient[0]!.event), {
          kind: "user",
        }),
      ).toBe(true);
      expect(
        f
          .events()
          .filter(
            (event) =>
              event.stream_kind === "user" && event.stream_id === "outsider",
          ),
      ).toHaveLength(1);
      expect(
        f.sqlite
          .prepare(
            "SELECT count(*) AS n FROM space_memberships WHERE user_id='outsider'",
          )
          .get(),
      ).toEqual({ n: 0 });
    } finally {
      f.sqlite.close();
    }
  });
  it("publishes all collaboration CRUD signals with real authorization and no execution Workspace", async () => {
    const f = fixture();
    try {
      const created = await handleCreateSpace(
        f.request({ name: "Space" }),
        f.env,
      );
      const { space } = (await created.json()) as { space: { id: string } };
      const p = space.id;
      f.sqlite
        .prepare(
          "INSERT INTO space_memberships VALUES('member-p', ?, 'member', 'collaborator', 'now', 'now')",
        )
        .run(p);
      await handleUpdateSpace(
        f.request({ name: "Renamed" }, "PATCH"),
        f.env,
        p,
      );
      await handleUpdateSpace(f.request({ archived: true }, "PATCH"), f.env, p);
      const streamResponse = await handleCreateThread(
        f.request({ name: "Stream" }),
        f.env,
        p,
      );
      const { thread } = (await streamResponse.json()) as {
        thread: { id: string };
      };
      const w = thread.id;
      await handleUpdateThread(
        f.request({ name: "New Stream" }, "PATCH"),
        f.env,
        w,
      );
      const discussionResponse = await handleCreateDiscussionMessage(
        f.request({ body: "Private text never broadcast" }),
        f.env,
        w,
      );
      const { message } = (await discussionResponse.json()) as {
        message: { id: string };
      };
      await handleEditDiscussionMessage(
        f.request({ body: "Edited text" }, "PATCH"),
        f.env,
        message.id,
      );
      const detail = await handleGetDiscussionMessage(
        new Request("https://cloud.test/api/discussion-messages/" + message.id),
        f.env,
        message.id,
      );
      expect(await detail.json()).toMatchObject({
        message: {
          id: message.id,
          body: "Edited text",
          threadId: w,
          references: [],
        },
      });
      await handleDeleteThread(f.request({}, "DELETE"), f.env, w);
      await handleDeleteSpace(f.request({}, "DELETE"), f.env, p);
      const events = f.events();
      expect(events.map((row) => row.event_type)).toEqual([
        "space.created",
        "space.updated",
        "space.archived",
        "thread.created",
        "thread.updated",
        "discussion.created",
        "discussion.updated",
        "thread.deleted",
        "space.deleted",
      ]);
      expect(events.map((row) => row.sequence)).toEqual([
        1, 2, 3, 4, 5, 6, 7, 8, 9,
      ]);
      for (const row of events) {
        expect(row.stream_kind).toBe("space");
        expect(row.stream_id).toBe(p);
        expect(row.workspace_id).toBeNull();
        expect(Object.keys(JSON.parse(String(row.payload_json)))).toEqual(
          expect.arrayContaining(["entityId"]),
        );
        expect(row.payload_json).not.toContain("text");
      }
      expect(
        f.sqlite
          .prepare("SELECT COUNT(*) AS n FROM execution_workspaces")
          .get()!.n,
      ).toBe(0);
      expect(
        f.deliveries
          .filter((item) => item.event.type === "space.deleted")
          .map((item) => item.user)
          .sort(),
      ).toEqual(["user:member", "user:owner"]);
      expect(f.deliveries.some((item) => item.user === "user:outsider")).toBe(
        false,
      );
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM space_memberships").get()!
          .n,
      ).toBe(0);
    } finally {
      f.sqlite.close();
    }
  });
  it("signals grant creation, editing and revocation on the Space stream", async () => {
    const f = fixture();
    try {
      const response = await handleCreateSpace(f.request({ name: "P" }), f.env);
      const { space } = (await response.json()) as {
        space: { id: string };
      };
      f.sqlite.exec(
        "INSERT INTO execution_workspaces(id,owner_user_id,name,status,created_at,updated_at) VALUES('ws','owner','Workspace','online','now','now')",
      );
      const granted = await handleCreateWorkspaceSpaceGrant(
        f.request({ allowedPermissions: ["repository:read"] }),
        f.env,
        "ws",
        space.id,
      );
      const { grant } = (await granted.json()) as { grant: { id: string } };
      await handleUpdateWorkspaceSpaceGrant(
        f.request({ status: "suspended" }, "PATCH"),
        f.env,
        grant.id,
      );
      await handleRevokeWorkspaceSpaceGrant(
        f.request({}, "DELETE"),
        f.env,
        grant.id,
      );
      const grants = f
        .events()
        .filter(
          (row) =>
            row.event_type === "workspace_space_grant.updated" &&
            row.stream_kind === "space",
        );
      expect(grants).toHaveLength(3);
      expect(
        grants.every(
          (row) =>
            row.stream_kind === "space" &&
            row.workspace_id === null &&
            row.stream_id === space.id,
        ),
      ).toBe(true);
    } finally {
      f.sqlite.close();
    }
  });
  it("isolates same-named execution, Space and user streams and idempotency keys", async () => {
    const f = fixture();
    try {
      const publisher = new CloudEventPublisher({ SYNTILA_DB: f.db });
      const input = {
        type: "space.updated",
        spaceId: "same",
        payload: { entityId: "same" },
        idempotencyKey: "same-key",
      };
      const p = await publisher.publish({
        ...input,
        stream: { kind: "space", id: "same" },
      });
      const u = await publisher.publish({
        ...input,
        stream: { kind: "user", id: "same" },
      });
      const e = await publisher.publish({
        type: "work_request.created",
        workspaceId: "same",
        payload: { entityId: "r" },
        idempotencyKey: "same-key",
      });
      const duplicate = await publisher.publish({
        ...input,
        stream: { kind: "space", id: "same" },
      });
      expect([
        p.event.sequence,
        u.event.sequence,
        e.event.sequence,
        duplicate.event.sequence,
      ]).toEqual([1, 1, 1, 1]);
      expect(duplicate.persisted).toBe(false);
      expect(e.event.version).toBe("1.0");
      expect(e.event.stream).toBeUndefined();
      const next = await publisher.publish({
        ...input,
        idempotencyKey: "next",
        stream: { kind: "space", id: "same" },
      });
      expect(next.event.sequence).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("retains Space sequence counters after expired events are pruned", async () => {
    const f = fixture();
    try {
      const publisher = new CloudEventPublisher({ SYNTILA_DB: f.db });
      const input = {
        type: "space.updated",
        spaceId: "p",
        stream: { kind: "space", id: "p" } as const,
        payload: { entityId: "p" },
      };
      await publisher.publish({
        ...input,
        occurredAt: "2025-01-01T00:00:00.000Z",
      });
      expect(
        await pruneExpiredRealtimeEvents(
          f.db,
          new Date("2026-10-06T00:00:00.000Z"),
        ),
      ).toBe(1);
      expect((await publisher.publish(input)).event.sequence).toBe(2);
    } finally {
      f.sqlite.close();
    }
  });
  it("denies message reads/edits without Thread access or authorship and emits no signal", async () => {
    const f = fixture();
    try {
      const { space } = (await (
        await handleCreateSpace(f.request({ name: "P" }), f.env)
      ).json()) as { space: { id: string } };
      const { thread } = (await (
        await handleCreateThread(f.request({ name: "W" }), f.env, space.id)
      ).json()) as { thread: { id: string } };
      const { message } = (await (
        await handleCreateDiscussionMessage(
          f.request({ body: "Private" }),
          f.env,
          thread.id,
        )
      ).json()) as { message: { id: string } };
      const count = f.events().length;
      Object.assign(f.env, {
        TEST_AUTHENTICATION: async () => ({ userId: "outsider" }),
      });
      await expect(
        handleGetDiscussionMessage(
          new Request(
            "https://cloud.test/api/discussion-messages/" + message.id,
          ),
          f.env,
          message.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      f.sqlite
        .prepare(
          "INSERT INTO space_memberships VALUES('member-p',?,'member','collaborator','now','now')",
        )
        .run(space.id);
      Object.assign(f.env, {
        TEST_AUTHENTICATION: async () => ({ userId: "member" }),
      });
      await expect(
        handleEditDiscussionMessage(
          f.request({ body: "Overwrite" }, "PATCH"),
          f.env,
          message.id,
        ),
      ).rejects.toMatchObject({ status: 403 });
      expect(f.events()).toHaveLength(count);
      expect(
        f.sqlite
          .prepare("SELECT body FROM discussion_messages WHERE id = ?")
          .get(message.id)!.body,
      ).toBe("Private");
    } finally {
      f.sqlite.close();
    }
  });
  it("rolls back a domain write and sequence together when event persistence fails", async () => {
    const f = fixture();
    try {
      f.sqlite.exec(
        "CREATE FUNCTION fail_realtime_fn() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test failure'; END $$; CREATE TRIGGER fail_realtime BEFORE INSERT ON realtime_events FOR EACH ROW EXECUTE FUNCTION fail_realtime_fn();",
      );
      await expect(
        handleCreateSpace(f.request({ name: "P" }), f.env),
      ).rejects.toThrow("test failure");
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM spaces").get()!.n,
      ).toBe(0);
      expect(
        f.sqlite
          .prepare("SELECT COUNT(*) AS n FROM realtime_event_cursors")
          .get()!.n,
      ).toBe(0);
      expect(f.deliveries).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });
});
