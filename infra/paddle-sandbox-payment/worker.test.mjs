import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import worker from './worker.mjs';

const request = (path, method = 'GET') => new Request(`https://sandbox.syntila.app${path}`, { method });
test('serves a clearly labeled sandbox page and Paddle initialization script', async () => {
  const response = await worker.fetch(request('/checkout/'), {});
  assert.equal(response.status, 200);
  assert.match(await response.text(), /cannot accept real payments/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  const script = await (await worker.fetch(request('/checkout.js'), {})).text();
  assert.match(script, /Paddle\.Environment\.set\('sandbox'\)/);
  assert.match(script, /_ptxn/);
});
test('exposes only a valid sandbox client token and rejects other requests', async () => {
  assert.equal((await worker.fetch(request('/config.json'), {})).status, 503);
  assert.equal((await worker.fetch(request('/config.json'), { PADDLE_SANDBOX_CLIENT_TOKEN: 'live_bad' })).status, 503);
  const config = await worker.fetch(request('/config.json'), { PADDLE_SANDBOX_CLIENT_TOKEN: 'test_example123' });
  assert.deepEqual(await config.json(), { clientToken: 'test_example123' });
  assert.equal((await worker.fetch(request('/anything'), {})).status, 404);
  assert.equal((await worker.fetch(request('/', 'POST'), {})).status, 405);
});
test('initializes Paddle only for a transaction payment link', async () => {
  const script = await (await worker.fetch(request('/checkout.js'), {})).text();
  const status = { textContent: '' };
  const calls = [];
  const Paddle = { Environment: { set: (mode) => calls.push(['environment', mode]) }, Initialize: (options) => calls.push(['initialize', options.token]) };
  const run = (search) => runInNewContext(script, { document: { getElementById: () => status }, location: { search }, URLSearchParams,
    window: { Paddle }, Paddle, fetch: async () => ({ ok: true, json: async () => ({ clientToken: 'test_example123' }) }), Error });
  run('');
  assert.match(status.textContent, /Open a sandbox payment link/);
  assert.equal(calls.length, 0);
  run('?_ptxn=txn_test');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, [['environment', 'sandbox'], ['initialize', 'test_example123']]);
});
