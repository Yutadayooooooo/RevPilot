// GENERATED CODE - DO NOT EDIT.
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
  PlanDef(
    key: 'free',
    name: 'Free',
    tagline: 'まず1本のアプリで試す',
    features: ['1アプリ', 'レビュー履歴 30日', 'AI返信 月3件', '自動取得 毎時・新着通知'],
    popular: false,
    hidden: false,
    trialLabel: null,
    monthly: null,
    yearly: null,
    limits: PlanLimits(
      maxApps: 1,
      historyDays: 30,
      aiUnitsPerMonth: 30,
      bulkReplyLimit: 1,
      topicAnalysis: false,
      weeklySummary: false,
    ),
  ),
  PlanDef(
    key: 'pro',
    name: 'Pro',
    tagline: '個人開発者の標準',
    features: ['アプリ数 無制限', 'レビュー履歴 無期限', 'AI返信 月300件', '一括返信 最大20件', 'トピック分析', '週次サマリー'],
    popular: true,
    hidden: false,
    trialLabel: '1か月',
    monthly: PlanPrice(yen: 1480, productId: 'jp.revpilot.app.pro.monthly'),
    yearly: PlanPrice(yen: 14800, productId: 'jp.revpilot.app.pro.yearly'),
    limits: PlanLimits(
      maxApps: null,
      historyDays: null,
      aiUnitsPerMonth: 3000,
      bulkReplyLimit: 20,
      topicAnalysis: true,
      weeklySummary: true,
    ),
  ),
  PlanDef(
    key: 'max',
    name: 'Max',
    tagline: 'レビューが多い・返信量が多い方へ',
    features: ['Pro のすべて', 'AI返信 月1,000件', '一括返信 最大50件', '優先サポート'],
    popular: false,
    hidden: false,
    trialLabel: null,
    monthly: PlanPrice(yen: 2980, productId: 'jp.revpilot.app.max.monthly'),
    yearly: PlanPrice(yen: 29800, productId: 'jp.revpilot.app.max.yearly'),
    limits: PlanLimits(
      maxApps: null,
      historyDays: null,
      aiUnitsPerMonth: 10000,
      bulkReplyLimit: 50,
      topicAnalysis: true,
      weeklySummary: true,
    ),
  ),
  PlanDef(
    key: 'team',
    name: 'Team',
    tagline: 'チームで運用する',
    features: ['Maxの全機能', '複数メンバーで共有', 'メンバー別の権限・履歴', 'まとめて請求'],
    popular: false,
    hidden: true,
    trialLabel: null,
    monthly: PlanPrice(yen: 5800, productId: null),
    yearly: null,
    limits: PlanLimits(
      maxApps: null,
      historyDays: null,
      aiUnitsPerMonth: 20000,
      bulkReplyLimit: 50,
      topicAnalysis: true,
      weeklySummary: true,
    ),
  ),
];
