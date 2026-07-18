-- RevPilot schema (Supabase / Postgres)
-- Run in Supabase SQL Editor.

create extension if not exists "pgcrypto";

-- ユーザー（Supabase Authのuser.idと1:1）
create table if not exists profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  plan text not null default 'free',          -- free | pro | team
  line_user_id text,
  created_at timestamptz not null default now()
);

-- 監視対象アプリ
create table if not exists apps (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references profiles (id) on delete cascade,
  store text not null check (store in ('appstore','googleplay')),
  store_app_id text not null,                 -- Apple: appId / Google: packageName
  name text not null,
  description text,                            -- AI返信の文脈に使う
  reply_tone text not null default 'polite',  -- polite | casual | apologetic
  created_at timestamptz not null default now(),
  unique (owner, store, store_app_id)
);

-- レビュー本体
create table if not exists reviews (
  id uuid primary key default gen_random_uuid(),
  app_id uuid not null references apps (id) on delete cascade,
  store text not null check (store in ('appstore','googleplay')),
  external_id text not null,                   -- ストア側のレビューID（重複防止）
  rating int not null check (rating between 1 and 5),
  title text,
  body text,
  author text,
  territory text,                              -- 国コード
  app_version text,
  reviewed_at timestamptz,
  raw jsonb,
  created_at timestamptz not null default now(),
  unique (store, external_id)
);

-- 星・未読でのフィルタを速くする
create index if not exists idx_reviews_app_rating on reviews (app_id, rating);
create index if not exists idx_reviews_reviewed_at on reviews (reviewed_at desc);

-- 返信（ドラフト & 送信済み）
create table if not exists replies (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references reviews (id) on delete cascade,
  body text not null,
  status text not null default 'draft',        -- draft | posted | copied
  source text not null default 'ai',           -- ai | manual
  posted_at timestamptz,
  created_at timestamptz not null default now()
);

-- AIトピック分類（1レビュー複数トピック可）
create table if not exists review_topics (
  review_id uuid not null references reviews (id) on delete cascade,
  topic text not null,                         -- bug | feature_request | ux | price | praise | other
  primary key (review_id, topic)
);

-- ポーリングのチェックポイント（Google Playの7日制限対策）
create table if not exists poll_state (
  app_id uuid primary key references apps (id) on delete cascade,
  last_seen_external_id text,
  last_polled_at timestamptz
);

-- RLS（本人のデータのみ）。service_roleはRLSをバイパスするのでcronは影響なし。
alter table profiles enable row level security;
alter table apps enable row level security;
alter table reviews enable row level security;
alter table replies enable row level security;

create policy "own profile" on profiles
  for all using (auth.uid() = id) with check (auth.uid() = id);

create policy "own apps" on apps
  for all using (auth.uid() = owner) with check (auth.uid() = owner);

create policy "own reviews" on reviews
  for select using (
    exists (select 1 from apps a where a.id = reviews.app_id and a.owner = auth.uid())
  );

create policy "own replies" on replies
  for all using (
    exists (
      select 1 from reviews r join apps a on a.id = r.app_id
      where r.id = replies.review_id and a.owner = auth.uid()
    )
  );

-- 新規サインアップ時に profiles 行を自動作成（apps.owner のFK先を用意）
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
