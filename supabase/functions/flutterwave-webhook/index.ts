import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const secretHash = Deno.env.get('FLW_WEBHOOK_HASH');
  const secretKey = Deno.env.get('FLW_SECRET_KEY');
  if (!secretHash || !secretKey) return new Response('Webhook is not configured', { status: 503 });
  if (req.headers.get('verif-hash') !== secretHash) return new Response('Invalid signature', { status: 401 });
  const body = await req.json().catch(() => null);
  const transactionId = body?.data?.id;
  if (!transactionId) return new Response('Missing transaction id', { status: 400 });

  // Verify directly with Flutterwave before changing order state. Never trust
  // the event body alone to mark an order as paid.
  const verificationResponse = await fetch(`https://api.flutterwave.com/v3/transactions/${encodeURIComponent(transactionId)}/verify`, { headers: { Authorization: `Bearer ${secretKey}` } });
  const verification = await verificationResponse.json();
  const tx = verification?.data;
  if (!verificationResponse.ok || verification.status !== 'success' || !tx) return new Response('Transaction verification failed', { status: 400 });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const { data: payment, error } = await admin.from('payments').select('id,order_id,provider_reference,amount_minor,currency').eq('provider_reference', tx.tx_ref).eq('provider', 'flutterwave').single();
  if (error || !payment) return new Response('Unknown payment reference', { status: 404 });
  const divisor = payment.currency === 'JPY' ? 1 : 100;
  if (tx.status !== 'successful') {
    await admin.from('payments').update({ status: 'failed', event_id: String(transactionId) }).eq('id', payment.id);
    await admin.rpc('cancel_pending_order', { p_order_id: payment.order_id });
    return new Response('Failed payment recorded', { status: 200 });
  }
  if (tx.currency !== payment.currency || Math.round(Number(tx.amount) * divisor) !== Number(payment.amount_minor)) return new Response('Payment does not match expected order', { status: 400 });
  const { data: order, error: orderError } = await admin.from('orders').select('id,shop_id,subtotal_minor,platform_fee_minor,currency,status').eq('id', payment.order_id).single();
  if (orderError || !order) return new Response('Order not found', { status: 404 });
  if (order.status === 'paid' || order.status === 'processing') return new Response('Already processed', { status: 200 });
  if (order.status !== 'pending') {
    await admin.from('payments').update({ status: 'successful', event_id: String(transactionId) }).eq('id', payment.id);
    // A late settlement for a cancelled order needs manual refund handling.
    return new Response('Paid cancelled order requires reconciliation', { status: 200 });
  }
  const { error: paymentUpdateError } = await admin.from('payments').update({ status: 'successful', event_id: String(transactionId) }).eq('id', payment.id);
  if (paymentUpdateError) return new Response('Could not record payment', { status: 500 });
  const { error: orderUpdateError } = await admin.from('orders').update({ status: 'paid' }).eq('id', order.id);
  if (orderUpdateError) return new Response('Could not mark order paid', { status: 500 });
  // Seller share and the 10% platform commission are split by Flutterwave's
  // subaccount settlement. Do not create a marketplace wallet balance here.
  return new Response('ok', { status: 200 });
});
