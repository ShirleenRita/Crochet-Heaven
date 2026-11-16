import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': Deno.env.get('PUBLIC_SITE_URL') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed' }, 405);
  const authorization = req.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return reply({ error: 'Sign in before checkout.' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const flutterwaveKey = Deno.env.get('FLW_SECRET_KEY');
  const siteUrl = Deno.env.get('PUBLIC_SITE_URL');
  if (!flutterwaveKey || !siteUrl) return reply({ error: 'Checkout is not configured. Set Flutterwave and site URL secrets.' }, 503);

  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
  const { data: userData, error: authError } = await userClient.auth.getUser();
  if (authError || !userData.user?.email) return reply({ error: 'Your session is invalid or has no verified email.' }, 401);
  let payload: { items?: Array<{ product_id: string; quantity: number }>; shipping_address?: Record<string, string>; payment_method?: string };
  try { payload = await req.json(); } catch { return reply({ error: 'Invalid checkout request.' }, 400); }
  if (!Array.isArray(payload.items) || !payload.shipping_address) return reply({ error: 'Cart and shipping address are required.' }, 400);
  const paymentMethod = payload.payment_method;
  if (!['card', 'mpesa'].includes(paymentMethod ?? '')) return reply({ error: 'That payment method is not enabled.' }, 400);
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  if (!payload.items.every((item) => typeof item.product_id === 'string' && Number.isInteger(item.quantity) && item.quantity > 0 && item.quantity <= 20)) return reply({ error: 'Cart contains an invalid product or quantity.' }, 400);
  const productIds = payload.items.map((item) => item.product_id);
  const { data: requestedProducts, error: productError } = await admin.from('products').select('id,currency,is_active,shops!inner(status,flutterwave_subaccount_id)').in('id', productIds);
  if (productError || requestedProducts?.length !== productIds.length || requestedProducts.some((p) => !p.is_active || p.shops.status !== 'approved')) return reply({ error: 'One or more products are no longer available.' }, 409);
  if (new Set(requestedProducts.map((p) => p.currency)).size !== 1) return reply({ error: 'Check out products in one currency at a time.' }, 400);
  const subaccountId = requestedProducts[0].shops.flutterwave_subaccount_id;
  if (!subaccountId) return reply({ error: 'This maker is not yet enabled for split settlement.' }, 409);
  if (paymentMethod === 'mpesa' && requestedProducts[0].currency !== 'KES') return reply({ error: 'M-Pesa is available for KES listings only.' }, 400);
  const result = await admin.rpc('create_pending_order', { p_buyer_id: userData.user.id, p_items: payload.items, p_shipping_address: payload.shipping_address, p_commission_bps: 1000 });
  if (result.error) return reply({ error: result.error.message }, 422);
  const order = result.data as { order_id: string; payment_id: string; amount_minor: number; commission_minor: number; currency: string };
  const txRef = `CH-${order.order_id}`;
  await admin.from('payments').update({ provider_reference: txRef }).eq('id', order.payment_id);
  const divisor = order.currency === 'JPY' ? 1 : 100;
  const amount = Number(order.amount_minor) / divisor;
  const paymentOptions = paymentMethod === 'mpesa' ? 'mpesa' : 'card';
  let flwResponse: Response; let flw: any;
  try { flwResponse = await fetch('https://api.flutterwave.com/v3/payments', {
    method: 'POST',
    headers: { Authorization: `Bearer ${flutterwaveKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      tx_ref: txRef,
      amount,
      currency: order.currency,
      payment_options: paymentOptions,
      subaccounts: [{ id: subaccountId, transaction_charge_type: 'flat', transaction_charge: Number(order.commission_minor) / divisor }],
      redirect_url: `${siteUrl.replace(/\/$/, '')}/?checkout=return`,
      customer: { email: userData.user.email, name: userData.user.user_metadata?.display_name ?? userData.user.email },
      customizations: { title: 'Crochet Haven', description: 'Handmade crochet order' },
      meta: { order_id: order.order_id },
    }),
  });
  flw = await flwResponse.json();
  } catch (error) {
    await admin.from('payments').update({ status: 'failed' }).eq('id', order.payment_id);
    await admin.rpc('cancel_pending_order', { p_order_id: order.order_id });
    return reply({ error: error instanceof Error ? error.message : 'Payment provider connection failed.' }, 502);
  }
  if (!flwResponse.ok || flw.status !== 'success' || !flw.data?.link) {
    await admin.from('payments').update({ status: 'failed' }).eq('id', order.payment_id);
    await admin.rpc('cancel_pending_order', { p_order_id: order.order_id });
    return reply({ error: flw.message ?? 'Payment provider could not start checkout.' }, 502);
  }
  return reply({ checkout_url: flw.data.link });
});
