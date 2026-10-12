#!/usr/bin/env node
/**
 * shared/plans.json から Flutter 用の mobile/lib/plan_catalog.g.dart を生成する。
 *
 *   npm run gen:plans     … 生成して上書き
 *   npm run check:plans   … 生成結果と既存ファイルが一致するか確認（ズレていれば exit 1）
 *
 * プラン定義（名前・価格・特徴・上限・ストア商品ID）は JSON だけを編集し、
 * Dart 側を手で直さないこと。
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "shared/plans.json");
const out = join(root, "mobile/lib/plan_catalog.g.dart");

const catalog = JSON.parse(readFileSync(src, "utf8"));

const str = (s) => `'${String(s).replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/\$/g, "\\$")}'`;
const opt = (v) => (v === null || v === undefined ? "null" : String(v));
const price = (p) =>
  p ? `PlanPrice(yen: ${p.yen}, productId: ${p.productId ? str(p.productId) : "null"})` : "null";

const plans = catalog.plans
  .map((p) => {
    const l = p.limits;
    return `  PlanDef(
    key: ${str(p.key)},
    name: ${str(p.name)},
    tagline: ${str(p.tagline)},
    features: [${p.features.map(str).join(", ")}],
    popular: ${Boolean(p.popular)},
    hidden: ${Boolean(p.hidden)},
    trialLabel: ${p.trialLabel ? str(p.trialLabel) : "null"},
    monthly: ${price(p.prices?.monthly)},
    yearly: ${price(p.prices?.yearly)},
    limits: PlanLimits(
      maxApps: ${opt(l.maxApps)},
      historyDays: ${opt(l.historyDays)},
      aiUnitsPerMonth: ${l.aiUnitsPerMonth},
      bulkReplyLimit: ${l.bulkReplyLimit},
      topicAnalysis: ${l.topicAnalysis},
      weeklySummary: ${l.weeklySummary},
    ),
  ),`;
  })
  .join("\n");

const dart = `// GENERATED CODE - DO NOT EDIT.
// shared/plans.json から scripts/gen-plans.mjs で生成（npm run gen:plans）。

class PlanPrice {
  /// 税込の円（ストアの価格が取れないときの表示用）。
  final int yen;

  /// App Store / Google Play 共通の商品ID。未販売なら null。
  final String? productId;

  const PlanPrice({required this.yen, required this.productId});
}

class PlanLimits {
  /// null = 無制限
  final int? maxApps;

  /// null = 無期限
  final int? historyDays;
  final int aiUnitsPerMonth;

  /// 1 = 一括不可
  final int bulkReplyLimit;
  final bool topicAnalysis;
  final bool weeklySummary;

  const PlanLimits({
    required this.maxApps,
    required this.historyDays,
    required this.aiUnitsPerMonth,
    required this.bulkReplyLimit,
    required this.topicAnalysis,
    required this.weeklySummary,
  });
}

class PlanDef {
  final String key;
  final String name;
  final String tagline;
  final List<String> features;
  final bool popular;
  final bool hidden;

  /// 初回購入時の無料トライアルの期間の表示（例: 1か月）。ストアのオファーと一致させる。
  final String? trialLabel;
  final PlanPrice? monthly;
  final PlanPrice? yearly;
  final PlanLimits limits;

  const PlanDef({
    required this.key,
    required this.name,
    required this.tagline,
    required this.features,
    required this.popular,
    required this.hidden,
    required this.trialLabel,
    required this.monthly,
    required this.yearly,
    required this.limits,
  });
}

const List<PlanDef> planCatalog = [
${plans}
];
`;

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(out, "utf8");
  } catch {}
  if (current !== dart) {
    console.error("mobile/lib/plan_catalog.g.dart が shared/plans.json と一致しません。npm run gen:plans を実行してください。");
    process.exit(1);
  }
  console.log("plan_catalog.g.dart is up to date.");
} else {
  writeFileSync(out, dart);
  console.log(`wrote ${out}`);
}
