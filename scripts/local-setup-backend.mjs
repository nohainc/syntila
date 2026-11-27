// Local-only wiring between the auth Worker (wrangler dev, :8787) and the
// backend (Bun, :8788): an Ed25519 key pair for backend tokens and a shared
// email-relay secret. Idempotent; secrets are never printed.
//   apps/cloud/.dev.vars                    SYNTILA_BACKEND_SIGNING_KEY, EMAIL_RELAY_SECRET
//   .development/local-backend/auth-public-keys.json
//   .development/local-backend/relay-secret
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEnv } from "node:util";

function appendVar(file, name, value, comment) {
  const previous = existsSync(file) ? readFileSync(file, "utf8") : "";
  if (Object.hasOwn(parseEnv(previous), name)) return false;
  writeFileSync(file, `${previous}${previous && !previous.endsWith("\n") ? "\n" : ""}\n# ${comment}\n${name}=${value}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
  return true;
}

export function setupLocalBackend(root) {
  const devVars = join(root, "apps/cloud/.dev.vars");
  const dir = join(root, ".development/local-backend");
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  mkdirSync(dirname(devVars), { recursive: true });
  const publicKeys = join(dir, "auth-public-keys.json");
  const relaySecret = join(dir, "relay-secret");
  const vars = existsSync(devVars) ? parseEnv(readFileSync(devVars, "utf8")) : {};

  let generatedKey = false;
  if (!Object.hasOwn(vars, "SYNTILA_BACKEND_SIGNING_KEY") || !existsSync(publicKeys)) {
    const kid = `local-${new Date().toISOString().slice(0, 10)}-${randomBytes(4).toString("hex")}`;
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    const pub = { ...publicKey.export({ format: "jwk" }), kid, alg: "EdDSA", use: "sig" };
    const priv = { ...privateKey.export({ format: "jwk" }), kid, alg: "EdDSA" };
    if (Object.hasOwn(vars, "SYNTILA_BACKEND_SIGNING_KEY")) {
      // Replace a stale private key whose public half is gone.
      const text = readFileSync(devVars, "utf8").replace(/^SYNTILA_BACKEND_SIGNING_KEY=.*$/m, `SYNTILA_BACKEND_SIGNING_KEY=${JSON.stringify(priv)}`);
      writeFileSync(devVars, text, { mode: 0o600 });
    } else {
      appendVar(devVars, "SYNTILA_BACKEND_SIGNING_KEY", JSON.stringify(priv), "Local backend token signing key; never deploy.");
    }
    writeFileSync(publicKeys, JSON.stringify([pub]) + "\n", { mode: 0o600 });
    generatedKey = true;
  }

  let secret = existsSync(relaySecret) ? readFileSync(relaySecret, "utf8").trim() : "";
  if (!secret) {
    secret = randomBytes(32).toString("base64url");
    writeFileSync(relaySecret, secret, { mode: 0o600 });
  }
  if (!appendVar(devVars, "EMAIL_RELAY_SECRET", secret, "Local email relay secret shared with the backend.")) {
    const text = readFileSync(devVars, "utf8").replace(/^EMAIL_RELAY_SECRET=.*$/m, `EMAIL_RELAY_SECRET=${secret}`);
    writeFileSync(devVars, text, { mode: 0o600 });
  }
  return { generatedKey, publicKeys, relaySecret };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = setupLocalBackend(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
  console.log(`Local backend auth ${result.generatedKey ? "generated" : "preserved"} (secrets not printed).`);
}
