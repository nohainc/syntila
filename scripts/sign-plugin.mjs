// Offline author tool. The private key is read from a file, never an argument.
import {
  createHash,
  createPrivateKey,
  createPublicKey,
  sign,
} from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export function canonicalPluginJson(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalPluginJson).join(",")}]`;
  }
  if (value !== null && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalPluginJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export function signPlugin(directory, keyFile, keyId) {
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(keyId)) {
    throw new Error("key id must be 1-64 of A-Z a-z 0-9 . _ -");
  }
  const key = createPrivateKey(readFileSync(keyFile));
  if (key.asymmetricKeyType !== "ed25519") {
    throw new Error("private key must be Ed25519 PEM (PKCS#8)");
  }
  const manifest = JSON.parse(
    readFileSync(resolve(directory, "plugin.json"), "utf8"),
  );
  if (manifest?.schemaVersion !== 1 || typeof manifest.pluginId !== "string") {
    throw new Error("pack and validate plugin.json before signing");
  }
  const digest = createHash("sha256")
    .update(canonicalPluginJson(manifest), "utf8")
    .digest("hex");
  const publicKey = createPublicKey(key).export({ format: "jwk" });
  const envelope = {
    alg: "ed25519",
    keyId,
    publicKey: Buffer.from(publicKey.x, "base64url").toString("base64"),
    signature: sign(null, Buffer.from(digest, "utf8"), key).toString("base64"),
  };
  // Refuse to overwrite an existing signature: repacking requires explicit removal.
  writeFileSync(
    resolve(directory, "plugin.sig"),
    `${JSON.stringify(envelope, null, 2)}\n`,
    { flag: "wx" },
  );
  return digest;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  const args = process.argv.slice(2);
  if (args.length !== 3) {
    console.error(
      "usage: node scripts/sign-plugin.mjs <package-dir> <private-key.pem> <key-id>",
    );
    process.exitCode = 64;
  } else {
    try {
      console.log(`Signed manifest digest: ${signPlugin(...args)}`);
    } catch (error) {
      // Do not print crypto exception details or key material.
      console.error(
        `Signing failed (${error.code ?? "invalid input"}). Check the key, packed manifest and destination.`,
      );
      process.exitCode = 65;
    }
  }
}
