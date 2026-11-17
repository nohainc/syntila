import { dataOf } from "../../platform/data.js";
import { signCheckoutReference, verifyCheckoutReference } from '../../paddle-reference.js';
import { verifyPaddleSignature } from '../../paddle-signature.js';
import { HttpError, json, securityContext, type SecurityEnv } from './http-security.js';

type SandboxEnv = SecurityEnv & {
  PADDLE_SANDBOX_CLIENT_TOKEN?: string;
  PADDLE_SANDBOX_MONTHLY_PRICE_ID?: string;
  PADDLE_SANDBOX_ANNUAL_PRICE_ID?: string;
  PADDLE_SANDBOX_REFERENCE_SECRET?: string;
  PADDLE_SANDBOX_WEBHOOK_SECRET?: string;
  PADDLE_SANDBOX_API_KEY?: string;
};

/** Explicitly local-only configuration; production must never use test payments. */
export async function handleSandboxCheckoutConfig(request: Request, env: SandboxEnv, ctx?: ExecutionContext): Promise<Response> {
  if (env.SYNTILA_ENVIRONMENT !== 'development') throw new HttpError(404, 'Not found');
  if (request.method !== 'GET') throw new HttpError(405, 'Unsupported method');
  const token = env.PADDLE_SANDBOX_CLIENT_TOKEN;
  const monthly = env.PADDLE_SANDBOX_MONTHLY_PRICE_ID;
  const annual = env.PADDLE_SANDBOX_ANNUAL_PRICE_ID;
  const secret = env.PADDLE_SANDBOX_REFERENCE_SECRET;
  if (!token?.startsWith('test_') || !monthly?.startsWith('pri_') || !annual?.startsWith('pri_') || !secret || secret.length < 32)
    throw new HttpError(503, 'Sandbox checkout is not configured');
  const context = await securityContext(request, env, ctx);
  return json({ environment: 'sandbox', clientToken: token, monthlyPriceId: monthly, annualPriceId: annual,
    checkoutReference: await signCheckoutReference(context.userId, secret) }, { headers: { 'cache-control': 'no-store' } });
}

/** Mint a short-lived portal link only for the authenticated local account. */
export async function handleSandboxPortal(request: Request, env: SandboxEnv, ctx?: ExecutionContext, requestPaddle: typeof fetch = fetch): Promise<Response> {
  if (env.SYNTILA_ENVIRONMENT !== 'development') throw new HttpError(404, 'Not found');
  if (request.method !== 'POST') throw new HttpError(405, 'Unsupported method');
  const apiKey = env.PADDLE_SANDBOX_API_KEY;
  if (!apiKey?.startsWith('pdl_sdbx_')) throw new HttpError(503, 'Sandbox customer portal is not configured');
  const context = await securityContext(request, env, ctx);
  const customer = await dataOf(env).read.row<{ customer_id: string }>`SELECT customer_id FROM paddle_sandbox_subscriptions WHERE user_id=${context.userId} ORDER BY occurred_at DESC LIMIT 1`;
  if (!customer) throw new HttpError(404, 'No sandbox subscription found');
  const response = await requestPaddle(`https://sandbox-api.paddle.com/customers/${encodeURIComponent(customer.customer_id)}/portal-sessions`, {
    method: 'POST', redirect: 'error', headers: { authorization: `Bearer ${apiKey}`, 'content-type': 'application/json' }, body: '{}',
  });
  if (!response.ok) throw new HttpError(502, 'Could not open the sandbox customer portal');
  const body = await response.json() as { data?: { urls?: { general?: { overview?: string } } } };
  let url: URL;
  try { url = new URL(body.data?.urls?.general?.overview ?? ''); } catch { throw new HttpError(502, 'Invalid sandbox portal response'); }
  if (url.protocol !== 'https:' || url.hostname !== 'sandbox-customer-portal.paddle.com' || url.username || url.password || url.port)
    throw new HttpError(502, 'Invalid sandbox portal response');
  return json({ url: url.toString() }, { headers: { 'cache-control': 'no-store' } });
}

