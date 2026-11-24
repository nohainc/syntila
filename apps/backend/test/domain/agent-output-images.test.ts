import { describe, expect, it } from "./helpers/vitest-compat";
import { pgD1 } from "./helpers/pg-d1";
import { basicThread } from "./helpers/seed";
import { hashToken } from "@syntila/security";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { LocalFolderBucket } from "../../src/platform/local-bucket.js";
import { handleAgentUploadWorkerOutputImage } from "../../src/domain/routes/worker-output-images.js";

// A 1x1 PNG.
const png = Uint8Array.from(atob(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
), (c) => c.charCodeAt(0));

describe("Connect output images", () => {
  it("stores an image only for the calling Worker's open assignment", async () => {
    const f = await pgD1();
    const root = await mkdtemp(join(tmpdir(), "outputs-"));
    const bucket = new LocalFolderBucket(root);
    const env = { SYNTILA_DB: f.db, SYNTILA_ARTIFACTS: bucket } as never;
    await f.sqlite.exec(`${basicThread({ user: "alice", space: "sp", thread: "th" })}
      INSERT INTO worker_instances(id,actor_id,owner_user_id,worker_type_id,name) VALUES
        ('worker-mac','','alice','gemini','Mac'), ('worker-linux','','alice','gemini','Linux');
      INSERT INTO worker_assignments(id,space_id,thread_id,worker_type_id,worker_instance_id,worker_snapshot_json,status)
        VALUES ('asg-1','sp','th','gemini','worker-mac','{}','running');`);
    for (const [id, key] of [["worker-mac", "a"], ["worker-linux", "b"]] as const)
      await f.sqlite.exec(`INSERT INTO worker_credentials(id,worker_instance_id,public_key,key_fingerprint) VALUES ('c-${id}','${id}','${key.repeat(43)}','${key.repeat(64)}');
        INSERT INTO worker_agent_sessions(worker_instance_id,session_id,session_epoch,credential_id,token_digest,lease_expires_at)
        VALUES ('${id}','s-${id}',1,'c-${id}','${await hashToken("sess")}',now()+interval '5 minutes')`);
    const upload = (workerId: string) => new Request(
      "https://x/api/worker-agent/outputs?assignmentId=asg-1&name=lake.png",
      {
        method: "POST",
        body: png,
        headers: {
          authorization: "Bearer sess", "x-worker-id": workerId, "x-worker-session-id": `s-${workerId}`,
          "content-type": "image/png", "content-length": String(png.length),
        },
      },
    );
    try {
      const ok = await handleAgentUploadWorkerOutputImage(upload("worker-mac"), env);
      expect(ok.status).toBe(201);
      const { image } = await ok.json() as { image: Record<string, unknown> };
      expect(image).toMatchObject({ kind: "file", name: "lake.png", mediaType: "image/png", sizeBytes: png.length });
      expect((await bucket.head(`work-request-inputs/${image.fileId}`))?.size).toBe(png.length);
      // Any file type: a text file comes back with its preview text.
      const text = new TextEncoder().encode("hello from the Worker");
      const note = await handleAgentUploadWorkerOutputImage(new Request(
        "https://x/api/worker-agent/outputs?assignmentId=asg-1&name=hello.txt",
        { method: "POST", body: text, headers: {
          authorization: "Bearer sess", "x-worker-id": "worker-mac", "x-worker-session-id": "s-worker-mac",
          "content-type": "text/plain", "content-length": String(text.length) } },
      ), env);
      expect(((await note.json()) as { image: unknown }).image).toMatchObject({
        name: "hello.txt", mediaType: "text/plain", previewText: "hello from the Worker" });
      await expect(handleAgentUploadWorkerOutputImage(upload("worker-linux"), env)).rejects.toMatchObject({ status: 404 });
      await f.sqlite.exec("UPDATE worker_assignments SET status = 'completed'");
      await expect(handleAgentUploadWorkerOutputImage(upload("worker-mac"), env)).rejects.toMatchObject({ status: 409 });
    } finally {
      await f.sqlite.close();
      await rm(root, { recursive: true, force: true });
    }
  });
});
