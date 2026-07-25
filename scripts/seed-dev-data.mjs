// 開発用ダミーデータ投入スクリプト。
// .env.local の service_role キーを使い、RLSをバイパスして自分のアカウントに
// アプリ/レビュー/返信/トピックを投入する。再実行しても external_id で冪等。
//
//   node scripts/seed-dev-data.mjs            # 既定アカウントに投入
//   TARGET_EMAIL=you@example.com node scripts/seed-dev-data.mjs
//   node scripts/seed-dev-data.mjs --clean    # 投入したダミーを削除
//
import { readFileSync } from "node:fs";
import { createClient } from "@supabase/supabase-js";

// --- .env.local 読み込み（秘密鍵は出力しない） ---
const env = readFileSync(new URL("../.env.local", import.meta.url), "utf8");
const get = (k) => (env.match(new RegExp("^" + k + "=(.*)$", "m")) || [])[1]?.trim() || "";
const URL_ = get("NEXT_PUBLIC_SUPABASE_URL") || get("SUPABASE_URL");
const SERVICE = get("SUPABASE_SERVICE_ROLE_KEY");
if (!URL_ || !SERVICE || SERVICE.includes("PASTE")) {
  console.error("SupabaseのURL/service_roleキーが .env.local にありません。");
  process.exit(1);
}
const db = createClient(URL_, SERVICE, { auth: { persistSession: false } });
const CLEAN = process.argv.includes("--clean");
const SEED_PREFIX = "seed-"; // このプレフィックスの external_id をダミーとして管理
const ANN_ID = "00000000-0000-0000-0000-0000000000a1"; // サンプルお知らせの固定ID（冪等用）

// --- 対象ユーザーの解決 ---
const targetEmail = process.env.TARGET_EMAIL || "";
const { data: list, error: uErr } = await db.auth.admin.listUsers({ perPage: 200 });
if (uErr) { console.error("ユーザー取得失敗:", uErr.message); process.exit(1); }
const users = list.users || [];
if (users.length === 0) {
  console.error("ユーザーが存在しません。先にアプリ/Webでサインアップしてください。");
  process.exit(1);
}
const owner = (targetEmail && users.find((u) => u.email === targetEmail)) || users[0];
console.log(`対象アカウント: ${owner.email} (${owner.id})`);

await db.from("profiles").upsert({ id: owner.id, email: owner.email }, { onConflict: "id" });

// --- アプリ定義（App Store 3件 / Google Play 3件） ---
const APPS = [
  { key: "ios1", store: "appstore", store_app_id: "6480001111", name: "FocusFlow – 集中タイマー",
    description: "ポモドーロ式の集中タイマー。作業と休憩を自動で回し記録をグラフ化。", reply_tone: "polite", count: 9 },
  { key: "ios2", store: "appstore", store_app_id: "6480002222", name: "MoneyMint – 家計簿",
    description: "レシート読み取りに対応したシンプルな家計簿アプリ。", reply_tone: "polite", count: 6 },
  { key: "ios3", store: "appstore", store_app_id: "6480003333", name: "AquaLog – 水分記録",
    description: "1日の水分摂取をワンタップで記録しリマインドする健康アプリ。", reply_tone: "casual", count: 4 },
  { key: "and1", store: "googleplay", store_app_id: "com.revpilot.focusflow", name: "FocusFlow (Android)",
    description: "ポモドーロ式の集中タイマー。作業と休憩を自動で回し記録をグラフ化。", reply_tone: "casual", count: 8 },
  { key: "and2", store: "googleplay", store_app_id: "com.revpilot.moneymint", name: "MoneyMint (Android)",
    description: "レシート読み取りに対応したシンプルな家計簿アプリ。", reply_tone: "polite", count: 5 },
  { key: "and3", store: "googleplay", store_app_id: "com.revpilot.habitgrid", name: "HabitGrid – 習慣化",
    description: "習慣をマス目で可視化して継続を後押しするトラッカー。", reply_tone: "apologetic", count: 7 },
];

if (CLEAN) {
  const { data: del } = await db.from("reviews").delete().like("external_id", `${SEED_PREFIX}%`).select("id");
  await db.from("apps").delete().eq("owner", owner.id).in("store_app_id", APPS.map((a) => a.store_app_id)).select("id");
  try { await db.from("announcements").delete().eq("id", ANN_ID); } catch (_) {}
  console.log(`削除完了: レビュー ${del?.length ?? 0} 件とダミーアプリ ${APPS.length} 件。`);
  process.exit(0);
}

// --- アプリ upsert ---
for (const a of APPS) {
  const { data, error } = await db.from("apps")
    .upsert({ owner: owner.id, store: a.store, store_app_id: a.store_app_id, name: a.name,
      description: a.description, reply_tone: a.reply_tone },
      { onConflict: "owner,store,store_app_id" })
    .select("id").single();
  if (error) { console.error("アプリ投入失敗:", error.message); process.exit(1); }
  a.id = data.id;
}
console.log(`アプリを${APPS.length}件用意しました。`);

