/** A checkout reference is issued by Syntila, not trusted from the browser. */
export async function signCheckoutReference(userId: string, secret: string): Promise<string> {
  if (!userId || !secret) throw new Error('Checkout reference requires a user and secret');
  const payload = Buffer.from(JSON.stringify({ version: 1, userId })).toString('base64url');
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`syntila-paddle-checkout:${payload}`));
  return `${payload}.${Buffer.from(mac).toString('base64url')}`;
}

/** A Paddle webhook may contain browser-supplied custom data: authenticate it first. */
export async function verifyCheckoutReference(reference: string, secret: string): Promise<string | null> {
  if (!secret || reference.length > 2048 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(reference)) return null;
  const [payload, signature] = reference.split('.') as [string, string];
  try {
    const bytes = Buffer.from(signature, 'base64url');
    if (bytes.length !== 32 || bytes.toString('base64url') !== signature) return null;
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    if (!await crypto.subtle.verify('HMAC', key, bytes, new TextEncoder().encode(`syntila-paddle-checkout:${payload}`))) return null;
    const value: unknown = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (!value || typeof value !== 'object' || !('version' in value) || value.version !== 1 || !('userId' in value) || typeof value.userId !== 'string' || !value.userId || value.userId.length > 256) return null;
    return value.userId;
  } catch {
    return null;
  }
}
