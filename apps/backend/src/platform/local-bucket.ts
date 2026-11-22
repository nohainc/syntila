/**
 * Development-only R2Bucket stand-in that keeps objects in a local folder, so
 * file uploads (attachments, Worker output images, artifacts) work without R2
 * credentials. Keys are flat (like R2: `a/b` and `a/b/preview` can both
 * exist), so each object is one file named by its encoded key, with its
 * metadata beside it. Never used when R2 is configured.
 */
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { R2ObjectBodyLike, R2ObjectLike } from "./r2";

interface Meta {
  httpMetadata: R2ObjectLike["httpMetadata"];
  customMetadata: Record<string, string>;
  uploaded: string;
}

const META = ".meta.json";

export class LocalFolderBucket {
  private readonly root: string;
  constructor(root: string) {
    this.root = resolve(root);
  }

  private path(key: string): string {
    if (!key || key.split("/").some((part) => part === ".." || part === "."))
      throw new Error("Invalid object key");
    return join(this.root, encodeURIComponent(key));
  }

  private object(key: string, size: number, meta: Meta): R2ObjectLike {
    const http = meta.httpMetadata;
    const etag = `${size}-${Date.parse(meta.uploaded)}`;
    return {
      key, size, etag, httpEtag: `"${etag}"`, uploaded: new Date(meta.uploaded),
      httpMetadata: http, customMetadata: meta.customMetadata,
      writeHttpMetadata(h: Headers) {
        if (http.contentType) h.set("content-type", http.contentType);
        if (http.contentDisposition) h.set("content-disposition", http.contentDisposition);
        if (http.cacheControl) h.set("cache-control", http.cacheControl);
      },
    };
  }

  private async meta(key: string): Promise<Meta> {
    try {
      return JSON.parse(await readFile(this.path(key) + META, "utf8")) as Meta;
    } catch {
      return { httpMetadata: {}, customMetadata: {}, uploaded: new Date().toISOString() };
    }
  }

  async head(key: string): Promise<R2ObjectLike | null> {
    try {
      const info = await stat(this.path(key));
      if (!info.isFile()) return null;
      return this.object(key, info.size, await this.meta(key));
    } catch {
      return null;
    }
  }

  async get(key: string): Promise<R2ObjectBodyLike | null> {
    const head = await this.head(key);
    if (!head) return null;
    const bytes = await readFile(this.path(key));
    const response = new Response(bytes);
    return Object.assign(head, {
      body: response.body!, get bodyUsed() { return response.bodyUsed; },
      arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
      text: async () => bytes.toString("utf8"),
      json: async <T>() => JSON.parse(bytes.toString("utf8")) as T,
      blob: async () => new Blob([bytes]),
    });
  }

  async put(key: string, value: ReadableStream | ArrayBuffer | ArrayBufferView | string | Blob | null,
            options: { httpMetadata?: R2ObjectLike["httpMetadata"] | Headers; customMetadata?: Record<string, string> } = {}): Promise<R2ObjectLike> {
    const bytes = new Uint8Array(await new Response(value as BodyInit | null).arrayBuffer());
    const file = this.path(key);
    await mkdir(this.root, { recursive: true });
    await writeFile(file, bytes);
    const hm = options.httpMetadata instanceof Headers
      ? { contentType: options.httpMetadata.get("content-type") ?? undefined }
      : options.httpMetadata ?? {};
    const meta: Meta = { httpMetadata: hm, customMetadata: options.customMetadata ?? {}, uploaded: new Date().toISOString() };
    await writeFile(file + META, JSON.stringify(meta));
    return this.object(key, bytes.byteLength, meta);
  }

  async delete(keys: string | string[]): Promise<void> {
    for (const key of Array.isArray(keys) ? keys : [keys]) {
      await rm(this.path(key), { force: true });
      await rm(this.path(key) + META, { force: true });
    }
  }

  async list(options: { prefix?: string; limit?: number; cursor?: string; delimiter?: string } = {}) {
    let names: string[] = [];
    try { names = await readdir(this.root); } catch { names = []; }
    const keys = names.filter((n) => !n.endsWith(META)).map((n) => decodeURIComponent(n)).sort();
    const matching = keys.filter((k) => !options.prefix || k.startsWith(options.prefix));
    const start = options.cursor ? matching.findIndex((k) => k > options.cursor!) : 0;
    const from = start < 0 ? matching.length : start;
    const page = matching.slice(from, from + (options.limit ?? 1000));
    const objects = (await Promise.all(page.map((k) => this.head(k)))).filter((o): o is R2ObjectLike => !!o);
    const truncated = from + page.length < matching.length;
    return { objects, truncated, cursor: truncated ? page[page.length - 1] : undefined, delimitedPrefixes: [] as string[] };
  }
}
