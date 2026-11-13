/**
 * Verifies short-lived access tokens issued by the Cloudflare auth Worker.
 * The backend holds only public keys, so a VPS compromise cannot mint tokens.
 *
 * Token: compact JWS, alg EdDSA (Ed25519) or ES256, header.kid required.
 * Claims: iss, aud, sub, exp, iat, typ ("user" | "workspace" | "internal").
 *   user:      email, name, email_verified?, picture?
 *   workspace: owner (user id), name?
 */
export type Principal =
  | { kind: "user"; userId: string; email: string; name: string; emailVerified: boolean; avatarUrl?: string;
      /** Cloudflare session id (jti of the session, for audit), client kind and desktop audience. */
      sessionId?: string; clientType?: "web" | "desktop"; clientAudience?: string }
  | { kind: "workspace"; workspaceId: string; ownerUserId: string; name: string }
  /** Server-to-server call from the auth Worker (account lifecycle). */
  | { kind: "internal"; caller: string };

export class AuthError extends Error {}

const b64url = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(s.length / 4) * 4, "=")), (c) => c.charCodeAt(0));
const decoder = new TextDecoder();
const CLOCK_SKEW_S = 30;
const MAX_LIFETIME_S = 24 * 3600;

export class TokenVerifier {
  private keys = new Map<string, { key: CryptoKey; alg: string }>();
  private ready: Promise<void>;

  constructor(private jwks: JsonWebKey[], private issuer: string, private audience: string) {
    this.ready = this.importKeys();
  }

  private async importKeys() {
    for (const jwk of this.jwks as (JsonWebKey & { kid?: string })[]) {
      if (!jwk.kid) throw new Error("Auth public key is missing kid");
      if (jwk.d) throw new Error("Auth key set must not contain private keys");
      if (jwk.kty === "OKP" && jwk.crv === "Ed25519") {
        this.keys.set(jwk.kid, { alg: "EdDSA", key: await crypto.subtle.importKey("jwk", jwk, { name: "Ed25519" }, false, ["verify"]) });
      } else if (jwk.kty === "EC" && jwk.crv === "P-256") {
        this.keys.set(jwk.kid, { alg: "ES256", key: await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]) });
      } else throw new Error(`Unsupported auth key type for kid ${jwk.kid}`);
    }
  }

  get configured() { return this.jwks.length > 0; }

  async verify(token: string, now = Date.now() / 1000): Promise<Principal> {
    await this.ready;
    const parts = token.split(".");
    if (parts.length !== 3 || token.length > 8192) throw new AuthError("malformed token");
    let header: { alg?: string; kid?: string }, claims: Record<string, unknown>;
    try {
      header = JSON.parse(decoder.decode(b64url(parts[0])));
      claims = JSON.parse(decoder.decode(b64url(parts[1])));
    } catch { throw new AuthError("malformed token"); }
    const entry = header.kid ? this.keys.get(header.kid) : undefined;
    if (!entry || entry.alg !== header.alg) throw new AuthError("unknown signing key");
    const data = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    const signature = b64url(parts[2]);
    const ok = entry.alg === "EdDSA"
      ? await crypto.subtle.verify("Ed25519", entry.key, signature, data)
      : await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, entry.key, signature, data);
    if (!ok) throw new AuthError("bad signature");

    const exp = Number(claims.exp), iat = Number(claims.iat);
    if (claims.iss !== this.issuer) throw new AuthError("bad issuer");
    const aud = claims.aud;
    if (!(aud === this.audience || (Array.isArray(aud) && aud.includes(this.audience)))) throw new AuthError("bad audience");
    if (!Number.isFinite(exp) || exp + CLOCK_SKEW_S < now) throw new AuthError("expired");
    if (!Number.isFinite(iat) || iat - CLOCK_SKEW_S > now || exp - iat > MAX_LIFETIME_S) throw new AuthError("bad lifetime");
    const sub = typeof claims.sub === "string" ? claims.sub : "";
    if (!sub || sub.length > 128) throw new AuthError("bad subject");

    if (claims.typ === "user") {
      if (typeof claims.email !== "string" || !claims.email.includes("@")) throw new AuthError("missing email");
      return {
        kind: "user", userId: sub, email: claims.email,
        name: typeof claims.name === "string" && claims.name ? claims.name : claims.email.split("@")[0],
        emailVerified: claims.email_verified === true,
        avatarUrl: typeof claims.picture === "string" ? claims.picture : undefined,
        sessionId: typeof claims.sid === "string" ? claims.sid : undefined,
        clientType: claims.client === "desktop" ? "desktop" : "web",
        clientAudience: typeof claims.client_aud === "string" ? claims.client_aud : undefined,
      };
    }
    if (claims.typ === "workspace") {
      if (typeof claims.owner !== "string" || !claims.owner) throw new AuthError("missing owner");
      return { kind: "workspace", workspaceId: sub, ownerUserId: claims.owner, name: typeof claims.name === "string" ? claims.name : sub };
    }
    if (claims.typ === "internal") {
      // Internal calls are single requests: keep their tokens very short-lived.
      if (exp - iat > 300) throw new AuthError("internal token lifetime too long");
      return { kind: "internal", caller: sub };
    }
    throw new AuthError("unknown token type");
  }
}

export function bearer(request: Request): string | null {
  const h = request.headers.get("authorization");
  return h && /^Bearer\s+/i.test(h) ? h.replace(/^Bearer\s+/i, "").trim() : null;
}

/** Signs tokens with a private JWK. Used by tests and the dev token script only. */
export async function signToken(privateJwk: JsonWebKey & { kid: string }, claims: Record<string, unknown>): Promise<string> {
  const enc = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const ed = privateJwk.kty === "OKP";
  const key = await crypto.subtle.importKey("jwk", privateJwk, ed ? { name: "Ed25519" } : { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const input = `${enc({ alg: ed ? "EdDSA" : "ES256", typ: "JWT", kid: privateJwk.kid })}.${enc(claims)}`;
  const sig = await crypto.subtle.sign(ed ? "Ed25519" : { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(sig).toString("base64url")}`;
}
