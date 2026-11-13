#!/usr/bin/env node
// Generates the production Ed25519 key pair for backend access tokens.
// Run on your Mac from the repo root:  node apps/backend/scripts/generate-signing-key.mjs
//   private JWK -> .development/backend-signing-key.private.jwk  (gitignored; goes to the Cloudflare secret)
//   public JWKS -> infra/vps/auth-public-keys.json              (safe to commit; goes to the VPS)
// Rotation: generate a new pair, put BOTH public keys in the array, deploy the VPS,
// then switch the Cloudflare secret, and remove the old public key after 1 hour.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
const privPath = ".development/backend-signing-key.private.jwk";
const pubPath = "infra/vps/auth-public-keys.json";
if (existsSync(privPath) && !process.argv.includes("--rotate")) {
  console.error(`${privPath} already exists; pass --rotate to add a new key.`);
  process.exit(1);
}
const { publicKey, privateKey } = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const kid = `syntila-${new Date().toISOString().slice(0, 10)}-${crypto.randomUUID().slice(0, 8)}`;
const pub = { ...(await crypto.subtle.exportKey("jwk", publicKey)), kid, alg: "EdDSA", use: "sig" };
const priv = { ...(await crypto.subtle.exportKey("jwk", privateKey)), kid, alg: "EdDSA" };
mkdirSync(".development", { recursive: true });
writeFileSync(privPath, JSON.stringify(priv), { mode: 0o600 });
const existing = existsSync(pubPath) ? JSON.parse(readFileSync(pubPath, "utf8")) : [];
writeFileSync(pubPath, JSON.stringify([...existing, pub], null, 2) + "\n");
console.log(`kid ${kid}\nprivate: ${privPath}\npublic:  ${pubPath}`);
