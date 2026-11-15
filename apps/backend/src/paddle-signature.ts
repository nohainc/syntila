/** Verify Paddle's signature over the exact, unmodified webhook body. */
export async function verifyPaddleSignature(
  body: string,
  header: string | null,
  secret: string,
  now = Date.now(),
): Promise<boolean> {
  if (!header || !secret) return false;
  const parts = header.split(';').map((part) => part.trim().split('='));
  const timestamps = parts.filter(([key]) => key === 'ts').map(([, value]) => value);
  const signatures = parts.filter(([key]) => key === 'h1').map(([, value]) => value);
  if (timestamps.length !== 1 || !/^\d+$/.test(timestamps[0] ?? '')) return false;
  const timestamp = Number(timestamps[0]);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now / 1000 - timestamp) > 5) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const message = new TextEncoder().encode(`${timestamps[0]}:${body}`);
  for (const signature of signatures) {
    if (!signature || !/^[0-9a-f]{64}$/i.test(signature)) continue;
    const bytes = Uint8Array.from(signature.match(/../g)!, (byte) => parseInt(byte, 16));
    if (await crypto.subtle.verify('HMAC', key, bytes, message)) return true;
  }
  return false;
}
