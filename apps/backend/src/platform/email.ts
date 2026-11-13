/**
 * `SYNTILA_EMAIL` transport replacement: forwards structured messages to the
 * Cloudflare auth Worker's email relay (`POST /api/internal/email`), which
 * calls its own `send_email` binding. Authenticated with HMAC-SHA256 over the
 * body and a timestamp (5-minute window) to prevent replay.
 */
/** HMAC headers for a call to the auth Worker's /api/internal/* endpoints. */
export async function signedWorkerHeaders(secret: string, body: string): Promise<Record<string, string>> {
  const ts = Math.floor(Date.now() / 1000).toString();
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${ts}.${body}`))).toString("base64url");
  return { "content-type": "application/json", "x-syntila-timestamp": ts, "x-syntila-signature": sig };
}

/**
 * Keeps the auth Worker's account record in step with profile data the
 * backend owns (the avatar): `/api/session` on the Worker shows it.
 */
export class AuthWorkerSync {
  constructor(private origin: string, private secret: string) {}

  async avatarChanged(userId: string, avatarUrl: string | null): Promise<void> {
    const body = JSON.stringify({ userId, avatarUrl });
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const res = await fetch(`${this.origin}/api/internal/profile-avatar`, {
          method: "POST", headers: await signedWorkerHeaders(this.secret, body), body, signal: AbortSignal.timeout(10_000),
        });
        if (res.ok) return;
        if (res.status < 500) break;
      } catch {
        // retried below
      }
      await Bun.sleep(250 * 2 ** attempt);
    }
    console.warn(JSON.stringify({ level: "warn", message: "auth_worker.avatar_sync_failed", userId }));
  }
}

export class EmailRelay {
  constructor(private url: string, private secret: string) {}

  async send(message: unknown): Promise<{ messageId?: string }> {
    const body = JSON.stringify(message);
    const res = await fetch(this.url, {
      method: "POST",
      headers: await signedWorkerHeaders(this.secret, body),
      body,
      signal: AbortSignal.timeout(15_000),
    });
    const payload = (await res.json().catch(() => ({}))) as { messageId?: string; code?: string; error?: string };
    if (!res.ok) throw Object.assign(new Error(payload.error ?? `Email relay failed: ${res.status}`), { code: payload.code ?? "service_unavailable" });
    return { messageId: payload.messageId };
  }
}

type Sql = { unsafe(query: string, params?: unknown[]): Promise<any[]> };
type Transport = { send(message: unknown): Promise<{ messageId?: string }> };

/**
 * `SYNTILA_EMAIL` as used by the domain: `send` stores the message in
 * PostgreSQL (in the caller's request) and returns at once; a background loop
 * delivers it through the relay and retries with backoff until the relay
 * accepts it. The relay applies the fallback sender itself.
 */
export class EmailOutbox {
  private timer: ReturnType<typeof setInterval> | null = null;
  private running: Promise<void> | null = null;
  static readonly MAX_ATTEMPTS = 40; // backoff caps at 1 h → gives up after ~1.5 days

  constructor(private sql: Sql, private relay: Transport, private options: { pollMs?: number; batch?: number } = {}) {}

  async send(message: unknown): Promise<{ messageId?: string }> {
    const id = `email-${crypto.randomUUID()}`;
    await this.sql.unsafe("INSERT INTO email_outbox (id, message) VALUES ($1, $2::text::jsonb)", [id, JSON.stringify(message)]);
    queueMicrotask(() => this.poke());
    return { messageId: id };
  }

  start() {
    this.timer ??= setInterval(() => this.poke(), this.options.pollMs ?? 15_000);
    this.poke();
  }

  async stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    await this.running;
  }

  poke() {
    this.running ??= this.deliverDue()
      .catch((e) => console.error(JSON.stringify({ level: "error", message: "email.outbox_failed", error: String(e?.stack ?? e) })))
      .finally(() => { this.running = null; });
  }

  /** Delivers due messages; one row per transaction so a slow relay holds no locks. */
  async deliverDue(): Promise<number> {
    let delivered = 0;
    for (let i = 0; i < (this.options.batch ?? 50); i++) {
      // Claim by pushing the next attempt out; a crash mid-send retries later.
      const [row] = await this.sql.unsafe(`UPDATE email_outbox SET attempts = attempts + 1,
          next_attempt_at = now() + make_interval(secs => LEAST(3600, 30 * power(2, attempts)))
        WHERE id = (SELECT id FROM email_outbox WHERE status = 'pending' AND next_attempt_at <= now()
                    ORDER BY next_attempt_at LIMIT 1 FOR UPDATE SKIP LOCKED)
        RETURNING id, message, attempts`);
      if (!row) break;
      try {
        const result = await this.relay.send(row.message);
        await this.sql.unsafe("UPDATE email_outbox SET status = 'sent', sent_at = now(), relay_message_id = $2, last_error = NULL WHERE id = $1", [row.id, result.messageId ?? null]);
        delivered++;
      } catch (e) {
        const error = (e as Error)?.message ?? String(e);
        const permanent = (e as { code?: string })?.code === "invalid_recipient" || Number(row.attempts) >= EmailOutbox.MAX_ATTEMPTS;
        await this.sql.unsafe("UPDATE email_outbox SET last_error = $2, status = CASE WHEN $3 THEN 'failed' ELSE status END WHERE id = $1", [row.id, error.slice(0, 2000), permanent]);
        console.warn(JSON.stringify({ level: "warn", message: "email.delivery_retry", id: row.id, attempts: Number(row.attempts), permanent, error }));
      }
    }
    return delivered;
  }
}
