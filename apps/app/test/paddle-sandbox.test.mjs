import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const script = await readFile(new URL('../web/paddle-sandbox.js', import.meta.url), 'utf8');

function harness(host = 'localhost') {
  const elements = Object.fromEntries(['status', 'monthly-price', 'annual-price', 'monthly', 'annual'].map((id) => [id, { textContent: '', disabled: true }]));
  const calls = [];
  const document = {
    querySelector: (selector) => elements[selector.slice(1)],
    createElement: () => ({}),
    head: { appendChild: (element) => element.onload() },
  };
  const Paddle = {
    Environment: { set: (mode) => calls.push(['environment', mode]) },
    Initialize: (options) => calls.push(['initialize', options.token]),
    PricePreview: async ({ items }) => ({ data: { details: { lineItems: [{ formattedTotals: { total: items[0].priceId === 'pri_month' ? '€9' : '€81' } }] } } }),
    Checkout: { open: (options) => calls.push(['checkout', options]) },
  };
  const fetch = async (url) => {
    calls.push(['fetch', url]);
    const body = url.endsWith('/session') ? { authenticated: true, user: { email: 'alice@example.test' } }
      : url.endsWith('/backend-token') ? { token: 'backend-token' }
      : { environment: 'sandbox', clientToken: 'test_token', monthlyPriceId: 'pri_month', annualPriceId: 'pri_year', checkoutReference: 'signed-reference' };
    return { ok: true, json: async () => body };
  };
  runInNewContext(script, { document, Paddle, fetch, location: { protocol: 'http:', hostname: host }, Promise, Error });
  return { elements, calls };
}

test('shows Paddle prices and opens the selected sandbox price for the signed-in user', async () => {
  const { elements, calls } = harness();
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(elements['monthly-price'].textContent, '€9');
  assert.equal(elements['annual-price'].textContent, '€81');
  assert.equal(elements.annual.disabled, false);
  elements.annual.onclick();
  const checkout = calls.find(([name]) => name === 'checkout')[1];
  assert.equal(checkout.items[0].priceId, 'pri_year');
  assert.equal(checkout.customData.syntila_checkout_reference, 'signed-reference');
  assert.equal(checkout.customer.email, 'alice@example.test');
  assert.equal(checkout.settings.displayMode, 'overlay');
  assert.equal(calls.find(([name]) => name === 'environment')[1], 'sandbox');
});

test('refuses to contact Paddle or auth from a non-local origin', async () => {
  const { elements, calls } = harness('app.syntila.app');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.match(elements.status.textContent, /only on your local/);
  assert.deepEqual(calls, []);
});
