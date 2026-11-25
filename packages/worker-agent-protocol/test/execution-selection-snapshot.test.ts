import { expect, it } from "vitest";
import {
  parseWorkspaceRuntimeMessage,
  WORKSPACE_RUNTIME_PROTOCOL_NAME,
  WORKSPACE_RUNTIME_PROTOCOL_VERSION,
} from "../src/index.js";
const selection = {
  schemaVersion: 1,
  catalogSource: "provider_catalog",
  workerTypeId: "gemini",
  workerDisplayName: "Gemini",
  profileReleaseVersion: 2,
  modelId: "family",
  modelName: "Family",
  effort: "high",
  catalogRevision: "a".repeat(64),
  modelSource: "explicit",
  effortSource: "explicit",
};
function frame(value: Record<string, unknown> = selection) {
  return {
    protocol: WORKSPACE_RUNTIME_PROTOCOL_NAME,
    protocolVersion: WORKSPACE_RUNTIME_PROTOCOL_VERSION,
    messageId: "message",
    timestamp: "2026-10-11T00:00:00Z",
    type: "assignment.start",
    executionWorkspaceId: "workspace",
    workspaceRuntimeId: "runtime",
    workerId: "worker",
    runId: "run",
    taskId: "task",
    attemptId: "attempt",
    assignmentId: "assignment",
    idempotencyKey: "key",
    payload: {
      snapshot: {
        workerTypeId: "gemini",
        model: "family",
        reasoningEffort: "high",
        executionSelection: value,
      },
      input: {},
    },
  };
}
it("accepts only public frozen selection evidence matching the invocation", () => {
  expect(parseWorkspaceRuntimeMessage(frame()).type).toBe("assignment.start");
  for (const invalid of [
    { ...selection, resolvedNativeModelId: "secret-native" },
    { ...selection, modelId: "different" },
    { ...selection, effort: "low" },
    { ...selection, workerTypeId: "chatgpt" },
    { ...selection, catalogRevision: "invalid" },
  ]) {
    expect(() => parseWorkspaceRuntimeMessage(frame(invalid))).toThrow();
  }
});
