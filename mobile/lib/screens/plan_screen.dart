import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data.dart';
import '../iap.dart';
import '../theme.dart';
import '../ui.dart';

/// プランの確認・変更。決済はStripe Checkoutを外部ブラウザで開く。
class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  String _plan = 'free';
  bool _loading = true;
  String? _busy; // 実行中のアクション識別子

  // App内課金（当面iOSのStoreKitローカルテスト用）。商品を取得できたときだけ使う。
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
      onPurchased: (planKey) {
        if (!mounted) return;
        setState(() => _busy = null);
        // ローカルテストでは購入は擬似成立。本番のプラン確定はサーバー検証実装後。
        showSnack(context,
            '購入が完了しました（テスト）。本番反映はサーバー検証の実装後に有効になります。',
            kind: SnackKind.success);
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _busy = null);
        showSnack(context, message, kind: SnackKind.error);
      },
    );
    if (mounted) setState(() => _iapReady = _iap.isReady);
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

  /// IAPで購入開始（ネイティブ購入シート）。結果は _initIap のコールバックで処理。
  Future<void> _buyIap(String plan) async {
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

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    // アプリ内ブラウザ（iOS: SFSafariViewController / Android: Custom Tabs）で開き、
    // 決済後もアプリに留まれるようにする。失敗時は外部ブラウザにフォールバック。
    final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!ok) {
      final ext = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ext && mounted) {
        showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
      }
    }
  }

  Future<void> _upgrade(String plan) async {
    HapticFeedback.lightImpact();
    setState(() => _busy = plan);
    try {
      final url = await Repo.checkoutUrl(plan);
      // URL取得が完了したらスピナーを解除する。この後アプリ内ブラウザを前面に出すが、
      // inAppBrowserView は閉じ方によって launchUrl が解決しないことがあり、
      // ここで解除しないとカードが回りっぱなしになるため。
      if (mounted) setState(() => _busy = null);
      await _openExternal(url);
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _manage() async {
    HapticFeedback.lightImpact();
    setState(() => _busy = 'portal');
    try {
      final url = await Repo.billingPortalUrl();
      await _openExternal(url);
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
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
                  if (Platform.isIOS) _iapStatus(),
                  const SizedBox(height: 20),
                  _planCard(
                    plan: 'free',
                    name: 'Free',
                    price: '¥0',
                    features: const [
                      'アプリ 1件まで',
                      'AI返信 月10件まで',
                      '返信は1件ずつ（一括なし）',
                      '手動更新のみ',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'pro',
                    name: 'Pro',
                    price: '¥1,480 / 月',
                    popular: true,
                    features: const [
                      'アプリ 5件まで',
                      'AI返信 無制限',
                      '一括返信 最大20件',
                      '自動取得・週次サマリー',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'max',
                    name: 'Max',
                    price: '¥2,980 / 月',
                    features: const [
                      'アプリ 無制限',
                      'AI返信 無制限',
                      '全レビュー 一括返信',
                      '自動取得・週次サマリー・優先処理',
                    ],
                  ),
                  const SizedBox(height: 24),
                  // 別セグメント（チーム向け）。個人向け3層の意思決定を薄めないよう分離。
                  Text('チーム向け',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.subtleC)),
                  const SizedBox(height: 8),
                  _planCard(
                    plan: 'team',
                    name: 'Team',
                    price: '¥5,800 / 月',
                    features: const [
                      'Maxの全機能',
                      '複数メンバーで共有',
                      'メンバー別の権限・履歴',
                      'まとめて請求',
                    ],
                  ),
                  if (isPaid) ...[
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: _busy == null ? _manage : null,
                      icon: _busy == 'portal'
                          ? const _MiniSpinner()
                          : const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('プランを管理・解約'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.subtleSurfaceC,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '決済は安全なStripeのページ（外部ブラウザ）で行います。'
                      '購入後、プランの反映まで少し時間がかかる場合があります。',
                      style:
                          TextStyle(fontSize: 12, color: context.subtleC),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// iOSでのIAPの状態表示（開発時の切り分け用）。取得できていればネイティブ購入、
  /// 取れていなければStripeにフォールバックしている旨を明示する。
  Widget _iapStatus() {
    final ok = _iapReady;
    final color = ok ? AppTheme.success : AppTheme.warning;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.info_outline,
              size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ok
                  ? 'アプリ内課金(IAP)が有効です。購入はネイティブ画面で行われます。'
                  : 'IAP商品を取得できていません→Stripe決済にフォールバック中。'
                      'IAPのテストはXcodeの▶から起動してください（run.shでは反映されません）。',
              style: TextStyle(fontSize: 11, color: context.inkC, height: 1.4),
            ),
          ),
        ],
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
                    color: _plan != 'free'
                        ? AppTheme.primary
                        : context.subtleC,
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
    required List<String> features,
    bool popular = false,
  }) {
    final isCurrent = _plan == plan;
    // センターステージ：おすすめ(Pro)は枠を強調して視線を集める。
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
            const SizedBox(height: 12),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
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

  /// プランごとのアクションボタン。
  /// - 現在プラン → 「利用中」
  /// - Free（有料からの移行）→ 解約導線（ポータル）
  /// - Pro/Max → アップグレード
  Widget _planAction(String plan, String name, bool isCurrent) {
    if (isCurrent) {
      return OutlinedButton(onPressed: null, child: const Text('利用中'));
    }
    if (plan == 'free') {
      return OutlinedButton(
        onPressed: _busy == null ? _manage : null,
        child: _busy == 'portal'
            ? const _MiniSpinner()
            : const Text('無料に戻す（解約手続き）'),
      );
    }
    // 既に有料会員が別の有料プランへ変更する場合は、再Checkout（＝サブスク二重作成）を
    // 避け、Stripeのポータルで差額精算つきの変更を行う。free会員のみ新規Checkout。
    if (_plan != 'free') {
      return OutlinedButton(
        onPressed: _busy == null ? _manage : null,
        child: _busy == 'portal'
            ? const _MiniSpinner()
            : Text('$nameに変更（管理画面）'),
      );
    }
    // iOSでStoreKit（IAP）が使える状態なら、ネイティブ購入シートで購入。
    // まだStoreKit設定が無い等で商品未取得なら、従来のStripe Checkoutにフォールバック。
    final useIap = Platform.isIOS && _iapReady;
    return FilledButton(
      onPressed: _busy == null
          ? () => useIap ? _buyIap(plan) : _upgrade(plan)
          : null,
      child: _busy == plan
          ? const _MiniSpinner()
          : Text('$nameにアップグレード'),
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
