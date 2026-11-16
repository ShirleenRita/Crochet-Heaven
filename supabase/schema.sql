-- Crochet Haven marketplace foundation (Supabase / PostgreSQL)
-- Run in a new Supabase project's SQL editor. This schema intentionally does
-- not create or settle payments; use a verified provider webhook and a
-- server-side order function before accepting real money.

create extension if not exists pgcrypto;

create type public.shop_status as enum ('pending','approved','rejected','suspended');
create type public.shipping_mode as enum ('seller','platform');
create type public.order_status as enum ('pending','paid','processing','shipped','delivered','cancelled','refunded');
create type public.payment_status as enum ('pending','successful','failed','refunded');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_url text,
  country_code char(2),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name',''))
  on conflict (id) do nothing;
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function public.handle_new_user();

create table public.shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 3 and 80),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  description text not null default '',
  country_code char(2) not null,
  status public.shop_status not null default 'pending',
  shipping_options public.shipping_mode[] not null default array['seller']::public.shipping_mode[],
  flutterwave_subaccount_id text unique,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  title text not null check (char_length(title) between 3 and 120),
  description text not null default '',
  category text not null,
  image_urls text[] not null default '{}',
  price_minor bigint not null check (price_minor > 0),
  currency char(3) not null default 'USD',
  stock integer not null default 1 check (stock >= 0),
  shipping_mode public.shipping_mode not null default 'seller',
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index products_marketplace_idx on public.products(category, created_at desc) where is_active;
create index products_shop_idx on public.products(shop_id, created_at desc);

create table public.addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  full_name text not null,
  address_line_1 text not null,
  address_line_2 text,
  city text not null,
  region text,
  postal_code text,
  country_code char(2) not null,
  created_at timestamptz not null default now()
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references public.profiles(id),
  shop_id uuid not null references public.shops(id),
  shipping_address_id uuid references public.addresses(id),
  status public.order_status not null default 'pending',
  shipping_mode public.shipping_mode not null,
  currency char(3) not null,
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  shipping_minor bigint not null default 0 check (shipping_minor >= 0),
  platform_fee_minor bigint not null check (platform_fee_minor >= 0),
  total_minor bigint not null check (total_minor = subtotal_minor + shipping_minor),
  commission_bps integer not null default 1000 check (commission_bps between 0 and 10000),
  created_at timestamptz not null default now()
);
create index orders_buyer_idx on public.orders(buyer_id, created_at desc);
create index orders_shop_idx on public.orders(shop_id, created_at desc);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_title text not null,
  quantity integer not null check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor > 0),
  currency char(3) not null
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  provider text not null,
  provider_reference text unique,
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null,
  status public.payment_status not null default 'pending',
  event_id text unique,
  created_at timestamptz not null default now()
);

create table public.payouts (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id),
  order_id uuid not null references public.orders(id),
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null,
  status text not null default 'pending' check (status in ('pending','processing','paid','failed')),
  provider_reference text,
  created_at timestamptz not null default now(),
  unique(shop_id, order_id)
);

