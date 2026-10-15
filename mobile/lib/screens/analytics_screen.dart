import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../app_events.dart';
import '../data.dart';
import '../locked_preview.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

/// 直近レビューの集計（平均・星分布・トピック件数）。
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  late Future<ReviewSummary> _future;
  List<AppRow> _apps = [];
  String? _appId; // 特定アプリで絞り込み
  String? _store; // 特定ストア全体で絞り込み（appIdとは排他）
  // 既に読んだプランがあれば最初から使う（有料会員にロック表示を一瞬見せない）。
  String _plan = AppEvents.plan.value ?? 'free';
  LockedPreview _locked = LockedPreview.empty;

  @override
  void initState() {
    super.initState();
    _applyScope();
    _loadApps();
    _loadPlan();
    // タブは IndexedStack で保持され、作り直されない。購入やほかのタブでの変更を聞いて読み直す。
    AppEvents.planChanged.addListener(_onPlanChanged);
    AppEvents.dataChanged.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppEvents.planChanged.removeListener(_onPlanChanged);
    AppEvents.dataChanged.removeListener(_onDataChanged);
    super.dispose();
  }

  void _loadApps() {
    Repo.apps().then((a) {
      if (!mounted) return;
      setState(() {
        _apps = a;
        // 選んでいたアプリが削除されていたら、全アプリに戻す。
        if (_appId != null && !a.any((x) => x.id == _appId)) {
          _appId = null;
          _applyScope();
        }
      });
    }).catchError((_) {});
  }

  /// プランと、Free で見えない古いレビューの件数を読み直す。
  Future<void> _loadPlan() async {
    try {
      final p = await Repo.plan();
      final locked =
          p == 'free' ? await Repo.lockedPreview() : LockedPreview.empty;
      if (mounted) {
        setState(() {
          _plan = p;
          _locked = locked;
        });
      }
    } catch (_) {}
  }

  /// 購入・復元・解約でプランが変わった。
  void _onPlanChanged() {
    _loadPlan();
    // 有料になると30日より前のレビューも集計に入る（範囲はサーバーの RLS で決まる）。
    if (mounted) setState(_applyScope);
  }

  /// 連携・アプリ・レビュー・返信が変わった（件数や未返信の数が変わる）。
  void _onDataChanged() {
    final kind = AppEvents.lastChange;
    if (kind == DataChange.apps || kind == DataChange.stores) _loadApps();
    if (mounted) setState(_applyScope);
  }

  void _applyScope() {
    _future = Repo.reviewSummary(appId: _appId, store: _store);
    // FutureBuilder が受け取るのは次のビルドから。それより先に失敗しても
    // 「未処理のエラー」にならないよう受けておく（表示は FutureBuilder が行う）。
    _future.then<void>((_) {}, onError: (_) {});
  }

  bool get _filtered => _appId != null || _store != null;

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    setState(_applyScope);
    _loadApps();
    // 失敗は画面にエラー表示として出すので、ここでは投げない。
    await Future.wait([
      _future.then<void>((_) {}, onError: (_) {}),
      _loadPlan(),
    ]);
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
              child: FutureBuilder<ReviewSummary>(
                // スコープを切り替えたときは作り直してスケルトンから出す。
                // 同じスコープの読み直し（引っ張って更新・ほかのタブでの変更）は、
                // 前の数字を出したまま差し替える。
                key: ValueKey(_appId ?? _store ?? 'all'),
                future: _future,
                builder: (context, snap) {
                  final waiting =
                      snap.connectionState == ConnectionState.waiting;
                  if (waiting && !snap.hasData) {
                    return const _AnalyticsSkeleton();
                  }
                  // 通信の失敗を「データがありません」と見せない。
                  if (snap.hasError && !waiting) {
                    return ListView(children: [
                      const SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.wifi_off_rounded,
                        title: '読み込みに失敗しました',
                        subtitle: friendlyError(snap.error!),
                        action: FilledButton.tonal(
                          onPressed: () => setState(_applyScope),
                          child: const Text('再試行'),
                        ),
                      ),
                    ]);
                  }
                  final summary = snap.data;
                  final empty = summary == null || summary.total == 0;
                  // 閲覧範囲内は空でも、それより前に保存済みのレビューがあるなら
                  // 「データがない」とは言わずにチラ見せする（件数は全アプリ合計）。
                  if (empty && _locked.hasHidden) {
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        LockedReviewsTeaser(_locked, acrossAllApps: _filtered),
                      ],
                    );
                  }
                  if (empty) {
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
                    key: ValueKey('${_appId ?? _store ?? "all"}-${summary.total}'),
                    padding: const EdgeInsets.all(16),
                    children: [
                      staggered(_summaryRow(summary)),
                      const SizedBox(height: 16),
                      staggered(_ratingDistribution(summary)),
                      const SizedBox(height: 16),
                      staggered(planDef(_plan).limits.topicAnalysis
                          ? _topicBreakdown(summary)
                          : const LockedTopicsCard()),
                      if (_locked.hasHidden) ...[
                        const SizedBox(height: 16),
                        staggered(LockedReviewsTeaser(
                          _locked,
                          acrossAllApps: _filtered,
                        )),
                      ],
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
              // 長いアプリ名でも▼が画面外に押し出されないよう、名前の方を省略する。
              Flexible(
                child: Text(_scopeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
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
                color: selected ? context.accentTextC : context.subtleC),
            title: Text(label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? context.accentTextC : context.inkC,
                )),
            trailing: selected
                ? Icon(Icons.check_rounded, color: context.accentTextC)
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

  Widget _summaryRow(ReviewSummary s) {
    final avg = s.avgRating;
    final unreplied = s.unreplied;
    return Row(
      children: [
        Expanded(
            child: _statCard('平均評価', avg, Icons.star_rounded,
                decimals: 2,
                color: AppTheme.ratingColor(avg.round()),
                textColor: context.ratingTextC(avg.round()))),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('レビュー数', s.total.toDouble(),
                Icons.rate_review_outlined)),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('未返信', unreplied.toDouble(),
                Icons.mark_email_unread_outlined,
                color: unreplied > 0 ? AppTheme.danger : null,
                textColor: unreplied > 0 ? context.dangerTextC : null)),
      ],
    );
  }

  /// [color] はアイコン用、[textColor] は数字用（状態色のままだと文字では薄すぎる）。
  Widget _statCard(String label, double value, IconData icon,
      {int decimals = 0, Color? color, Color? textColor}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color ?? context.subtleC),
            const SizedBox(height: 8),
            _CountUp(
              value,
              decimals: decimals,
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: textColor ?? context.inkC),
            ),
            Text(label,
                style: TextStyle(fontSize: 11, color: context.subtleC)),
          ],
        ),
      ),
    );
  }

  Widget _ratingDistribution(ReviewSummary s) {
    final counts = <int, int>{
      for (var i = 1; i <= 5; i++) i: s.byRating[i] ?? 0,
    };
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
                  // 文字を大きくしても「★5」が2行に割れないよう、幅は最小値だけ決める。
                  ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 28),
                      child: Text('★$star',
                          softWrap: false,
                          style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: _GrowBar(
                      value: (counts[star] ?? 0) / maxCount,
                      color: AppTheme.ratingColor(star),
                      delay: Duration(milliseconds: 150 + (5 - star) * 90),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(minWidth: 28),
                        child: Text('${counts[star]}',
                            textAlign: TextAlign.right,
                            softWrap: false,
                            style: const TextStyle(fontSize: 12))),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topicBreakdown(ReviewSummary s) {
    final counts = s.topics;
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
                  style: TextStyle(color: context.subtleC, fontSize: 13)),
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
          // ダークでは白60%だとまぶしい帯になるので、ごく薄くする。
          color: Colors.white.withValues(alpha: context.isDark ? 0.08 : 0.6),
        );
  }
}
