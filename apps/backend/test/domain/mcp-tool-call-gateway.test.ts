import { describe, expect, it } from "./helpers/vitest-compat";
import { gatewayFixture } from "./helpers/assignment-gateway.js";

const call = (taskId: string) => ({
  schemaVersion: 1,
  taskId,
  dispatchKey: `mcp-tool-v1:${taskId}`,
  serverId: "echo",
  tool: "echo",
  toolDefinitionHash: "a".repeat(64),
  arguments: { text: "hi" },
  timeoutMs: 5000,
});

async function fixture(capable = true) {
  const f = await gatewayFixture("created");
  f.sqlite.exec(
    `INSERT OR REPLACE INTO workspace_runtime_facts(workspace_id,runtime_capabilities_json,updated_at)
     VALUES('WS','${capable ? '["workspace.mcp_tool_call.v1","workspace.mcp_tool_call_status.v1"]' : "[]"}','now')`,
  );
  f.sqlite.exec(
    `INSERT INTO workflow_tasks(id,work_request_id,step_kind,execution_mode,timeout_ms,prompt_profile_version,status,created_at,updated_at)
     VALUES('tool','R','tool_call','stateless_read',5000,'tool:v1','running','now','now')`,
  );
  const request = (body: unknown) =>
    f.gateway.fetch(
      new Request("https://gateway.internal/mcp-tool-call", {
        method: "POST",
        body: JSON.stringify(body),
      }),
    );
  return { f, request };
}

