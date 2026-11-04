import { strict as assert } from "node:assert";
import { generateKeyPairSync, verify, createPublicKey } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { signPlugin, canonicalPluginJson } from "./sign-plugin.mjs";

test("signs the canonical digest using the Service wire format", () => {
  const root = mkdtempSync(join(tmpdir(), "syntila-sign-"));
  try {
    const { privateKey } = generateKeyPairSync("ed25519");
    const keyFile = join(root, "private.pem");
    writeFileSync(
      keyFile,
      privateKey.export({ format: "pem", type: "pkcs8" }),
      { mode: 0o600 },
    );
    const manifest = {
      version: "1.0.0",
      pluginId: "test-plugin",
      schemaVersion: 1,
    };
    writeFileSync(join(root, "plugin.json"), JSON.stringify(manifest));
    const digest = signPlugin(root, keyFile, "author-1");
    const envelope = JSON.parse(readFileSync(join(root, "plugin.sig"), "utf8"));
    assert.equal(envelope.alg, "ed25519");
    assert.equal(envelope.keyId, "author-1");
    const raw = Buffer.from(envelope.publicKey, "base64");
    assert.equal(raw.length, 32);
    const publicKey = createPublicKey({
      key: { kty: "OKP", crv: "Ed25519", x: raw.toString("base64url") },
      format: "jwk",
    });
    const signature = Buffer.from(envelope.signature, "base64");
    assert.equal(verify(null, Buffer.from(digest), publicKey, signature), true);
    assert.equal(
      verify(null, Buffer.from("0".repeat(64)), publicKey, signature),
      false,
    );
    assert.throws(() => signPlugin(root, keyFile, "author-1"), {
      code: "EEXIST",
    });
    assert.throws(() => signPlugin(root, keyFile, "bad id"));
    assert.equal(
      canonicalPluginJson({ z: [1, { b: 2, a: 1 }], a: "é" }),
      '{"a":"é","z":[1,{"a":1,"b":2}]}',
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
