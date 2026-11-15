import { describe, expect, test } from 'bun:test';
import { signCheckoutReference, verifyCheckoutReference } from '../src/paddle-reference';

describe('Paddle checkout account association', () => {
  test('accepts an authenticated reference and rejects modification and other secrets', async () => {
    const reference = await signCheckoutReference('user-123', 'sandbox-secret');
    expect(await verifyCheckoutReference(reference, 'sandbox-secret')).toBe('user-123');
    expect(await verifyCheckoutReference(reference, 'other-secret')).toBeNull();
    const altered = `${Buffer.from(JSON.stringify({ version: 1, userId: 'another-user' })).toString('base64url')}.${reference.split('.')[1]}`;
    expect(await verifyCheckoutReference(altered, 'sandbox-secret')).toBeNull();
  });
  test('rejects missing, malformed and oversized references', async () => {
    expect(await verifyCheckoutReference('', 'secret')).toBeNull();
    expect(await verifyCheckoutReference('bad.payload', '')).toBeNull();
    expect(await verifyCheckoutReference(`${'a'.repeat(2048)}.x`, 'secret')).toBeNull();
  });
});
