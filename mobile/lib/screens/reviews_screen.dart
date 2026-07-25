import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'plan_screen.dart';
import 'review_detail_screen.dart';

class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  late Future<List<ReviewRow>> _future;
  List<AppRow> _apps = [];
  List<Announcement> _announcements = [];

  // フィルタ・並び替え
  final Set<int> _ratings = {}; // 空=全評価
  bool _unrepliedOnly = false;
  String? _appId;
  ReviewSort _sort = ReviewSort.newest;

  String _plan = 'free';
  bool _bulkRunning = false;

  int get _activeCount =>
      _ratings.length + (_unrepliedOnly ? 1 : 0) + (_appId != null ? 1 : 0);

  String get _filterSig =>
      '$_appId-${(_ratings.toList()..sort()).join(",")}-$_unrepliedOnly-$_sort';

  @override
  void initState() {
    super.initState();
    _reloadReviews();
    _fetchMeta();
  }

  void _reloadReviews() {
    _future = Repo.reviews(
      appId: _appId,
      ratings: _ratings.toList(),
      unrepliedOnly: _unrepliedOnly,
      sort: _sort,
    );
  }

  void _fetchMeta() {
    Repo.apps().then((a) {
      if (mounted) setState(() => _apps = a);
    }).catchError((_) {});
    Repo.announcements().then((a) {
      if (mounted) setState(() => _announcements = a);
    }).catchError((_) {});
    Repo.plan().then((p) {
      if (mounted) setState(() => _plan = p);
    }).catchError((_) {});
  }

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    _fetchMeta();
    setState(_reloadReviews);
    await _future;
  }

  String _appName(String id) {
    for (final a in _apps) {
      if (a.id == id) return a.name;
    }
    return 'アプリ';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('レビュー'),
        actions: [
          IconButton(
            onPressed: _bulkRunning ? null : _bulkAction,
            tooltip: '一括AI返信',
            icon: _bulkRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_motion_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_announcements.isNotEmpty) _announcementBanner(),
          _bar(),
          if (_activeCount > 0) _activeChips(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: FutureBuilder<List<ReviewRow>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const ReviewListSkeleton();
                  }
                  if (snap.hasError) {
                    return ListView(children: [
                      const SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.wifi_off_rounded,
                        title: '読み込みに失敗しました',
                        subtitle: '${snap.error}',
                        action: FilledButton.tonal(
                          onPressed: () => setState(_reloadReviews),
                          child: const Text('再試行'),
                        ),
                      ),
                    ]);
                  }
                  final reviews = snap.data ?? [];
                  if (reviews.isEmpty) {
                    return ListView(children: [
                      const SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'レビューがありません',
                        subtitle: _activeCount > 0
                            ? '絞り込み条件に一致するレビューがありません。'
                            : 'アプリを連携し、ストアから取得すると表示されます。',
                        action: _activeCount > 0
                            ? TextButton(
                                onPressed: _clearAll,
                                child: const Text('絞り込みを解除'))
                            : null,
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: reviews.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final delay = (i < 12 ? i * 45 : 0).ms;
                      return _ReviewCard(
                        reviews[i],
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ReviewDetailScreen(reviews[i]),
                          ));
                          if (mounted) setState(_reloadReviews);
                        },
                      )
                          .animate(key: ValueKey('$_filterSig-$i'))
                          .fadeIn(duration: 280.ms, delay: delay)
                          .slideY(
                              begin: 0.08, end: 0, curve: Curves.easeOutCubic);
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- お知らせバナー ----
  Widget _announcementBanner() {
    return Column(
      children: _announcements.map((a) {
        final (bg, fg, icon) = switch (a.level) {
          'critical' => (
              AppTheme.danger.withValues(alpha: 0.10),
              AppTheme.danger,
              Icons.error_outline
            ),
          'warning' => (
              AppTheme.warning.withValues(alpha: 0.12),
              const Color(0xFF92600A),
              Icons.warning_amber_rounded
            ),
          _ => (
              AppTheme.primary.withValues(alpha: 0.08),
              AppTheme.primary,
              Icons.campaign_outlined
            ),
        };
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.title,
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: fg)),
                    if (a.body != null && a.body!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(a.body!,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF334155))),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 250.ms);
      }).toList(),
    );
  }

  // ---- 絞り込み / 並び替え バー ----
  Widget _bar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: _barButton(
              icon: Icons.tune_rounded,
              label: '絞り込み',
              badge: _activeCount > 0 ? '$_activeCount' : null,
              active: _activeCount > 0,
              onTap: _openFilterSheet,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _barButton(
              icon: Icons.swap_vert_rounded,
              label: _sort.label,
              active: _sort != ReviewSort.newest,
              onTap: _openSortSheet,
            ),
          ),
        ],
      ),
    );
  }

  Widget _barButton({
    required IconData icon,
    required String label,
    String? badge,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: active ? AppTheme.primary.withValues(alpha: 0.08) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? AppTheme.primary : AppTheme.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18, color: active ? AppTheme.primary : AppTheme.ink),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? AppTheme.primary : AppTheme.ink)),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: const BoxDecoration(
                    color: AppTheme.primary, shape: BoxShape.circle),
                child: Text(badge,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- 適用中フィルタのチップ（個別解除） ----
  Widget _activeChips() {
    final chips = <Widget>[];
    for (final r in _ratings.toList()..sort()) {
      chips.add(_activeChip('★$r', () => setState(() {
            _ratings.remove(r);
            _reloadReviews();
          })));
    }
    if (_unrepliedOnly) {
      chips.add(_activeChip('未返信', () => setState(() {
            _unrepliedOnly = false;
            _reloadReviews();
          })));
    }
    if (_appId != null) {
      chips.add(_activeChip(_appName(_appId!), () => setState(() {
            _appId = null;
            _reloadReviews();
          })));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            onPressed: _clearAll,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32)),
            child: const Text('すべて解除'),
          ),
        ],
      ),
    );
  }

  Widget _activeChip(String label, VoidCallback onRemove) {
    return InkWell(
      onTap: onRemove,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
        decoration: BoxDecoration(
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.close, size: 14, color: Colors.white),
          ],
        ),
      ),
    );
  }

  void _clearAll() {
    setState(() {
      _ratings.clear();
      _unrepliedOnly = false;
      _appId = null;
      _reloadReviews();
    });
  }

  // ---- 一括AI返信（プラン別ゲート） ----
  Future<void> _bulkAction() async {
    HapticFeedback.selectionClick();
    final limit = planBulkLimit(_plan); // 1=不可, null=無制限

    // Free（一括不可）はアップセル
    if (limit == 1) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('一括返信はProプランから'),
          content: const Text(
              'Proは最大20件、Maxは全レビューにまとめてAI返信を生成・投稿できます。'
              'アップグレードしますか？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('あとで')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('プランを見る')),
          ],
        ),
      );
      if (go == true && mounted) {
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const PlanScreen()));
      }
      return;
    }

    // 現在の絞り込み結果のうち未返信を対象にする
    final all = await _future;
    final unreplied = all.where((r) => !r.hasReply).toList();
    if (unreplied.isEmpty) {
      if (mounted) showSnack(context, '未返信のレビューはありません');
      return;
    }
    var targets = unreplied;
    var capped = false;
    if (limit != null && targets.length > limit) {
      targets = targets.sublist(0, limit);
      capped = true;
    }

    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('未返信 ${targets.length} 件に一括AI返信',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(
                capped
                    ? '現在のプランでは一度に $limit 件まで。残りは繰り返し実行するか、Maxで全件一括に。'
                    : 'AIが各レビューに合わせた返信を作成します。',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, 'post'),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('生成してストアに投稿'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(ctx, 'draft'),
                icon: const Icon(Icons.drafts_outlined, size: 18),
                label: const Text('下書きだけ生成'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return;

    setState(() => _bulkRunning = true);
    try {
      final res = await Repo.bulkReply(targets.map((r) => r.id).toList(),
          post: choice == 'post');
      final gen = (res['generated'] as num?)?.toInt() ?? 0;
      final posted = (res['posted'] as num?)?.toInt() ?? 0;
      HapticFeedback.mediumImpact();
      if (mounted) {
        showSnack(
          context,
          choice == 'post'
              ? '生成 $gen 件・投稿 $posted 件が完了しました'
              : '下書きを $gen 件生成しました',
          kind: SnackKind.success,
        );
        setState(_reloadReviews);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  // ---- 絞り込みシート ----
  Future<void> _openFilterSheet() async {
    final tempRatings = {..._ratings};
    var tempUnreplied = _unrepliedOnly;
    var tempApp = _appId;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.border,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('絞り込み',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 16),
                  const Text('評価（複数選択可）',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in [5, 4, 3, 2, 1])
                        _sheetToggle(
                          label: '★$r',
                          selected: tempRatings.contains(r),
                          onTap: () => setSheet(() {
                            tempRatings.contains(r)
                                ? tempRatings.remove(r)
                                : tempRatings.add(r);
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('状態', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _sheetToggle(
                    label: '未返信のみ',
                    selected: tempUnreplied,
                    onTap: () => setSheet(() => tempUnreplied = !tempUnreplied),
                  ),
                  if (_apps.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('アプリ',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _sheetToggle(
                          label: '全アプリ',
                          selected: tempApp == null,
                          onTap: () => setSheet(() => tempApp = null),
                        ),
                        for (final a in _apps)
                          _sheetToggle(
                            label: a.name,
                            selected: tempApp == a.id,
                            onTap: () => setSheet(() => tempApp = a.id),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setSheet(() {
                            tempRatings.clear();
                            tempUnreplied = false;
                            tempApp = null;
                          }),
                          child: const Text('リセット'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            setState(() {
                              _ratings
                                ..clear()
                                ..addAll(tempRatings);
                              _unrepliedOnly = tempUnreplied;
                              _appId = tempApp;
                              _reloadReviews();
                            });
                            Navigator.pop(ctx);
                          },
                          child: const Text('適用'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Widget _sheetToggle({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border:
              Border.all(color: selected ? AppTheme.primary : AppTheme.border),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppTheme.ink)),
      ),
    );
  }

  // ---- 並び替えシート ----
  Future<void> _openSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.border,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('並び替え',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              for (final s in ReviewSort.values)
                ListTile(
                  title: Text(s.label,
                      style: TextStyle(
                        fontWeight:
                            _sort == s ? FontWeight.w700 : FontWeight.w500,
                        color: _sort == s ? AppTheme.primary : AppTheme.ink,
                      )),
                  trailing: _sort == s
                      ? const Icon(Icons.check_rounded,
                          color: AppTheme.primary)
                      : null,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _sort = s;
                      _reloadReviews();
                    });
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final ReviewRow review;
  final VoidCallback onTap;
  const _ReviewCard(this.review, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final date = review.reviewedAt != null
        ? DateFormat('M/d').format(review.reviewedAt!)
        : '';
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StarRating(review.rating),
                  const SizedBox(width: 8),
                  if (review.appName != null)
                    Expanded(
                      child: Text(review.appName!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ),
                  Text(date,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
              if (review.title != null && review.title!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(review.title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
              if (review.body != null && review.body!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(review.body!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade800)),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  ...review.topics.take(3).map((t) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: TopicChip(t),
                      )),
                  const Spacer(),
                  if (review.isPosted)
                    _statusBadge('返信済み', AppTheme.success)
                  else if (review.hasReply)
                    _statusBadge('下書きあり', AppTheme.warning)
                  else
                    _statusBadge('未返信', Colors.grey),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
