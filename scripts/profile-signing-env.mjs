#!/usr/bin/env node
// Convert an existing raw Ed25519 seed only after checking its public trust root.
import { createPrivateKey, createPublicKey, timingSafeEqual } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

function fail(message) { console.error(message); process.exit(1); }
const args = process.argv.slice(2);
if (args.length !== 4 && args.length !== 5) fail("Usage: node scripts/profile-signing-env.mjs <seed.base64> <trust-roots.json> <key-id> --verify-only|--output <new-file>");
const [seedPath, rootsPath, keyId, mode, output] = args;
if (!/^[A-Za-z0-9._-]+$/.test(keyId) || !((mode === "--verify-only" && !output) || (mode === "--output" && output))) fail("Invalid key ID or output option.");
try {
  const encoded = readFileSync(seedPath, "utf8").trim();
  if (!/^[A-Za-z0-9+/]{43}=$/.test(encoded)) throw new Error("Seed must be a base64-encoded 32-byte Ed25519 seed.");
  const seed = Buffer.from(encoded, "base64");
  if (seed.length !== 32 || seed.toString("base64") !== encoded) throw new Error("Invalid Ed25519 seed encoding.");
  // PKCS#8 wrapper for a raw Ed25519 seed (RFC 8410).
  const key = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]), format: "der", type: "pkcs8" });
  const jwk = key.export({ format: "jwk" });
  const publicBytes = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x, "base64url");
  const roots = JSON.parse(readFileSync(rootsPath, "utf8"));
  const root = roots[keyId];
  if (typeof root !== "string" || !/^[A-Za-z0-9+/_-]{43}=?$/.test(root)) throw new Error("Trust root for the key ID is missing or invalid.");
  const expected = Buffer.from(root, "base64url");
  if (expected.length !== 32 || !timingSafeEqual(publicBytes, expected)) throw new Error("Seed does not match the specified public trust root.");
  if (mode === "--output") {
    const content = `SYNTILA_PROFILE_SIGNING_KEY_ID=${keyId}\nSYNTILA_PROFILE_SIGNING_JWK='${JSON.stringify(jwk)}'\n`;
    writeFileSync(output, content, { mode: 0o600, flag: "wx" });
    console.log("Trust root matches. Wrote a new owner-only environment file; private key was not printed.");
  } else console.log("Seed matches the specified public trust root; private key was not printed.");
} catch (error) { fail(`Profile signing setup failed: ${error.message}`); }
