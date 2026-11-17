import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { user, workspace } from "./helpers/seed";
import { hashToken } from "@syntila/security";
import { WorkspaceRuntimeAuthenticator } from "../../src/domain/workspace-gateway/runtime-authenticator.js";

describe("WorkspaceRuntimeAuthenticator", () => {
  it("authenticates credentials and binds sessions to the same Workspace", async () => {
    const token = "runtime-secret";
    const tokenHash = await hashToken(token);
    const f = await pgD1();
    try {
      await f.sqlite.exec(`${user("owner")}
        ${workspace("workspace-1", "owner")}
        INSERT INTO workspace_runtime_identities(id, workspace_id, credential_token_hash, installation_id)
          VALUES ('runtime-1', 'workspace-1', '${tokenHash}', 'install-1');
        INSERT INTO workspace_sessions(id, workspace_id, runtime_identity_id, client_version, protocol_version, connected_at, last_heartbeat_at)
          VALUES ('session-1', 'workspace-1', 'runtime-1', '1', '1', '2026-10-10T00:00:00.000Z', '2026-10-10T00:00:00.000Z');`);
      const authenticator = new WorkspaceRuntimeAuthenticator(f.db);

      await expect(
        authenticator.authenticateRuntime("runtime-1", token),
      ).resolves.toMatchObject({ executionWorkspaceId: "workspace-1" });
      await expect(
        authenticator.authenticateRuntime("runtime-1", "wrong"),
      ).resolves.toBeNull();
      await expect(
        authenticator.authenticateSession("session-1", token),
      ).resolves.toMatchObject({ executionWorkspaceId: "workspace-1" });
      await expect(
        authenticator.authenticateSession("missing", token),
      ).resolves.toBeNull();
      // A revoked Workspace no longer authenticates its runtime.
      (await f.sqlite.exec("UPDATE execution_workspaces SET status = 'revoked' WHERE id = 'workspace-1'"));
      await expect(
        authenticator.authenticateRuntime("runtime-1", token),
      ).resolves.toBeNull();
    } finally {
      await f.sqlite.close();
    }
  });
});
