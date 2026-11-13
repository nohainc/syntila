import { describe, expect, it } from "./helpers/vitest-compat";
import {
  workRequestFileMetadata,
  isWorkRequestFileId,
  verifyWorkRequestFile,
  workRequestFileName,
} from "../../src/domain/routes/work-request-files.js";

const fileId = "wrf-11111111-2222-3333-4444-555555555555";

function bucketWith(bytes: Uint8Array, customMetadata: Record<string, string>) {
  const object = {
    size: bytes.byteLength,
    customMetadata,
    arrayBuffer: async () => bytes.buffer.slice(0),
  };
  const keys: string[] = [];
  return {
    keys,
    bucket: {
      head: async (key: string) => (keys.push(key), object),
      get: async (key: string) => (keys.push(key), object),
    } as unknown as R2Bucket,
  };
}

describe("Work Request files", () => {
  it("projects historical metadata with opaque download IDs and no original bytes or storage paths", () => {
    expect(
      workRequestFileMetadata({
        attachments: [
          {
            kind: "file",
            name: "photo.jpg",
            sizeBytes: 1234,
            fileId,
            contentBase64: "private-bytes",
            mediaType: "image/jpeg",
          },
          { kind: "url", url: "https://example.com" },
          null,
        ],
      }),
    ).toEqual([{ kind: "file", name: "photo.jpg", sizeBytes: 1234, fileId }]);
    expect(workRequestFileMetadata({})).toEqual([]);
  });

  it("accepts only generated file ids", () => {
    expect(isWorkRequestFileId(fileId)).toBe(true);
    expect(isWorkRequestFileId("../secret")).toBe(false);
  });

  it("verifies owner, Thread and size, with no total limit", async () => {
    const { bucket } = bucketWith(new Uint8Array(10 * 1024 * 1024), {
      threadId: "thread-1",
      userId: "user-1",
      digest: "sha256:x",
    });
    const env = { SYNTILA_ARTIFACTS: bucket } as never;
    const size = 10 * 1024 * 1024;
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-1", size),
    ).resolves.toEqual({ digest: "sha256:x" });
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-2", "user-1", size),
    ).rejects.toThrow("not found");
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-2", size),
    ).rejects.toThrow("not found");
    await expect(
      verifyWorkRequestFile(env, fileId, "thread-1", "user-1", size - 1),
    ).rejects.toThrow("not found");
  });

  it("keeps readable file names and strips only separators and controls", () => {
    expect(
      workRequestFileName("ChatGPT Image Oct 6, 2026, 05_47_11 PM.png"),
    ).toBe("ChatGPT Image Oct 6, 2026, 05_47_11 PM.png");
    expect(
      workRequestFileName(
        "61135810_2063761467249879_2135703738118045696_n.jpg",
      ),
    ).toBe("61135810_2063761467249879_2135703738118045696_n.jpg");
    expect(workRequestFileName("../a\\b\u0000c\nd.txt")).toBe(".._a_b_c_d.txt");
    expect(workRequestFileName("Звіт.pdf")).toBe("Звіт.pdf");
    expect(workRequestFileName("")).toBe("Attachment");
    expect(workRequestFileName(42)).toBe("Attachment");
  });
});
