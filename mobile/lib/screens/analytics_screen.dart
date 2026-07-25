import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets.dart';

/// 直近レビューの集計（平均・星分布・トピック件数）。
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late Future<List<ReviewRow>> _future;
  List<AppRow> _apps = [];
  String? _appId; // 特定アプリで絞り込み
  String? _store; // 特定ストア全体で絞り込み（appIdとは排他）

  @override
  void initState() {
    super.initState();
    _future = Repo.reviews();
    Repo.apps().then((a) {
      if (mounted) setState(() => _apps = a);
    }).catchError((_) {});
  }

  void _applyScope() {
    _future = Repo.reviews(appId: _appId, store: _store);
  }

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    setState(_applyScope);
    await _future;
  }

  String get _scopeLabel {
    if (_appId != null) {
      for (final a in _apps) {
        if (a.id == _appId) return a.name;
      }
      return 'アプリ';
    }
    if (_store == 'appstore') return 'App Store（全体）';
    if (_store == 'googleplay') return 'Google Play（全体）';
    return '全アプリ';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分析')),
      body: Column(
        children: [
          _scopeBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<ReviewRow>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const _AnalyticsSkeleton();
                  }
                  final reviews = snap.data ?? [];
                  if (reviews.isEmpty) {
                    return ListView(children: const [
                      SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.insights_outlined,
                        title: 'このスコープにはデータがありません',
                        subtitle: '別のアプリ/ストアを選ぶか、レビューが集まるとここに表示されます。',
                      ),
                    ]);
                  }
                  var i = 0;
                  Widget staggered(Widget child) => child
                      .animate(delay: (80 * i++).ms)
                      .fadeIn(duration: 300.ms);
                  return ListView(
                    // scope切替時にアニメを作り直し、バーの伸びを見せる
                    key: ValueKey('${_appId ?? _store ?? "all"}-${reviews.length}'),
                    padding: const EdgeInsets.all(16),
                    children: [
                      staggered(_summaryRow(reviews)),
                      const SizedBox(height: 16),
                      staggered(_ratingDistribution(reviews)),
                      const SizedBox(height: 16),
                      staggered(_topicBreakdown(reviews)),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopeBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: _apps.isEmpty ? null : _pickScope,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: context.surfaceC,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: context.borderC),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.filter_list_rounded,
                  size: 18, color: AppTheme.primary),
              const SizedBox(width: 6),
              Text(_scopeLabel,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: context.inkC),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickScope() async {
    HapticFeedback.selectionClick();
    final hasAppstore = _apps.any((a) => a.store == 'appstore');
    final hasGoogle = _apps.any((a) => a.store == 'googleplay');
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surfaceC,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        Widget tile(String label, IconData icon,
            {String? appId, String? store}) {
          final selected = _appId == appId && _store == store;
          return ListTile(
            leading: Icon(icon,
                color: selected ? AppTheme.primary : Colors.grey.shade700),
            title: Text(label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.primary : context.inkC,
                )),
            trailing: selected
                ? const Icon(Icons.check_rounded, color: AppTheme.primary)
                : null,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() {
                _appId = appId;
                _store = store;
                _applyScope();
              });
              Navigator.pop(ctx);
            },
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: context.borderC,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('分析するスコープ',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                  ),
                ),
                tile('全アプリ', Icons.dashboard_outlined),
                if (hasAppstore)
                  tile('App Store（全体）', Icons.apple, store: 'appstore'),
                if (hasGoogle)
                  tile('Google Play（全体）', Icons.android, store: 'googleplay'),
                if (_apps.isNotEmpty) const Divider(height: 1),
                for (final a in _apps)
                  tile(a.name,
                      a.store == 'appstore' ? Icons.apple : Icons.android,
                      appId: a.id),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _summaryRow(List<ReviewRow> reviews) {
    final avg = reviews.map((r) => r.rating).reduce((a, b) => a + b) /
        reviews.length;
    final unreplied = reviews.where((r) => !r.hasReply).length;
    return Row(
      children: [
        Expanded(
            child: _statCard('平均評価', avg, Icons.star_rounded,
                decimals: 2, color: AppTheme.ratingColor(avg.round()))),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('レビュー数', reviews.length.toDouble(),
                Icons.rate_review_outlined)),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('未返信', unreplied.toDouble(),
                Icons.mark_email_unread_outlined,
                color: unreplied > 0 ? AppTheme.danger : null)),
      ],
    );
  }

  Widget _statCard(String label, double value, IconData icon,
      {int decimals = 0, Color? color}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color ?? Colors.grey.shade500),
            const SizedBox(height: 8),
            _CountUp(
              value,
              decimals: decimals,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color ?? context.inkC),
            ),
            Text(label,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _ratingDistribution(List<ReviewRow> reviews) {
    final counts = <int, int>{for (var i = 1; i <= 5; i++) i: 0};
    for (final r in reviews) {
      counts[r.rating] = (counts[r.rating] ?? 0) + 1;
    }
    final maxCount = counts.values.fold<int>(1, (m, v) => v > m ? v : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('星の分布',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            for (var star = 5; star >= 1; star--) ...[
              Row(
                children: [
                  SizedBox(
                      width: 28,
                      child: Text('★$star',
                          style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: _GrowBar(
                      value: (counts[star] ?? 0) / maxCount,
                      color: AppTheme.ratingColor(star),
                      delay: Duration(milliseconds: 150 + (5 - star) * 90),
                    ),
                  ),
                  SizedBox(
                      width: 32,
                      child: Text(' ${counts[star]}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12))),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topicBreakdown(List<ReviewRow> reviews) {
    final counts = <String, int>{};
    for (final r in reviews) {
      for (final t in r.topics) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('トピック傾向',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('AI分類がまだありません（サーバー接続後に自動分類されます）。',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            ],
          ),
        ),
      );
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('トピック傾向',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var k = 0; k < sorted.length; k++)
                  Chip(
                    label: Text(
                        '${topicLabels[sorted[k].key] ?? sorted[k].key} ${sorted[k].value}'),
                    backgroundColor: AppTheme.primary.withValues(alpha: 0.06),
                    side: BorderSide.none,
                  )
                      .animate(delay: (300 + 60 * k).ms)
                      .fadeIn(duration: 220.ms)
                      .scale(begin: const Offset(0.9, 0.9), end: const Offset(1, 1)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 星分布バー。表示後に少し遅れて0→目標値へ伸びる（カスケード）。
/// 単一の短命コントローラのみ・静止後は再描画しないため軽量。
class _GrowBar extends StatefulWidget {
  final double value;
  final Color color;
  final Duration delay;
  const _GrowBar({
    required this.value,
    required this.color,
    this.delay = Duration.zero,
  });

  @override
  State<_GrowBar> createState() => _GrowBarState();
}

class _GrowBarState extends State<_GrowBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final Animation<double> _a =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: AnimatedBuilder(
        animation: _a,
        builder: (_, __) => LinearProgressIndicator(
          value: _a.value * widget.value,
          minHeight: 10,
          backgroundColor: context.trackC,
          color: widget.color,
        ),
      ),
    );
  }
}

/// 数値を0から目標値へカウントアップ表示する。
class _CountUp extends StatelessWidget {
  final double value;
  final int decimals;
  final TextStyle style;
  const _CountUp(this.value, {this.decimals = 0, required this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (_, v, __) => Text(v.toStringAsFixed(decimals), style: style),
    );
  }
}

/// 分析ロード中のシマー・スケルトン。
class _AnalyticsSkeleton extends StatelessWidget {
  const _AnalyticsSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget card(double height) => Card(
          child: SizedBox(height: height, width: double.infinity),
        );
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Row(children: [
          Expanded(child: card(84)),
          const SizedBox(width: 12),
          Expanded(child: card(84)),
          const SizedBox(width: 12),
          Expanded(child: card(84)),
        ]),
        const SizedBox(height: 16),
        card(220),
        const SizedBox(height: 16),
        card(120),
      ],
    ).animate(onPlay: (c) => c.repeat()).shimmer(
          duration: 1100.ms,
          color: Colors.white.withValues(alpha: 0.6),
        );
  }
}
