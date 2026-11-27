#!/usr/bin/env node
let input = '';
for await (const chunk of process.stdin) input += chunk;
try {
  const roots = JSON.parse(input);
  if (!roots || typeof roots !== 'object' || Array.isArray(roots) || Object.keys(roots).length < 1 || Object.keys(roots).length > 32) throw new Error();
  for (const [id, key] of Object.entries(roots)) {
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(id) || typeof key !== 'string' || !/^[A-Za-z0-9+/_-]{43}=?$/.test(key)) throw new Error();
    const decoded = Buffer.from(key, 'base64url');
    if (decoded.length !== 32 || decoded.toString('base64url') !== key.replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')) throw new Error();
  }
  process.stdout.write(JSON.stringify(roots));
} catch {
  console.error('Invalid SYNTILA_PROFILE_TRUST_ROOTS: expected a flat JSON map of key IDs to 32-byte Ed25519 public keys.');
  process.exit(1);
}
