import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import worker from './worker.mjs';

const request = (path, method = 'GET') => new Request(`https://payments.syntila.app${path}`, { method });
test('serves a live payment page and Paddle initialization script', async () => {
  const response = await worker.fetch(request('/checkout/'), {});
  assert.equal(response.status, 200);
  assert.match(await response.text(), /Complete your payment securely/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
  const script = await (await worker.fetch(request('/checkout/checkout.js'), {})).text();
  assert.doesNotMatch(script, /Paddle\.Environment\.set/);
  assert.match(script, /_ptxn/);
});
test('exposes only a valid live client token and rejects other requests', async () => {
  assert.equal((await worker.fetch(request('/checkout/config.json'), {})).status, 503);
  assert.equal((await worker.fetch(request('/checkout/config.json'), { PADDLE_LIVE_CLIENT_TOKEN: 'test_bad' })).status, 503);
  const config = await worker.fetch(request('/checkout/config.json'), { PADDLE_LIVE_CLIENT_TOKEN: 'live_example123' });
  assert.deepEqual(await config.json(), { clientToken: 'live_example123' });
  assert.equal((await worker.fetch(request('/anything'), {})).status, 404);
  assert.equal((await worker.fetch(request('/', 'POST'), {})).status, 405);
});
test('initializes Paddle only for a transaction payment link', async () => {
  const script = await (await worker.fetch(request('/checkout/checkout.js'), {})).text();
  const status = { textContent: '' };
  const calls = [];
  const Paddle = { Environment: { set: (mode) => calls.push(['environment', mode]) }, Initialize: (options) => calls.push(['initialize', options.token]) };
  const run = (search) => runInNewContext(script, { document: { getElementById: () => status }, location: { search }, URLSearchParams,
    window: { Paddle }, Paddle, fetch: async () => ({ ok: true, json: async () => ({ clientToken: 'live_example123' }) }), Error });
  run('');
  assert.match(status.textContent, /Open a payment link/);
  assert.equal(calls.length, 0);
  run('?_ptxn=txn_test');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(calls, [['initialize', 'live_example123']]);
});
