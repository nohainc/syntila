import { describe, expect, it } from "./helpers/vitest-compat";
import {
  grantExecutionPermissions,
  grantStringArray,
} from "../../src/domain/routes/workspace-access.js";

describe("Workspace Grant execution permissions", () => {
  it("accepts the canonical permission IDs", () => {
    expect(
      grantExecutionPermissions(["repository:read", "shell:execute"]),
    ).toBe('["repository:read","shell:execute"]');
  });

  it("rejects aliases and unknown permission IDs at the write boundary", () => {
    expect(() => grantExecutionPermissions(["workspace:read"])).toThrow(
      /invalid or duplicate/,
    );
    expect(() => grantExecutionPermissions(["system:admin"])).toThrow(
      /invalid or duplicate/,
    );
    expect(() =>
      grantExecutionPermissions(["repository:read", "repository:read"]),
    ).toThrow(/invalid or duplicate/);
  });

  it("rejects duplicate Worker ID values", () => {
    expect(() =>
      grantStringArray(["worker-a", "worker-a"], "allowedWorkerIds"),
    ).toThrow(/invalid or duplicate/);
  });
});
