import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { describe, expect, it, vi } from "./helpers/vitest-compat";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalFolderBucket } from "../../src/platform/local-bucket.js";

const authorize = vi.fn(async (..._args: unknown[]) => ({ context: { userId: "alice" }, spaceId: "sp" }));
vi.mock("../../src/domain/routes/handlers.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
vi.mock("../../src/domain/routes/thread-policy.js", async (original) => ({
  ...(await original<Record<string, unknown>>()),
  authorizeThreadAccess: (...args: unknown[]) => authorize(...args),
}));
import {
  handleCreateThreadMediaLink,
  handleGetMediaFile,
  parseByteRange,
} from "../../src/domain/routes/media-links.js";

const AUDIO = "wrf-11111111-1111-4111-8111-111111111111";
const TEXT = "wrf-22222222-2222-4222-8222-222222222222";

async function fixture() {
  const f = await pgD1();
  const root = await mkdtemp(join(tmpdir(), "media-"));
  const bucket = new LocalFolderBucket(root);
  const bytes = Uint8Array.from({ length: 100 }, (_, i) => i);
  await bucket.put(`work-request-inputs/${AUDIO}`, bytes, {
    httpMetadata: { contentType: "audio/wav" }, customMetadata: { threadId: "th" } });
  await bucket.put(`work-request-inputs/${TEXT}`, "hi", {
    httpMetadata: { contentType: "text/plain" }, customMetadata: { threadId: "th" } });
  const output = JSON.stringify({ output: { images: [
    { kind: "file", fileId: AUDIO, name: "a.wav", mediaType: "audio/wav", sizeBytes: 100 },
    { kind: "file", fileId: TEXT, name: "a.txt", mediaType: "text/plain", sizeBytes: 2 },
  ] } });
  await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
    INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES ('w','','alice','gemini','Mac');
    INSERT INTO worker_assignments(id,space_id,thread_id,worker_type_id,worker_instance_id,worker_snapshot_json,status,output_json)
      VALUES ('asg','sp','th','gemini','w','{}','completed','${output}')`);
  const env = { SYNTILA_DB: f.db, SYNTILA_ARTIFACTS: bucket } as never;
  return { f, env, bytes, close: async () => { await f.sqlite.close(); await rm(root, { recursive: true, force: true }); } };
}

const play = (path: string, range?: string) =>
  new Request(`https://x${path}`, range ? { headers: { range } } : {});

describe("Thread media links", () => {
  it("plays a Thread's audio by byte range with a signed link, and refuses tampering", async () => {
    const t = await fixture();
    try {
      const made = await handleCreateThreadMediaLink(new Request("https://x", { method: "POST" }), t.env, "th", AUDIO);
      const { path, mediaType } = await made.json() as { path: string; mediaType: string };
      expect(mediaType).toBe("audio/wav");
      const fileId = path.split("?")[0]!.split("/").pop()!;

      const whole = await handleGetMediaFile(play(path), t.env, fileId);
      expect(whole.status).toBe(200);
      expect(whole.headers.get("accept-ranges")).toBe("bytes");
      expect(new Uint8Array(await whole.arrayBuffer())).toEqual(t.bytes);

      const part = await handleGetMediaFile(play(path, "bytes=10-19"), t.env, fileId);
      expect(part.status).toBe(206);
      expect(part.headers.get("content-range")).toBe("bytes 10-19/100");
      expect([...new Uint8Array(await part.arrayBuffer())]).toEqual([10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);

      expect((await handleGetMediaFile(play(path, "bytes=500-"), t.env, fileId)).status).toBe(416);
      await expect(handleGetMediaFile(play(path.replace("thread=th", "thread=other")), t.env, fileId))
        .rejects.toMatchObject({ status: 403 });
      await expect(handleGetMediaFile(play(path), t.env, TEXT)).rejects.toMatchObject({ status: 403 });
      const expired = path.replace(/expires=\d+/, "expires=1000");
      await expect(handleGetMediaFile(play(expired), t.env, fileId)).rejects.toMatchObject({ status: 403 });

      await expect(handleCreateThreadMediaLink(new Request("https://x"), t.env, "th", TEXT))
        .rejects.toMatchObject({ status: 415 });
    } finally {
      await t.close();
    }
  });

  it("parses byte ranges", () => {
    expect(parseByteRange(null, 10)).toBeNull();
    expect(parseByteRange("bytes=0-", 10)).toEqual({ offset: 0, length: 10 });
    expect(parseByteRange("bytes=-3", 10)).toEqual({ offset: 7, length: 3 });
    expect(parseByteRange("bytes=8-50", 10)).toEqual({ offset: 8, length: 2 });
    expect(parseByteRange("bytes=5-2", 10)).toBe("invalid");
    expect(parseByteRange("items=0-1", 10)).toBe("invalid");
  });
});
