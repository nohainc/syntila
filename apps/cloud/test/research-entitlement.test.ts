import { afterEach, expect, it } from "vitest";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { requireWorkflowPermission } from "../src/routes/space-permissions.js";

const open: Array<{ close(): void }> = [];
afterEach(() => {
  for (const sqlite of open.splice(0)) sqlite.close();
});

function fixture() {
  const { sqlite, db } = sqliteD1();
  open.push(sqlite);
  sqlite.exec(`
    INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
      ('owner','o@t','Owner','now','now'),('member','m@t','Member','now','now');
    INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES('S','owner','S','now','now');
    INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES
      ('m1','S','owner','owner','now','now'),('m2','S','member','collaborator','now','now');
    INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at)
      VALUES('owner','paid','active','manual','now','now');`);
  const env = { SYNTILA_DB: db } as never;
  return { sqlite, env };
}

it("requires the requester's own Syntila Plus for Research and Implement, not the Space owner's", async () => {
  const { env, sqlite } = fixture();
  await expect(
    requireWorkflowPermission(env, "owner", "S", "research"),
  ).resolves.toBeTruthy();
  // A Free member of a Plus-owned Space cannot use Research...
  await expect(
    requireWorkflowPermission(env, "member", "S", "research"),
  ).rejects.toMatchObject({ status: 402, code: "paid_plan_required" });
  // ...nor Implement...
  await expect(
    requireWorkflowPermission(env, "member", "S", "plan_implement"),
  ).rejects.toMatchObject({ status: 402, code: "paid_plan_required" });
  await expect(
    requireWorkflowPermission(env, "owner", "S", "plan_implement"),
  ).resolves.toBeTruthy();
  // ...but keeps Chat and Work.
  await expect(
    requireWorkflowPermission(env, "member", "S", "chat"),
  ).resolves.toBeTruthy();
  await expect(
    requireWorkflowPermission(env, "member", "S", "direct"),
  ).resolves.toBeTruthy();
  // Expired plans follow the existing effective-tier rules.
  sqlite.exec(
    "INSERT INTO account_plans(user_id,tier,status,source,current_period_end,created_at,updated_at) VALUES('member','paid','active','manual','2000-01-01T00:00:00Z','now','now')",
  );
  await expect(
    requireWorkflowPermission(env, "member", "S", "research"),
  ).rejects.toMatchObject({ code: "paid_plan_required" });
  sqlite.exec(
    "UPDATE account_plans SET current_period_end='2999-01-01T00:00:00Z', status='past_due' WHERE user_id='member'",
  );
  await expect(
    requireWorkflowPermission(env, "member", "S", "research"),
  ).resolves.toBeTruthy();
});
