import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "./helpers/vitest-compat";

const httpSecurity = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/http-security.ts", import.meta.url)),
  "utf8",
);
const spaces = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/spaces.ts", import.meta.url)),
  "utf8",
);
const threads = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/threads.ts", import.meta.url)),
  "utf8",
);
const entrypoint = readFileSync(
  fileURLToPath(new URL("../../src/domain/index.ts", import.meta.url)),
  "utf8",
);

describe("Space lifecycle integrity", () => {
  it("registers space deletion in the production route handler table", () => {
    expect(entrypoint).toContain(
      "handleDeleteSpace: handlers.handleDeleteSpace",
    );
  });

  it("records Space-scoped audits without requiring a Workspace", () => {
    expect(httpSecurity).toContain("space_audit_log");
    expect(httpSecurity).not.toContain(".catch(() => undefined)");
  });

  it("guards duplicate names and invitations across lifecycle changes", () => {
    const all = `${spaces}\n${threads}`;
    expect(all).toContain("LOWER(TRIM(name)) = LOWER(TRIM(${name}))");
    expect(all).toContain("id <> ${spaceId}");
    expect(all).toContain(
      "status = 'pending' AND (LOWER(email) = LOWER(${email}) OR invitee_user_id = ${inviteeUserId})",
    );
    expect(all).toContain("You already have a Space with this name");
    expect(all).toContain("This Space already has a Thread with this name");
  });

  it("deletes a Space with one cascading statement", () => {
    const start = spaces.indexOf("async function handleDeleteSpace");
    const end = spaces.indexOf(
      "async function authorizeSpaceOwnerOrThrow",
      start,
    );
    const body = spaces.slice(start, end);
    // Children are removed by foreign-key cascades (see
    // test/domain/history-cascade.test.ts), not by hand-ordered deletes.
    expect(body).toContain("DELETE FROM spaces WHERE id = ${spaceId}");
    expect(body).not.toContain("DELETE FROM runs");
  });
});
