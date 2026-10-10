-- 【このファイルは不要になりました】
--
-- announcements テーブルとポリシーは supabase/schema.sql に統合済みです。
-- schema.sql は何度実行しても安全（冪等）なので、そちらを実行してください。
--
--   Supabase SQL Editor で supabase/schema.sql を貼り付けて実行
--
-- 内容は互換のために残してありますが、schema.sql を実行していれば適用は不要です。

create table if not exists announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  level text not null default 'info',          -- info | warning | critical
  active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now()
);

alter table announcements enable row level security;

drop policy if exists "read active announcements" on announcements;
create policy "read active announcements" on announcements
  for select using (
    active = true
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at >= now())
  );
