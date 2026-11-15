import { afterAll, describe, expect, test } from 'bun:test';
import { createHmac } from 'node:crypto';
import { pgD1, dropTestDatabases } from './domain/helpers/pg-d1';
import { signCheckoutReference } from '../src/paddle-reference';
import { handleSandboxWebhook } from '../src/domain/routes/paddle-sandbox';

const store = pgD1();
const referenceSecret = 'r'.repeat(32);
const webhookSecret = 'webhook-secret';
const env = { SYNTILA_DB: store.db, SYNTILA_ENVIRONMENT: 'development', PADDLE_SANDBOX_REFERENCE_SECRET: referenceSecret,
  PADDLE_SANDBOX_WEBHOOK_SECRET: webhookSecret, PADDLE_SANDBOX_MONTHLY_PRICE_ID: 'pri_month', PADDLE_SANDBOX_ANNUAL_PRICE_ID: 'pri_year' } as any;
store.sqlite.exec("INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('alice','alice@example.test','Alice',now(),now()),('manual','manual@example.test','Manual',now(),now()); INSERT INTO account_plans(user_id,tier,status,source,created_at,updated_at) VALUES('manual','paid','active','manual',now(),now())");
afterAll(dropTestDatabases);

async function event(status: string, occurred: string, signatureSecret = webhookSecret, user = 'alice', price = 'pri_month') {
  const reference = await signCheckoutReference(user, referenceSecret);
  const raw = JSON.stringify({ event_type: 'subscription.updated', occurred_at: occurred, data: { id: `sub_${user}`, customer_id: 'ctm_test', status,
    custom_data: { syntila_checkout_reference: reference }, items: [{ price: { id: price } }],
    current_billing_period: status === 'canceled' ? null : { ends_at: '2999-01-01T00:00:00Z' } } });
  const ts = Math.floor(Date.now()/1000);
  const sig = createHmac('sha256', signatureSecret).update(`${ts}:${raw}`).digest('hex');
  return new Request('http://localhost/api/billing/sandbox/webhook', { method: 'POST', headers: { 'paddle-signature': `ts=${ts};h1=${sig}` }, body: raw });
}

describe('sandbox subscription notifications', () => {
  test('authenticates, provisions, ignores stale and duplicate events, and cancels', async () => {
    expect(handleSandboxWebhook(await event('active', '2026-01-01T00:00:00Z', 'wrong'), env)).rejects.toMatchObject({ status: 401 });
    const active = await event('active', '2026-01-01T00:00:00Z');
    expect((await handleSandboxWebhook(active.clone(), env)).status).toBe(200);
    expect((await handleSandboxWebhook(active.clone(), env)).status).toBe(200);
    expect(store.sqlite.prepare("SELECT status FROM account_plans WHERE user_id='alice'").get()).toEqual({ status: 'active' });
    await handleSandboxWebhook(await event('canceled', '2026-02-01T00:00:00Z'), env);
    await handleSandboxWebhook(await event('active', '2026-01-01T00:00:00Z'), env);
    expect(store.sqlite.prepare("SELECT status FROM account_plans WHERE user_id='alice'").get()).toEqual({ status: 'canceled' });
    expect(handleSandboxWebhook(await event('active', '2026-03-01T00:00:00Z'), { ...env, SYNTILA_ENVIRONMENT: 'production' })).rejects.toMatchObject({ status: 404 });
  });
  test('preserves manual grants and rejects unrecognized prices', async () => {
    await handleSandboxWebhook(await event('canceled', '2026-02-01T00:00:00Z', webhookSecret, 'manual'), env);
    expect(store.sqlite.prepare("SELECT status,source FROM account_plans WHERE user_id='manual'").get()).toEqual({ status: 'active', source: 'manual' });
    expect(handleSandboxWebhook(await event('active', '2026-03-01T00:00:00Z', webhookSecret, 'alice', 'pri_unknown'), env)).rejects.toMatchObject({ status: 400 });
  });
});
