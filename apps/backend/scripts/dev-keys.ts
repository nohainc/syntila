// Generates an Ed25519 signing key pair for development or for the Cloudflare
// auth Worker. Prints the public JWKS (backend) and the private JWK (issuer).
const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
const kid = `syntila-${new Date().toISOString().slice(0, 10)}-${crypto.randomUUID().slice(0, 8)}`;
const pub = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid, alg: "EdDSA", use: "sig" };
const priv = { ...(await crypto.subtle.exportKey("jwk", pair.privateKey)), kid, alg: "EdDSA" };
console.log("PUBLIC (backend auth-public-keys):\n" + JSON.stringify([pub]));
console.log("\nPRIVATE (issuer secret, never put on the VPS):\n" + JSON.stringify(priv));
