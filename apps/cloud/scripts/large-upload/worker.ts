// Evidence harness only (not deployed): runs the production streaming store
// in real workerd against a real R2 binding.
import { putStream } from "../../src/upload-stream.js";

interface HarnessEnv {
  BUCKET: R2Bucket;
}

export default {
  async fetch(request: Request, env: HarnessEnv): Promise<Response> {
    const url = new URL(request.url);
    const size = Number(request.headers.get("content-length"));
    const declared = Number(url.searchParams.get("declared") ?? size);
    if (!request.body) return new Response("no body", { status: 400 });
    if (url.searchParams.get("mode") === "buffer") {
      // The previous implementation, kept only as the memory baseline.
      const body = await request.arrayBuffer();
      const digest = await crypto.subtle.digest("SHA-256", body);
      await env.BUCKET.put("evidence/object", body);
      return Response.json({
        digest: `sha256:${[...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")}`,
        stored: body.byteLength,
      });
    }
    try {
      const { digest } = await putStream(
        env.BUCKET,
        "evidence/object",
        request.body,
        declared,
        {},
      );
      const head = await env.BUCKET.head("evidence/object");
      return Response.json({ digest, stored: head?.size ?? null });
    } catch (error) {
      await env.BUCKET.delete("evidence/object");
      return Response.json(
        { rejected: (error as { code?: string }).code ?? String(error) },
        { status: 400 },
      );
    }
  },
};
