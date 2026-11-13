import { expect, it, vi } from "./helpers/vitest-compat";
import { sqliteD1 } from "./helpers/sqlite-d1.js";
import { handleSpaceAdditionalFolders } from "../../src/domain/routes/space-additional-folders.js";
import { handleWorkflowWorkspace } from "../../src/domain/routes/workflow-workspace.js";
import { recordWorkspaceAllowedFolders } from "../../src/domain/workspace-gateway/inventory.js";
import type { SecurityEnv } from "../../src/domain/routes/http-security.js";

vi.mock("../../src/domain/routes/http-security.js", async (original) => ({
  ...(await original<typeof import("../../src/domain/routes/http-security.js")>()),
  securityContext: async (request: Request) => ({
    userId: request.headers.get("authorization")!,
  }),
}));
vi.mock("../../src/domain/collaboration-events.js", () => ({
  publishCollaborationEvent: async () => undefined,
}));

const folder = (id: string, displayName: string, status = "available") => ({
  id,
  displayName,
  status,
  checkedAt: "2026-10-25T12:00:00.000Z",
});
const API = "folder-00000000000000a1";
const DOCS = "folder-00000000000000b2";

function fixture() {
  const { sqlite, db } = sqliteD1();
  sqlite.exec(
    `INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES
       ('U','u@test','U','now','now'),('V','v@test','V','now','now');
     INSERT INTO execution_workspaces(id,owner_user_id,name,created_at,updated_at) VALUES
       ('A','U','Mine','now','now'),('B','U','Other','now','now'),('F','V','Foreign','now','now');
     INSERT INTO spaces(id,owner_user_id,name,created_at,updated_at) VALUES
       ('S','U','Space','now','now'),('T','V','Theirs','now','now');
     INSERT INTO space_memberships VALUES
       ('m1','S','U','owner','now','now'),('m2','S','V','collaborator','now','now'),
       ('m3','T','V','owner','now','now'),('m4','T','U','collaborator','now','now');
     INSERT INTO space_workflow_settings VALUES('S','A','now'),('T','F','now');`,
  );
  const env = { SYNTILA_DB: db } as SecurityEnv;
  const call = async (user: string, space: string, body?: unknown) => {
    let response: Response;
    try {
      response = await handleSpaceAdditionalFolders(
        new Request(
          `https://cloud.test/api/spaces/${space}/additional-folders`,
          {
            method: body ? "PUT" : "GET",
            headers: { authorization: user },
            ...(body ? { body: JSON.stringify(body) } : {}),
          },
        ),
        env,
        space,
      );
    } catch (error) {
      return {
        status: (error as { status: number }).status,
        body: null as unknown as {
          eligible: boolean;
          workspaceId: string;
          folders: Array<{ id: string; name: string; attached: boolean }>;
        },
      };
    }
    return {
      status: response.status,
      body: (await response.json()) as {
        eligible: boolean;
        workspaceId: string;
        folders: Array<{ id: string; name: string; attached: boolean }>;
      },
    };
  };
  return { sqlite, env, call };
}

it("lets the Space and Workspace owner attach published folders only", async () => {
  const { sqlite, env, call } = fixture();
  try {
    await recordWorkspaceAllowedFolders(
      env,
      "A",
      [folder(API, "api"), folder(DOCS, "Docs", "read_only")],
      "now",
    );
    const listed = await call("U", "S");
    expect(listed.body).toMatchObject({ eligible: true, workspaceId: "A" });
    expect(listed.body.folders.map((f) => [f.id, f.attached])).toEqual([
      [API, false],
      [DOCS, false],
    ]);
    expect(JSON.stringify(listed.body)).not.toContain("path");

    const saved = await call("U", "S", { folderIds: [DOCS] });
    expect(saved.status).toBe(200);
    expect(saved.body.folders.find((f) => f.id === DOCS)!.attached).toBe(true);

    expect(
      (await call("U", "S", { folderIds: ["folder-ffffffffffffffff"] })).status,
    ).toBe(409);
    expect((await call("U", "S", { folderIds: ["../etc"] })).status).toBe(400);
    expect((await call("U", "S", { folderIds: [API], extra: 1 })).status).toBe(
      400,
    );
  } finally {
    sqlite.close();
  }
});

it("hides folders from collaborators and from Spaces on foreign Workspaces", async () => {
  const { sqlite, env, call } = fixture();
  try {
    await recordWorkspaceAllowedFolders(env, "A", [folder(API, "api")], "now");
    await recordWorkspaceAllowedFolders(env, "F", [folder(DOCS, "x")], "now");
    expect((await call("V", "S")).body).toMatchObject({
      eligible: false,
      reason: "not_space_owner",
      folders: [],
    });
    expect((await call("V", "S", { folderIds: [] })).status).toBe(403);
    expect((await call("V", "T")).body).toMatchObject({
      eligible: true,
      workspaceId: "F",
    });
    sqlite.exec("UPDATE spaces SET owner_user_id='U' WHERE id='T'");
    expect((await call("U", "T")).body).toMatchObject({
      eligible: false,
      reason: "not_workspace_owner",
    });
  } finally {
    sqlite.close();
  }
});

it("detaches folders when the folder is removed or the Space changes Workspace", async () => {
  const { sqlite, env, call } = fixture();
  try {
    await recordWorkspaceAllowedFolders(
      env,
      "A",
      [folder(API, "api"), folder(DOCS, "Docs")],
      "now",
    );
    await call("U", "S", { folderIds: [API, DOCS] });

    // Omitted or malformed lists keep the stored folders.
    await recordWorkspaceAllowedFolders(env, "A", undefined, "now");
    await recordWorkspaceAllowedFolders(
      env,
      "A",
      [{ ...folder(API, "api"), path: "/Users/u/api" }],
      "now",
    );
    expect((await call("U", "S")).body.folders).toHaveLength(2);

    await recordWorkspaceAllowedFolders(env, "A", [folder(API, "api")], "now");
    expect(
      (await call("U", "S")).body.folders.map((f) => [f.id, f.attached]),
    ).toEqual([[API, true]]);

    const switched = await handleWorkflowWorkspace(
      new Request("https://cloud.test/api/spaces/S/workflow-workspace", {
        method: "PUT",
        headers: { authorization: "U" },
        body: JSON.stringify({ workspaceId: "B", confirmReset: true }),
      }),
      env,
      "S",
    );
    expect(switched.status).toBe(200);
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM space_additional_folders")
        .get(),
    ).toEqual({ n: 0 });
    expect(
      sqlite
        .prepare("SELECT COUNT(*) AS n FROM workspace_allowed_folders")
        .get(),
    ).toEqual({ n: 1 });
  } finally {
    sqlite.close();
  }
});
