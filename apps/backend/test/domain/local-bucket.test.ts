import { describe, expect, it } from "./helpers/vitest-compat";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalFolderBucket } from "../../src/platform/local-bucket.js";
import { putStream } from "../../src/domain/upload-stream.js";

const streamOf = (bytes: Uint8Array) => new Response(bytes).body!;

describe("local development bucket", () => {
  it("stores a streamed upload with its size and metadata, and removes it", async () => {
    const root = await mkdtemp(join(tmpdir(), "bucket-"));
    try {
      const bucket = new LocalFolderBucket(root);
      const bytes = new Uint8Array([1, 2, 3, 4]);
      await putStream(bucket as never, "work-request-inputs/wrf-1", streamOf(bytes), 4, {
        httpMetadata: { contentType: "image/png" }, customMetadata: { name: "a.png" },
      } as never);
      const head = await bucket.head("work-request-inputs/wrf-1");
      expect(head).toMatchObject({ size: 4, httpMetadata: { contentType: "image/png" }, customMetadata: { name: "a.png" } });
      expect(new Uint8Array(await (await bucket.get("work-request-inputs/wrf-1"))!.arrayBuffer())).toEqual(bytes);
      expect((await bucket.list({ prefix: "work-request-inputs/" })).objects.map((o) => o.key)).toEqual(["work-request-inputs/wrf-1"]);
      // Flat keys: an object and one "below" it can both exist (previews).
      await bucket.put("work-request-inputs/wrf-1/preview", "p");
      expect((await bucket.head("work-request-inputs/wrf-1"))?.size).toBe(4);
      expect(await (await bucket.get("work-request-inputs/wrf-1/preview"))!.text()).toBe("p");
      await bucket.delete(["work-request-inputs/wrf-1/preview"]);
      await bucket.delete(["work-request-inputs/wrf-1"]);
      expect(await bucket.head("work-request-inputs/wrf-1")).toBeNull();
      await expect(bucket.put("../escape", "x")).rejects.toThrow("Invalid object key");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("reports a storage failure as itself, not as a size mismatch", async () => {
    const broken = { put: async () => { throw new Error("R2 is not configured (bucket.put)"); } };
    await expect(putStream(broken as never, "k", streamOf(new Uint8Array([1])), 1, {} as never))
      .rejects.toThrow("R2 is not configured");
  });
});