/** Accept only signed sandbox subscription events on a development backend. */
export async function handleSandboxWebhook(request: Request, env: SandboxEnv): Promise<Response> {
  if (env.SYNTILA_ENVIRONMENT !== 'development') throw new HttpError(404, 'Not found');
  if (request.method !== 'POST') throw new HttpError(405, 'Unsupported method');
  const secret = env.PADDLE_SANDBOX_WEBHOOK_SECRET;
  const refSecret = env.PADDLE_SANDBOX_REFERENCE_SECRET;
  const prices = [env.PADDLE_SANDBOX_MONTHLY_PRICE_ID, env.PADDLE_SANDBOX_ANNUAL_PRICE_ID];
  if (!secret || !refSecret || refSecret.length < 32 || prices.some((p) => !p?.startsWith('pri_')))
    throw new HttpError(503, 'Sandbox notifications are not configured');
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, 'Missing webhook body');
  const chunks: Uint8Array[] = [];
  let length = 0;
  for (;;) {
    const part = await reader.read();
    if (part.done) break;
    length += part.value.length;
    if (length > 256 * 1024) { void reader.cancel().catch(() => undefined); throw new HttpError(413, 'Webhook too large'); }
    chunks.push(part.value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  const raw = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  if (!await verifyPaddleSignature(raw, request.headers.get('paddle-signature'), secret))
    throw new HttpError(401, 'Invalid webhook signature');
  let event: any;
  try { event = JSON.parse(raw); } catch { throw new HttpError(400, 'Invalid webhook JSON'); }
  if (!['subscription.created', 'subscription.updated', 'subscription.activated', 'subscription.resumed', 'subscription.canceled', 'subscription.paused', 'subscription.past_due', 'subscription.trialing'].includes(event?.event_type))
    return json({ ok: true });
  const data = event.data;
  const reference = data?.custom_data?.syntila_checkout_reference;
  const userId = typeof reference === 'string' ? await verifyCheckoutReference(reference, refSecret) : null;
  const occurred = typeof event.occurred_at === 'string' ? Date.parse(event.occurred_at) : NaN;
  const statuses: Record<string, string> = { active: 'active', trialing: 'trialing', past_due: 'past_due', canceled: 'canceled', paused: 'canceled' };
  const status = statuses[data?.status];
  const ends = data?.current_billing_period?.ends_at;
  const periodEnd = typeof ends === 'string' && Number.isFinite(Date.parse(ends)) ? new Date(ends).toISOString() : null;
  if (!userId || typeof data?.id !== 'string' || !data.id.startsWith('sub_') || typeof data.customer_id !== 'string' || !data.customer_id.startsWith('ctm_') || !Number.isFinite(occurred) || !status || (status !== 'canceled' && !periodEnd) || !Array.isArray(data.items) || !data.items.some((item: any) => prices.includes(item?.price?.id)))
    throw new HttpError(400, 'Unsupported subscription event');
  const db = env.SYNTILA_DB;
  await db.batch([
    db.prepare(`INSERT INTO paddle_sandbox_subscriptions(subscription_id,user_id,customer_id,status,current_period_end,occurred_at)
      VALUES (?1,?2,?3,?4,?5,?6)
      ON CONFLICT(subscription_id) DO UPDATE SET customer_id=excluded.customer_id,status=excluded.status,current_period_end=excluded.current_period_end,occurred_at=excluded.occurred_at
      WHERE paddle_sandbox_subscriptions.user_id=excluded.user_id AND paddle_sandbox_subscriptions.occurred_at < excluded.occurred_at`)
      .bind(data.id, userId, data.customer_id, status, periodEnd, new Date(occurred).toISOString()),
    db.prepare(`INSERT INTO account_plans(user_id,tier,status,source,current_period_end,provider_customer_id,provider_subscription_id,created_at,updated_at)
      SELECT user_id,'paid',status,'provider',current_period_end,customer_id,subscription_id,now(),now()
      FROM paddle_sandbox_subscriptions WHERE user_id=?1
      ORDER BY (status IN ('active','trialing','past_due') AND current_period_end > now()) DESC, current_period_end DESC NULLS LAST, occurred_at DESC LIMIT 1
      ON CONFLICT(user_id) DO UPDATE SET
        tier=CASE WHEN account_plans.source='manual' AND account_plans.tier='paid' AND account_plans.status='active' THEN account_plans.tier ELSE excluded.tier END,
        status=CASE WHEN account_plans.source='manual' AND account_plans.tier='paid' AND account_plans.status='active' THEN account_plans.status ELSE excluded.status END,
        source=CASE WHEN account_plans.source='manual' AND account_plans.tier='paid' AND account_plans.status='active' THEN account_plans.source ELSE excluded.source END,
        current_period_end=CASE WHEN account_plans.source='manual' AND account_plans.tier='paid' AND account_plans.status='active' THEN account_plans.current_period_end ELSE excluded.current_period_end END,
        provider_customer_id=excluded.provider_customer_id,provider_subscription_id=excluded.provider_subscription_id,updated_at=excluded.updated_at
      WHERE account_plans.source='provider'
         OR (account_plans.source='manual' AND ((account_plans.tier='free' AND account_plans.status='canceled')
             OR (account_plans.tier='paid' AND account_plans.status='active')))`).bind(userId),
  ]);
  return json({ ok: true });
}
