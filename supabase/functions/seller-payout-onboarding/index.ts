import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const siteUrl = (Deno.env.get('PUBLIC_SITE_URL') ?? '').replace(/\/$/, '');
const corsHeaders = {
  'Access-Control-Allow-Origin': siteUrl,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);

  const origin = req.headers.get('Origin');
  if (!siteUrl || (origin && origin.replace(/\/$/, '') !== siteUrl)) return reply({ error: 'This website is not allowed to use payout onboarding.' }, 403);

  const authorization = req.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return reply({ error: 'Sign in to continue.' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const flutterwaveKey = Deno.env.get('FLW_SECRET_KEY');
  if (!supabaseUrl || !anonKey || !serviceKey || !flutterwaveKey) return reply({ error: 'Payout onboarding is not configured yet. Please try again later.' }, 503);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = authorization.slice('Bearer '.length);
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user?.id || !user.email) return reply({ error: 'Your sign-in session is invalid. Please sign in again.' }, 401);

  let payload: { action?: string; bank_code?: string; account_number?: string; phone?: string; consent?: boolean };
  try { payload = await req.json(); } catch { return reply({ error: 'Invalid request.' }, 400); }
  if (!['banks', 'create'].includes(payload.action ?? '')) return reply({ error: 'Unknown payout action.' }, 400);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: shop, error: shopError } = await admin.from('shops')
    .select('id, owner_id, name, country_code, status, flutterwave_subaccount_id')
    .eq('owner_id', user.id).maybeSingle();
  if (shopError) return reply({ error: 'Could not verify your shop. Please try again.' }, 500);
  if (!shop) return reply({ error: 'No shop application was found for this account.' }, 404);
  if (shop.status !== 'approved') return reply({ error: 'Your shop must be approved before payout setup.' }, 403);
  if (shop.flutterwave_subaccount_id) return reply({ ok: true, already_connected: true });

  const country = String(shop.country_code || '').trim().toUpperCase();
  if (!/^[A-Z]{2}$/.test(country)) return reply({ error: 'Your shop country is not valid. Contact support.' }, 400);

  const bankResponse = await fetch(`https://api.flutterwave.com/v3/banks/${encodeURIComponent(country)}?include_provider_type=1`, {
    headers: { Authorization: `Bearer ${flutterwaveKey}`, Accept: 'application/json' },
  });
  const bankResult = await bankResponse.json().catch(() => null);
  if (!bankResponse.ok || bankResult?.status !== 'success' || !Array.isArray(bankResult.data)) {
    return reply({ error: 'Flutterwave could not retrieve banks for your shop country. Check whether payouts are supported there.' }, 502);
  }

  if (payload.action === 'banks') {
    const banks = bankResult.data
      .filter((bank: any) => typeof bank.code === 'string' && typeof bank.name === 'string')
      .map((bank: any) => ({ code: bank.code, name: bank.name }));
    return reply({ banks });
  }

  const bankCode = String(payload.bank_code ?? '').trim();
  const accountNumber = String(payload.account_number ?? '').trim().replace(/\s+/g, '');
  const phone = String(payload.phone ?? '').trim();
  if (payload.consent !== true) return reply({ error: 'You must confirm consent before connecting a payout account.' }, 400);
  if (!bankCode || !bankResult.data.some((bank: any) => String(bank.code) === bankCode)) return reply({ error: 'Choose a bank listed for your shop country.' }, 400);
  if (!/^[A-Za-z0-9-]{5,34}$/.test(accountNumber)) return reply({ error: 'Enter a valid bank account number.' }, 400);
  if (!/^\+?[0-9 ()-]{8,20}$/.test(phone)) return reply({ error: 'Enter a valid mobile number with country code.' }, 400);

  const bank = bankResult.data.find((item: any) => String(item.code) === bankCode);
  const contactName = String(user.user_metadata?.display_name ?? shop.name).slice(0, 80);
  const createResponse = await fetch('https://api.flutterwave.com/v3/subaccounts', {
    method: 'POST',
    headers: { Authorization: `Bearer ${flutterwaveKey}`, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({
      account_bank: bankCode,
      account_number: accountNumber,
      business_name: shop.name,
      business_email: user.email,
      business_mobile: phone,
      business_contact: contactName,
      business_contact_mobile: phone,
      country,
      split_type: 'percentage',
      split_value: 0.9,
      meta: [{ metaname: 'CrochetHavenShopId', metavalue: shop.id }],
    }),
  });
  const created = await createResponse.json().catch(() => null);
  const subaccountId = created?.data?.subaccount_id;
  if (!createResponse.ok || created?.status !== 'success' || typeof subaccountId !== 'string' || !subaccountId.startsWith('RS_')) {
    return reply({ error: created?.message || 'Flutterwave could not create the seller payout account. Check the details and try again.' }, 502);
  }

  const { error: saveError } = await admin.from('shops')
    .update({ flutterwave_subaccount_id: subaccountId })
    .eq('id', shop.id).eq('owner_id', user.id).is('flutterwave_subaccount_id', null);
  if (saveError) return reply({ error: 'Flutterwave created the account, but Crochet Haven could not save its reference. Please contact support before retrying.' }, 500);

  return reply({ ok: true, connected: true, bank_name: String(bank?.name ?? 'Selected bank') });
});