create table public.tutorials (
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid references public.profiles(id),
  title text not null,
  description text not null default '',
  level text not null check (level in ('beginner','intermediate','advanced')),
  video_url text not null,
  thumbnail_url text,
  duration_seconds integer check (duration_seconds > 0),
  is_published boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.reviews (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  product_id uuid not null references public.products(id),
  buyer_id uuid not null references public.profiles(id),
  rating smallint not null check (rating between 1 and 5),
  body text not null default '',
  created_at timestamptz not null default now(),
  unique(order_id, product_id)
);

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  opened_by uuid not null references public.profiles(id),
  reason text not null,
  status text not null default 'open' check (status in ('open','investigating','resolved','closed')),
  resolution text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

-- Private-by-default access. Financial rows are read-only to participants;
-- service_role server functions handle order, payment, payout and approval writes.
alter table public.profiles enable row level security;
alter table public.shops enable row level security;
alter table public.products enable row level security;
alter table public.addresses enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.payouts enable row level security;
alter table public.tutorials enable row level security;
alter table public.reviews enable row level security;
alter table public.disputes enable row level security;

create policy "Users read their own profile" on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "Users update their own profile" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy "Approved shops are public" on public.shops for select to anon, authenticated using (status = 'approved' or owner_id = (select auth.uid()));
create policy "Users apply for their own shop" on public.shops for insert to authenticated with check (owner_id = (select auth.uid()) and status = 'pending');
create policy "Owners edit shop details" on public.shops for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
revoke update on public.shops from authenticated;
grant update(name, description, country_code, shipping_options) on public.shops to authenticated;

create policy "Active products from approved shops are public" on public.products for select to anon, authenticated using ((is_active and exists(select 1 from public.shops s where s.id = shop_id and s.status = 'approved')) or exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid())));
create policy "Approved shop owners add products" on public.products for insert to authenticated with check (exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid()) and s.status = 'approved'));
create policy "Shop owners edit their products" on public.products for update to authenticated using (exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid()) and s.status = 'approved')) with check (exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid()) and s.status = 'approved'));
create policy "Shop owners remove their products" on public.products for delete to authenticated using (exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid()) and s.status = 'approved'));

create policy "Users manage their addresses" on public.addresses for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Buyers and shop owners read orders" on public.orders for select to authenticated using (buyer_id = (select auth.uid()) or exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid())));
create policy "Participants read order items" on public.order_items for select to authenticated using (exists(select 1 from public.orders o where o.id = order_id and (o.buyer_id = (select auth.uid()) or exists(select 1 from public.shops s where s.id = o.shop_id and s.owner_id = (select auth.uid())))));
create policy "Buyers read their payments" on public.payments for select to authenticated using (exists(select 1 from public.orders o where o.id = order_id and o.buyer_id = (select auth.uid())));
create policy "Shop owners read their payouts" on public.payouts for select to authenticated using (exists(select 1 from public.shops s where s.id = shop_id and s.owner_id = (select auth.uid())));
create policy "Published tutorials are public" on public.tutorials for select to anon, authenticated using (is_published or teacher_id = (select auth.uid()));
create policy "Teachers submit unpublished lessons" on public.tutorials for insert to authenticated with check (teacher_id=(select auth.uid()) and is_published=false);
create policy "Teachers edit their unpublished lessons" on public.tutorials for update to authenticated using (teacher_id=(select auth.uid()) and is_published=false) with check (teacher_id=(select auth.uid()) and is_published=false);
create policy "Reviews are public" on public.reviews for select to anon, authenticated using (true);
create policy "Buyers write verified reviews" on public.reviews for insert to authenticated with check (buyer_id = (select auth.uid()) and exists(select 1 from public.orders o where o.id = order_id and o.buyer_id = (select auth.uid()) and o.status = 'delivered'));
create policy "Dispute parties can read disputes" on public.disputes for select to authenticated using (opened_by = (select auth.uid()) or exists(select 1 from public.orders o join public.shops s on s.id=o.shop_id where o.id=order_id and (o.buyer_id=(select auth.uid()) or s.owner_id=(select auth.uid()))));
create policy "Buyers open order disputes" on public.disputes for insert to authenticated with check (opened_by=(select auth.uid()) and exists(select 1 from public.orders o where o.id=order_id and o.buyer_id=(select auth.uid())));

