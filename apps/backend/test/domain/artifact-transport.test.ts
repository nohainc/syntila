import { describe, expect, it } from "./helpers/vitest-compat";
import worker from "../../src/domain/index.js";

type ArtifactRow = Record<string, unknown>;

function createArtifactEnvironment() {
  const artifacts = new Map<string, ArtifactRow>();
  const objects = new Map<string, Uint8Array>();
  const events = new Map<string, ArtifactRow>();
  let nextSequence = 0;
  const db = {
    prepare(query: string) {
      let values: readonly unknown[] = [];
      const statement = {
        bind(...next: unknown[]) {
          values = next;
          return statement;
        },
        async first<T>() {
          if (query.includes("FROM spaces p JOIN runs r")) {
            return (
              values[2] === "workspace-1"
                ? { workspaceId: "workspace-1" }
                : null
            ) as T;
          }
          if (query.includes("SELECT * FROM artifacts")) {
            return (artifacts.get(String(values[0])) ?? null) as T;
          }
          if (query.includes("realtime_event_cursors")) {
            return { sequence: 1 } as T;
          }
          return null;
        },
        async all<T>() {
          return { results: [] as readonly T[] };
        },
        async run() {
          if (query.includes("INSERT INTO artifacts")) {
            const [
              id,
              workspaceId,
              spaceId,
              runId,
              taskId,
              attemptId,
              assignmentId,
              mediaType,
              digest,
              storageKey,
              sizeBytes,
              provenanceJson,
              createdAt,
            ] = values;
            artifacts.set(String(id), {
              id,
              workspace_id: workspaceId,
              space_id: spaceId,
              run_id: runId,
              task_id: taskId,
              attempt_id: attemptId,
              assignment_id: assignmentId,
              media_type: mediaType,
              content_digest: digest,
              storage_kind: "r2",
              storage_key: storageKey,
              size_bytes: sizeBytes,
              provenance_json: provenanceJson,
              created_at: createdAt,
            });
          }
          if (query.includes("INSERT INTO realtime_events")) {
            const [
              eventId,
              workspaceId,
              spaceId,
              runId,
              taskId,
              attemptId,
              assignmentId,
              workspaceRuntimeId,
              eventType,
              payloadJson,
              idempotencyKey,
              occurredAt,
            ] = values;
            const row = {
              event_id: eventId,
              workspace_id: workspaceId,
              space_id: spaceId,
              run_id: runId,
              task_id: taskId,
              attempt_id: attemptId,
              assignment_id: assignmentId,
              workspace_runtime_id: workspaceRuntimeId,
              sequence: ++nextSequence,
              event_type: eventType,
              payload_json: payloadJson,
              idempotency_key: idempotencyKey,
              occurred_at: occurredAt,
            };
            events.set(String(eventId), row);
            return { success: true, results: [row] };
          }
          return { success: true };
        },
      };
      return statement;
    },
    async batch(statements: Array<{ run(): Promise<unknown> }>) {
      return Promise.all(statements.map((statement) => statement.run()));
    },
  };
  const bucket = {
    async put(key: string, value: ArrayBuffer | ArrayBufferView) {
      const bytes =
        value instanceof ArrayBuffer
          ? new Uint8Array(value)
          : new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
      objects.set(key, bytes);
    },
    async get(key: string) {
      const bytes = objects.get(key);
      if (!bytes) return null;
      return { body: new Response(bytes as unknown as BodyInit).body };
    },
    async delete(key: string) {
      objects.delete(key);
    },
  };
  const env = {
    SYNTILA_ENVIRONMENT: "development",
    TEST_AUTHENTICATION: async () => ({
      userId: "user-1",
      user: {
        id: "user-1",
        email: "user@example.test",
        displayName: "User One",
        status: "active",
      },
      workspaceId: "workspace-1",
      spaceRoles: {},
      sessionId: "session-1",
      clientType: "web",
    }),
    SYNTILA_DB: db,
    SYNTILA_ARTIFACTS: bucket,
  } as unknown as Env;
  return { env, artifacts, objects };
}

