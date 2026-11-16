// @ts-check
// An isolated Paddle payment-link page for the live account only.
// Paddle client-side tokens are public; server API and webhook keys never belong here.
const headers = {
  'cache-control': 'no-store',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
  'x-robots-tag': 'noindex, nofollow, noarchive',
  'content-security-policy': "base-uri 'none'; object-src 'none'; frame-ancestors 'none'",
};

const page = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>Syntila payment</title>
<link rel="stylesheet" href="/checkout/style.css"><script defer src="https://cdn.paddle.com/paddle/v2/paddle.js"></script><script defer src="/checkout/checkout.js"></script></head>
<body><main><p class="eyebrow">SYNTILA</p><h1>Complete your payment</h1>
<p>Complete your payment securely with Paddle.</p>
<p id="status" role="status" aria-live="polite">Loading checkout…</p>
<a href="https://syntila.app/">Visit Syntila</a></main></body></html>`;

const style = `:root{color-scheme:dark;font-family:system-ui,sans-serif;background:#11121e;color:#f2f2f8}body{margin:0;padding:2rem}main{max-width:34rem;margin:12vh auto;padding:2rem;border:1px solid #3c3d55;border-radius:1rem;background:#1b1c2d}h1{font-size:2rem;margin:.5rem 0 1rem}p{line-height:1.6;color:#d3d3e1}.eyebrow{font-size:.75rem;letter-spacing:.12em;color:#b7b5ff;font-weight:700}a{color:#c4c2ff}`;

const javascript = `(() => {
  const status = document.getElementById('status');
  if (!new URLSearchParams(location.search).has('_ptxn')) {
    status.textContent = 'Open a payment link from Paddle to continue.';
    return;
  }
  fetch('/checkout/config.json', {cache: 'no-store'}).then((response) => {
    if (!response.ok) throw new Error('Checkout is unavailable.');
    return response.json();
  }).then(({clientToken}) => {
    if (!window.Paddle || !/^live_[a-zA-Z0-9]+$/.test(clientToken)) throw new Error('Checkout is unavailable.');
    Paddle.Initialize({token: clientToken, eventCallback(event) {
      if (event.name === 'checkout.completed') status.textContent = 'Checkout completed. You may close this page.';
      if (event.name === 'checkout.error') status.textContent = 'The checkout could not be opened. Please try your payment link again.';
    }});
    status.textContent = 'Opening Paddle checkout…';
  }).catch(() => { status.textContent = 'The checkout is unavailable. Please try again later.'; });
})();`;

export default {
  /** @param {Request} request @param {Env} env */
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== 'GET' && request.method !== 'HEAD') return new Response('Method not allowed', { status: 405, headers: { ...headers, allow: 'GET, HEAD' } });
    let content;
    let type;
    if (url.pathname === '/checkout/') { content = page; type = 'text/html; charset=utf-8'; }
    else if (url.pathname === '/checkout/style.css') { content = style; type = 'text/css; charset=utf-8'; }
    else if (url.pathname === '/checkout/checkout.js') { content = javascript; type = 'text/javascript; charset=utf-8'; }
    else if (url.pathname === '/checkout/config.json') {
      if (!/^live_[a-zA-Z0-9]+$/.test(env.PADDLE_LIVE_CLIENT_TOKEN ?? '')) return new Response('Checkout is not configured', { status: 503, headers });
      content = JSON.stringify({ clientToken: env.PADDLE_LIVE_CLIENT_TOKEN });
      type = 'application/json; charset=utf-8';
    } else return new Response('Not found', { status: 404, headers });
    return new Response(request.method === 'HEAD' ? null : content, { headers: { ...headers, 'content-type': type } });
  },
};