async function outboundRequest(f: Awaited<ReturnType<typeof fixture>>["f"]) {
  for (let i = 0; i < 50; i += 1) {
    const found = (await f.outbound()).find(
      (m) => m.type === "mcp.tool_call.request",
    );
    if (found) return found;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error("request was not sent");
}

describe("Gateway MCP tool call", () => {
  it("claims, sends the frozen request and records the Workspace's outcome", async () => {
    const { f, request } = await fixture();
    try {
      const pending = request(call("tool"));
      const sent = await outboundRequest(f);
      expect(sent.payload).toMatchObject({
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        serverId: "echo",
      });
      await f.send("mcp.tool_call.result", {
        schemaVersion: 1,
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        state: "completed",
        code: "completed",
        result: { content: [{ type: "text", text: "hi" }] },
      });
      const body = (await (await pending).json()) as Record<string, unknown>;
      expect(body).toMatchObject({ state: "completed", code: "completed" });
      // A repeat returns the recorded outcome and never re-dispatches.
      const again = await request(call("tool"));
      expect(await again.json()).toMatchObject({ state: "completed" });
      expect(
        (await f.outbound()).filter((m) => m.type === "mcp.tool_call.request"),
      ).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });

  it("refuses before claiming when the Workspace did not advertise tool calls", async () => {
    const { f, request } = await fixture(false);
    try {
      const response = await request(call("tool"));
      expect(response.status).toBe(503);
      expect(
        f.sqlite.prepare("SELECT COUNT(*) AS n FROM mcp_tool_calls").get(),
      ).toEqual({ n: 0 });
      expect(
        (await f.outbound()).filter((m) => m.type === "mcp.tool_call.request"),
      ).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });

  it("answers unknown, not retryable, when a claimed call has no outcome", async () => {
    const { f, request } = await fixture();
    try {
      f.sqlite.exec(
        "INSERT INTO mcp_tool_calls(task_id,workspace_id,dispatch_key,claimed_at) VALUES('tool','WS','mcp-tool-v1:tool','now')",
      );
      const response = await request(call("tool"));
      expect(await response.json()).toMatchObject({
        state: "unknown",
        code: "dispatch_already_claimed",
      });
    } finally {
      f.sqlite.close();
    }
  });

  it("does not return another Workspace's claimed outcome or dispatch again", async () => {
    const { f, request } = await fixture();
    try {
      f.sqlite
        .exec(`INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('WS2','U','Other','now','now');
        INSERT INTO mcp_tool_calls(task_id,workspace_id,dispatch_key,claimed_at,state,code,result_json,completed_at)
        VALUES('tool','WS2','mcp-tool-v1:tool','now','completed','completed','{"content":[{"text":"private"}]}','now')`);
      const response = await request(call("tool"));
      expect(response.status).toBe(409);
      expect(await response.text()).not.toContain("private");
      expect(
        (await f.outbound()).filter((m) => m.type === "mcp.tool_call.request"),
      ).toHaveLength(0);
    } finally {
      f.sqlite.close();
    }
  });

  it("rejects malformed calls and ignores results nobody awaits", async () => {
    const { f, request } = await fixture();
    try {
      expect(
        (await request({ ...call("tool"), dispatchKey: "other" })).status,
      ).toBe(400);
      await f.send("mcp.tool_call.result", {
        schemaVersion: 1,
        taskId: "tool",
        dispatchKey: "mcp-tool-v1:tool",
        state: "completed",
        code: "completed",
      });
      expect(
        f.sqlite.prepare("SELECT count(*) n FROM mcp_tool_calls").get(),
      ).toEqual({ n: 0 });
    } finally {
      f.sqlite.close();
    }
  });

  it("never records an oversized or mismatched result as success", async () => {
    for (const bad of [
      { result: { text: "x".repeat(300 * 1024) } },
      { dispatchKey: "mcp-tool-v1:other" },
      { taskId: "other-task" },
    ]) {
      const { f, request } = await fixture();
      try {
        void request(call("tool"));
        await outboundRequest(f);
        await f
          .send("mcp.tool_call.result", {
            schemaVersion: 1,
            taskId: "tool",
            dispatchKey: "mcp-tool-v1:tool",
            state: "completed",
            code: "completed",
            ...bad,
          })
          .catch(() => undefined);
        const row = f.sqlite
          .prepare("SELECT state FROM mcp_tool_calls WHERE task_id = 'tool'")
          .get() as { state: string | null } | undefined;
        expect(row?.state ?? null).not.toBe("completed");
      } finally {
        f.sqlite.close();
      }
    }
  });

  describe("status (read-only reconciliation)", () => {
    const status = (
      f: Awaited<ReturnType<typeof fixture>>["f"],
      body: unknown,
    ) =>
      f.gateway.fetch(
        new Request("https://gateway.internal/mcp-tool-call-status", {
          method: "POST",
          body: JSON.stringify(body),
        }),
      );
    const query = (taskId: string) => ({
      schemaVersion: 1,
      taskId,
      dispatchKey: `mcp-tool-v1:${taskId}`,
    });
    const claim = (f: Awaited<ReturnType<typeof fixture>>["f"], ws = "WS") =>
      f.sqlite.exec(
        `INSERT INTO mcp_tool_calls(task_id,workspace_id,dispatch_key,claimed_at)
         VALUES('tool','${ws}','mcp-tool-v1:tool','now')`,
      );

    it("asks the Workspace and returns its answer next to Cloud's record", async () => {
      const { f } = await fixture();
      try {
        claim(f);
        const pending = status(f, query("tool"));
        let sent;
        for (let i = 0; i < 50 && !sent; i += 1) {
          sent = (await f.outbound()).find(
            (m) => m.type === "mcp.tool_call.status.request",
          );
          if (!sent) await new Promise((r) => setTimeout(r, 10));
        }
        expect(sent?.payload).toMatchObject({ taskId: "tool" });
        await f.send("mcp.tool_call.status.result", {
          ...query("tool"),
          status: "recorded",
          state: "completed",
          code: "completed",
        });
        const body = (await (await pending).json()) as Record<
          string,
          unknown
        > & { cloud?: unknown; workspace?: unknown; reason?: unknown };
        expect(body.cloud).toEqual({ state: null, code: "dispatch_claimed" });
        expect(body.workspace).toMatchObject({
          status: "recorded",
          state: "completed",
        });
        // Read-only: Cloud's own record is untouched and nothing was dispatched.
        expect(
          f.sqlite.prepare("SELECT state FROM mcp_tool_calls").get(),
        ).toEqual({ state: null });
        expect(
          (await f.outbound()).filter(
            (m) => m.type === "mcp.tool_call.request",
          ),
        ).toHaveLength(0);
      } finally {
        f.sqlite.close();
      }
    });

    it("never asks for a step Cloud did not claim, or another Workspace's", async () => {
      const { f } = await fixture();
      try {
        expect((await status(f, query("tool"))).status).toBe(404);
        f.sqlite.exec(
          `INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES('OTHER','U','Other','now','now')`,
        );
        claim(f, "OTHER");
        expect((await status(f, query("tool"))).status).toBe(409);
        expect(
          (await f.outbound()).filter(
            (m) => m.type === "mcp.tool_call.status.request",
          ),
        ).toHaveLength(0);
        expect(
          (await status(f, { ...query("tool"), dispatchKey: "x" })).status,
        ).toBe(400);
      } finally {
        f.sqlite.close();
      }
    });

    it("reports unsupported without asking an older Service", async () => {
      const { f } = await fixture(false);
      try {
        claim(f);
        const body = (await (await status(f, query("tool"))).json()) as {
          workspace: unknown;
          reason: unknown;
        };
        expect(body.workspace).toBeNull();
        expect(body.reason).toBe("unsupported");
        expect(
          (await f.outbound()).filter(
            (m) => m.type === "mcp.tool_call.status.request",
          ),
        ).toHaveLength(0);
      } finally {
        f.sqlite.close();
      }
    });
  });

  describe("inventory ingestion", () => {
    const inventory = (revision: number, name = "Files") => ({
      schemaVersion: 1,
      revision,
      servers: [
        {
          serverId: "files",
          displayName: name,
          transport: "local",
          consented: true,
          enabled: true,
          availability: "unknown",
          tools: [{ name: "read", definitionHash: "a".repeat(64) }],
          boundWorkerTypes: ["chatgpt"],
        },
      ],
    });
    const read = async (f: Awaited<ReturnType<typeof fixture>>["f"]) =>
      (await (
        await f.gateway.fetch(
          new Request("https://gateway.internal/mcp-inventory"),
        )
      ).json()) as {
        inventory: { revision: number; servers: { displayName: string }[] };
      } | null;

    it("stores the latest sanitized snapshot and ignores stale ones", async () => {
      const { f } = await fixture();
      try {
        expect(await read(f)).toBeNull();
        await f.send("mcp.inventory", inventory(5, "Files five"));
        expect((await read(f))?.inventory.servers[0]?.displayName).toBe(
          "Files five",
        );
        // Older revisions never replace newer data.
        await f.send("mcp.inventory", inventory(4, "Files four"));
        expect((await read(f))?.inventory.revision).toBe(5);
        // The same revision (a new session republishing) is accepted; a newer one wins.
        await f.send("mcp.inventory", inventory(6, "Files six"));
        expect((await read(f))?.inventory.servers[0]?.displayName).toBe(
          "Files six",
        );
      } finally {
        f.sqlite.close();
      }
    });

    it("never stores a payload that carries launch details", async () => {
      const { f } = await fixture();
      try {
        const bad = inventory(1);
        (bad.servers[0] as Record<string, unknown>).command = "/usr/bin/x";
        await f.send("mcp.inventory", bad).catch(() => undefined);
        expect(await read(f)).toBeNull();
      } finally {
        f.sqlite.close();
      }
    });
  });
});
