import type { Query } from "../../platform/data.js";
import { HttpError } from "./http-security.js";

/** Authenticated, endpoint-scoped receipt committed atomically with domain writes. */
export class MutationIdempotency {
  private constructor(
    readonly q: Query,
    readonly userId: string,
    readonly scope: string,
    readonly key: string,
    readonly hash: string,
  ) {}

  static async from(
    request: Request,
    q: Query,
    userId: string,
    scope: string,
    body: unknown,
  ): Promise<MutationIdempotency | null> {
    const key = request.headers.get("Idempotency-Key");
    if (key === null) return null;
    if (!/^[A-Za-z0-9_-]{16,128}$/.test(key)) {
      throw new HttpError(400, "Invalid Idempotency-Key");
    }
    const canonical = (value: unknown): unknown => {
      if (Array.isArray(value)) return value.map(canonical);
      if (value !== null && typeof value === "object") {
        return Object.fromEntries(
          Object.entries(value)
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([key, item]) => [key, canonical(item)]),
        );
      }
      return value;
    };
    const digest = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(JSON.stringify(canonical(body))),
    );
    const hash = Array.from(new Uint8Array(digest), (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
    return new MutationIdempotency(db, userId, scope, key, hash);
  }

  async replay(): Promise<Response | null> {
    const row = await this.q.row<{ hash: string; body: string; status: number }>`
      SELECT request_hash AS hash, response_json AS body,
      response_status AS status FROM mutation_receipts
      WHERE user_id = ${this.userId} AND scope = ${this.scope} AND idempotency_key = ${this.key}
    `;
    if (!row) return null;
    if (row.hash !== this.hash)
      throw new HttpError(
        409,
        "Idempotency key was already used for different input",
      );
    return new Response(row.body, {
      status: row.status,
      headers: {
        "content-type": "application/json",
        "Idempotency-Replayed": "true",
      },
    });
  }

  async record(
    tx: { run: (strings: TemplateStringsArray, ...values: unknown[]) => Promise<unknown> },
    body: unknown,
    status: number,
  ): Promise<void> {
    await tx.run`INSERT INTO mutation_receipts
      (user_id, scope, idempotency_key, request_hash, response_json, response_status, created_at)
      VALUES (${this.userId}, ${this.scope}, ${this.key}, ${this.hash}, ${JSON.stringify(body)}, ${status}, ${new Date().toISOString()})`;
  }

  async replayOnConflict(_error: unknown): Promise<Response | null> {
    return this.replay();
  }
}
