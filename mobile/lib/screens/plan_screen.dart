import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data.dart';
import '../iap.dart';
import '../theme.dart';
import '../ui.dart';

/// プランの確認・変更。
///
/// 【決済はアプリ内課金のみ】
/// iOS は App Store Review Guideline 3.1.1、Android は Google Play の課金ポリシーにより、
/// アプリ内のデジタルコンテンツのサブスクは各ストアの課金を使う必要があり、
/// 外部の決済ページへ誘導することはできない。
/// 以前は StoreKit の商品取得に失敗したとき Stripe Checkout をアプリ内ブラウザで開く
/// フォールバックがあったが、これは確実にリジェクトされるため撤去した。
/// 商品を取得できない場合は購入導線そのものを出さない。
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  String _plan = 'free';
  bool _loading = true;
  String? _busy;

  final IapService _iap = IapService();
  bool _iapReady = false;

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
          final plan = Platform.isIOS
              ? await Repo.confirmApplePurchase(
                  productId: result.productId,
                  transactionId: result.transactionId,
                  verificationData: result.verificationData,
                )
              : await Repo.confirmGooglePurchase(
                  productId: result.productId,
                  purchaseToken: result.verificationData ?? '',
                );
          if (!mounted) return;
          setState(() {
            _busy = null;
            _plan = plan;
          });
          showSnack(
            context,
            result.restored ? '購入を復元しました。' : '${planLabel(plan)}にアップグレードしました。',
            kind: SnackKind.success,
          );
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
    if (mounted) setState(() => _iapReady = _iap.isReady);
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
    final p = await Repo.plan();
    if (mounted) {
      setState(() {
        _plan = p;
        _loading = false;
      });
    }
  }

  Future<void> _buy(String plan) async {
    HapticFeedback.lightImpact();
    setState(() => _busy = plan);
    try {
      await _iap.buy(plan);
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
      final fallback = await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    final uri = Platform.isIOS
        ? Uri.parse('https://apps.apple.com/account/subscriptions')
        : Uri.parse('https://play.google.com/store/account/subscriptions');
    await _openUrl(uri, external: true);
  }

  @override
  Widget build(BuildContext context) {
    final isPaid = _plan != 'free';
    return Scaffold(
      appBar: AppBar(title: const Text('プラン')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _current(),
                  // 開発時の切り分け用。リリースビルドには出さない。
                  if (kDebugMode) _iapDebugStatus(),
                  if (!_iapReady) _iapUnavailableNotice(),
                  const SizedBox(height: 20),
                  _planCard(
                    plan: 'free',
                    name: 'Free',
                    price: '¥0',
                    tagline: 'まず1本のアプリで試す',
                    features: const [
                      'アプリ 1件',
                      'レビュー履歴 30日',
                      'AI返信 月3件',
                      '自動取得 毎時・新着通知',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'pro',
                    name: 'Pro',
                    price: _iap.priceFor('pro') ?? '¥1,480 / 月',
                    tagline: '個人開発者の標準',
                    popular: true,
                    features: const [
                      'アプリ数 無制限',
                      'レビュー履歴 無期限',
                      'AI返信 月300件',
                      '一括返信 最大20件',
                      'トピック分析・週次サマリー',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'max',
                    name: 'Max',
                    price: _iap.priceFor('max') ?? '¥2,980 / 月',
                    tagline: 'レビューが多い方へ',
                    features: const [
                      'Pro のすべて',
                      'AI返信 月1,000件',
                      '一括返信 最大50件',
                      '優先サポート',
                    ],
                  ),
                  if (isPaid) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _manage,
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: Text(Platform.isIOS
                          ? 'サブスクリプションを管理・解約（App Store）'
                          : '定期購入を管理・解約（Google Play）'),
                    ),
                  ],
                  if (_iapReady) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _busy == null ? _restore : null,
                      icon: _busy == 'restore'
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
                        child: const Text('利用規約', style: TextStyle(fontSize: 12)),
                      ),
                      Text('·', style: TextStyle(color: context.subtleC)),
                      TextButton(
                        onPressed: () => _openLegal('/privacy'),
                        child: const Text('プライバシーポリシー',
                            style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  /// 自動更新サブスクの開示（Apple / Google の両ストアで必須の記載）。
  Widget _disclosure() {
    final store = Platform.isIOS ? 'Apple ID' : 'Googleアカウント';
    final path = Platform.isIOS
        ? '「設定 > Apple ID > サブスクリプション」'
        : 'Google Play ストアの「お支払いと定期購入 > 定期購入」';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'サブスクリプションは月額です。お支払いは購入確定時に$storeへ請求されます。'
        '解約しない限り期間終了時に自動更新され、更新料は現在の期間終了の24時間前に請求されます。'
        '自動更新は購入後、$pathからいつでも解約できます。'
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
    final hint = Platform.isIOS
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
            : '[debug] IAP商品を取得できていません（${_iap.lastError ?? "理由不明"}）。$hint',
        style: TextStyle(fontSize: 11, color: context.inkC, height: 1.4),
      ),
    );
  }

  Widget _current() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Text('現在のプラン',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _plan != 'free'
                    ? AppTheme.primary.withValues(alpha: 0.12)
                    : context.subtleSurfaceC,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(planLabel(_plan),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color:
                        _plan != 'free' ? AppTheme.primary : context.subtleC,
                  )),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planCard({
    required String plan,
    required String name,
    required String price,
    required String tagline,
    required List<String> features,
    bool popular = false,
  }) {
    final isCurrent = _plan == plan;
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: popular ? AppTheme.primary : context.borderC,
          width: popular ? 1.8 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                if (popular) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('おすすめ',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
                ],
                const Spacer(),
                Text(price,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, color: AppTheme.primary)),
              ],
            ),
            const SizedBox(height: 2),
            Text(tagline,
                style: TextStyle(fontSize: 12, color: context.subtleC)),
            const SizedBox(height: 12),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_rounded,
                        size: 18, color: AppTheme.success),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: _planAction(plan, name, isCurrent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planAction(String plan, String name, bool isCurrent) {
    if (isCurrent) {
      return const OutlinedButton(onPressed: null, child: Text('利用中'));
    }

    // Freeカード（有料からの移行）＝ストアでの解約手続きへ。
    if (plan == 'free') {
      return OutlinedButton(
        onPressed: _manage,
        child: Text(Platform.isIOS ? '解約手続き（App Store）' : '解約手続き（Google Play）'),
      );
    }

    // 商品が取れないときは購入ボタンを無効化する。
    // ここで外部決済へ誘導すると 3.1.1 / Play課金ポリシー違反になる。
    if (!_iapReady) {
      return const OutlinedButton(
        onPressed: null,
        child: Text('現在ご利用いただけません'),
      );
    }
    return FilledButton(
      onPressed: _busy == null ? () => _buy(plan) : null,
      child: _busy == plan
          ? const _MiniSpinner()
          : Text(_plan == 'free' ? '$nameにアップグレード' : '$nameに変更'),
    );
  }
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 18,
      width: 18,
      child: CircularProgressIndicator(strokeWidth: 2));
}
