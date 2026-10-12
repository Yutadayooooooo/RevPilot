-- RevPilot schema (Supabase / Postgres)
-- Supabase SQL Editor で実行する。何度実行しても安全（冪等）。
--
-- 【設計の原則】
--   1. クライアント(anon key + ユーザーJWT)は「自分のデータを読む」ことしかできない。
--      課金・使用量・取得状態など、サーバーが真実を持つべき列はクライアントから書けない。
--   2. 金銭に直結する制限（プラン・AI使用量・アプリ数）はDB側で強制する。
--      アプリ層のチェックだけだと、REST APIを直接叩かれた時点で無意味になるため。

create extension if not exists "pgcrypto";

-- ============================================================
-- テーブル
-- ============================================================

-- ユーザー（Supabase Authのuser.idと1:1）
create table if not exists profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  plan text not null default 'free',          -- free | pro | max | team
  -- 廃止: LINE通知は利用者が自分のuserIdを知る手段が無く実用にならなかったため撤去。
  -- 既存データを壊さないよう列だけ残してある（新規の書き込みはしない）。
  line_user_id text,
  created_at timestamptz not null default now()
);

-- 通知先（Slack/Discord の Incoming Webhook URL）。LINEは廃止（利用者がuserIdを知る手段がないため）。
alter table profiles add column if not exists notify_webhook_url text;

-- Stripe課金（既存DBへの再実行でも安全に追加）
alter table profiles add column if not exists stripe_customer_id text;
alter table profiles add column if not exists stripe_subscription_id text;
alter table profiles add column if not exists plan_status text;       -- Stripeのsubscription.status
alter table profiles add column if not exists current_period_end timestamptz;
create index if not exists idx_profiles_stripe_customer on profiles (stripe_customer_id);

-- 週次サマリーの送信済み時刻。
-- cronが時間内に全員を処理しきれなくても、次回の実行で「まだ送っていない人」から
-- 再開できるようにするための印（以前は打ち切られた後ろの利用者に永久に届かなかった）。
alter table profiles add column if not exists weekly_summary_sent_at timestamptz;

-- Apple IAP（購入の同一性・失効の判定に使う）
alter table profiles add column if not exists apple_original_transaction_id text;
alter table profiles add column if not exists apple_expires_at timestamptz;
create index if not exists idx_profiles_apple_otid on profiles (apple_original_transaction_id);

-- Google Play Billing（同上）。purchaseToken が購入の同一性の鍵になる。
alter table profiles add column if not exists google_purchase_token text;
alter table profiles add column if not exists google_expires_at timestamptz;
create index if not exists idx_profiles_google_token on profiles (google_purchase_token);

-- リモートpush(FCM)の通知対象。モバイルの通知設定と同じ選択肢を持つ。
--   all : すべての新着レビュー（既定） / low : ★1〜2のみ / off : 送らない
-- 端末側の設定(SharedPreferences)だけではサーバーが知り得ないため、profiles に持つ。
-- （設定を「★1〜2のみ」にしている人に全部pushするのは、通知としては壊れている）
alter table profiles add column if not exists push_scope text not null default 'all';
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'profiles'::regclass and conname = 'profiles_push_scope_check'
  ) then
    alter table profiles
      add constraint profiles_push_scope_check check (push_scope in ('all','low','off'));
  end if;
end $$;

-- ストア認証情報（オーナー×ストアで1組。data_encryptedはAES-256-GCMで暗号化済み）
create table if not exists store_credentials (
  owner uuid not null references profiles (id) on delete cascade,
  store text not null check (store in ('appstore','googleplay')),
  data_encrypted text not null,               -- lib/crypto.ts で暗号化した文字列
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (owner, store)
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

-- 取得の健康状態。連携が壊れていることをユーザー自身が気づけるようにする
-- （サーバーがservice_roleで書き、オーナーは読むだけ）。
alter table apps add column if not exists last_polled_at timestamptz;
alter table apps add column if not exists last_error text;
alter table apps add column if not exists last_error_at timestamptz;

-- 返信スタイル（AI返信に統一感を持たせるための、アプリごとの決まりごと）。
--   reply_opening : 冒頭の挨拶（例: 「〇〇をご利用いただきありがとうございます。」）
--   reply_closing : 結び・署名（例: 「〇〇開発チーム」）
--   reply_rules   : 必ず守ること（問い合わせ先・使わない言葉など）
-- どれも任意。空ならこれまでどおりトーンとアプリ概要だけで書く。
alter table apps add column if not exists reply_opening text;
alter table apps add column if not exists reply_closing text;
alter table apps add column if not exists reply_rules text;

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
  created_at timestamptz not null default now()
);

