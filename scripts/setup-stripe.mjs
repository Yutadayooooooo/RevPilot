// Stripe（テストモード）の商品・価格をセットアップする開発用スクリプト。
//
// あなたが .env.local に STRIPE_SECRET_KEY=sk_test_... を貼ってから実行すると、
// RevPilot の Pro/Max/Team の Product と月額 Price を作成（既にあれば再利用）し、
// STRIPE_PRICE_PRO / MAX / TEAM を .env.local に自動で書き込みます。
//
//   node scripts/setup-stripe.mjs
//
// 安全のためテストキー(sk_test_)のみ許可。本番キーでは実行を中止します。
// 課金や送金は一切行いません（作成するのは商品と価格の定義のみ）。
//
import { readFileSync, writeFileSync } from "node:fs";
import Stripe from "stripe";

const ENV_PATH = new URL("../.env.local", import.meta.url);

// --- .env.local 読み込み（値は出力しない） ---
let envText = "";
try {
  envText = readFileSync(ENV_PATH, "utf8");
} catch {
  console.error("✖ .env.local が見つかりません。プロジェクト直下に用意してください。");
  process.exit(1);
}
const get = (k) => (envText.match(new RegExp("^" + k + "=(.*)$", "m")) || [])[1]?.trim() || "";

const SECRET = get("STRIPE_SECRET_KEY");
if (!SECRET || SECRET.includes("PASTE")) {
  console.error(
    "✖ STRIPE_SECRET_KEY が .env.local にありません。\n" +
      "  Stripeダッシュボード（テストモード）> 開発者 > APIキー の\n" +
      "  『シークレットキー』(sk_test_...) を .env.local に貼って再実行してください。"
  );
  process.exit(1);
}
if (!SECRET.startsWith("sk_test_")) {
  console.error(
    "✖ 安全のためテストキー(sk_test_...)のみ許可しています。\n" +
      "  現在のキーはテストキーではないため中止しました（本番商品を誤作成しないため）。"
  );
  process.exit(1);
}

const stripe = new Stripe(SECRET);

// lib/stripe.ts と一致させる。JPY はゼロ小数通貨なので unit_amount は円そのまま。
const PLANS = [
  { key: "pro", name: "RevPilot Pro", amount: 1480, env: "STRIPE_PRICE_PRO" },
  { key: "max", name: "RevPilot Max", amount: 2980, env: "STRIPE_PRICE_MAX" },
  { key: "team", name: "RevPilot Team", amount: 5800, env: "STRIPE_PRICE_TEAM" },
];

/** metadata.revpilot_plan で既存商品を探す。無ければ作成。 */
async function ensureProduct(plan) {
  const found = await stripe.products.search({
    query: `active:'true' AND metadata['revpilot_plan']:'${plan.key}'`,
  });
  if (found.data[0]) return found.data[0];
  return stripe.products.create({
    name: plan.name,
    metadata: { revpilot_plan: plan.key },
  });
}

/** 商品配下に、同額・月額・JPY の有効な価格があれば再利用。無ければ作成。 */
async function ensurePrice(product, plan) {
  const prices = await stripe.prices.list({ product: product.id, active: true, limit: 100 });
  const match = prices.data.find(
    (p) =>
      p.currency === "jpy" &&
      p.unit_amount === plan.amount &&
      p.recurring?.interval === "month"
  );
  if (match) return match;
  return stripe.prices.create({
    product: product.id,
    currency: "jpy",
    unit_amount: plan.amount,
    recurring: { interval: "month" },
  });
}

/** .env.local の KEY=... を置換、無ければ追記（他行は保持）。 */
function upsertEnv(text, key, value) {
  const line = `${key}=${value}`;
  const re = new RegExp("^" + key + "=.*$", "m");
  if (re.test(text)) return text.replace(re, line);
  return (text.endsWith("\n") || text === "" ? text : text + "\n") + line + "\n";
}

console.log("▶ Stripe テストモードで RevPilot の商品・価格をセットアップします…\n");

const results = [];
for (const plan of PLANS) {
  const product = await ensureProduct(plan);
  const price = await ensurePrice(product, plan);
  results.push({ plan, product, price });
  console.log(
    `  ✓ ${plan.name.padEnd(14)} product=${product.id}  price=${price.id}  ¥${plan.amount}/月`
  );
}

// price ID を .env.local に反映（シークレットは触らない）
let next = envText;
for (const { plan, price } of results) {
  next = upsertEnv(next, plan.env, price.id);
}
if (next !== envText) {
  writeFileSync(ENV_PATH, next);
  console.log("\n✓ .env.local に STRIPE_PRICE_PRO / MAX / TEAM を書き込みました。");
} else {
  console.log("\n= .env.local は既に最新でした（変更なし）。");
}

console.log(
  "\n次のステップ:\n" +
    "  1) 開発サーバーを起動:  npm run dev\n" +
    "  2) （任意）webhookをローカル転送してプラン自動反映を試す:\n" +
    "       stripe listen --forward-to localhost:3000/api/billing/webhook\n" +
    "     表示される whsec_... を .env.local の STRIPE_WEBHOOK_SECRET に設定\n" +
    "  3) アプリからプラン変更 → テストカード 4242 4242 4242 4242 で決済\n"
);
