import { describe, expect, it } from "vitest";
import { parseWorkerDescriptor } from "../src/worker-descriptor.js";

describe("WorkerDescriptor", () => {
  it("accepts a Cloud-defined Worker without a code-level provider case", () => {
    expect(
      parseWorkerDescriptor({
        workerTypeId: "claude",
        displayName: "Claude",
        description: "Claude Code CLI integration",
        engineFamily: "cli",
        profileDefinitionId: "claude-code",
        providerToolName: "claude",
        releaseStage: "beta",
        visibilityState: "visible",
        sortOrder: 30,
      }),
    ).toEqual({
      workerTypeId: "claude",
      displayName: "Claude",
      description: "Claude Code CLI integration",
      engineFamily: "cli",
      profileDefinitionId: "claude-code",
      providerToolName: "claude",
      releaseStage: "beta",
      visibilityState: "visible",
      sortOrder: 30,
    });
  });

  it("rejects computer-local state in the Cloud descriptor", () => {
    expect(() =>
      parseWorkerDescriptor({
        workerTypeId: "claude",
        displayName: "Claude",
        description: "",
        engineFamily: "cli",
        profileDefinitionId: "claude-code",
        providerToolName: "claude",
        releaseStage: "stable",
        visibilityState: "visible",
        sortOrder: 30,
        readiness: "ready",
      }),
    ).toThrow("Worker descriptor is invalid");
  });
});
