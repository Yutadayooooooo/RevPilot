/**
 * レビュー取得“後”の配管を検証する（実ストア連携なしで実行可能）。
 *
 * 何を確かめるか:
 *   1) 重複排除     … 同じレビューを2回取り込んでも、新規挿入は1回目だけ（2回目=0件）。
 *   2) 低評価通知   … ★1〜2は notifyLowRating が呼ばれる（LINE/メールが設定済みなら実際に届く）。
 *   3) トピック分類 … ANTHROPIC_API_KEY があればAI分類が走る（--no-ai でスキップ可）。
 *   4) チェックポイント … poll_state に最新レビューIDが記録される。
 *   5) 処理時間     … 取り込み1回あたりのミリ秒。
 *
 * 前提: Web を起動しておく →  npm run dev
 * 実行:
 *   node --env-file=.env.local scripts/test-review-pipeline.mjs
 *   （オプション）--keep でテストデータを残す / --no-ai でAI分類スキップ /
 *                 --email you@example.com で対象ユーザー指定 / --url http://localhost:3000
 *
 * 注意: これは“取得後の配管”のテスト。App Store/Google Play からの実取得と実レイテンシは
 *       各ストアの開発者登録＋実アプリが必要なため、このスクリプトの対象外。
 */

const args = process.argv.slice(2);
const has = (f) => args.includes(f);
const val = (f, d) => {
  const i = args.indexOf(f);
  return i >= 0 && args[i + 1] ? args[i + 1] : d;
};

const BASE = val("--url", process.env.NEXT_PUBLIC_SITE_URL || "http://localhost:3000").replace(/\/$/, "");
const EMAIL = val("--email", process.env.TEST_OWNER_EMAIL || "businessyuta313@gmail.com");
const KEEP = has("--keep");
const SKIP_AI = has("--no-ai");
const SECRET = process.env.CRON_SECRET;

if (!SECRET) {
  console.error("✗ CRON_SECRET が未設定です（.env.local）。`node --env-file=.env.local ...` で実行してください。");
  process.exit(1);
}

// 合成レビュー（App Store と Google Play の両方 × ★1〜5）。
// 実行ごとに一意なIDにして、--keep でも毎回“新規”になるように。
const runId = Date.now();
const bodies = {
  1: "起動するたびに落ちて使い物になりません。返金してほしい。",
  2: "通知が来ないし動作が重い。改善を期待します。",
  3: "普通。可もなく不可もなく。",
  4: "便利です。あと少しUIが良くなれば最高。",
  5: "個人開発のレビュー管理がすごく楽になりました！最高です。",
};
const reviews = [];
for (const store of ["appstore", "googleplay"]) {
  for (const rating of [5, 4, 3, 2, 1]) {
    reviews.push({
      store,
      external_id: `test-${runId}-${store}-r${rating}`,
      rating,
      title: store === "appstore" ? `テストレビュー ★${rating}` : null, // Google Playにtitleは無い
      body: bodies[rating],
      author: `tester_${store}_${rating}`,
      territory: store === "appstore" ? "JPN" : "ja",
      app_version: "1.0.0",
      reviewed_at: new Date().toISOString(),
      raw: { synthetic: true, store },
    });
  }
}
// reviews[0] が最新扱い（チェックポイント検証用）。
const lowCount = reviews.filter((r) => r.rating <= 2).length;
const byStore = `App Store ${reviews.filter((r) => r.store === "appstore").length}件 / Google Play ${reviews.filter((r) => r.store === "googleplay").length}件`;

console.log(`▶ 対象: ${BASE}/api/dev/seed-reviews  user=${EMAIL}`);
console.log(`  合成レビュー: ${reviews.length}件（${byStore}／★1〜2=${lowCount}）`);
if (SKIP_AI) console.log("  （AI分類はスキップ）");

let res, json;
try {
  res = await fetch(`${BASE}/api/dev/seed-reviews`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-cron-secret": SECRET },
    body: JSON.stringify({
      ownerEmail: EMAIL,
      reviews,
      appName: "[TEST] Pipeline",
      cleanup: !KEEP,
      skipAi: SKIP_AI,
    }),
  });
} catch (e) {
  console.error(`✗ 接続失敗: ${e.message}\n  Web(npm run dev)が起動しているか、--url を確認してください。`);
  process.exit(1);
}

try {
  json = await res.json();
} catch {
  console.error(`✗ 応答が不正 (HTTP ${res.status})`);
  process.exit(1);
}
if (!res.ok) {
  console.error(`✗ サーバーエラー (HTTP ${res.status}): ${json.error ?? JSON.stringify(json)}`);
  process.exit(1);
}

// ---- 結果とアサーション ----
const checks = [];
const check = (name, ok, detail) => {
  checks.push(ok);
  console.log(`${ok ? "✅" : "❌"} ${name}${detail ? ` — ${detail}` : ""}`);
};

console.log("\n=== 結果 ===");
check(
  "重複排除: 1回目は全件新規",
  json.firstRun.inserted === reviews.length,
  `1回目=${json.firstRun.inserted}件 / 期待=${reviews.length}件`
);
check(
  "重複排除: 2回目は0件（再取得しても重複しない）",
  json.secondRun.inserted === 0,
  `2回目=${json.secondRun.inserted}件`
);
check(
  "チェックポイント: 最新レビューIDを記録",
  json.checkpoint?.last_seen_external_id === reviews[0].external_id,
  `${json.checkpoint?.last_seen_external_id ?? "なし"}`
);
console.log(`ℹ 低評価通知: ★1〜2 が ${json.lowRatingCount} 件 → 1回目に notifyLowRating を実行`);
console.log("   （LINE/メールが設定済みなら実際に届きます。届かない=そのチャネル未設定 or 宛先未設定）");
console.log(`ℹ 処理時間: 1回目 ${json.firstRun.ms}ms / 2回目 ${json.secondRun.ms}ms（=③取得後の処理秒数）`);
console.log(`ℹ DB内レビュー件数(このテストアプリ): ${json.reviewCountInDb}`);
console.log(`ℹ テストデータ: ${json.cleaned ? "削除済み" : "保持（--keep）appId=" + json.appId}`);

const passed = checks.every(Boolean);
console.log(`\n${passed ? "🟢 PASS" : "🔴 FAIL"} — 配管（重複排除/通知/チェックポイント）${passed ? "は正常です" : "に問題あり"}`);
process.exit(passed ? 0 : 1);
