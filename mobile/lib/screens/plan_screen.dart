import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
    }
  }

  Future<void> _upgrade(String plan) async {
    HapticFeedback.lightImpact();
    setState(() => _busy = plan);
    try {
      final url = await Repo.checkoutUrl(plan);
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
                  const SizedBox(height: 20),
                  _planCard(
                    plan: 'free',
                    name: 'Free',
                    price: '¥0',
                    features: const [
                      'アプリ 1件まで',
                      'AI返信 月10件まで',
                      '手動更新のみ（自動取得なし）',
                      '週次サマリーメールなし',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'pro',
                    name: 'Pro',
                    price: '¥1,480 / 月',
                    features: const [
                      'アプリ数 無制限',
                      'AI返信 無制限',
                      '自動取得（cron）',
                      '週次サマリーメール',
                    ],
                  ),
                  const SizedBox(height: 12),
                  _planCard(
                    plan: 'team',
                    name: 'Team',
                    price: '¥3,980 / 月',
                    features: const [
                      'Proの全機能',
                      'チームでの利用に最適',
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
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '決済は安全なStripeのページ（外部ブラウザ）で行います。'
                      '購入後、プランの反映まで少し時間がかかる場合があります。',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ),
                ],
              ),
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
                    : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(planLabel(_plan),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: _plan != 'free'
                        ? AppTheme.primary
                        : Colors.grey.shade700,
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
  }) {
    final isCurrent = _plan == plan;
    return Card(
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
  /// - Pro/Team → アップグレード
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
    return FilledButton(
      onPressed: _busy == null ? () => _upgrade(plan) : null,
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
