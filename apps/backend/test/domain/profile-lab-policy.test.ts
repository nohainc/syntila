import { expect, test } from "bun:test";
import { isProfileLabOwner } from "../../src/domain/routes/profile-lab-policy";
import { inTransaction } from "../../src/platform/tx-env";
import { pgD1 } from "./helpers/pg-d1";

test("owner lookup respects active status, case and an open transaction", async () => {
  const { db, sqlite } = pgD1();
  sqlite.exec("INSERT INTO users(id,email,display_name,status,created_at,updated_at) VALUES('owner','Owner@example.test','Owner','active','now','now')");
  const env = { SYNTILA_DB: db, SYNTILA_PROFILE_LAB_OWNER_EMAIL: " owner@example.test " } as any;
  expect(await isProfileLabOwner(env, "owner")).toBe(true);
  expect(await isProfileLabOwner(env, "missing")).toBe(false);
  expect(await isProfileLabOwner({ ...env, SYNTILA_PROFILE_LAB_OWNER_EMAIL: "" }, "owner")).toBe(false);
  await inTransaction(env, "test.profile-owner", async (txEnv, tx) => {
    await tx.run`UPDATE users SET status = 'suspended' WHERE id = ${"owner"}`;
    expect(await isProfileLabOwner(txEnv, "owner")).toBe(false);
    throw new Error("rollback");
  }).catch((e) => { if (e.message !== "rollback") throw e; });
  expect(await isProfileLabOwner(env, "owner")).toBe(true);
});
