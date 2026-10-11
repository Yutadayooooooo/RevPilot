import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data.dart';
import '../iap.dart';
import '../local_notifications.dart';
import '../plan_catalog.g.dart';
import '../theme.dart';
import '../ui.dart';

/// どの「壁」から課金画面を開いたか。画面上部の見出しをその理由に合わせる。
///
/// 一般論の「Proはおすすめです」より、今まさに困っていることへの答えを先に見せる方が
/// 納得して選んでもらえる（＝購入後の「思っていたのと違う」も減る）。
enum PaywallReason { general, history, bulk, aiQuota, apps }

/// 課金画面へ遷移する。どの画面からでもこれを使う。
Future<void> openPlanScreen(
  BuildContext context, {
  PaywallReason reason = PaywallReason.general,
}) => Navigator.of(
  context,
).push(MaterialPageRoute(builder: (_) => PlanScreen(reason: reason)));

/// Free の上限に当たったエラーなら、課金画面への導線付きで知らせる。
/// それ以外のエラーは通常のスナックバー。
void showErrorWithUpgrade(
  BuildContext context,
  Object error, {
  required PaywallReason reason,
}) {
  if (error is! ApiException || !error.isPlanLimit) {
    showSnack(context, '$error', kind: SnackKind.error);
    return;
  }
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(error.message),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'プランを見る',
          onPressed: () => openPlanScreen(context, reason: reason),
        ),
      ),
    );
}

