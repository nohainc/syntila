import { describe, expect, it } from "./helpers/vitest-compat";
import { workerOutputImages } from "../../src/domain/routes/worker-output-images.js";

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
