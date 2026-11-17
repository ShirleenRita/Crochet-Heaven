-- Restore the app's project comments feature with owner-bound RLS.
create table if not exists public.community_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.community_posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists community_comments_post_recent_idx on public.community_comments(post_id, created_at);
alter table public.community_comments enable row level security;
drop policy if exists "Public read comments on published posts" on public.community_comments;
create policy "Public read comments on published posts" on public.community_comments
  for select to anon, authenticated
  using (exists(select 1 from public.community_posts p where p.id=post_id and p.is_published));
drop policy if exists "Signed-in users comment on published posts" on public.community_comments;
create policy "Signed-in users comment on published posts" on public.community_comments
  for insert to authenticated
  with check (user_id=(select auth.uid()) and exists(select 1 from public.community_posts p where p.id=post_id and p.is_published));
grant select on public.community_comments to anon, authenticated;
grant insert on public.community_comments to authenticated;
grant all on public.community_comments to service_role;

-- The event trigger remains installed and postgres-owned; API roles do not need RPC access.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Cover marketplace foreign keys used by joins and deletes.
create index if not exists addresses_user_id_idx on public.addresses(user_id);
create index if not exists community_likes_user_id_idx on public.community_likes(user_id);
create index if not exists community_posts_user_id_idx on public.community_posts(user_id);
create index if not exists disputes_opened_by_idx on public.disputes(opened_by);
create index if not exists disputes_order_id_idx on public.disputes(order_id);
create index if not exists favorites_product_id_idx on public.favorites(product_id);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists order_items_product_id_idx on public.order_items(product_id);
create index if not exists orders_shipping_address_id_idx on public.orders(shipping_address_id);
create index if not exists payments_order_id_idx on public.payments(order_id);
create index if not exists payouts_order_id_idx on public.payouts(order_id);
create index if not exists reviews_buyer_id_idx on public.reviews(buyer_id);
create index if not exists reviews_product_id_idx on public.reviews(product_id);
create index if not exists tutorials_teacher_id_idx on public.tutorials(teacher_id);
