/**
 * VPS identity boundary: humans authenticate at the Cloudflare auth Worker,
 * which issues short-lived signed backend tokens. This service only verifies
 * them (public keys) — it never sees passwords, cookies or session secrets.
 */
import { AuthError, bearer, type TokenVerifier } from "../../auth.js";

export interface AuthenticatedIdentity {
  readonly userId: string;
  readonly email: string;
  readonly name: string;
  readonly sessionId: string;
  readonly clientType?: "web" | "desktop";
  readonly audience?: string;
  readonly emailVerified?: boolean;
  readonly avatarUrl?: string;
}

let verifier: TokenVerifier | null = null;

/** Called once at startup with the configured public keys. */
export function configureIdentityVerifier(v: TokenVerifier | null): void {
  verifier = v;
}
export function identityVerifier(): TokenVerifier | null {
  return verifier;
}

/**
 * Browsers cannot set headers on a WebSocket upgrade: they exchange their
 * token for a single-use ticket (30 s) and pass it as `?ticket=` on
 * `/api/realtime`. Tickets live in memory (single node).
 */
const TICKET_TTL_MS = 30_000;
const tickets = new Map<string, { identity: AuthenticatedIdentity; expires: number }>();

export function issueRealtimeTicket(identity: AuthenticatedIdentity): string {
  const now = Date.now();
  if (tickets.size > 10_000) for (const [k, v] of tickets) if (v.expires < now) tickets.delete(k);
  const ticket = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64url");
  tickets.set(ticket, { identity, expires: now + TICKET_TTL_MS });
  return ticket;
}

const redeemed = new WeakMap<Request, AuthenticatedIdentity>();
function redeemTicket(request: Request): AuthenticatedIdentity | null {
  const known = redeemed.get(request);
  if (known) return known; // the same upgrade request is resolved again by the gateway
  const url = new URL(request.url);
  if (url.pathname !== "/api/realtime") return null;
  const ticket = url.searchParams.get("ticket");
  if (!ticket) return null;
  const entry = tickets.get(ticket);
  tickets.delete(ticket);
  if (!entry || entry.expires <= Date.now()) return null;
  redeemed.set(request, entry.identity);
  return entry.identity;
}

export class IdentityService {
  async resolve(request: Request, _env?: unknown): Promise<AuthenticatedIdentity | null> {
    const token = bearer(request);
    if (!token) {
      const fromTicket = redeemTicket(request);
      if (fromTicket) return fromTicket;
    }
    if (!token || !verifier) return null;
    try {
      const p = await verifier.verify(token);
      if (p.kind !== "user") return null;
      return {
        userId: p.userId, email: p.email, name: p.name, sessionId: p.sessionId ?? p.userId,
        clientType: p.clientType, audience: p.clientAudience, emailVerified: p.emailVerified, avatarUrl: p.avatarUrl,
      };
    } catch (e) {
      if (e instanceof AuthError) return null;
      throw e;
    }
  }
}

export const identityService = new IdentityService();
