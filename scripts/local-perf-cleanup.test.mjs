import { describe, expect, it, vi } from "vitest";
import { finalizeBenchmarkSpace } from "./local-perf-cleanup.mjs";

describe("benchmark Space cleanup", () => {
  it("preserves failed or active runs and removes successful runs", async () => {
    const remove = vi.fn();
    expect(
      await finalizeBenchmarkSpace({ activeCount: 1, succeeded: true, remove }),
    ).toBe("active");
    expect(
      await finalizeBenchmarkSpace({
        activeCount: 0,
        succeeded: false,
        remove,
      }),
    ).toBe("failed");
    expect(remove).not.toHaveBeenCalled();
    expect(
      await finalizeBenchmarkSpace({ activeCount: 0, succeeded: true, remove }),
    ).toBe("deleted");
    expect(remove).toHaveBeenCalledOnce();
  });
  it("surfaces a failed deletion", async () => {
    await expect(
      finalizeBenchmarkSpace({
        activeCount: 0,
        succeeded: true,
        remove: async () => {
          throw new Error("denied");
        },
      }),
    ).rejects.toThrow("denied");
  });
});
