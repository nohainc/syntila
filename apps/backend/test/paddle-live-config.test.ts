import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { handleLiveCheckoutConfig } from '../src/domain/routes/paddle-live';
import { verifyCheckoutReference } from '../src/paddle-reference';
import { pgD1, dropTestDatabases } from './domain/helpers/pg-d1';
import { testTokens } from './domain/helpers/tokens';

const store = await pgD1();
const secret = 'a'.repeat(32);
let authenticated: Request;
beforeAll(async () => {
  const mint = await testTokens();
  authenticated = new Request('https://api.example.test/api/billing/live/checkout-config', { headers: { authorization: `Bearer ${await mint('user-123')}` } });
});
afterAll(dropTestDatabases);
const env = { SYNTILA_DB: store.db, SYNTILA_ENVIRONMENT: 'production', PADDLE_LIVE_CHECKOUT_ENABLED: 'true',
  PADDLE_LIVE_CLIENT_TOKEN: 'live_example', PADDLE_LIVE_MONTHLY_PRICE_ID: 'pri_month',
  PADDLE_LIVE_ANNUAL_PRICE_ID: 'pri_year', PADDLE_LIVE_REFERENCE_SECRET: secret,
} as any;
const request = new Request('https://api.example.test/api/billing/live/checkout-config');

describe('live checkout configuration', () => {
  test('returns a signed account reference without exposing its secret', async () => {
    const response = await handleLiveCheckoutConfig(authenticated, env);
    const body = await response.json() as any;
    expect(response.headers.get('cache-control')).toBe('no-store');
    expect(body.environment).toBe('live');
    expect(await verifyCheckoutReference(body.checkoutReference, secret)).toBe('user-123');
    expect(JSON.stringify(body)).not.toContain(secret);
  });
  test('requires a real authenticated identity in production', async () => {
    expect(handleLiveCheckoutConfig(request, env)).rejects.toMatchObject({ status: 401 });
  });
  test('fails closed when disabled, outside production, or misconfigured', async () => {
    expect(handleLiveCheckoutConfig(request, { ...env, PADDLE_LIVE_CHECKOUT_ENABLED: undefined })).rejects.toMatchObject({ status: 404 });
    expect(handleLiveCheckoutConfig(request, { ...env, SYNTILA_ENVIRONMENT: 'development' })).rejects.toMatchObject({ status: 404 });
    expect(handleLiveCheckoutConfig(request, { ...env, PADDLE_LIVE_CLIENT_TOKEN: 'test_example' })).rejects.toMatchObject({ status: 503 });
    expect(handleLiveCheckoutConfig(request, { ...env, PADDLE_LIVE_ANNUAL_PRICE_ID: 'pri_month' })).rejects.toMatchObject({ status: 503 });
  });
});
