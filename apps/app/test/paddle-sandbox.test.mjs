import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

const script = await readFile(new URL('../web/paddle-sandbox.js', import.meta.url), 'utf8');

function harness(host = 'localhost', search = '', theme = '') {
  const elements = Object.fromEntries(['status', 'monthly-price', 'annual-price', 'monthly', 'annual', 'portal'].map((id) => [id, { textContent: '', disabled: true }]));
  const calls = [];
  const document = {
    documentElement: { dataset: { theme } },
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
  const fetch = async (url, options) => {
    calls.push(['fetch', url, options]);
    const body = url.endsWith('/session') ? { authenticated: true, user: { email: 'alice@example.test' } }
      : url.endsWith('/backend-token') ? { token: 'backend-token' }
      : url.endsWith('/portal') ? { url: 'https://sandbox-customer-portal.paddle.com/test' }
      : { environment: 'sandbox', clientToken: 'test_token', monthlyPriceId: 'pri_month', annualPriceId: 'pri_year', checkoutReference: 'signed-reference' };
    return { ok: true, json: async () => body };
  };
  const location = { protocol: 'http:', hostname: host, search, assign: (url) => calls.push(['navigate', url]) };
  runInNewContext(script, { document, Paddle, fetch, location, Promise, Error, URLSearchParams });
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
  assert.equal(checkout.settings.theme, 'light');
  assert.equal(calls.find(([name]) => name === 'environment')[1], 'sandbox');
});

test('opens the checkout using the app theme', async () => {
  const { elements, calls } = harness('localhost', '', 'dark');
  await new Promise((resolve) => setTimeout(resolve, 0));
  elements.monthly.onclick();
  assert.equal(calls.find(([name]) => name === 'checkout')[1].settings.theme, 'dark');
});

test('opens a server-issued portal link using the authenticated backend session', async () => {
  const { elements, calls } = harness();
  await new Promise((resolve) => setTimeout(resolve, 0));
  await elements.portal.onclick();
  const portalRequest = calls.find(([name, url]) => name === 'fetch' && url.endsWith('/portal'));
  assert.equal(portalRequest[2].headers.authorization, 'Bearer backend-token');
  assert.equal(calls.find(([name]) => name === 'navigate')[1], 'https://sandbox-customer-portal.paddle.com/test');
});

test('opens the billing period selected on the plans page', async () => {
  const { calls } = harness('localhost', '?plan=year');
  await new Promise((resolve) => setTimeout(resolve, 0));
  const checkout = calls.find(([name]) => name === 'checkout')[1];
  assert.equal(checkout.items[0].priceId, 'pri_year');
});

test('refuses to contact Paddle or auth from a non-local origin', async () => {
  const { elements, calls } = harness('app.syntila.app');
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.match(elements.status.textContent, /only on your local/);
  assert.deepEqual(calls, []);
});
