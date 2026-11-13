import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "./helpers/vitest-compat";

const workspaces = readFileSync(
  fileURLToPath(
    new URL("../../src/domain/routes/workspaces-management.ts", import.meta.url),
  ),
  "utf8",
);
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
const router = readFileSync(
  fileURLToPath(new URL("../../src/domain/routes/router.ts", import.meta.url)),
  "utf8",
);

describe("Space lifecycle integrity", () => {
  it("registers space deletion in the production route handler table", () => {
    expect(entrypoint).toContain(
      "handleDeleteSpace: handlers.handleDeleteSpace",
    );
  });

  it("routes Workspace revoke to the execution Workspace lifecycle", () => {
    const start = router.indexOf("const workspaceMatch = url.pathname.match");
    const end = router.indexOf('if (request.method === "PATCH"', start);
    const body = router.slice(start, end);

    expect(body).toContain('request.method === "DELETE"');
    expect(body).toContain("handleRevokeWorkspace");
    expect(entrypoint).toContain(
      "handleRevokeWorkspace: handlers.handleRevokeWorkspace",
    );
    expect(workspaces).toContain(
      "UPDATE execution_workspaces SET status = 'revoked'",
    );
    expect(workspaces).toContain(
      "UPDATE workspace_space_grants SET status = 'revoked'",
    );
    expect(workspaces).toContain(
      "UPDATE workspace_runtime_identities SET revoked_at = ?1",
    );
    expect(workspaces).not.toContain("catch(() => undefined)");
    expect(workspaces).not.toContain(
      "partially migrated development/preview database",
    );
    expect(workspaces).toContain(
      'const alreadyRevoked = workspace.status === "revoked"',
    );
    expect(workspaces).toContain("status <> 'revoked'");
  });

  it("records Space-scoped audits without requiring a Workspace", () => {
    expect(httpSecurity).toContain("space_audit_log");
    expect(httpSecurity).toContain("if (!auditWorkspaceId)");
    expect(httpSecurity).not.toContain(".catch(() => undefined)");
  });

  it("guards duplicate names, grants, and invitations across lifecycle changes", () => {
    const all = `${spaces}\n${threads}\n${workspaces}`;
    expect(all).toContain("LOWER(TRIM(name)) = LOWER(TRIM(?2))");
    expect(all).toContain("id <> ?2");
    expect(all).toContain("status IN ('active', 'suspended')");
    expect(all).toContain(
      "status = 'pending' AND (LOWER(email) = LOWER(?2) OR invitee_user_id = ?3)",
    );
    expect(all).toContain("You already have a Space with this name");
    expect(all).toContain("This Space already has a Thread with this name");
  });

  it("cleans restrictive Thread dependencies before deleting a Space", () => {
    const start = spaces.indexOf("async function handleDeleteSpace");
    const end = spaces.indexOf(
      "async function authorizeSpaceOwnerOrThrow",
      start,
    );
    const body = spaces.slice(start, end);

    expect(body).toContain("DELETE FROM runs WHERE space_id = ?1");
    expect(body).toContain("DELETE FROM work_requests");
    expect(body).toContain("DELETE FROM threads");
    expect(body).toContain(
      "DELETE FROM workspace_space_grants WHERE space_id = ?1",
    );
    expect(body).toContain("mutations: cleanupStatements.map");
    expect(body).toContain("DELETE FROM spaces WHERE id = ?1");
  });
});
