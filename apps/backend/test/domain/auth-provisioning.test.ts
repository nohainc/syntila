import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { provisionSyntilaUser } from "../../src/domain/auth/provisioning-service";

describe("user provisioning", () => {
  it("creates a missing authenticated user", async () => {
    const { db, sqlite } = await pgD1();
    await provisionSyntilaUser(db, { userId: "provision-new", email: "new@example.com", name: "New", sessionId: "session" });
    const created = await sqlite.prepare("SELECT email, display_name, status FROM users WHERE id = ?").get("provision-new");
    expect(created).toEqual({ email: "new@example.com", display_name: "New", status: "active" });
  });

  it("preserves unchanged user data and updates changed identity details", async () => {
    const { db, sqlite } = await pgD1();
    await sqlite.exec(`INSERT INTO users (id, email, display_name, status, created_at, updated_at)
      VALUES ('provision-owner', 'owner@example.com', 'Owner', 'active', '2020-01-01T00:00:00Z', '2020-01-01T00:00:00Z')`);
    const identity = { userId: "provision-owner", email: "owner@example.com", name: "Owner", sessionId: "session" };
    await provisionSyntilaUser(db, identity, "2021-01-01T00:00:00Z");
    const original = await sqlite.prepare("SELECT email, display_name, updated_at FROM users WHERE id = ?").get(identity.userId) as { email: string; display_name: string; updated_at: Date | string };
    expect(original.email).toBe(identity.email);
    expect(original.display_name).toBe(identity.name);
    expect(new Date(original.updated_at).toISOString()).toBe("2020-01-01T00:00:00.000Z");
    await provisionSyntilaUser(db, { ...identity, name: "Updated" }, "2022-01-01T00:00:00Z");
    const updated = await sqlite.prepare("SELECT display_name, updated_at FROM users WHERE id = ?").get(identity.userId) as { display_name: string; updated_at: Date | string };
    expect(updated.display_name).toBe("Updated");
    expect(new Date(updated.updated_at).toISOString()).toBe("2022-01-01T00:00:00.000Z");
  });
});
