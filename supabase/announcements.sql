-- お知らせ機能の追加（既存DBへ後から適用する差分）。
-- Supabase SQL Editor で一度だけ実行する。

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
