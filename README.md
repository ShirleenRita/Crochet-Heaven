# Crochet Haven

Crochet Haven is a responsive marketplace for handmade crochet, maker shops, lessons, and a creator community. The application now uses Supabase for authentication, data, and file storage; Flutterwave Standard for hosted card/M-Pesa checkout; and a verified payment webhook. There are no seeded marketplace products, local demo accounts, or fake successful orders.

## Run the website

Serve this folder over HTTP (ES modules do not work from `file://`). For example:

```powershell
python -m http.server 8000
```

Open `http://localhost:8000`. Add your Supabase project URL and **publishable** key in `supabase-config.js`. That file is safe for the publishable key. Never put a service-role key or Flutterwave secret in browser code.

Without the project configuration, the site shows a setup message and does not create accounts, listings, posts, or orders.

## Create the Supabase backend

1. Create a Supabase project and run [`supabase/schema.sql`](supabase/schema.sql) once in its SQL editor.
2. In Authentication settings, enable email sign-up and configure the site URL and allowed redirect URLs. Enable Google and Apple providers if you want those options.
3. Set up the project’s mail delivery before opening registrations to the public. Supabase’s default email service has limits.
4. Add `SUPABASE_URL` and the publishable key to `supabase-config.js`.
5. Install the Supabase CLI, link this folder to the project, and deploy the two Edge Functions using the official Supabase CLI workflow.
6. Set Edge Function secrets: `FLW_SECRET_KEY`, `FLW_WEBHOOK_HASH`, and `PUBLIC_SITE_URL`. Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. Keep the Flutterwave and service-role secrets there only.
7. Configure Flutterwave’s webhook URL to the deployed `flutterwave-webhook` function and set the same webhook secret hash in the Flutterwave dashboard.

The Flutterwave webhook function must be reachable without a Supabase JWT. Its handler validates Flutterwave’s `verif-hash` header and verifies each transaction with Flutterwave before marking an order paid. Do not remove either check.

## Seller review and settlement

Shops start with `pending` status. A marketplace administrator reviews identity and business details, changes the shop to `approved`, and adds the maker’s Flutterwave collection subaccount ID to `shops.flutterwave_subaccount_id`. The checkout function refuses payment for shops without that vetted subaccount. Flutterwave then splits each successful order with the 10% platform fee and maker share. Add each seller as a verified merchant in accordance with your Flutterwave account terms before enabling checkout.

Seller-arranged and Crochet Haven-coordinated shipping are recorded with a seller-set shipping amount. Crochet Haven-coordinated delivery requires your team to fulfill the order manually; no carrier label or tracking integration is included yet. Configure the real shipping operation before offering that mode to buyers.

## Languages and currencies

The interface includes English, French, Spanish, Portuguese, German, Italian, Swahili, Arabic, Hindi, and Japanese. User-authored product and lesson content stays in the language its creator wrote it in. Currency display supports USD, EUR (France), GBP, KES, CAD, AUD, JPY, INR, CHF, and ZAR. Daily indicative exchange rates are cached and attributed to ExchangeRate-API. Buyers are charged in the listing’s currency; display currency is an estimate and never changes the amount sent to the payment provider.

## Important launch work

- Configure Supabase email delivery, OAuth providers, backups, domain, and production redirect URLs.
- Complete seller identity checks and create/verify each Flutterwave subaccount.
- Confirm payment and settlement eligibility for every seller country and listing currency with Flutterwave.
- Configure an operating process for platform-coordinated shipping, order support, refunds, and disputes.
- Add admin review screens, order status updates, notification delivery, and end-to-end checks using provider sandbox credentials before going live.

Marketplace listings, favorites, community posts, lesson drafts, orders, and payment events are stored in Supabase. Uploaded images go to the public `marketplace-media` bucket. Public image URLs must never contain private customer documents.
