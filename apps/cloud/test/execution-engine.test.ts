import { expect, it } from "vitest";
import { BUILTIN_WORKFLOWS } from "@syntila/core";
import {
  prepareWorkerStepExecution,
  completeWorkerStepExecution,
} from "../src/execution-engine.js";

it("execution boundary configures next-turn choices without rewriting workflow or earlier executions", () => {
  const binding = {
    workerId: "worker-a",
    model: "model-x",
    reasoningEffort: "medium",
  };
  const input = {
    taskId: "task",
    step: BUILTIN_WORKFLOWS.direct.steps[0]!,
    bindingId: "direct" as const,
    binding,
    prompt: "Implement this",
    workerInput: { attachment: "A" },
    scope: {
      spaceId: "P",
      requesterUserId: "U",
      threadId: "W",
      workRequestId: "R",
    },
    retry: {},
  };
  const before = JSON.stringify(BUILTIN_WORKFLOWS.direct);
  const first = prepareWorkerStepExecution(input);
  binding.workerId = "worker-b";
  binding.model = "model-y";
  binding.reasoningEffort = "high";
  const second = prepareWorkerStepExecution({
    ...input,
    scope: { ...input.scope, workRequestId: "R2" },
  });
  expect(first.workerId).toBe("worker-a");
  expect(first.task).toMatchObject({
    model: "model-x",
    reasoningEffort: "medium",
    readOnly: false,
    executionClass: "stateful_thread",
    sessionPolicy: "durable_session",
    input: { attachment: "A", prompt: "Implement this" },
  });
  expect(second.workerId).toBe("worker-b");
  expect(second.task.model).toBe("model-y");
  expect(second.task.sessionKey).toBe(first.task.sessionKey);
  expect(JSON.stringify(BUILTIN_WORKFLOWS.direct)).toBe(before);
  const chat = prepareWorkerStepExecution({
    ...input,
    step: BUILTIN_WORKFLOWS.chat.steps[0]!,
    bindingId: "chat",
  });
  expect(chat.task.readOnly).toBe(true);
  // Chat and Work share the Thread session; permissions stay per execution.
  expect(chat.task.sessionKey).toBe(first.task.sessionKey);
  expect(() => prepareWorkerStepExecution({ ...input, prompt: " " })).toThrow(
    /empty/,
  );
});

it("execution evidence produces the generic result consumed by workflow planning", () => {
  const result = completeWorkerStepExecution({
    output: { output: { text: "Worker answer" } },
    evidence: {
      profileDefinitionId: "profile",
      profileReleaseVersion: 3,
      reasoningEffort: "high",
    },
    attribution: {
      workerId: "worker",
      workerTypeId: "type",
      engineVersion: "1.0.0",
      model: "model-y",
    },
    startedAt: "start",
    completedAt: "end",
    configuredEffort: "medium",
  });
  expect(result).toMatchObject({
    text: "Worker answer",
    workerId: "worker",
    model: "model-y",
    reasoningEffort: "high",
    profileReleaseVersion: 3,
    status: "completed",
  });
  expect(() =>
    completeWorkerStepExecution({
      output: {},
      evidence: {},
      attribution: result,
      startedAt: "start",
      completedAt: "end",
      configuredEffort: null,
    }),
  ).toThrow(/final answer/);
});

it("a compacting retry resumes the same session and asks the Worker to compact it", () => {
  const input = {
    taskId: "task",
    step: BUILTIN_WORKFLOWS.direct.steps[0]!,
    bindingId: "direct" as const,
    binding: { workerId: "worker-a" },
    prompt: "Implement this",
    workerInput: {},
    scope: {
      spaceId: "P",
      requesterUserId: "U",
      threadId: "W",
      workRequestId: "R",
    },
    retry: {},
  };
  const original = prepareWorkerStepExecution(input);
  const compacting = prepareWorkerStepExecution({
    ...input,
    retry: {
      stepKind: "implement",
      sessionStrategy: "resume",
      number: 1,
      compactContext: true,
    },
  });
  expect(original.task).not.toHaveProperty("contextCompaction");
  expect(compacting.task.contextCompaction).toBe(true);
  expect(compacting.task.sessionKey).toBe(original.task.sessionKey);
});