-- Persistent community, favorites, shipping quotes and inventory-backed checkout.
create table public.community_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  image_url text,
  likes_count integer not null default 0 check (likes_count >= 0),
  is_published boolean not null default true,
  created_at timestamptz not null default now()
);
create index community_posts_recent_idx on public.community_posts(created_at desc) where is_published;
create table public.community_likes (
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(post_id,user_id)
);
create table public.favorites (
  user_id uuid not null references public.profiles(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_id,product_id)
);
alter table public.products add column if not exists shipping_minor bigint not null default 0 check (shipping_minor >= 0);
alter table public.community_posts enable row level security;
alter table public.community_likes enable row level security;
alter table public.favorites enable row level security;
create policy "Published community posts are public" on public.community_posts for select to anon, authenticated using (is_published or user_id=(select auth.uid()));
create policy "Users publish their own posts" on public.community_posts for insert to authenticated with check (user_id=(select auth.uid()));
create policy "Users manage their own posts" on public.community_posts for delete to authenticated using (user_id=(select auth.uid()));
create policy "Likes are public" on public.community_likes for select to anon, authenticated using (true);
create policy "Users add their own likes" on public.community_likes for insert to authenticated with check (user_id=(select auth.uid()));
create policy "Users remove their own likes" on public.community_likes for delete to authenticated using (user_id=(select auth.uid()));
create policy "Users read their own favorites" on public.favorites for select to authenticated using (user_id=(select auth.uid()));
create policy "Users save their own favorites" on public.favorites for insert to authenticated with check (user_id=(select auth.uid()));
create policy "Users remove their own favorites" on public.favorites for delete to authenticated using (user_id=(select auth.uid()));

-- Public creator names/country are needed beside their published work; profiles
-- do not contain email addresses or credentials.
drop policy if exists "Users read their own profile" on public.profiles;
create policy "Public creator profiles are visible" on public.profiles for select to anon, authenticated using (true);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('marketplace-media','marketplace-media',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true, file_size_limit=5242880, allowed_mime_types=array['image/jpeg','image/png','image/webp'];
create policy "Marketplace media is public" on storage.objects for select to anon, authenticated using (bucket_id='marketplace-media');
create policy "Users upload their own marketplace media" on storage.objects for insert to authenticated with check (bucket_id='marketplace-media' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy "Users delete their own marketplace media" on storage.objects for delete to authenticated using (bucket_id='marketplace-media' and (storage.foldername(name))[1]=(select auth.uid())::text);

-- Only the trusted Edge Function service role may invoke this transaction.
-- It locks listings, validates stock and creates order/items/payment atomically.
create or replace function public.create_pending_order(
  p_buyer_id uuid, p_items jsonb, p_shipping_address jsonb, p_commission_bps integer default 1000
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_shop_id uuid; v_currency char(3); v_shipping_mode public.shipping_mode;
  v_subtotal bigint; v_shipping bigint; v_fee bigint; v_total bigint;
  v_address_id uuid; v_order_id uuid; v_payment_id uuid;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'Cart is empty'; end if;
  if p_commission_bps <> 1000 then raise exception 'Unexpected commission'; end if;
  perform p.id from public.products p join public.shops s on s.id=p.shop_id
   where p.id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)
   order by p.id for update of p;
  if (select count(*) from jsonb_array_elements(p_items)) <> (select count(distinct x->>'product_id') from jsonb_array_elements(p_items) x) then raise exception 'Duplicate cart item'; end if;
  select p.shop_id,p.currency,min(p.shipping_mode::text)::public.shipping_mode
    into v_shop_id,v_currency,v_shipping_mode
    from jsonb_array_elements(p_items) i
    join public.products p on p.id=(i->>'product_id')::uuid
    join public.shops s on s.id=p.shop_id
    where p.is_active and s.status='approved'
    group by p.shop_id,p.currency
    having count(distinct p.shipping_mode)=1;
  if v_shop_id is null then raise exception 'Cart must contain active products from one approved shop, one currency, and one shipping method'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) i join public.products p on p.id=(i->>'product_id')::uuid where p.shop_id<>v_shop_id or p.currency<>v_currency or not p.is_active or (i->>'quantity')::integer<1 or (i->>'quantity')::integer>p.stock) then raise exception 'Product is unavailable or stock is insufficient'; end if;
  select sum(p.price_minor*(i->>'quantity')::integer),sum(p.shipping_minor*(i->>'quantity')::integer)
    into v_subtotal,v_shipping from jsonb_array_elements(p_items) i join public.products p on p.id=(i->>'product_id')::uuid;
  v_fee=floor(v_subtotal*p_commission_bps/10000.0)::bigint; v_total=v_subtotal+v_shipping;
  insert into public.addresses(user_id,full_name,address_line_1,city,postal_code,country_code)
    values(p_buyer_id,p_shipping_address->>'full_name',p_shipping_address->>'address_line_1',p_shipping_address->>'city',p_shipping_address->>'postal_code',p_shipping_address->>'country_code') returning id into v_address_id;
  insert into public.orders(buyer_id,shop_id,shipping_address_id,status,shipping_fulfillment,currency,subtotal_minor,shipping_minor,platform_fee_minor,total_minor,commission_bps)
    values(p_buyer_id,v_shop_id,v_address_id,'pending',v_shipping_mode,v_currency,v_subtotal,v_shipping,v_fee,v_total,p_commission_bps) returning id into v_order_id;
  insert into public.order_items(order_id,product_id,product_title,quantity,unit_price_minor,currency)
    select v_order_id,p.id,p.title,(i->>'quantity')::integer,p.price_minor,p.currency from jsonb_array_elements(p_items) i join public.products p on p.id=(i->>'product_id')::uuid;
  update public.products p set stock=p.stock-(i->>'quantity')::integer,is_active=(p.stock-(i->>'quantity')::integer)>0,updated_at=now()
    from jsonb_array_elements(p_items) i where p.id=(i->>'product_id')::uuid;
  insert into public.payments(order_id,provider,amount_minor,currency,status) values(v_order_id,'flutterwave',v_total,v_currency,'pending') returning id into v_payment_id;
  return jsonb_build_object('order_id',v_order_id,'payment_id',v_payment_id,'amount_minor',v_total,'currency',v_currency,'commission_minor',v_fee);