describe("artifact transport", () => {
  it("stores large output in R2 and returns only an opaque download reference", async () => {
    const { env, objects } = createArtifactEnvironment();
    const response = await worker.fetch(
      new Request(
        "https://syntila.test/api/workspaces/workspace-1/artifacts?spaceId=space-1&runId=run-1&artifactId=artifact-1&name=build%20output.zip",
        {
          method: "POST",
          headers: {
            "content-type": "application/zip",
            "content-length": "4",
            origin: "https://syntila.test",
          },
          body: "data",
        },
      ),
      env,
    );

    expect(response.status).toBe(201);
    const body = (await response.json()) as {
      artifact: { downloadUrl: string; sizeBytes: number; name: string };
    };
    expect(body.artifact.downloadUrl).toBe(
      "/api/artifacts/artifact-1?workspaceId=workspace-1",
    );
    expect(body.artifact.sizeBytes).toBe(4);
    expect(body.artifact.name).toBe("build_output.zip");
    expect([...objects.keys()][0]).not.toContain("artifact-1");
  });

  it("retries an interrupted/reconnected upload idempotently", async () => {
    const { env, objects } = createArtifactEnvironment();
    const url =
      "https://syntila.test/api/workspaces/workspace-1/artifacts?spaceId=space-1&runId=run-1&artifactId=artifact-retry";
    const request = () =>
      new Request(url, {
        method: "POST",
        headers: {
          "content-type": "text/plain",
          origin: "https://syntila.test",
        },
        body: "retryable",
      });
    const first = await worker.fetch(request(), env);
    const second = await worker.fetch(request(), env);
    expect(first.status).toBe(201);
    expect(second.status).toBe(200);
    expect((await second.json()) as { deduplicated: boolean }).toMatchObject({
      deduplicated: true,
    });
    expect(objects.size).toBe(1);
  });

  it("rejects an upload before storage when the declared body is too large", async () => {
    const { env, objects } = createArtifactEnvironment();
    const response = await worker.fetch(
      new Request(
        "https://syntila.test/api/workspaces/workspace-1/artifacts?spaceId=space-1&runId=run-1",
        {
          method: "POST",
          headers: {
            "content-length": String(64 * 1024 * 1024 + 1),
            origin: "https://syntila.test",
          },
          body: "small body",
        },
      ),
      env,
    );
    expect(response.status).toBe(413);
    expect(objects.size).toBe(0);
  });

  it("uses the current Space authorization path on retrieval and rejects expired sessions", async () => {
    const { env, artifacts, objects } = createArtifactEnvironment();
    const key = "artifact-objects/workspace-1/object-1";
    const row = {
      id: "artifact-1",
      workspace_id: "workspace-1",
      space_id: "space-1",
      run_id: "run-1",
      media_type: "text/plain",
      content_digest: "sha256:test",
      storage_kind: "r2",
      storage_key: key,
      size_bytes: 4,
      provenance_json: JSON.stringify({ name: "log.txt" }),
      created_at: new Date().toISOString(),
    };
    artifacts.set("artifact-1", row);
    objects.set(key, new TextEncoder().encode("safe"));

    const denied = await worker.fetch(
      new Request("https://syntila.test/api/artifacts/artifact-1"),
      {
        ...env,
        TEST_AUTHENTICATION: async () => ({
          ...(await (
            env as unknown as {
              TEST_AUTHENTICATION: () => Promise<Record<string, unknown>>;
            }
          ).TEST_AUTHENTICATION()),
          workspaceId: "workspace-2",
        }),
      } as unknown as Env,
    );
    // Legacy Workspace selector fields are ignored; access is Space-scoped.
    expect(denied.status).toBe(200);

    const expired = await worker.fetch(
      new Request("https://syntila.test/api/artifacts/artifact-1"),
      {
        ...env,
        SYNTILA_ENVIRONMENT: "production",
        TEST_AUTHENTICATION: undefined,
      } as unknown as Env,
    );
    expect(expired.status).toBe(401);
  });
});