/// プランの確認・変更。
///
/// 【決済はアプリ内課金のみ】
/// iOS は App Store Review Guideline 3.1.1、Android は Google Play の課金ポリシーにより、
/// アプリ内のデジタルコンテンツのサブスクは各ストアの課金を使う必要があり、
/// 外部の決済ページへ誘導することはできない。
/// 以前は StoreKit の商品取得に失敗したとき Stripe Checkout をアプリ内ブラウザで開く
/// フォールバックがあったが、これは確実にリジェクトされるため撤去した。
/// 商品を取得できない場合は購入導線そのものを出さない。
///
/// 【画面の考え方】
///   - 冒頭で「なぜ必要か」を一文で示す（開いた理由に合わせて文言を変える）。
///   - 年額を初期表示にする。年額は利用者にとって安く、解約の判断が年1回になり継続率も上がる。
///   - 無料トライアルは対象者にだけ見せ、その後いくら・いつ課金されるかをボタン直下に書く
///     （App Store 3.1.2 は請求額を最も目立つ価格表示にすることを求めている）。
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key, this.reason = PaywallReason.general});

  final PaywallReason reason;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  String _plan = 'free';
  int _aiRepliesUsed = 0;
  bool _loading = true;
  String? _busy;
  BillingPeriod _period = BillingPeriod.yearly;

  final IapService _iap = IapService();
  bool _iapReady = false;

  static final _purchasable =
      planCatalog.where((p) => !p.hidden && p.monthly != null).toList();

  @override
  void initState() {
    super.initState();
    _load();
    _initIap();
  }

  @override
  void dispose() {
    _iap.dispose();
    super.dispose();
  }

  Future<void> _initIap() async {
    if (!IapService.platformSupported) return;
    await _iap.init(
      onPurchased: (result) async {
        // 購入/復元が成立 → サーバーがストアに問い合わせて検証し、プランを確定する。
        try {
          final confirmed =
              Platform.isIOS
                  ? await Repo.confirmApplePurchase(
                    productId: result.productId,
                    transactionId: result.transactionId,
                    verificationData: result.verificationData,
                  )
                  : await Repo.confirmGooglePurchase(
                    productId: result.productId,
                    purchaseToken: result.verificationData ?? '',
                  );
          final name = planLabel(confirmed.plan);
          var message = result.restored ? '購入を復元しました。' : '$nameにアップグレードしました。';
          if (confirmed.inTrial && confirmed.expiresAt != null) {
            final end = confirmed.expiresAt!.toLocal();
            if (!result.restored) {
              message =
                  '$nameの無料トライアルを開始しました。'
                  '${DateFormat('M月d日').format(end)}まで無料です。'
                  '終了の2日前にお知らせします。';
            }
            await LocalNotifier.scheduleTrialReminder(
              trialEndsAt: end,
              planName: name,
            ).catchError((_) {});
          }
          if (!mounted) return;
          setState(() {
            _busy = null;
            _plan = confirmed.plan;
          });
          showSnack(context, message, kind: SnackKind.success);
        } catch (e) {
          if (!mounted) return;
          setState(() => _busy = null);
          showSnack(context, 'プランの反映に失敗しました：$e', kind: SnackKind.error);
        }
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _busy = null);
        showSnack(context, message, kind: SnackKind.error);
      },
    );
    if (!mounted) return;
    setState(() {
      _iapReady = _iap.isReady;
      // 年額を販売していない（ストアで未作成）なら月額を初期表示にする。
      if (_iapReady &&
          !_purchasable.any(
            (p) => _iap.hasPeriod(p.key, BillingPeriod.yearly),
          )) {
        _period = BillingPeriod.monthly;
      }
    });
  }

  /// 過去の購入を復元（Apple審査要件。Androidでも機種変更時に必要）。
  Future<void> _restore() async {
    HapticFeedback.lightImpact();
    setState(() => _busy = 'restore');
    try {
      await _iap.restore();
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _load() async {
    final s = await Repo.billingStatus();
    if (mounted) {
      setState(() {
        _plan = s.plan;
        _aiRepliesUsed = s.aiRepliesUsed;
        _loading = false;
      });
    }
  }

  Future<void> _buy(String plan, BillingPeriod period) async {
    HapticFeedback.lightImpact();
    setState(() => _busy = plan);
    try {
      await _iap.buy(plan, period);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = null);
        showSnack(context, '$e', kind: SnackKind.error);
      }
    }
  }

  Future<void> _openUrl(Uri uri, {bool external = false}) async {
    final mode =
        external ? LaunchMode.externalApplication : LaunchMode.inAppBrowserView;
    final ok = await launchUrl(uri, mode: mode);
    if (!ok) {
      final fallback = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!fallback && mounted) {
        showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
      }
    }
  }

  Future<void> _openLegal(String path) async {
    if (!AppConfig.hasWeb) return;
    await _openUrl(Uri.parse('${AppConfig.webUrl}$path'));
  }

  /// 解約・プラン管理。
  ///
  /// アプリ内課金の契約は各ストアの管理下にあり、こちらからは解約できない。
  /// 必ずストアの管理画面へ案内する（以前はStripeのポータルを開こうとして、
  /// IAP契約者には「Stripe顧客が未作成です」というエラーが出ていた）。
  Future<void> _manage() async {
    HapticFeedback.lightImpact();
    final uri =
        Platform.isIOS
            ? Uri.parse('https://apps.apple.com/account/subscriptions')
            : Uri.parse('https://play.google.com/store/account/subscriptions');
    await _openUrl(uri, external: true);
  }

  // ---- 価格の表示 ----
  //
  // ストアが返すローカライズ済みの価格を優先し、取れないときだけ定義の円価格を出す。

  static String _yen(int v) => '¥${NumberFormat('#,###').format(v)}';

  PlanPrice? _catalogPrice(PlanDef p, BillingPeriod period) =>
      period == BillingPeriod.yearly ? p.yearly : p.monthly;

  bool _hasPeriod(PlanDef p, BillingPeriod period) =>
      _iapReady
          ? _iap.hasPeriod(p.key, period)
          : _catalogPrice(p, period)?.productId != null;

  String _price(PlanDef p, BillingPeriod period) {
    final store = _iap.priceFor(p.key, period);
    final unit = period == BillingPeriod.yearly ? '年' : '月';
    if (store != null) return '$store / $unit';
    final c = _catalogPrice(p, period);
    return c == null ? '' : '${_yen(c.yen)} / $unit';
  }

  String? _monthlyEquivalent(PlanDef p) {
    final store = _iap.monthlyEquivalentFor(p.key);
    if (store != null) return store;
    final y = p.yearly;
    return y == null ? null : _yen((y.yen / 12).round());
  }

  int? _discountPct(PlanDef p) {
    final store = _iap.yearlyDiscountPct(p.key);
    if (store != null) return store;
    final m = p.monthly, y = p.yearly;
    if (m == null || y == null) return null;
    final pct = ((1 - y.yen / (m.yen * 12)) * 100).round();
    return pct > 0 ? pct : null;
  }

  bool _trial(PlanDef p, BillingPeriod period) =>
      _iapReady && p.trialDays != null && _iap.trialAvailable(p.key, period);

  int? get _maxDiscountPct {
    final values = _purchasable.map(_discountPct).whereType<int>();
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final isPaid = _plan != 'free';
    final showYearlyToggle = _purchasable.any(
      (p) => _hasPeriod(p, BillingPeriod.yearly),
    );
    final free = planDef('free');
    return Scaffold(
      appBar: AppBar(title: const Text('プラン')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (isPaid) _current() else _hero(),
                    // 開発時の切り分け用。リリースビルドには出さない。
                    if (kDebugMode) _iapDebugStatus(),
                    if (!_iapReady) _iapUnavailableNotice(),
                    if (!isPaid) ...[
                      const SizedBox(height: 12),
                      _freeUsage(free),
                    ],
                    const SizedBox(height: 20),
                    if (showYearlyToggle) ...[
                      _periodToggle(),
                      const SizedBox(height: 14),
                    ],
                    for (final p in _purchasable) ...[
                      _planCard(p),
                      const SizedBox(height: 12),
                    ],
                    _freeCard(free),
                    const SizedBox(height: 16),
                    _reassurance(),
                    if (isPaid) ...[
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        onPressed: _manage,
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: Text(
                          Platform.isIOS
                              ? 'サブスクリプションを管理・解約（App Store）'
                              : '定期購入を管理・解約（Google Play）',
                        ),
                      ),
                    ],
                    if (_iapReady) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _busy == null ? _restore : null,
                        icon:
                            _busy == 'restore'
                                ? const _MiniSpinner()
                                : const Icon(Icons.restore, size: 18),
                        label: const Text('購入を復元'),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _disclosure(),
                    const SizedBox(height: 12),
                    // 購入画面から規約・プライバシーへ到達できるようにする
                    // （App Store Review Guideline 3.1.2 の要件。Playも同様に求められる）。
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => _openLegal('/terms'),
                          child: const Text(
                            '利用規約',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                        Text('·', style: TextStyle(color: context.subtleC)),
                        TextButton(
                          onPressed: () => _openLegal('/privacy'),
                          child: const Text(
                            'プライバシーポリシー',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
    );
  }

  /// 冒頭の一文。開いた理由ごとに「今困っていること」への答えを出す。
  Widget _hero() {
    final pro = planDef('pro');
    final proReplies = planAiReplies('pro');
    final (icon, title, body) = switch (widget.reason) {
      PaywallReason.history => (
        Icons.history,
        '30日より前のレビューも、保存してあります',
        '${pro.name}にすると、これまでRevPilotが集めたレビューを今すぐ全期間表示します。'
            'Google Play は直近7日ぶんしか残らないので、ここにしかない記録です。',
      ),
      PaywallReason.bulk => (
        Icons.done_all,
        '未返信のレビューを、まとめて片付ける',
        '${pro.name}は一度に最大${planBulkLimit('pro')}件、'
            'Maxは最大${planBulkLimit('max')}件をAIがまとめて返信案にします。',
      ),
      PaywallReason.aiQuota => (
        Icons.auto_awesome,
        '今月のAI返信を使い切りました',
        '${pro.name}なら月$proReplies件まで。返信文を考える時間をAIに任せられます。',
      ),
      PaywallReason.apps => (
        Icons.apps,
        'すべてのアプリを、1か所で',
        '${pro.name}はアプリ数が無制限です。小さなアプリをいくつ持っていても料金は変わりません。',
      ),
      PaywallReason.general => (
        Icons.inventory_2_outlined,
        'レビューを、消える前に全部残す',
        'Google Play は直近7日ぶんのレビューしか返しません。'
            '${pro.name}なら毎時集めたレビューを全期間いつでも読み返せて、'
            'AI返信も月$proReplies件まで使えます。',
      ),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(fontSize: 13, height: 1.6, color: context.inkC),
          ),
        ],
      ),
    );
  }

  /// Free の今月の使用状況。上限に近いことを、押し付けずに事実として見せる。
  Widget _freeUsage(PlanDef free) {
    final limit = planAiReplies('free');
    final used = _aiRepliesUsed.clamp(0, limit);
    final ratio = limit == 0 ? 0.0 : used / limit;
    final full = used >= limit;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderC),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${free.name}・今月のAI返信',
                style: TextStyle(fontSize: 12, color: context.subtleC),
              ),
              const Spacer(),
              Text(
                '$used / $limit件',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: full ? AppTheme.warning : context.inkC,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: context.trackC,
              color: full ? AppTheme.warning : AppTheme.primary,
            ),
          ),
          if (free.limits.historyDays != null) ...[
            const SizedBox(height: 8),
            Text(
              'レビューの表示は直近${free.limits.historyDays}日ぶん（それ以前も保存しています）',
              style: TextStyle(fontSize: 11, color: context.subtleC),
            ),
          ],
        ],
      ),
    );
  }

  Widget _periodToggle() {
    final pct = _maxDiscountPct;
    return Center(
      child: SegmentedButton<BillingPeriod>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: BillingPeriod.yearly,
            label: Text(pct == null ? '年額' : '年額（最大$pct%お得）'),
          ),
          const ButtonSegment(value: BillingPeriod.monthly, label: Text('月額')),
        ],
        selected: {_period},
        onSelectionChanged: (s) {
          HapticFeedback.selectionClick();
          setState(() => _period = s.first);
        },
      ),
    );
  }

  Widget _current() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Text('現在のプラン', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                planLabel(_plan),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planCard(PlanDef p) {
    final isCurrent = _plan == p.key;
    final period =
        _hasPeriod(p, _period) ? _period : BillingPeriod.monthly; // 年額未販売なら月額
    final yearly = period == BillingPeriod.yearly;
    final trial = _trial(p, period);
    final discount = yearly ? _discountPct(p) : null;
    final perMonth = yearly ? _monthlyEquivalent(p) : null;
    final price = _price(p, period);

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: p.popular ? AppTheme.primary : context.borderC,
          width: p.popular ? 1.8 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (p.popular) ...[
                  const SizedBox(width: 8),
                  const _Pill('おすすめ', filled: true),
                ],
                if (trial) ...[
                  const SizedBox(width: 6),
                  _Pill('${p.trialDays}日間無料'),
                ],
              ],
            ),
            const SizedBox(height: 2),
            Text(
              p.tagline,
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
            const SizedBox(height: 10),
            // 請求額を最も目立つ価格表示にする（月あたりの換算は補足として小さく）。
            Text(
              price,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppTheme.primary,
              ),
            ),
            if (perMonth != null || discount != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [
                    if (perMonth != null) '月あたり $perMonth',
                    if (discount != null) '月額より$discount%お得',
                  ].join('・'),
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                ),
              ),
            const SizedBox(height: 12),
            for (final f in p.features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: AppTheme.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: _planAction(p, period, isCurrent, trial),
            ),
            if (!isCurrent && _iapReady) ...[
              const SizedBox(height: 6),
              Text(
                trial
                    ? '${p.trialDays}日間無料、その後 $price（自動更新）。'
                        '終了の2日前にお知らせします。無料期間中に解約すれば料金はかかりません。'
                    : '$price（自動更新）。いつでも解約できます。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: context.subtleC,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _planAction(
    PlanDef p,
    BillingPeriod period,
    bool isCurrent,
    bool trial,
  ) {
    if (isCurrent) {
      return Column(
        children: [
          const SizedBox(
            width: double.infinity,
            child: OutlinedButton(onPressed: null, child: Text('利用中')),
          ),
          // 同じプランの月額⇄年額の切り替え。今の周期と同じなら、ストアが「購読中」と案内する。
          if (_iapReady && _iap.hasPeriod(p.key, period))
            TextButton(
              onPressed: _busy == null ? () => _buy(p.key, period) : null,
              child: Text(
                period == BillingPeriod.yearly ? '年額に切り替える' : '月額に切り替える',
              ),
            ),
        ],
      );
    }

    // 商品が取れないときは購入ボタンを無効化する。
    // ここで外部決済へ誘導すると 3.1.1 / Play課金ポリシー違反になる。
    if (!_iapReady) {
      return const OutlinedButton(onPressed: null, child: Text('現在ご利用いただけません'));
    }
    final label =
        trial
            ? '${p.trialDays}日間無料で試す'
            : (_plan == 'free' ? '${p.name}にアップグレード' : '${p.name}に変更');
    return FilledButton(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: _busy == null ? () => _buy(p.key, period) : null,
      child:
          _busy == p.key
              ? const _MiniSpinner()
              : Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
    );
  }

  /// Free は比較用に小さく出す。有料からの移行（解約）はストアでの手続きになる。
  Widget _freeCard(PlanDef free) {
    final isCurrent = _plan == 'free';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                free.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text('¥0', style: TextStyle(color: context.subtleC)),
              const Spacer(),
              if (isCurrent)
                Text(
                  '利用中',
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                )
              else
                TextButton(
                  onPressed: _manage,
                  child: Text(
                    Platform.isIOS ? '解約手続き（App Store）' : '解約手続き（Google Play）',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            free.features.join('・'),
            style: TextStyle(fontSize: 12, color: context.subtleC),
          ),
        ],
      ),
    );
  }

  /// 購入前の不安を先回りして消す3点。
  Widget _reassurance() {
    Widget item(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: context.subtleC),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        item(Icons.event_available_outlined, 'いつでも解約できます（解約後も期間終了まで使えます）'),
        item(Icons.lock_outline, 'Freeに戻してもレビューの記録は消えません'),
        item(Icons.swap_horiz, 'プランや年額・月額はあとから変更できます'),
      ],
    );
  }

  /// 自動更新サブスクの開示（Apple / Google の両ストアで必須の記載）。
  Widget _disclosure() {
    final store = Platform.isIOS ? 'Apple ID' : 'Googleアカウント';
    final path =
        Platform.isIOS
            ? '「設定 > Apple ID > サブスクリプション」'
            : 'Google Play ストアの「お支払いと定期購入 > 定期購入」';
    final trialDays = _purchasable
        .map((p) => p.trialDays)
        .whereType<int>()
        .fold<int?>(null, (a, b) => a == null || b > a ? b : a);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'サブスクリプションは月額または年額で、選択した期間ごとに自動更新されます。'
        'お支払いは購入確定時に$storeへ請求されます。'
        '${trialDays != null ? '無料トライアルの対象となる方は、無料期間（$trialDays日間）の終了時に初回の料金が請求されます。無料トライアルはお一人様1回限りです。' : ''}'
        '解約しない限り期間終了時に自動更新され、更新料は現在の期間終了の24時間前に請求されます。'
        '自動更新は購入後、$pathからいつでも解約できます。'
        '${trialDays != null ? '無料期間中に解約した場合、料金はかかりません。' : ''}'
        '解約後も、その課金期間の終了までは有料機能をご利用いただけます。',
        style: TextStyle(fontSize: 12, color: context.subtleC, height: 1.5),
      ),
    );
  }

  /// 商品を取得できないとき。外部決済には絶対に落とさない。
  Widget _iapUnavailableNotice() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ただいま購入手続きをご利用いただけません。'
              '通信環境をご確認のうえ、時間をおいて再度お試しください。',
              style: TextStyle(fontSize: 12, color: context.inkC, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  /// デバッグビルド専用の状態表示。
  Widget _iapDebugStatus() {
    final ok = _iapReady;
    final color = ok ? AppTheme.success : AppTheme.warning;
    final hint =
        Platform.isIOS
            ? 'StoreKit設定を確認し、Xcodeの▶から起動してください。'
            : 'Play Console で定期購入を作成し、内部テスト版として署名済みビルドで起動してください。';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        ok
            ? '[debug] IAP商品を取得済み。ネイティブ購入シートが使えます。'
                '${_iap.lastError != null ? '（${_iap.lastError}）' : ''}'
            : '[debug] IAP商品を取得できていません（${_iap.lastError ?? "理由不明"}）。$hint',
        style: TextStyle(fontSize: 11, color: context.inkC, height: 1.4),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.filled = false});

  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color:
          filled ? AppTheme.primary : AppTheme.success.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: filled ? Colors.white : AppTheme.success,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 18,
    width: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