-- 一意制約は「アプリ単位」でなければならない。
-- (store, external_id) だけだと、同じアプリを2アカウントが監視したとき
-- 後から取り込んだ側のupsertが黙って0件になり、永久にレビューが表示されない。
do $$
begin
  if exists (
    select 1 from pg_constraint
    where conrelid = 'reviews'::regclass and conname = 'reviews_store_external_id_key'
  ) then
    alter table reviews drop constraint reviews_store_external_id_key;
  end if;
end $$;
create unique index if not exists uq_reviews_app_store_external
  on reviews (app_id, store, external_id);

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
create index if not exists idx_replies_review on replies (review_id);

-- AIトピック分類（1レビュー複数トピック可）
create table if not exists review_topics (
  review_id uuid not null references reviews (id) on delete cascade,
  topic text not null,                         -- bug | feature_request | ux | price | praise | other
  primary key (review_id, topic)
);

-- 運営からのお知らせ（障害/メンテ告知など）。全ユーザーに表示する。
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

-- ポーリングのチェックポイント（Google Playの7日制限対策）
create table if not exists poll_state (
  app_id uuid primary key references apps (id) on delete cascade,
  last_seen_external_id text,
  last_polled_at timestamptz
);

-- ============================================================
-- リモートpush（FCM）の宛先
-- ============================================================
-- アプリを完全終了していても通知を届けるための端末トークン。
-- 1端末＝1行。token は端末ごとに一意なので、機種変更や再インストールで
-- 新しい行が増える（古い行は送信失敗を検知した時点で削除する）。
--
-- 【所有者の付け替え】同じ端末で別アカウントにログインし直すと、
-- 同じ token が別の user_id で登録される。on conflict (token) で
-- 後から登録した方を正とする（＝前の利用者の通知が届かなくなる）。
-- これを許さないと、譲渡・共用端末で他人のレビューが通知され続ける。
create table if not exists device_tokens (
  token text primary key,
  user_id uuid not null references profiles (id) on delete cascade,
  platform text not null check (platform in ('ios','android')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_device_tokens_user on device_tokens (user_id);

-- ============================================================
-- AI使用量（原価の上限）
-- ============================================================
-- 「repliesの行数を数える」方式は使えない。理由:
--   1. ユーザーがrepliesを削除すればカウンタが0に戻り、無限に生成できてしまう。
--   2. カウント→生成→挿入の間に競合があり、並列リクエストが全て上限を通過する。
-- そのため使用量を独立したテーブルに持ち、consume_ai_units() で
-- 「生成する前に原子的に予約する」方式にする。
--
-- units は課金単位（lib/plan.ts の AI_UNITS と一致させること）:
--   返信生成    = 10 units (≈ ¥1.4)
--   トピック分類 =  2 units (≈ ¥0.3)
create table if not exists ai_usage (
  user_id uuid not null references profiles (id) on delete cascade,
  ym text not null,                            -- 'YYYY-MM'（UTC基準）
  units int not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, ym)
);

-- ============================================================
-- レート制限（関数実行時間・外部APIの保護）
-- ============================================================
create table if not exists rate_limits (
  user_id uuid not null references profiles (id) on delete cascade,
  bucket text not null,                        -- 'poll' | 'reply' など
  window_start timestamptz not null,
  count int not null default 0,
  primary key (user_id, bucket)
);

-- ============================================================
-- 関数
-- ============================================================

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

-- プラン別のアプリ数上限をDB側で強制する。
-- アプリ層(app/api/apps)だけのチェックだと、クライアントがPostgRESTへ直接
-- insertした時点で回避できてしまうため。lib/plan.ts の maxApps と一致させること。
--
-- 有料プランはアプリ数無制限。アプリ数は原価にほぼ影響せず（取得にAI原価はかからない）、
-- 分類の原価は ai_usage の枠で頭打ちになるため、無制限にしても損失は増えない。
create or replace function public.enforce_app_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_plan text;
  v_max int;
  v_count int;
begin
  select plan into v_plan from profiles where id = new.owner;
  if coalesce(v_plan, 'free') in ('pro', 'max', 'team') then
    return new;  -- 無制限
  end if;
  v_max := 1;    -- free
  select count(*) into v_count from apps where owner = new.owner;
  if v_count >= v_max then
    raise exception '現在のプランでは連携できるアプリは % 件までです。', v_max
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

-- プランごとのレビュー履歴の閲覧範囲（日数）。null = 無期限。
-- lib/plan.ts の PLAN_LIMITS.historyDays と一致させること。
create or replace function public.plan_history_days(p_plan text)
returns int language sql immutable set search_path = public as $$
  select case when coalesce(p_plan, 'free') in ('pro','max','team') then null::int else 30 end;
$$;

drop trigger if exists trg_apps_enforce_limit on apps;
create trigger trg_apps_enforce_limit
  before insert on apps
  for each row execute function public.enforce_app_limit();

-- AI使用量を「生成する前に」原子的に予約する。
-- @return 予約後の累計units。上限を超えて予約できない場合は -1。
create or replace function public.consume_ai_units(p_user uuid, p_units int, p_limit int)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_ym text := to_char(timezone('utc', now()), 'YYYY-MM');
  v_units int;
begin
  if p_units is null or p_units <= 0 then
    return 0;
  end if;
  -- 1回の要求が上限そのものを超えるなら、既存の消費に関わらず不可。
  if p_limit is not null and p_units > p_limit then
    return -1;
  end if;

  insert into ai_usage as u (user_id, ym, units)
  values (p_user, v_ym, p_units)
  on conflict (user_id, ym) do update
    set units = u.units + p_units,
        updated_at = now()
    where p_limit is null or u.units + p_units <= p_limit
  returning u.units into v_units;

  -- ON CONFLICT の WHERE を満たさなかった = 上限超過（行は返らない）
  if v_units is null then
    return -1;
  end if;
  return v_units;
end;
$$;

-- 予約したが生成に失敗したぶんを戻す（ユーザーがエラーで枠を失わないように）。
create or replace function public.refund_ai_units(p_user uuid, p_units int)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_ym text := to_char(timezone('utc', now()), 'YYYY-MM');
begin
  update ai_usage
     set units = greatest(0, units - p_units), updated_at = now()
   where user_id = p_user and ym = v_ym;
end;
$$;

-- 固定窓のレート制限。取得できたら true。
create or replace function public.take_rate_token(
  p_user uuid, p_bucket text, p_window_seconds int, p_max int
)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_now timestamptz := now();
  v_cutoff timestamptz := now() - make_interval(secs => p_window_seconds);
  v_ok boolean;
begin
  insert into rate_limits as r (user_id, bucket, window_start, count)
  values (p_user, p_bucket, v_now, 1)
  on conflict (user_id, bucket) do update
    set count = case when r.window_start < v_cutoff then 1 else r.count + 1 end,
        window_start = case when r.window_start < v_cutoff then v_now else r.window_start end
    where r.window_start < v_cutoff or r.count < p_max
  returning true into v_ok;
  return coalesce(v_ok, false);
end;
$$;

-- 集計はDB側で行う（クライアントに全件を送ってから平均を取ると、
-- LIMITで切られた分だけ数字が静かにずれるため）。
create or replace function public.review_stats(p_owner uuid)
returns table (
  total bigint,
  avg_rating numeric,
  low_count bigint,
  request_count bigint
) language sql stable security definer set search_path = public as $$
  select
    count(*)::bigint,
    round(avg(r.rating)::numeric, 2),
    count(*) filter (where r.rating <= 2)::bigint,
    count(*) filter (
      where exists (
        select 1 from review_topics t
        where t.review_id = r.id and t.topic = 'feature_request'
      )
    )::bigint
  from reviews r
  join apps a on a.id = r.app_id
  where a.owner = p_owner;
$$;

-- 日次の平均評価（分析タブの推移グラフ用）。直近 p_days 日。
create or replace function public.review_daily_avg(p_owner uuid, p_days int default 30)
returns table (day date, avg_rating numeric, n bigint)
language sql stable security definer set search_path = public as $$
  select
    (r.reviewed_at at time zone 'utc')::date as day,
    round(avg(r.rating)::numeric, 2),
    count(*)::bigint
  from reviews r
  join apps a on a.id = r.app_id
  where a.owner = p_owner
    and r.reviewed_at is not null
    and r.reviewed_at >= now() - make_interval(days => p_days)
  group by 1
  order by 1;
$$;

-- Free の「履歴の壁」の向こう側にあるレビューの件数と、ぼかして見せる数件の抜粋。
--
-- RLS で隠しているだけだと、30日より前にしかレビューが無い利用者には
-- 「レビューがありません」と出てしまい、実際は保存されていることが伝わらない。
-- 件数・評価・日付と本文の冒頭だけを返し、全文は返さない（全文はアップグレードで RLS が開く）。
-- auth.uid() で本人に限定するので、クライアントから直接呼べるようにしてある。
create or replace function public.locked_reviews_preview(p_limit int default 3)
returns table (
  hidden_total bigint,
  hidden_low bigint,
  rating int,
  reviewed_at timestamptz,
  app_name text,
  snippet text
) language sql stable security definer set search_path = public as $$
  with me as (
    select plan_history_days(p.plan) as days
    from profiles p
    where p.id = auth.uid()
  ),
  hidden as (
    select r.rating, r.reviewed_at, a.name as app_name,
           left(coalesce(nullif(trim(r.body), ''), r.title, ''), 40) as snippet
    from reviews r
    join apps a on a.id = r.app_id
    cross join me
    where a.owner = auth.uid()
      and me.days is not null
      and r.reviewed_at < now() - make_interval(days => me.days)
  ),
  totals as (
    select count(*)::bigint as n, count(*) filter (where h.rating <= 2)::bigint as low
    from hidden h
  )
  select t.n, t.low, s.rating, s.reviewed_at, s.app_name, s.snippet
  from totals t
  join lateral (
    select * from hidden
    order by reviewed_at desc
    limit least(greatest(coalesce(p_limit, 3), 0), 5)
  ) s on true;
$$;

revoke all on function public.locked_reviews_preview(int) from public, anon;
grant execute on function public.locked_reviews_preview(int) to authenticated;

-- security definer 関数はサーバー(service_role)からのみ呼ぶ。
-- クライアントが直接RPCして枠を払い戻す等ができないよう明示的に剥奪する。
revoke all on function public.consume_ai_units(uuid, int, int) from public, anon, authenticated;
revoke all on function public.refund_ai_units(uuid, int) from public, anon, authenticated;
revoke all on function public.take_rate_token(uuid, text, int, int) from public, anon, authenticated;
revoke all on function public.review_stats(uuid) from public, anon, authenticated;
revoke all on function public.review_daily_avg(uuid, int) from public, anon, authenticated;

-- ============================================================
-- RLS
-- ============================================================
-- service_role はRLSをバイパスするので、サーバー処理(cron/課金/取得)は影響を受けない。

alter table profiles          enable row level security;
alter table store_credentials enable row level security;
alter table apps              enable row level security;
alter table reviews           enable row level security;
alter table replies           enable row level security;
alter table review_topics     enable row level security;
alter table poll_state        enable row level security;
alter table announcements     enable row level security;
alter table ai_usage          enable row level security;
alter table rate_limits       enable row level security;
alter table device_tokens     enable row level security;

-- profiles: 読むだけ。
-- 【重要】かつては `for all` だったため、ユーザーが自分の plan を 'max' に
-- 書き換えるだけで課金を回避できた。書き込みは必ずサーバー(service_role)を通す。
drop policy if exists "own profile" on profiles;
drop policy if exists "read own profile" on profiles;
create policy "read own profile" on profiles
  for select using (auth.uid() = id);

-- store_credentials: クライアントからは一切触らせない（ポリシーを作らない）。
-- 連携状態は GET /api/credentials 経由で取得する。
drop policy if exists "own credentials" on store_credentials;

-- apps: 自分のアプリの読み書き。件数上限は trg_apps_enforce_limit で強制。
drop policy if exists "own apps" on apps;
create policy "own apps" on apps
  for all using (auth.uid() = owner) with check (auth.uid() = owner);

-- reviews: 参照のみ（書き込みは取り込み処理=service_role）。
--
-- 【履歴の壁】Freeは直近30日ぶんだけ見える。
-- クライアント（モバイル）は Supabase に直接クエリするため、UI側のフィルタでは守れない。
-- 課金の主要な壁なので、必ずここ（RLS）で強制する。
-- なお行そのものは削除しない：アップグレードした瞬間に全期間が見えるようにするため。
drop policy if exists "own reviews" on reviews;
create policy "own reviews" on reviews
  for select using (
    exists (
      select 1
      from apps a
      join profiles p on p.id = a.owner
      where a.id = reviews.app_id
        and a.owner = auth.uid()
        and (
          plan_history_days(p.plan) is null
          or reviews.reviewed_at is null          -- 日付不明のものは隠さない
          or reviews.reviewed_at >= now() - make_interval(days => plan_history_days(p.plan))
        )
    )
  );

-- replies: 参照と追加のみ。
-- 【重要】DELETE を許すと、AI返信を消してから再生成することで
-- 月次上限を無限に回避できてしまう（現在は ai_usage で計測しているため
-- 直接の抜け道ではないが、履歴の改ざんを防ぐ意味でも書き換えは許可しない）。
drop policy if exists "own replies" on replies;
drop policy if exists "read own replies" on replies;
drop policy if exists "insert own replies" on replies;
create policy "read own replies" on replies
  for select using (
    exists (
      select 1 from reviews r join apps a on a.id = r.app_id
      where r.id = replies.review_id and a.owner = auth.uid()
    )
  );
create policy "insert own replies" on replies
  for insert with check (
    exists (
      select 1 from reviews r join apps a on a.id = r.app_id
      where r.id = replies.review_id and a.owner = auth.uid()
    )
  );

-- トピックはクライアントが reviews に埋め込んで読むため参照だけ許可する。
drop policy if exists "own review topics" on review_topics;
create policy "own review topics" on review_topics
  for select using (
    exists (
      select 1 from reviews r join apps a on a.id = r.app_id
      where r.id = review_topics.review_id and a.owner = auth.uid()
    )
  );

-- AI使用量: 残数表示のために本人だけ読める。書き込みはRPC(service_role)のみ。
drop policy if exists "read own ai usage" on ai_usage;
create policy "read own ai usage" on ai_usage
  for select using (auth.uid() = user_id);

-- device_tokens: ポリシーを作らない = クライアントからは読み書き不可。
-- 登録/解除は POST /api/push/devices（service_role）を通す。
--
-- 【なぜAPI経由にするか】同じ端末で別アカウントにログインし直した場合、
-- 既存行の user_id は前の利用者のままで、RLS越しの upsert では
-- 「見えない行との一意制約違反」になって更新できない。
-- 端末の所有者を後勝ちで付け替えるには service_role が要る。
drop policy if exists "own device tokens" on device_tokens;

-- poll_state / rate_limits: ポリシーを一つも作らない = クライアントからは読み書き不可。
-- （poll_state を書ければ他人のチェックポイントを進めてレビューを恒久的に取りこぼさせられる）
drop policy if exists "own poll state" on poll_state;

-- お知らせ: 有効かつ期間内のものは全員が閲覧可。作成/更新はservice_role（管理者）のみ。
drop policy if exists "read active announcements" on announcements;
create policy "read active announcements" on announcements
  for select using (
    active = true
    and (starts_at is null or starts_at <= now())
    and (ends_at is null or ends_at >= now())
  );

-- ============================================================
-- 権限（GRANT）
-- ============================================================
-- RLSは「行を絞る」だけで、テーブルへのGRANTが無ければそもそも触れない。
-- Supabaseの既定権限に頼らず、意図を明示しておく（読み違いによる事故を防ぐ）。

grant select on ai_usage to authenticated;
revoke insert, update, delete on ai_usage from anon, authenticated;

-- サーバー専用テーブル。クライアントからは一切触らせない。
revoke all on store_credentials from anon, authenticated;
revoke all on poll_state        from anon, authenticated;
revoke all on rate_limits       from anon, authenticated;
revoke all on device_tokens     from anon, authenticated;

-- profiles は参照のみ。plan / stripe_* を書き換えられると課金が意味を失う。
revoke insert, update, delete on profiles from anon, authenticated;
grant select on profiles to authenticated;

-- replies は参照と追加のみ。削除・改ざんはさせない。
revoke update, delete on replies from anon, authenticated;
grant select, insert on replies to authenticated;

-- reviews / review_topics は取り込み処理(service_role)だけが書き込む。
revoke insert, update, delete on reviews       from anon, authenticated;
revoke insert, update, delete on review_topics from anon, authenticated;
grant select on reviews       to authenticated;
grant select on review_topics to authenticated;

grant select, insert, update, delete on apps to authenticated;
grant select on announcements to anon, authenticated;
