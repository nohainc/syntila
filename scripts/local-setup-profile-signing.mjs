// Development-only Profile signing identity. Preserve existing keys on every
// run: replacing one would invalidate cached Profiles and installed Agents.
import { generateKeyPairSync, createPrivateKey, createPublicKey } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const dir = join(root, ".development", "local-profile-signing");
const secret = join(dir, "private.jwk");
const publicFile = join(dir, "trust-roots.json");
const keyId = "local-profile-v1";
mkdirSync(dir, { recursive: true, mode: 0o700 });
if (!existsSync(secret)) {
  if (existsSync(publicFile)) throw new Error("Profile signing state is incomplete; preserve the trust roots and restore the private key.");
  const { privateKey } = generateKeyPairSync("ed25519");
  writeFileSync(secret, JSON.stringify(privateKey.export({ format: "jwk" })) + "\n", { mode: 0o600, flag: "wx" });
}
chmodSync(secret, 0o600);
const key = createPrivateKey({ key: JSON.parse(readFileSync(secret, "utf8")), format: "jwk" });
if (key.asymmetricKeyType !== "ed25519") throw new Error("Local Profile signing key is not Ed25519.");
const publicJwk = createPublicKey(key).export({ format: "jwk" });
const roots = JSON.stringify({ [keyId]: publicJwk.x });
if (existsSync(publicFile)) {
  const existing = JSON.parse(readFileSync(publicFile, "utf8"));
  if (existing[keyId] !== publicJwk.x) throw new Error("Local Profile signing key and trust roots do not match; preserve both and resolve the mismatch.");
} else {
  writeFileSync(publicFile, roots + "\n", { mode: 0o600, flag: "wx" });
}
console.log("Local Profile signing identity is ready; private key was not printed.");
