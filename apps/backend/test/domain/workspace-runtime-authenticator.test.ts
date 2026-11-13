import { describe, expect, it } from "./helpers/vitest-compat";
import { hashToken } from "@syntila/security";
import { WorkspaceRuntimeAuthenticator } from "../../src/domain/workspace-gateway/runtime-authenticator.js";

describe("WorkspaceRuntimeAuthenticator", () => {
  it("authenticates credentials and binds sessions to the same Workspace", async () => {
    const token = "runtime-secret";
    const tokenHash = await hashToken(token);
    const db = {
      prepare(sql: string) {
        return {
          bind: (...values: unknown[]) => ({
            first: async () => {
              if (sql.includes("workspace_sessions")) {
                return values[0] === "session-1"
                  ? {
                      sessionId: "session-1",
                      executionWorkspaceId: "workspace-1",
                      runtimeIdentityId: "runtime-1",
                      connectedAt: "2026-10-10T00:00:00.000Z",
                      disconnectedAt: null,
                    }
                  : null;
              }
              return values[1] === tokenHash
                ? {
                    runtimeId: "runtime-1",
                    executionWorkspaceId: "workspace-1",
                    installationId: "install-1",
                    credentialTokenHash: tokenHash,
                  }
                : null;
            },
          }),
        };
      },
    } as never;
    const authenticator = new WorkspaceRuntimeAuthenticator(db);

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
  });
});
