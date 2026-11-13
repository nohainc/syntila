/**
 * R2Bucket-compatible facade over Bun.S3Client (R2's S3 API).
 * Implements the subset the domain uses: get, head, put, delete, list.
 */
import { S3Client } from "bun";

export interface R2Config { accountId: string; bucket: string; accessKeyId: string; secretAccessKey: string }

export interface R2ObjectLike {
  key: string; size: number; etag: string; httpEtag: string; uploaded: Date;
  httpMetadata: { contentType?: string; contentDisposition?: string; cacheControl?: string };
  customMetadata: Record<string, string>;
  writeHttpMetadata(headers: Headers): void;
}
export interface R2ObjectBodyLike extends R2ObjectLike {
  body: ReadableStream; bodyUsed: boolean;
  arrayBuffer(): Promise<ArrayBuffer>; text(): Promise<string>; json<T>(): Promise<T>; blob(): Promise<Blob>;
}

const META_PREFIX = "x-amz-meta-";

export class S3R2Bucket {
  private client: S3Client;
  constructor(private cfg: R2Config) {
    this.client = new S3Client({
      accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey, bucket: cfg.bucket,
      endpoint: `https://${cfg.accountId}.r2.cloudflarestorage.com`, region: "auto",
    });
  }

  private endpoint(key: string) {
    return `https://${this.cfg.accountId}.r2.cloudflarestorage.com/${this.cfg.bucket}/${key.split("/").map(encodeURIComponent).join("/")}`;
  }

  private meta(key: string, headers: Headers): R2ObjectLike {
    const custom: Record<string, string> = {};
    headers.forEach((v, k) => { if (k.startsWith(META_PREFIX)) custom[k.slice(META_PREFIX.length)] = v; });
    const http = {
      contentType: headers.get("content-type") ?? undefined,
      contentDisposition: headers.get("content-disposition") ?? undefined,
      cacheControl: headers.get("cache-control") ?? undefined,
    };
    const etag = (headers.get("etag") ?? "").replaceAll('"', "");
    return {
      key, size: Number(headers.get("content-length") ?? 0), etag, httpEtag: `"${etag}"`,
      uploaded: new Date(headers.get("last-modified") ?? Date.now()), httpMetadata: http, customMetadata: custom,
      writeHttpMetadata(h: Headers) {
        if (http.contentType) h.set("content-type", http.contentType);
        if (http.contentDisposition) h.set("content-disposition", http.contentDisposition);
        if (http.cacheControl) h.set("cache-control", http.cacheControl);
      },
    };
  }

  /** Signed request with Bun's presigner (keeps us on the built-in client, no SDK). */
  private async request(method: string, key: string, init: { body?: BodyInit | null; headers?: Record<string, string> } = {}) {
    const url = this.client.presign(key, { method: method as any, expiresIn: 300 });
    return fetch(url, { method, body: init.body ?? undefined, headers: init.headers });
  }

  async head(key: string): Promise<R2ObjectLike | null> {
    const res = await this.request("HEAD", key);
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`R2 head ${key} failed: ${res.status}`);
    return this.meta(key, res.headers);
  }

  async get(key: string): Promise<R2ObjectBodyLike | null> {
    const res = await this.request("GET", key);
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`R2 get ${key} failed: ${res.status}`);
    const meta = this.meta(key, res.headers);
    return Object.assign(meta, {
      body: res.body!, get bodyUsed() { return res.bodyUsed; },
      arrayBuffer: () => res.arrayBuffer(), text: () => res.text(), json: <T>() => res.json() as Promise<T>, blob: () => res.blob(),
    });
  }

  async put(key: string, value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob | null,
            options: { httpMetadata?: { contentType?: string; contentDisposition?: string; cacheControl?: string } | Headers; customMetadata?: Record<string, string> } = {}): Promise<R2ObjectLike> {
    const headers: Record<string, string> = {};
    const hm = options.httpMetadata instanceof Headers ? Object.fromEntries(options.httpMetadata) : options.httpMetadata ?? {};
    if (hm.contentType ?? (hm as any)["content-type"]) headers["content-type"] = (hm.contentType ?? (hm as any)["content-type"])!;
    if (hm.contentDisposition) headers["content-disposition"] = hm.contentDisposition;
    if (hm.cacheControl) headers["cache-control"] = hm.cacheControl;
    for (const [k, v] of Object.entries(options.customMetadata ?? {})) headers[META_PREFIX + k] = v;
    // Streams must be buffered: presigned PUT needs a known length.
    const body = value instanceof ReadableStream ? await new Response(value).arrayBuffer() : (value as BodyInit | null);
    const res = await this.request("PUT", key, { body, headers });
    if (!res.ok) throw new Error(`R2 put ${key} failed: ${res.status} ${await res.text()}`);
    return (await this.head(key))!;
  }

  async delete(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) {
      const res = await this.request("DELETE", key);
      if (!res.ok && res.status !== 404) throw new Error(`R2 delete ${key} failed: ${res.status}`);
    }
  }

  async list(options: { prefix?: string; limit?: number; cursor?: string; delimiter?: string } = {}) {
    const r: any = await this.client.list({ prefix: options.prefix, maxKeys: options.limit ?? 1000, continuationToken: options.cursor, delimiter: options.delimiter });
    const objects = (r.contents ?? []).map((o: any) => ({
      key: o.key, size: o.size ?? 0, etag: (o.eTag ?? "").replaceAll('"', ""), httpEtag: o.eTag ?? "", uploaded: new Date(o.lastModified ?? Date.now()),
      httpMetadata: {}, customMetadata: {}, writeHttpMetadata() {},
    }));
    return { objects, truncated: !!r.isTruncated, cursor: r.nextContinuationToken, delimitedPrefixes: (r.commonPrefixes ?? []).map((p: any) => p.prefix) };
  }
}

/** Fails loudly when object storage is used but not configured. */
export const unconfiguredBucket = new Proxy({}, {
  get: (_t, prop) => async () => { throw new Error(`R2 is not configured (bucket.${String(prop)})`); },
});
