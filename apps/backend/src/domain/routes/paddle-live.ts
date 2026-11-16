import { signCheckoutReference } from '../../paddle-reference.js';
import { HttpError, json, securityContext, type SecurityEnv } from './http-security.js';

type LiveEnv = SecurityEnv & {
  PADDLE_LIVE_CHECKOUT_ENABLED?: string;
  PADDLE_LIVE_CLIENT_TOKEN?: string;
  PADDLE_LIVE_MONTHLY_PRICE_ID?: string;
  PADDLE_LIVE_ANNUAL_PRICE_ID?: string;
  PADDLE_LIVE_REFERENCE_SECRET?: string;
};

/** Disabled by default until live fulfillment and rollout are ready. */
export async function handleLiveCheckoutConfig(request: Request, env: LiveEnv, ctx?: ExecutionContext): Promise<Response> {
  if (env.SYNTILA_ENVIRONMENT !== 'production' || env.PADDLE_LIVE_CHECKOUT_ENABLED !== 'true')
    throw new HttpError(404, 'Not found');
  if (request.method !== 'GET') throw new HttpError(405, 'Unsupported method');
  const token = env.PADDLE_LIVE_CLIENT_TOKEN;
  const monthly = env.PADDLE_LIVE_MONTHLY_PRICE_ID;
  const annual = env.PADDLE_LIVE_ANNUAL_PRICE_ID;
  const secret = env.PADDLE_LIVE_REFERENCE_SECRET;
  if (!/^live_[a-zA-Z0-9]+$/.test(token ?? '') || !/^pri_[a-zA-Z0-9]+$/.test(monthly ?? '') ||
      !/^pri_[a-zA-Z0-9]+$/.test(annual ?? '') || monthly === annual || !secret || secret.length < 32)
    throw new HttpError(503, 'Live checkout is not configured');
  const context = await securityContext(request, env, ctx);
  return json({ environment: 'live', clientToken: token, monthlyPriceId: monthly, annualPriceId: annual,
    checkoutReference: await signCheckoutReference(context.userId, secret) }, { headers: { 'cache-control': 'no-store' } });
}
