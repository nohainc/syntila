import { executionErrorMessage } from "@syntila/protocol";
import { parseWorkspaceRuntimeMessage } from "@syntila/worker-agent-protocol";
import { describe, expect, it } from "./helpers/vitest-compat";
import { conversationFixture } from "./helpers/conversation.js";
import { recordAssignmentError } from "../../src/domain/assignment-dispatcher.js";
import {
  decryptProviderFailure,
  previousProviderFailureKeys,
  providerFailureKeyId,
  encryptProviderFailure,
  providerFailureKey,
} from "../../src/domain/provider-failure-encryption.js";
import {
  handleGetWorkRequest,
  handleListWorkRequests,
} from "../../src/domain/routes/work-lifecycle.js";

const testKey = "12".repeat(32);

describe("ProviderFailure persistence, credential boundary, and isolation", () => {
  it("retains a capability-gated unavailable marker on the matching failed attempt", async () => {
    const f = await conversationFixture({ failureDetailsSnapshot: true });
    await f.sqlite.exec(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('M','P','U','owner','now','now') ON CONFLICT DO NOTHING",
    );
    await f.assign("A1");
    const recorded = await recordAssignmentError(f.db as never, "A1", {
      error: {
        code: "execution_failed",
        message: executionErrorMessage("execution_failed"),
        retryable: false,
      },
      failedAt: new Date().toISOString(),
      providerFailureUnavailable: true,
    });
    expect(recorded).toBe(true);
    const env = {
      SYNTILA_ENVIRONMENT: "development",
      SYNTILA_DB: f.db,
      TEST_AUTHENTICATION: async () => ({
        userId: "U",
        user: {
          id: "U",
          email: "u@test",
          displayName: "User",
          status: "active",
        },
        workspaceId: "",
        spaceRoles: {},
        sessionId: "test",
        clientType: "web",
      }),
    } as never;
    const response = await handleGetWorkRequest(
      new Request("https://test/api/work-requests/R"),
      env,
      "R",
    );
    const work = (await response.json()) as any;
    expect(work.steps[0].status).toBe("failed");
    expect(work.steps[0].providerFailure).toBeNull();
    expect(work.steps[0].providerFailureUnavailable).toBe(true);
    expect(work.steps[0].errorCode).toBe("execution_failed");
  });
  it("reads details after key rotation through a decrypt-only previous key", () => {
    const oldKey = providerFailureKey("12".repeat(32))!;
    const newKey = providerFailureKey("56".repeat(32))!;
    const encrypted = encryptProviderFailure(
      { schemaVersion: 1, source: "stderr", providerErrorText: "kept" },
      "A1",
      oldKey,
    );
    expect(encrypted.keyId).toBe(providerFailureKeyId(oldKey));
    expect(decryptProviderFailure(encrypted, "A1", newKey)).toBeNull();
    expect(
      decryptProviderFailure(encrypted, "A1", [
        newKey,
        ...previousProviderFailureKeys(`bad, ${"12".repeat(32)}`),
      ])?.providerErrorText,
    ).toBe("kept");
    // Envelopes written before keyId existed still decrypt.
    const { keyId: _ignored, ...legacy } = encrypted;
    expect(
      decryptProviderFailure(legacy, "A1", [newKey, oldKey])?.providerErrorText,
    ).toBe("kept");
  });

  it("authenticates ciphertext and binds it to the assignment", () => {
    const key = providerFailureKey(testKey)!;
    const encrypted = encryptProviderFailure(
      { schemaVersion: 1, source: "stderr", providerErrorText: "private" },
      "A1",
      key,
    );
    expect(
      decryptProviderFailure(encrypted, "A1", key)?.providerErrorText,
    ).toBe("private");
    expect(decryptProviderFailure(encrypted, "A2", key)).toBeNull();
    expect(
      decryptProviderFailure(
        encrypted,
        "A1",
        providerFailureKey("34".repeat(32)),
      ),
    ).toBeNull();
    const tampered = {
      ...encrypted,
      ciphertext: Buffer.from("tampered").toString("base64"),
    };
    expect(decryptProviderFailure(tampered, "A1", key)).toBeNull();
  });
  it("persists sanitized providerFailure, omits credentials, and rejects duplicate/stale terminal updates", async () => {
    const f = await conversationFixture();
    await f.assign("A1");
    await f.sqlite
      .prepare("UPDATE worker_assignments SET attempt_id = ? WHERE id = 'A1'")
      .run("attempt-current");

    const stale = await recordAssignmentError(
      f.db as never,
      "A1",
      {
        error: {
          code: "execution_failed",
          message: executionErrorMessage("execution_failed"),
          retryable: false,
        },
        failedAt: new Date().toISOString(),
        providerFailure: {
          schemaVersion: 1,
          source: "stderr",
          providerErrorText: "stale",
        },
      },
      "attempt-stale",
      { providerFailureKey: testKey },
    );
    expect(stale).toBe(false);

    const recorded = await recordAssignmentError(
      f.db as never,
      "A1",
      {
        error: {
          code: "execution_failed",
          message: executionErrorMessage("execution_failed"),
          retryable: false,
        },
        failedAt: new Date().toISOString(),
        providerFailure: {
          schemaVersion: 1,
          nativeErrorCode: "MODEL_OVERLOADED",
          providerErrorText: "Failed with token Bearer secret_token_1234567890",
          failedRunResponse: "Partial response before failure",
          source: "structured_error",
          truncated: true,
          omitted: true,
          omittedFields: ["providerErrorText"],
        },
      },
      "attempt-current",
      { providerFailureKey: testKey },
    );
    expect(recorded).toBe(true);

    const row = (await f.sqlite
      .prepare(
        "SELECT status, error_json::text AS error_json FROM worker_assignments WHERE id = 'A1'",
      )
      .get()) as { status: string; error_json: string };
    expect(row.status).toBe("failed");

    const stored = JSON.parse(row.error_json) as Record<string, unknown>;
    expect(row.error_json).not.toContain("Partial response before failure");
    const pf = decryptProviderFailure(
      stored.providerFailureEncrypted,
      "A1",
      providerFailureKey(testKey),
    )!;
    expect(pf.nativeErrorCode).toBe("MODEL_OVERLOADED");
    expect(pf.providerErrorText).toBeUndefined();
    expect(pf.failedRunResponse).toBe("Partial response before failure");
    expect(pf.omitted).toBe(true);
    expect(pf.omittedFields).toEqual(["providerErrorText"]);
    expect(pf.truncated).toBe(true);
    expect(
      decryptProviderFailure(
        stored.providerFailureEncrypted,
        "wrong-assignment",
        providerFailureKey(testKey),
      ),
    ).toBeNull();

    // Duplicate terminal delivery must return false and not overwrite.
    const dup = await recordAssignmentError(f.db as never, "A1", {
      error: {
        code: "execution_failed",
        message: executionErrorMessage("execution_failed"),
        retryable: false,
      },
      failedAt: new Date().toISOString(),
      providerFailure: {
        schemaVersion: 1,
        nativeErrorCode: "SHOULD_NOT_OVERWRITE",
        source: "stderr",
      },
    });
    expect(dup).toBe(false);

    const afterDup = (await f.sqlite
      .prepare(
        "SELECT error_json::text AS error_json FROM worker_assignments WHERE id = 'A1'",
      )
      .get()) as { error_json: string };
    const storedAfter = JSON.parse(afterDup.error_json) as Record<
      string,
      unknown
    >;
    expect(
      decryptProviderFailure(
        storedAfter.providerFailureEncrypted,
        "A1",
        providerFailureKey(testKey),
      )?.nativeErrorCode,
    ).toBe("MODEL_OVERLOADED");
  });

  it("fails closed when no encryption key is available", async () => {
    const f = await conversationFixture();
    await f.assign("A1");
    expect(
      await recordAssignmentError(f.db as never, "A1", {
        error: {
          code: "execution_failed",
          message: executionErrorMessage("execution_failed"),
          retryable: false,
        },
        failedAt: new Date().toISOString(),
        providerFailure: {
          schemaVersion: 1,
          source: "stderr",
          providerErrorText: "sensitive provider text",
        },
      }),
    ).toBe(true);
    const row = (await f.sqlite
      .prepare(
        "SELECT error_json::text AS error_json FROM worker_assignments WHERE id = 'A1'",
      )
      .get()) as { error_json: string };
    expect(row.error_json).not.toContain("sensitive provider text");
    expect(JSON.parse(row.error_json).providerFailureUnavailable).toBe(true);
  });

  it("returns decrypted details only through authorized Work reads", async () => {
    const f = await conversationFixture({ failureDetailsSnapshot: true });
    await f.sqlite.exec(
      "INSERT INTO space_memberships(id,space_id,user_id,role,created_at,updated_at) VALUES('M','P','U','owner','now','now') ON CONFLICT DO NOTHING",
    );
    await f.assign("A1");
    await recordAssignmentError(
      f.db as never,
      "A1",
      {
        error: {
          code: "execution_failed",
          message: executionErrorMessage("execution_failed"),
          retryable: false,
        },
        failedAt: new Date().toISOString(),
        providerFailure: {
          schemaVersion: 1,
          source: "structured_error",
          providerErrorText: "exact error",
          failedRunResponse: "partial result",
          truncated: true,
        },
      },
      undefined,
      { providerFailureKey: testKey },
    );
    const env = (userId: string, key = testKey, previousKeys?: string) =>
      ({
        SYNTILA_ENVIRONMENT: "development",
        SYNTILA_DB: f.db,
        SYNTILA_PROVIDER_FAILURE_KEY: key,
        SYNTILA_PROVIDER_FAILURE_PREVIOUS_KEYS: previousKeys,
        TEST_AUTHENTICATION: async () => ({
          userId,
          user: {
            id: userId,
            email: "u@test",
            displayName: "User",
            status: "active",
          },
          workspaceId: "",
          spaceRoles: {},
          sessionId: "test",
          clientType: "web",
        }),
      }) as never;
    const request = new Request("https://test/api/work-requests/R");
    const body = (await (
      await handleGetWorkRequest(request, env("U"), "R")
    ).json()) as any;
    expect(body.steps[0].providerFailure).toMatchObject({
      providerErrorText: "exact error",
      failedRunResponse: "partial result",
      truncated: true,
    });
    const list = (await (
      await handleListWorkRequests(
        new Request("https://test/api/threads/W/work-requests"),
        env("U"),
        "W",
      )
    ).json()) as any;
    expect(
      list.workRequests[0].steps[0].providerFailure.providerErrorText,
    ).toBe("exact error");
    const unavailable = (await (
      await handleGetWorkRequest(request, env("U", "00".repeat(32)), "R")
    ).json()) as any;
    expect(unavailable.steps[0].providerFailure).toBeNull();
    expect(unavailable.steps[0].providerFailureUnavailable).toBe(true);
    const rotated = (await (
      await handleGetWorkRequest(
        request,
        env("U", "00".repeat(32), testKey),
        "R",
      )
    ).json()) as any;
    expect(rotated.steps[0].providerFailure.providerErrorText).toBe(
      "exact error",
    );
    await expect(
      handleGetWorkRequest(
        request,
        env("other", "00".repeat(32), testKey),
        "R",
      ),
    ).rejects.toThrow();
    await expect(
      handleGetWorkRequest(request, env("other"), "R"),
    ).rejects.toThrow();
    await f.assign("A2");
    const retry = (await (
      await handleGetWorkRequest(request, env("U"), "R")
    ).json()) as any;
    expect(retry.steps[0].assignmentId).toBe("A2");
    expect(retry.steps[0].providerFailure).toBeNull();
    await f.sqlite.exec("DELETE FROM work_requests WHERE id = 'R'");
    const remaining = (await f.sqlite
      .prepare(
        "SELECT COUNT(*) AS count FROM worker_assignments WHERE id IN ('A1','A2')",
      )
      .get()) as { count: number };
    expect(Number(remaining.count)).toBe(0);
  });

  it("preserves canonical failure when providerFailure is absent (legacy peer)", async () => {
    const f = await conversationFixture();
    await f.assign("A1");

    const recorded = await recordAssignmentError(f.db as never, "A1", {
      error: {
        code: "execution_failed",
        message: executionErrorMessage("execution_failed"),
        retryable: true,
      },
      failedAt: new Date().toISOString(),
    });
    expect(recorded).toBe(true);

    const row = (await f.sqlite
      .prepare(
        "SELECT status, error_json::text AS error_json FROM worker_assignments WHERE id = 'A1'",
      )
      .get()) as { status: string; error_json: string };
    expect(row.status).toBe("failed");
    const stored = JSON.parse(row.error_json) as Record<string, unknown>;
    expect(stored.providerFailure).toBeUndefined();
    expect((stored.error as Record<string, unknown>).code).toBe(
      "execution_failed",
    );
  });

  it("validates assignment.error wire messages with and without providerFailure", () => {
    const base = {
      protocol: "syntila.worker-agent-protocol",
      protocolVersion: "5.1",
      messageId: "msg-1",
      timestamp: "2026-11-18T00:00:00.000Z",
      type: "assignment.error",
      executionWorkspaceId: "ws-1",
      workspaceRuntimeId: "rt-1",
      workerId: "worker-1",
      runId: "run-1",
      taskId: "task-1",
      attemptId: "att-1",
      assignmentId: "asg-1",
      idempotencyKey: "idem-1",
    };

    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        payload: {
          error: {
            code: "execution_failed",
            message: executionErrorMessage("execution_failed"),
            retryable: false,
          },
          providerFailure: {
            schemaVersion: 1,
            nativeErrorCode: "ERR_CODE",
            providerErrorText: "Error text",
            failedRunResponse: "Response text",
            source: "structured_error",
          },
        },
      }),
    ).not.toThrow();

    expect(() =>
      parseWorkspaceRuntimeMessage({
        ...base,
        payload: {
          error: {
            code: "execution_failed",
            message: executionErrorMessage("execution_failed"),
            retryable: false,
          },
        },
      }),
    ).not.toThrow();
  });
});
