import { expect, test } from "bun:test";
import { signToken, TokenVerifier } from "../src/auth";

test("rejects retired machine tokens even when correctly signed", async () => {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const pub = { ...(await crypto.subtle.exportKey("jwk", keys.publicKey)), kid: "key" };
  const priv = { ...(await crypto.subtle.exportKey("jwk", keys.privateKey)), kid: "key" };
  const now = Math.floor(Date.now() / 1000);
  const token = await signToken(priv, { iss: "issuer", aud: "backend", sub: "old", typ: "legacy", owner: "user", iat: now, exp: now + 60 });
  await expect(new TokenVerifier([pub], "issuer", "backend").verify(token)).rejects.toThrow("unknown token type");
});
