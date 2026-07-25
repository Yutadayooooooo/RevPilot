import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'review_detail_screen.dart';

class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  late Future<List<ReviewRow>> _future;
  List<AppRow> _apps = [];
  String? _appFilter;
  int? _ratingFilter; // 1..5 で「その星のみ」
  bool _unrepliedOnly = false;

  /// フィルタ条件のシグネチャ。変化時のみリストを再アニメーションさせる。
  String get _filterSig => '$_appFilter-$_ratingFilter-$_unrepliedOnly';

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = Repo.reviews(
      appId: _appFilter,
      minRating: _ratingFilter,
      maxRating: _ratingFilter,
      unrepliedOnly: _unrepliedOnly,
    );
    Repo.apps().then((a) {
      if (mounted) setState(() => _apps = a);
    }).catchError((_) {});
  }

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    setState(_load);
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('レビュー')),
      body: Column(
        children: [
          _filters(),
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
                          onPressed: () => setState(_load),
                          child: const Text('再試行'),
                        ),
                      ),
                    ]);
                  }
                  final reviews = snap.data ?? [];
                  if (reviews.isEmpty) {
                    return ListView(children: const [
                      SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'レビューがありません',
                        subtitle: '条件を変えるか、アプリを連携すると表示されます。',
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: reviews.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      // 先頭12件のみ段階表示（大量スクロール時の負荷を避ける）。
                      final delay = (i < 12 ? i * 45 : 0).ms;
                      return _ReviewCard(
                        reviews[i],
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => ReviewDetailScreen(reviews[i]),
                          ));
                          if (mounted) setState(_load);
                        },
                      )
                          .animate(key: ValueKey('$_filterSig-$i'))
                          .fadeIn(duration: 280.ms, delay: delay)
                          .slideY(begin: 0.08, end: 0, curve: Curves.easeOutCubic);
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

  Widget _filters() {
    var appLabel = '全アプリ';
    if (_appFilter != null) {
      for (final a in _apps) {
        if (a.id == _appFilter) {
          appLabel = a.name;
          break;
        }
      }
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _pill(
              label: '未返信のみ',
              selected: _unrepliedOnly,
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  _unrepliedOnly = !_unrepliedOnly;
                  _load();
                });
              },
            ),
            for (final r in [5, 4, 3, 2, 1])
              _pill(
                label: '★$r',
                selected: _ratingFilter == r,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _ratingFilter = _ratingFilter == r ? null : r;
                    _load();
                  });
                },
              ),
            if (_apps.isNotEmpty)
              _pill(
                label: appLabel,
                selected: _appFilter != null,
                onTap: _pickApp,
                trailing: Icon(Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: _appFilter != null ? Colors.white : AppTheme.ink),
              ),
          ],
        ),
      ),
    );
  }

  /// 絞り込みピル（選択＝インディゴ塗り＋白文字ではっきり視認）。
  Widget _pill({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppTheme.ink,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 2), trailing],
            ],
          ),
        ),
      ),
    );
  }

  /// アプリ絞り込みをボトムシートで選ばせる（モバイル定番のUI）。
  Future<void> _pickApp() async {
    HapticFeedback.selectionClick();
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
                  child: Text('アプリで絞り込み',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              _appTile(ctx, null, '全アプリ', Icons.apps),
              for (final a in _apps)
                _appTile(ctx, a.id, a.name,
                    a.store == 'appstore' ? Icons.apple : Icons.android),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Widget _appTile(BuildContext ctx, String? id, String name, IconData icon) {
    final selected = _appFilter == id;
    return ListTile(
      leading: Icon(icon,
          color: selected ? AppTheme.primary : Colors.grey.shade700),
      title: Text(name,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppTheme.primary : AppTheme.ink,
          )),
      trailing:
          selected ? const Icon(Icons.check_rounded, color: AppTheme.primary) : null,
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() {
          _appFilter = id;
          _load();
        });
        Navigator.pop(ctx);
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
