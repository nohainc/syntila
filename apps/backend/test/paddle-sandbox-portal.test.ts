import { afterAll, expect, test } from 'bun:test';
import { pgD1, dropTestDatabases } from './domain/helpers/pg-d1';
import { handleSandboxPortal } from '../src/domain/routes/paddle-sandbox';

const store = pgD1();
store.sqlite.exec("INSERT INTO users(id,email,display_name,created_at,updated_at) VALUES('alice','a@example.test','Alice',now(),now()); INSERT INTO paddle_sandbox_subscriptions(subscription_id,user_id,customer_id,status,occurred_at) VALUES('sub_test','alice','ctm_owned','canceled',now())");
afterAll(dropTestDatabases);
const env = { SYNTILA_DB: store.db, SYNTILA_ENVIRONMENT: 'development', PADDLE_SANDBOX_API_KEY: 'pdl_sdbx_test', TEST_AUTHENTICATION: async () => ({ userId: 'alice' }) } as any;
const request = new Request('http://localhost/api/billing/sandbox/portal', { method: 'POST', body: JSON.stringify({ customerId: 'ctm_attacker' }) });

test('portal resolves customer server-side and only returns a sandbox URL', async () => {
  let target = '';
  const paddle: typeof fetch = async (url) => {
    target = String(url);
    return Response.json({ data: { urls: { general: { overview: 'https://sandbox-customer-portal.paddle.com/test?token=example' } } } });
  };
  const response = await handleSandboxPortal(request, env, undefined, paddle);
  expect(target).toBe('https://sandbox-api.paddle.com/customers/ctm_owned/portal-sessions');
  expect(response.headers.get('cache-control')).toBe('no-store');
  expect((await response.json() as any).url).toStartWith('https://sandbox-customer-portal.paddle.com/');
});

test('portal rejects production and untrusted redirect URLs', async () => {
  const bad: typeof fetch = async () => Response.json({ data: { urls: { general: { overview: 'https://evil.example/' } } } });
  expect(handleSandboxPortal(request, env, undefined, bad)).rejects.toMatchObject({ status: 502 });
  expect(handleSandboxPortal(request, { ...env, SYNTILA_ENVIRONMENT: 'production' }, undefined, bad)).rejects.toMatchObject({ status: 404 });
});
