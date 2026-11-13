import { afterEach, beforeEach, expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { identityService } from "../../src/domain/auth/identity-service.js";
import { handleListPeople, type Person } from "../../src/domain/routes/people.js";
import {
  handleCreateSpaceInvitation,
  handleAcceptSpaceInvitation,
  handleRemoveSpaceMember,
  handleDeleteSpace,
  handleDeclineSpaceInvitation,
  handleListCurrentUserInvitations,
} from "../../src/domain/routes/spaces.js";
import { publishPeopleProfileChanged } from "../../src/domain/people.js";
import { handleAccountProfileUpdated } from "../../src/domain/auth/account-lifecycle.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";
let store: ReturnType<typeof sqliteD1>;
let env: SecurityEnv;
const request = (
  user: string,
  body?: object,
  url = "https://test/api/people",
) =>
  new Request(url, {
    method: body ? "POST" : "GET",
    headers: user ? { authorization: user } : {},
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
const people = async (user: string) =>
  (
    (await (await handleListPeople(request(user), env)).json()) as {
      people: Person[];
    }
  ).people;
const invite = async (user: string, body: object, space = "A") =>
  (
    (await (
      await handleCreateSpaceInvitation(request(user, body), env, space)
    ).json()) as { invitation: { id: string } }
  ).invitation.id;
const accept = (user: string, id: string) =>
  handleAcceptSpaceInvitation(request(user, {}), env, id);
beforeEach(() => {
  store = sqliteD1();
  store.sqlite
    .exec(`INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('a','a@test','Alice','now','now'),('b','b@test','Bob','now','now'),('c','c@test','Carol','now','now'),('z','z@test','Unrelated','now','now');
 INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('A','a','First','now','now'),('B','b','Second','now','now');
 INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('ma','A','a','owner','now','now'),('mb','B','b','owner','now','now');`);
  vi.spyOn(identityService, "resolve").mockImplementation(async (req) => {
    const id = req.headers.get("authorization");
    const user = id
      ? store.sqlite
          .prepare("SELECT email,display_name FROM users WHERE id=?")
          .get(id)
      : null;
    return user
      ? {
          userId: id!,
          email: String(user.email),
          name: String(user.display_name),
          sessionId: "test",
        }
      : null;
  });
  env = {
    SYNTILA_DB: store.db,
    BETTER_AUTH_SECRET: "test",
    SYNTILA_ENVIRONMENT: "development",
  } as SecurityEnv;
});
afterEach(() => {
  vi.restoreAllMocks();
  store.sqlite.close();
});
it("establishes symmetric People only after acceptance, connects all members once, and retains them without shared Spaces", async () => {
  const id = await invite("a", { email: "b@test", role: "collaborator" });
  expect(await people("a")).toEqual([]);
  expect(await people("b")).toEqual([]);
  await expect(accept("c", id)).rejects.toMatchObject({ status: 403 });
  expect(await people("a")).toEqual([]);
  await accept("b", id);
  expect(await people("a")).toMatchObject([
    { userId: "b", sharedSpaceCount: 1 },
  ]);
  expect(await people("b")).toMatchObject([
    { userId: "a", sharedSpaceCount: 1 },
  ]);
  expect(await people("z")).toEqual([]);
  const second = await invite("b", { userId: "a", role: "collaborator" }, "B");
  await accept("a", second);
  expect((await people("a"))[0]!.sharedSpaceCount).toBe(2);
  expect(
    store.sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
  ).toEqual({ n: 1 });
  const third = await invite("a", { email: "c@test", role: "viewer" });
  await accept("c", third);
  expect((await people("c")).map((p) => p.userId)).toEqual(["a", "b"]);
  await handleRemoveSpaceMember(request("a", {}), env, "A", "b");
  expect(
    (await people("b")).find((p) => p.userId === "a")!.sharedSpaceCount,
  ).toBe(1);
  await handleDeleteSpace(
    new Request("https://test/api/spaces/B", {
      method: "DELETE",
      headers: { authorization: "b" },
    }),
    env,
    "B",
  );
  expect(
    (await people("b")).find((p) => p.userId === "a")!.sharedSpaceCount,
  ).toBe(0);
});
it("uses current profile email for stable Person invitations and prevents ownership spoofing or global enumeration", async () => {
  await expect(handleListPeople(request(""), env)).rejects.toMatchObject({
    status: 401,
  });
  await expect(
    handleListPeople(
      request("a", undefined, "https://test/api/people?userId=b"),
      env,
    ),
  ).rejects.toMatchObject({ status: 400 });
  await expect(
    invite("a", { userId: "c", role: "viewer" }),
  ).rejects.toMatchObject({ status: 403 });
  await expect(
    invite("a", { userId: "a", role: "viewer" }),
  ).rejects.toMatchObject({ status: 400 });
  await accept(
    "b",
    await invite("a", { email: "b@test", role: "collaborator" }),
  );
  await handleRemoveSpaceMember(request("a", {}), env, "A", "b");
  store.sqlite.exec(
    "UPDATE users SET email='new-b@test',display_name='Robert',avatar_url='https://test/avatar' WHERE id='b'",
  );
  expect(await people("a")).toMatchObject([
    {
      userId: "b",
      email: "new-b@test",
      displayName: "Robert",
      avatarUrl: "https://test/avatar",
      sharedSpaceCount: 0,
    },
  ]);
  const id = await invite("a", { userId: "b", role: "viewer" });
  expect(
    store.sqlite
      .prepare("SELECT email FROM space_invitations WHERE id=?")
      .get(id),
  ).toEqual({ email: "new-b@test" });
  await expect(
    invite("z", { userId: "b", role: "viewer" }),
  ).rejects.toMatchObject({ status: 404 });
  await expect(
    invite("a", { userId: "b", email: "someone@test", role: "viewer" }),
  ).rejects.toMatchObject({ status: 400 });
});
it("enforces pair identity and pending-invitation uniqueness under concurrent requests", async () => {
  expect(() =>
    store.sqlite.exec("INSERT INTO people_relationships VALUES('a','a','now')"),
  ).toThrow();
  const attempts = await Promise.allSettled([
    invite("a", { email: "B@test", role: "viewer" }),
    invite("a", { email: "b@test", role: "viewer" }),
  ]);
  expect(attempts.filter((r) => r.status === "fulfilled")).toHaveLength(1);
  const rejected = attempts.find(
    (r) => r.status === "rejected",
  ) as PromiseRejectedResult;
  expect(rejected.reason).toMatchObject({ status: 409 });
  const id = (
    attempts.find(
      (r) => r.status === "fulfilled",
    ) as PromiseFulfilledResult<string>
  ).value;
  const accepts = await Promise.allSettled([accept("b", id), accept("b", id)]);
  expect(accepts.filter((r) => r.status === "fulfilled")).toHaveLength(1);
  expect(
    store.sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
  ).toEqual({ n: 1 });
  expect(
    store.sqlite
      .prepare(
        "SELECT COUNT(*) n FROM space_audit_log WHERE action='space.invitation.accepted'",
      )
      .get(),
  ).toEqual({ n: 1 });
  expect(() =>
    store.sqlite.exec(
      "INSERT INTO people_relationships VALUES('a','b','2030-01-01T00:00:00Z')",
    ),
  ).toThrow();
  expect(() =>
    store.sqlite.exec(
      "INSERT INTO people_relationships VALUES('b','a','2030-01-01T00:00:00Z')",
    ),
  ).toThrow();
});
it("expired invitations do not establish People and may be replaced", async () => {
  const id = await invite("a", { email: "b@test", role: "viewer" });
  store.sqlite
    .prepare("UPDATE space_invitations SET expires_at='2000-01-01' WHERE id=?")
    .run(id);
  await expect(accept("b", id)).rejects.toMatchObject({ status: 410 });
  expect(await people("a")).toEqual([]);
  const fresh = await invite("a", { email: "b@test", role: "viewer" });
  expect(fresh).not.toBe(id);
  expect(
    store.sqlite
      .prepare("SELECT status FROM space_invitations WHERE id=?")
      .get(id),
  ).toEqual({ status: "expired" });
});
it("profile hooks publish replayable ID-only signals solely to established peers", async () => {
  await accept("b", await invite("a", { email: "b@test", role: "viewer" }));
  await publishPeopleProfileChanged(env, "b");
  const events = store.sqlite
    .prepare(
      "SELECT stream_kind,stream_id,payload_json FROM realtime_events WHERE event_type='people.updated'",
    )
    .all();
  expect(events).toEqual([
    {
      stream_kind: "user",
      stream_id: "a",
      payload_json: JSON.stringify({ entityId: "b" }),
    },
  ]);
  await handleAccountProfileUpdated(env as never, "b");
  expect(
    store.sqlite
      .prepare(
        "SELECT COUNT(*) n FROM realtime_events WHERE event_type='people.updated'",
      )
      .get(),
  ).toEqual({ n: 2 });
});

it("returns only shared Spaces and authorized invitation destinations, excluding members, pending invitations, and private Spaces", async () => {
  await accept("b", await invite("a", { email: "b@test", role: "viewer" }));
  store.sqlite
    .exec(`INSERT INTO spaces(id,owner_user_id,name,settings_json,created_at,updated_at) VALUES('C','a','Candidate','{}','now','now'),('D','c','Restricted','{}','now','now'),('E','a','Archived','{"archived":true}','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('mc','C','a','owner','now','now'),('mdc','D','c','owner','now','now'),('mda','D','a','viewer','now','now'),('me','E','a','owner','now','now');`);
  const bob = async () =>
    (await people("a")).find((p) => p.userId === "b") as Person & {
      sharedSpaces: { id: string; name: string }[];
      invitableSpaces: {
        id: string;
        name: string;
        permissions: { work: boolean };
      }[];
    };
  expect((await bob()).sharedSpaces).toEqual([{ id: "A", name: "First" }]);
  expect((await bob()).invitableSpaces.map((s) => s.id)).toEqual(["C"]);
  const id = await invite("a", { userId: "b", role: "viewer" }, "C");
  expect((await bob()).invitableSpaces).toEqual([]);
  store.sqlite
    .prepare("UPDATE space_invitations SET expires_at='2000-01-01' WHERE id=?")
    .run(id);
  store.sqlite.exec(
    `UPDATE spaces SET name='Renamed' WHERE id='C'; UPDATE spaces SET settings_json='{"memberPermissions":{"a":{"work":false}}}' WHERE id='D'`,
  );
  expect((await bob()).invitableSpaces).toMatchObject([
    { id: "C", name: "Renamed" },
  ]);
  await handleRemoveSpaceMember(request("a", {}), env, "A", "b");
  expect((await bob()).sharedSpaces).toEqual([]);
  expect((await bob()).invitableSpaces.map((s) => s.id)).toEqual(["A", "C"]);
  // A Person's other Spaces are private unless the caller is also a member.
  expect(JSON.stringify(await bob())).not.toContain("Second");
});

it("known invitations retain recipient identity through email changes and require acceptance or rejection", async () => {
  await accept("b", await invite("a", { email: "b@test", role: "viewer" }));
  await handleRemoveSpaceMember(request("a", {}), env, "A", "b");
  const id = await invite("a", { userId: "b", role: "viewer" });
  expect(
    store.sqlite
      .prepare("SELECT invitee_user_id FROM space_invitations WHERE id=?")
      .get(id),
  ).toEqual({ invitee_user_id: "b" });
  expect(
    store.sqlite
      .prepare(
        "SELECT COUNT(*) n FROM space_memberships WHERE space_id='A' AND user_id='b'",
      )
      .get(),
  ).toEqual({ n: 0 });
  store.sqlite.exec(
    "UPDATE users SET email='new@test' WHERE id='b'; UPDATE users SET email='b@test' WHERE id='c'",
  );
  const inbox = async (user: string) =>
    (await (
      await handleListCurrentUserInvitations(request(user), env)
    ).json()) as { invitations: { id: string }[] };
  expect((await inbox("b")).invitations.map((i) => i.id)).toEqual([id]);
  expect((await inbox("c")).invitations).toEqual([]);
  await expect(accept("c", id)).rejects.toMatchObject({ status: 403 });
  await expect(
    handleDeclineSpaceInvitation(request("c", {}), env, id),
  ).rejects.toMatchObject({ status: 403 });
  await expect(
    invite("a", { userId: "b", role: "viewer" }),
  ).rejects.toMatchObject({ status: 409 });
  expect(
    (await people("a")).find((p) => p.userId === "b")
      ?.pendingInvitationSpaceIds,
  ).toEqual(["A"]);
  await handleDeclineSpaceInvitation(request("b", {}), env, id);
  expect(
    store.sqlite
      .prepare(
        "SELECT COUNT(*) n FROM space_memberships WHERE space_id='A' AND user_id='b'",
      )
      .get(),
  ).toEqual({ n: 0 });
  const next = await invite("a", { userId: "b", role: "viewer" });
  store.sqlite.exec("UPDATE users SET email='another@test' WHERE id='b'");
  await accept("b", next);
  expect(
    (await people("a")).find((p) => p.userId === "b")?.sharedSpaceCount,
  ).toBe(1);
  expect(
    store.sqlite.prepare("SELECT COUNT(*) n FROM people_relationships").get(),
  ).toEqual({ n: 1 });
});
it("email invitations support a new user who registers later, while permissions and self guards remain authoritative", async () => {
  const id = await invite("a", { email: "john@test", role: "viewer" });
  expect(
    store.sqlite
      .prepare("SELECT invitee_user_id FROM space_invitations WHERE id=?")
      .get(id),
  ).toEqual({ invitee_user_id: null });
  expect(await people("a")).toEqual([]);
  store.sqlite.exec(
    "INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('john','john@test','John','now','now')",
  );
  await accept("john", id);
  expect((await people("a")).map((p) => p.userId)).toEqual(["john"]);
  expect((await people("john")).map((p) => p.userId)).toEqual(["a"]);
  await expect(
    invite("a", { email: "A@test", role: "viewer" }),
  ).rejects.toMatchObject({ status: 400 });
  await expect(
    invite("a", { userId: "john", role: "viewer" }),
  ).rejects.toMatchObject({ status: 409 });
  await expect(
    invite("john", { userId: "a", role: "viewer" }),
  ).rejects.toMatchObject({ status: 403 });
});