// --- レビュー素材（アプリ非依存の汎用テンプレ・星ごとに現実的） ---
const daysAgo = (d) => new Date(Date.now() - d * 86400000).toISOString();
// [rating, title, body, author, territory, version, topics, daysAgo, reply?]
const POOL = [
  [5, "毎日使ってます", "動作が軽くて使いやすいです。無駄な機能がなく気に入っています。", "たかし", "JP", "1.4.0", ["praise","ux"], 1, { body:"うれしいレビューをありがとうございます！", status:"posted" }],
  [5, "Simple and great", "Exactly what I needed. Clean and fast.", "mike_dev", "US", "1.4.0", ["praise"], 2, null],
  [4, "あと一歩", "満足していますが、通知音が小さいので大きくできると助かります。", "みか", "JP", "1.4.0", ["feature_request","ux"], 3, { body:"ご要望ありがとうございます。次回アップデートで調整します。", status:"draft" }],
  [2, "落ちる", "最新OSにしてから起動直後に落ちることが増えました。修正お願いします。", "user_918", "JP", "1.3.2", ["bug"], 4, null],
  [1, "同期されない", "有料版を買ったのに別端末で反映されません。問い合わせにも返信がなく残念です。", "koki", "JP", "1.3.2", ["bug","price"], 5, null],
  [3, "まあまあ", "悪くないですが、統計がもう少し詳しく見られると嬉しいです。", "n.saito", "JP", "1.4.0", ["feature_request"], 6, null],
  [5, "Love it", "Keeps me motivated every day. Would love a widget though!", "sara.k", "US", "1.4.0", ["praise","feature_request"], 7, null],
  [4, "続けられてる", "3週間続いています。迷わず始められるのが良いです。", "yuu", "JP", "1.4.0", ["praise","ux"], 8, { body:"継続いただきありがとうございます！", status:"posted" }],
  [2, "広告が多い", "無料版の広告頻度が高すぎます。せめて頻度を下げてほしい。", "anon", "JP", "1.3.2", ["ux","price"], 9, null],
  [5, "ちょうどいい", "余計な機能がなくて逆に良いです。安心して使えます。", "haru", "JP", "1.4.0", ["praise"], 11, null],
  [3, "Crashes sometimes", "Great concept but it crashed twice on my device.", "droiduser", "US", "2.1.0", ["bug"], 12, null],
  [4, "ダークモード希望", "使いやすいです。目に優しいダークテーマがあると夜も快適です。", "mei", "JP", "1.4.0", ["feature_request","ux"], 13, null],
  [1, "起動しない", "アップデート後に真っ白な画面で止まります。再インストールしても直りません。", "t_okada", "JP", "1.4.0", ["bug"], 14, null],
  [5, "Recommended", "Been using it for a month. Does one thing well.", "chris", "GB", "2.1.0", ["praise"], 16, null],
  [4, "コスパ良い", "有料版でも安く機能十分。あとはウォッチ対応があれば完璧。", "ren", "JP", "1.4.0", ["price","feature_request"], 18, { body:"ありがとうございます。ウォッチ対応も検討します！", status:"draft" }],
  [2, "使い方が分かりにくい", "初回の設定でつまずきました。チュートリアルがほしいです。", "pat_l", "US", "2.1.0", ["ux"], 20, null],
  [3, "普通", "特に不満はないですが特別すごくもないです。", "sho", "JP", "1.4.0", ["other"], 22, null],
  [5, "助かってます", "在宅の相棒です。習慣化に役立っています。", "aya", "JP", "1.4.0", ["praise","ux"], 25, null],
  [1, "返金したい", "説明と違い、記録が保存されませんでした。がっかりです。", "kenji", "JP", "1.3.2", ["bug","price"], 30, null],
  [4, "Nice UI", "Beautiful and minimal. A monthly summary would be great.", "jenn", "US", "2.1.0", ["ux","feature_request"], 27, null],
];

let offset = 0, reviewCount = 0, replyCount = 0, topicCount = 0;
for (const a of APPS) {
  for (let i = 0; i < a.count; i++) {
    const t = POOL[(offset + i) % POOL.length];
    const [rating, title, body, author, territory, version, topics, dAgo, reply] = t;
    const external_id = `${SEED_PREFIX}${a.store}-${a.key}-${i + 1}`;

    const { data: rev, error } = await db.from("reviews").upsert({
      app_id: a.id, store: a.store, external_id, rating, title, body, author,
      territory, app_version: version, reviewed_at: daysAgo(dAgo + i * 0.13),
      raw: { seeded: true },
    }, { onConflict: "store,external_id" }).select("id").single();
    if (error) { console.error("レビュー投入失敗:", error.message); process.exit(1); }
    reviewCount++;

    await db.from("review_topics").delete().eq("review_id", rev.id);
    if (topics?.length) {
      await db.from("review_topics").insert(topics.map((tp) => ({ review_id: rev.id, topic: tp })));
      topicCount += topics.length;
    }

    await db.from("replies").delete().eq("review_id", rev.id);
    if (reply) {
      await db.from("replies").insert({
        review_id: rev.id, body: reply.body, status: reply.status, source: "ai",
        posted_at: reply.status === "posted" ? daysAgo(dAgo) : null,
      });
      replyCount++;
    }
  }
  offset += a.count + 2; // アプリごとに分布をずらす
}

console.log(`投入完了: アプリ ${APPS.length} / レビュー ${reviewCount} / 返信 ${replyCount} / トピック ${topicCount}`);

// サンプルお知らせ（announcementsテーブルが未作成なら黙ってスキップ）。
try {
  const { error } = await db.from("announcements").upsert({
    id: ANN_ID,
    title: "RevPilotへようこそ",
    body: "これはサンプルのお知らせです。障害やメンテナンスの告知をここに表示できます。",
    level: "info",
    active: true,
  }, { onConflict: "id" });
  if (!error) console.log("サンプルお知らせを1件投入しました。");
  else console.log("お知らせは未投入（announcementsテーブル未作成の可能性）。");
} catch (_) {
  console.log("お知らせは未投入（announcementsテーブル未作成の可能性）。");
}

console.log("スマホ版を再読み込み（Pull-to-refresh）すると反映されます。");
process.exit(0);
