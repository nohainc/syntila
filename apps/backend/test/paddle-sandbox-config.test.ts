import { describe, expect, test } from 'bun:test';
import { handleSandboxCheckoutConfig } from '../src/domain/routes/paddle-sandbox';
import { verifyCheckoutReference } from '../src/paddle-reference';

const secret = 'a'.repeat(32);
const env = {
  SYNTILA_ENVIRONMENT: 'development',
  PADDLE_SANDBOX_CLIENT_TOKEN: 'test_example',
  PADDLE_SANDBOX_MONTHLY_PRICE_ID: 'pri_month',
  PADDLE_SANDBOX_ANNUAL_PRICE_ID: 'pri_year',
  PADDLE_SANDBOX_REFERENCE_SECRET: secret,
  TEST_AUTHENTICATION: async () => ({ userId: 'user-123' }),
} as any;
const request = new Request('http://localhost/api/billing/sandbox/checkout-config');

describe('sandbox checkout configuration', () => {
  test('returns the signed-in account reference without exposing the secret', async () => {
    const response = await handleSandboxCheckoutConfig(request, env);
    const body = await response.json() as any;
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(body.environment).toBe('sandbox');
    expect(await verifyCheckoutReference(body.checkoutReference, secret)).toBe('user-123');
    expect(JSON.stringify(body)).not.toContain(secret);
  });
  test('fails closed outside development or with incomplete sandbox configuration', async () => {
    expect(handleSandboxCheckoutConfig(request, { ...env, SYNTILA_ENVIRONMENT: 'production' })).rejects.toMatchObject({ status: 404 });
    expect(handleSandboxCheckoutConfig(request, { ...env, PADDLE_SANDBOX_CLIENT_TOKEN: 'live_bad' })).rejects.toMatchObject({ status: 503 });
  });
});
