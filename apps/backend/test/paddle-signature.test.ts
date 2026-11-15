import { describe, expect, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { verifyPaddleSignature } from '../src/paddle-signature';

describe('Paddle webhook authentication', () => {
  const secret = 'test-secret';
  const now = 1_700_000_000_000;
  const body = '{"event_id":"evt_test"}';
  const timestamp = now / 1000;
  const signature = createHmac('sha256', secret).update(`${timestamp}:${body}`).digest('hex');
  const header = `ts=${timestamp};h1=${signature}`;

  test('accepts a valid signature, including during key rotation', async () => {
    expect(await verifyPaddleSignature(body, header, secret, now)).toBe(true);
    expect(await verifyPaddleSignature(body, `ts=${timestamp};h1=${'0'.repeat(64)};h1=${signature}`, secret, now)).toBe(true);
  });
  test('rejects changed bodies, secrets, stale timestamps and malformed headers', async () => {
    expect(await verifyPaddleSignature(body + ' ', header, secret, now)).toBe(false);
    expect(await verifyPaddleSignature(body, header, 'wrong', now)).toBe(false);
    expect(await verifyPaddleSignature(body, header, secret, now + 6000)).toBe(false);
    expect(await verifyPaddleSignature(body, `ts=${timestamp};ts=${timestamp};h1=${signature}`, secret, now)).toBe(false);
    expect(await verifyPaddleSignature(body, null, secret, now)).toBe(false);
  });
});
