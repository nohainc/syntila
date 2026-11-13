import { generateKeyPairSync, createPrivateKey, sign } from "node:crypto";

export function generateEd25519ReleaseKeyPair(): {
  privateKeyBase64: string;
  publicKeyBase64: string;
} {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const rawPublic = publicKey
    .export({ format: "der", type: "spki" })
    .subarray(-32);
  const rawPrivate = privateKey.export({ format: "der", type: "pkcs8" });
  return {
    privateKeyBase64: rawPrivate.toString("base64"),
    publicKeyBase64: rawPublic.toString("base64"),
  };
}

export function signEd25519ReleaseMessage(args: {
  privateKeyBase64OrPem: string;
  message: string;
}): string {
  let keyInput: string | Buffer = args.privateKeyBase64OrPem;
  if (!args.privateKeyBase64OrPem.includes("-----BEGIN")) {
    const raw = Buffer.from(args.privateKeyBase64OrPem, "base64");
    if (raw.length === 32) {
      const header = Buffer.from("302e020100300506032b657004220420", "hex");
      keyInput = Buffer.concat([header, raw]);
    } else {
      keyInput = raw;
    }
  }
  const privateKey = createPrivateKey({
    key: keyInput as unknown as string,
    format: Buffer.isBuffer(keyInput) ? "der" : "pem",
    type: "pkcs8",
  });
  return sign(null, Buffer.from(args.message), privateKey).toString("base64");
}

export async function verifyEd25519ReleaseSignature(args: {
  trustKeysJson?: string;
  publisher: string;
  signingKeyId: string;
  signature: string;
  message: string;
}): Promise<boolean> {
  if (!args.trustKeysJson) return false;
  try {
    const trust = JSON.parse(args.trustKeysJson) as Record<
      string,
      Record<string, string>
    >;
    const encoded = trust[args.publisher]?.[args.signingKeyId];
    if (!encoded) return false;
    const publicKey = Uint8Array.from(atob(encoded), (char) =>
      char.charCodeAt(0),
    );
    const signature = Uint8Array.from(atob(args.signature), (char) =>
      char.charCodeAt(0),
    );
    if (publicKey.length !== 32 || signature.length !== 64) return false;
    const key = await crypto.subtle.importKey(
      "raw",
      publicKey,
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return crypto.subtle.verify(
      { name: "Ed25519" },
      key,
      signature,
      new TextEncoder().encode(args.message),
    );
  } catch {
    return false;
  }
}
