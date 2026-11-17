import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1, recordStatements } from "./helpers/pg-d1";
import { handleWorkspaceGatewayConnect } from "../../src/domain/routes/workspaces-runtime.js";

describe("Workspace WebSocket runtime authentication", () => {
  it.each(["token", "authToken"])(
    "does not accept the %s query parameter as a credential",
    async (parameter) => {
      const f = await pgD1();
      try {
        const recorded = recordStatements(f.db);
        const response = await handleWorkspaceGatewayConnect(
          new Request(
            `https://app.syntila.test/api/workspace-gateway/connect?workspaceRuntimeId=runtime-1&${parameter}=secret`,
            { headers: { upgrade: "websocket" } },
          ),
          { SYNTILA_DB: recorded.db } as never,
        );

        expect(response.status).toBe(401);
        expect(recorded.statements).toEqual([]);
      } finally {
        await f.sqlite.close();
      }
    },
  );
});
