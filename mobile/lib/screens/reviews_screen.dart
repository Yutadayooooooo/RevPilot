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
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            FilterChip(
              label: const Text('未返信のみ'),
              selected: _unrepliedOnly,
              onSelected: (v) {
                HapticFeedback.selectionClick();
                setState(() {
                  _unrepliedOnly = v;
                  _load();
                });
              },
            ),
            const SizedBox(width: 8),
            for (final r in [5, 4, 3, 2, 1]) ...[
              FilterChip(
                label: Text('★$r'),
                selected: _ratingFilter == r,
                onSelected: (v) {
                  HapticFeedback.selectionClick();
                  setState(() {
                    _ratingFilter = v ? r : null;
                    _load();
                  });
                },
              ),
              const SizedBox(width: 8),
            ],
            if (_apps.isNotEmpty)
              DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _appFilter,
                  hint: const Text('全アプリ'),
                  borderRadius: BorderRadius.circular(12),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全アプリ')),
                    for (final a in _apps)
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() {
                    _appFilter = v;
                    _load();
                  }),
                ),
              ),
          ],
        ),
      ),
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
