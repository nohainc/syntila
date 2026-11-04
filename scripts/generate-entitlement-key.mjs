// Generates the Ed25519 key pair for plugin entitlement leases (ADR-027).
//
//   node scripts/generate-entitlement-key.mjs [key-id]
//
// Prints three values. The private key is a Cloud secret and is never put in
// the repository or in a Workspace build; the public side is compiled into
// Workspace builds. The private key is shown once; store it in the secret
// manager immediately.
import {
  generateKeyPairSync,
  createPrivateKey,
  sign,
  verify,
} from "node:crypto";

const keyId = process.argv[2] ?? `ent-${new Date().toISOString().slice(0, 7)}`;
if (!/^[A-Za-z0-9._-]{1,64}$/.test(keyId)) {
  console.error("key id must be 1-64 of A-Z a-z 0-9 . _ -");
  process.exit(64);
}
const { privateKey, publicKey } = generateKeyPairSync("ed25519");
const privateBase64 = privateKey
  .export({ format: "der", type: "pkcs8" })
  .toString("base64");
const publicBase64 = publicKey
  .export({ format: "der", type: "spki" })
  .subarray(-32)
  .toString("base64");

// Prove the pair works with the same encodings Cloud and the Service use.
const probe = Buffer.from("entitlement-key-self-check");
const signature = sign(
  null,
  probe,
  createPrivateKey({
    key: Buffer.from(privateBase64, "base64"),
    format: "der",
    type: "pkcs8",
  }),
);
if (!verify(null, probe, publicKey, signature)) {
  console.error("self-check failed");
  process.exit(70);
}

console.log(`key id:      ${keyId}`);
console.log("");
console.log("Cloud secrets (wrangler secret put ...):");
console.log(`  SYNTILA_ENTITLEMENT_KEY_ID           ${keyId}`);
console.log(`  SYNTILA_ENTITLEMENT_SIGNING_KEY      ${privateBase64}`);
console.log("");
console.log("Workspace build define (public, safe to ship):");
console.log(
  `  --dart-define=SYNTILA_ENTITLEMENT_TRUST_KEYS_JSON='${JSON.stringify({
    entitlement: { [keyId]: publicBase64 },
  })}'`,
);
console.log("");
console.log(
  "To rotate: generate a new id, ship a Workspace build trusting BOTH",
);
console.log(
  "ids, switch the Cloud secrets, then drop the old id one release later.",
);