end; $$;
revoke all on function public.create_pending_order(uuid,jsonb,jsonb,integer) from public,anon,authenticated;
grant execute on function public.create_pending_order(uuid,jsonb,jsonb,integer) to service_role;

create or replace function public.cancel_pending_order(p_order_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_status public.order_status;
begin
  select status into v_status from public.orders where id=p_order_id for update;
  if v_status is distinct from 'pending' then return; end if;
  update public.orders set status='cancelled' where id=p_order_id;
  update public.products p set stock=p.stock+i.quantity,is_active=true,updated_at=now()
    from public.order_items i where i.order_id=p_order_id and i.product_id=p.id;
end; $$;
revoke all on function public.cancel_pending_order(uuid) from public,anon,authenticated;
grant execute on function public.cancel_pending_order(uuid) to service_role;

create or replace function public.toggle_post_like(p_post_id uuid) returns integer
language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_count integer;
begin
  if v_user is null then raise exception 'Sign in to react'; end if;
  if exists(select 1 from public.community_likes where post_id=p_post_id and user_id=v_user) then
    delete from public.community_likes where post_id=p_post_id and user_id=v_user;
    update public.community_posts set likes_count=greatest(0,likes_count-1) where id=p_post_id;
  else
    insert into public.community_likes(post_id,user_id) values(p_post_id,v_user) on conflict do nothing;
    update public.community_posts set likes_count=likes_count+1 where id=p_post_id;
  end if;
  select likes_count into v_count from public.community_posts where id=p_post_id;
  return v_count;
end; $$;
grant execute on function public.toggle_post_like(uuid) to authenticated;

-- No client write policies or grants for orders, order_items, payments, payouts.
-- Configure an admin-only server function to review shops. Verify provider
-- webhook signatures, idempotency keys, order totals, stock and seller eligibility
-- before any production payment is enabled. Never expose the service-role key.
