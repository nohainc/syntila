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

  it("drops anything that is not an accepted image", () => {
    expect(
      workerOutputImages([
        { fileId: "nope", mediaType: "image/png", sizeBytes: 1 },
        { fileId, mediaType: "text/html", sizeBytes: 1 },
        { fileId, mediaType: "image/png" },
        null,
      ]),
    ).toEqual([]);
    expect(workerOutputImages(null)).toEqual([]);
    expect(workerOutputImages("{bad")).toEqual([]);
  });
});
