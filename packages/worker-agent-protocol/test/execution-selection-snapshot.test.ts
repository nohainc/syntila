import { expect, it } from "vitest";
import {
  parseWorkerAgentMessage,
  WORKER_AGENT_PROTOCOL_NAME,
  WORKER_AGENT_PROTOCOL_VERSION,
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
    protocol: WORKER_AGENT_PROTOCOL_NAME,
    protocolVersion: WORKER_AGENT_PROTOCOL_VERSION,
    messageId: "message",
    timestamp: "2026-10-11T00:00:00Z",
    type: "assignment.start",
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
  expect(parseWorkerAgentMessage(frame()).type).toBe("assignment.start");
  for (const invalid of [
    { ...selection, resolvedNativeModelId: "secret-native" },
    { ...selection, modelId: "different" },
    { ...selection, effort: "low" },
    { ...selection, workerTypeId: "chatgpt" },
    { ...selection, catalogRevision: "invalid" },
  ]) {
    expect(() => parseWorkerAgentMessage(frame(invalid))).toThrow();
  }
});
