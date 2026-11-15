// Local-only test harness. Production never loads Paddle or calls the backend.
(async () => {
  const status = document.querySelector('#status');
  const fail = (message) => { status.textContent = message; };
  if (!['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)) {
    fail('Sandbox checkout is available only on your local development server.');
    return;
  }
  try {
    const authOrigin = `${location.protocol}//${location.hostname}:8787`;
    const backendOrigin = `${location.protocol}//${location.hostname}:8788`;
    const sessionResponse = await fetch(`${authOrigin}/api/session`, { credentials: 'include' });
    if (!sessionResponse.ok) throw new Error('Sign in to Syntila before opening the sandbox checkout.');
    const session = await sessionResponse.json();
    if (!session.authenticated) throw new Error('Sign in to Syntila before opening the sandbox checkout.');
    const backendToken = async () => {
      const response = await fetch(`${authOrigin}/api/backend-token`, {
        method: 'POST', credentials: 'include', headers: { 'content-type': 'application/json' }, body: '{}',
      });
      if (!response.ok) throw new Error('Could not authenticate with the local backend.');
      const { token } = await response.json();
      return token;
    };
    const token = await backendToken();
    const configResponse = await fetch(`${backendOrigin}/api/billing/sandbox/checkout-config`, { headers: { authorization: `Bearer ${token}` } });
    if (!configResponse.ok) throw new Error('Sandbox checkout is not configured on the local backend.');
    const config = await configResponse.json();
    if (config.environment !== 'sandbox' || !config.clientToken?.startsWith('test_')) throw new Error('Invalid sandbox configuration.');
    const portalButton = document.querySelector('#portal');
    portalButton.disabled = false;
    portalButton.onclick = async () => {
      portalButton.disabled = true;
      try {
        const freshToken = await backendToken();
        const response = await fetch(`${backendOrigin}/api/billing/sandbox/portal`, {
          method: 'POST', headers: { authorization: `Bearer ${freshToken}` },
        });
        if (!response.ok) throw new Error('Could not open the sandbox portal. Check that a test subscription and portal API key are configured.');
        const { url } = await response.json();
        location.assign(url);
      } catch (error) {
        fail(error instanceof Error ? error.message : 'Could not open the sandbox portal.');
        portalButton.disabled = false;
      }
    };
    await new Promise((resolve, reject) => {
      const script = document.createElement('script');
      script.src = 'https://cdn.paddle.com/paddle/v2/paddle.js';
      script.onload = resolve;
      script.onerror = () => reject(new Error('Could not load Paddle Checkout.'));
      document.head.appendChild(script);
    });
    Paddle.Environment.set('sandbox');
    Paddle.Initialize({ token: config.clientToken, eventCallback(event) {
      if (event.name === 'checkout.completed') fail('Test checkout completed. Subscription access is updated when the verified notification arrives.');
    } });
    for (const [key, priceId] of [['monthly', config.monthlyPriceId], ['annual', config.annualPriceId]]) {
      const preview = await Paddle.PricePreview({ items: [{ priceId, quantity: 1 }] });
      const total = preview?.data?.details?.lineItems?.[0]?.formattedTotals?.total;
      if (typeof total !== 'string') throw new Error('Paddle could not provide a localized price.');
      document.querySelector(`#${key}-price`).textContent = total;
      const button = document.querySelector(`#${key}`);
      button.onclick = () => Paddle.Checkout.open({
        items: [{ priceId, quantity: 1 }],
        customData: { syntila_checkout_reference: config.checkoutReference },
        ...(session.user?.email ? { customer: { email: session.user.email } } : {}),
        settings: {
          displayMode: 'overlay',
          variant: 'one-page',
          theme: document.documentElement?.dataset.theme ||
            (typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'),
        },
      });
      button.disabled = false;
    }
    status.textContent = 'Prices are localized by Paddle. Select a billing period to start a test checkout.';
    const selectedPlan = new URLSearchParams(location.search).get('plan');
    if (selectedPlan === 'month' || selectedPlan === 'year') {
      document.querySelector(selectedPlan === 'month' ? '#monthly' : '#annual').onclick();
    }
  } catch (error) {
    fail(error instanceof Error ? error.message : 'Unable to start sandbox checkout.');
  }
})();
