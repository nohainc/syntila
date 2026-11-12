import { describe, expect, it } from "vitest";
import { workerOutputImages } from "../src/routes/worker-output-images.js";

const fileId = "wrf-12345678-1234-1234-1234-123456789abc";

describe("workerOutputImages", () => {
  it("keeps well-formed image descriptors from stored JSON", () => {
    expect(
      workerOutputImages(
        JSON.stringify([
          {
            fileId,
            name: "fox/../x.png",
            mediaType: "image/png",
            sizeBytes: 10,
            extra: true,
          },
        ]),
      ),
    ).toEqual([
      {
        kind: "file",
        fileId,
        name: "fox_.._x.png",
        mediaType: "image/png",
        sizeBytes: 10,
      },
    ]);
  });

  it("accepts files and drops malformed descriptors", () => {
    expect(
      workerOutputImages([
        { fileId: "nope", mediaType: "image/png", sizeBytes: 1 },
        { fileId, mediaType: "image/png" },
        null,
      ]),
    ).toEqual([]);
    expect(
      workerOutputImages([
        {
          fileId,
          name: "report.pdf",
          mediaType: "application/pdf",
          sizeBytes: 10,
        },
      ]),
    ).toHaveLength(1);
    expect(workerOutputImages(null)).toEqual([]);
    expect(workerOutputImages("{bad")).toEqual([]);
  });

  it("keeps only a bounded JPEG preview", () => {
    const base = {
      fileId,
      name: "a.png",
      mediaType: "image/png",
      sizeBytes: 1,
    };
    const [kept, script, huge] = workerOutputImages([
      { ...base, previewImage: "/9j/AAAA" },
      { ...base, previewImage: "<script>" },
      { ...base, previewImage: `/9j/${"A".repeat(48000)}` },
    ]);
    expect(kept?.previewImage).toBe("/9j/AAAA");
    expect(script).not.toHaveProperty("previewImage");
    expect(huge).not.toHaveProperty("previewImage");
  });
});

describe("generated output upload", () => {
  it("stores the file under the Space owner and rejects finished assignments", async () => {
    const { vi } = await import("vitest");
    const { handleUploadWorkerOutputImage } =
      await import("../src/routes/worker-output-images.js");
    const runtime = await import("../src/routes/work-request-inputs.js");
    const plans = await import("../src/account-plan.js");
    const files = await import("../src/routes/work-request-files.js");
    const runtimeSpy = vi
      .spyOn(runtime, "requireRuntime")
      .mockResolvedValue("workspace-1");
    const limitsSpy = vi
      .spyOn(plans, "getAttachmentLimits")
      .mockResolvedValue({ fileBytes: 100, storageBytes: 1000 } as never);
    const storeSpy = vi
      .spyOn(files, "storeWorkRequestFile")
      .mockResolvedValue({ digest: "sha256:test", sizeBytes: 4 });
    let status = "running";
    const env = {
      SYNTILA_DB: {
        prepare: () => ({
          bind: () => ({
            first: async () => ({
              threadId: "thread-1",
              spaceId: "space-1",
              ownerUserId: "space-owner",
              status,
            }),
          }),
        }),
      },
    } as never;
    const request = () =>
      new Request(
        "https://example.com/api/workspace-runtime/outputs?assignmentId=asg-1&name=report.txt",
        {
          method: "POST",
          headers: { "content-type": "text/plain", "content-length": "4" },
          body: "test",
        },
      );
    try {
      expect((await handleUploadWorkerOutputImage(request(), env)).status).toBe(
        201,
      );
      expect(limitsSpy).toHaveBeenCalledWith(env, "space-owner");
      expect(storeSpy).toHaveBeenCalledWith(
        env,
        expect.objectContaining({
          userId: "space-owner",
          spaceId: "space-1",
          threadId: "thread-1",
          assignmentId: "asg-1",
          name: "report.txt",
        }),
      );
      status = "completed";
      await expect(
        handleUploadWorkerOutputImage(request(), env),
      ).rejects.toThrow("already finished");
      expect(storeSpy).toHaveBeenCalledTimes(1);
    } finally {
      runtimeSpy.mockRestore();
      limitsSpy.mockRestore();
      storeSpy.mockRestore();
    }
  });
});
