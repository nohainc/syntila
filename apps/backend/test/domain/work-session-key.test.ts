import { expect, it } from "./helpers/vitest-compat";
import { createHash } from "node:crypto";
import { workStepSessionKey } from "../../src/domain/work-session-key.js";

it("uses Engine-safe opaque keys and preserves the Work/direct conversation across requests", () => {
  const params = {
    workBindingId: "direct" as const,
    threadId: "thread-1",
    workRequestId: "request-1",
    stepKind: "implement",
  };
  const key = workStepSessionKey(params);
  expect(key).toBe(
    `work-session-${createHash("sha256").update("thread:thread-1:conversation").digest("hex")}`,
  );
  expect(key).toMatch(/^[A-Za-z0-9_-]+$/);
  expect(key.length).toBeLessThanOrEqual(256);
  expect(workStepSessionKey({ ...params, workRequestId: "request-2" })).toBe(
    key,
  );
  expect(workStepSessionKey({ ...params, threadId: "thread-2" })).not.toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "implement",
      retrySessionStrategy: "continue",
      retryNumber: 1,
    }),
  ).toBe(key);
  // A fresh retry of the Thread's Work conversation moves to a new session
  // through the Thread's generation, so later requests share that session.
  const fresh = workStepSessionKey({
    ...params,
    retryStepKind: "implement",
    retrySessionStrategy: "fresh",
    retryNumber: 1,
    workSessionGeneration: 1,
  });
  expect(fresh).not.toBe(key);
  expect(workStepSessionKey({ ...params, workSessionGeneration: 1 })).toBe(
    fresh,
  );
});

it("keeps Chat durable within a Thread and shares the session with Work", () => {
  const params = {
    workBindingId: "chat" as const,
    threadId: "thread-1",
    workRequestId: "request-1",
    stepKind: "chat",
  };
  const key = workStepSessionKey(params);
  expect(key).toBe(
    `work-session-${createHash("sha256").update("thread:thread-1:conversation").digest("hex")}`,
  );
  for (const workRequestId of ["request-2", "request-3"]) {
    expect(workStepSessionKey({ ...params, workRequestId })).toBe(key);
  }
  expect(workStepSessionKey({ ...params, threadId: "thread-2" })).not.toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      workBindingId: "direct",
      stepKind: "implement",
    }),
  ).toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "chat",
      retrySessionStrategy: "continue",
    }),
  ).toBe(key);
  expect(
    workStepSessionKey({
      ...params,
      retryStepKind: "chat",
      retrySessionStrategy: "fresh",
      retryNumber: 1,
    }),
  ).not.toBe(key);
});

it.each(["research", "plan", "implement", "test", "verify"])(
  "isolates %s sessions by request and Step",
  (stepKind) => {
    const params = {
      threadId: "thread-1",
      workRequestId: "request-1",
      stepKind,
    };
    const key = workStepSessionKey(params);
    expect(
      workStepSessionKey({ ...params, workRequestId: "request-2" }),
    ).not.toBe(key);
    expect(workStepSessionKey({ ...params, stepKind: "other-step" })).not.toBe(
      key,
    );
  },
);

it("uses work session generation to create fresh sessions for direct Work, with gen 0 as legacy", () => {
  const baseKey = `work-session-${createHash("sha256").update("thread:thread-1:conversation").digest("hex")}`;
  const params = {
    workBindingId: "direct" as const,
    threadId: "thread-1",
    workRequestId: "request-1",
    stepKind: "implement",
  };
  expect(workStepSessionKey(params)).toBe(baseKey);
  expect(workStepSessionKey({ ...params, workSessionGeneration: 0 })).toBe(
    baseKey,
  );
  const gen1Key = workStepSessionKey({ ...params, workSessionGeneration: 1 });
  expect(gen1Key).not.toBe(baseKey);
  expect(gen1Key).toBe(
    `work-session-${createHash("sha256").update("thread:thread-1:conversation:gen-1").digest("hex")}`,
  );
  const gen2Key = workStepSessionKey({ ...params, workSessionGeneration: 2 });
  expect(gen2Key).not.toBe(gen1Key);
  expect(gen2Key).toBe(
    `work-session-${createHash("sha256").update("thread:thread-1:conversation:gen-2").digest("hex")}`,
  );
});

it("continues the fresh Chat session after clearing AI History", () => {
  const params = {
    workBindingId: "chat" as const,
    threadId: "T",
    workRequestId: "R",
    stepKind: "chat",
  };
  const old = workStepSessionKey(params);
  const fresh = workStepSessionKey({
    ...params,
    workSessionGeneration: 1,
    retryStepKind: "chat",
    retrySessionStrategy: "fresh",
    retryNumber: 1,
  });
  expect(fresh).not.toBe(old);
  expect(
    workStepSessionKey({
      ...params,
      workSessionGeneration: 1,
      workRequestId: "next",
    }),
  ).toBe(fresh);
});

it("isolates superseded active requests from both original and fresh sessions", () => {
  const params = {
    workBindingId: "chat" as const,
    threadId: "T",
    workRequestId: "R",
    stepKind: "chat",
  };
  const isolated = workStepSessionKey({ ...params, workSessionGeneration: -1 });
  expect(isolated).not.toBe(workStepSessionKey(params));
  expect(isolated).not.toBe(
    workStepSessionKey({ ...params, workSessionGeneration: 1 }),
  );
});
