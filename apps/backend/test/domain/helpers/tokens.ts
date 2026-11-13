// Test identity tokens: configures the backend verifier with a fresh key and
// mints the JWTs the auth Worker would issue.
import { signToken, TokenVerifier } from "../../../src/auth";
import { configureIdentityVerifier } from "../../../src/domain/auth/identity-service";

export async function testTokens() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid: "k" } as JsonWebKey & { kid: string };
  configureIdentityVerifier(new TokenVerifier([pub], "https://syntila.app", "syntila-backend"));
  return (sub: string, extra: Record<string, unknown> = {}) => {
    const now = Math.floor(Date.now() / 1000);
    return signToken(priv, { iss: "https://syntila.app", aud: "syntila-backend", sub, typ: "user", email: `${sub}@test`, name: sub, iat: now, exp: now + 600, sid: `s-${sub}`, client: "web", ...extra });
  };
}
