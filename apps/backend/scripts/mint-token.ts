// Dev/test helper: mint a token with a private JWK.
// bun scripts/mint-token.ts <private-jwk-file> user <id> <email> [name]
import { signToken } from "../src/auth";
const [file, typ, sub, extra, name] = Bun.argv.slice(2);
if (!file || typ !== "user" || !sub || !extra) { console.error("usage: see header"); process.exit(2); }
const jwk = JSON.parse(await Bun.file(file).text());
const now = Math.floor(Date.now() / 1000);
const claims: Record<string, unknown> = {
  iss: process.env.AUTH_JWT_ISSUER || "https://syntila.app",
  aud: process.env.AUTH_JWT_AUDIENCE || "syntila-backend",
  sub, typ, iat: now, exp: now + 3600,
};
Object.assign(claims, { email: extra, name: name ?? extra.split("@")[0] });
console.log(await signToken(jwk, claims));
