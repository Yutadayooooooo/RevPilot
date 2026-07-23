import 'package:flutter/material.dart';

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

  @override
  void initState() {
    super.initState();
    _future = Repo.reviews();
  }

  Future<void> _refresh() async {
    setState(() => _future = Repo.reviews());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分析', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<ReviewRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final reviews = snap.data ?? [];
            if (reviews.isEmpty) {
              return ListView(children: const [
                SizedBox(height: 80),
                EmptyState(
                  icon: Icons.insights_outlined,
                  title: 'まだ分析できるデータがありません',
                  subtitle: 'レビューが集まると平均評価や傾向を表示します。',
                ),
              ]);
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _summaryRow(reviews),
                const SizedBox(height: 16),
                _ratingDistribution(reviews),
                const SizedBox(height: 16),
                _topicBreakdown(reviews),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _summaryRow(List<ReviewRow> reviews) {
    final avg = reviews.map((r) => r.rating).reduce((a, b) => a + b) /
        reviews.length;
    final unreplied = reviews.where((r) => !r.hasReply).length;
    return Row(
      children: [
        Expanded(
            child: _statCard(
                '平均評価', avg.toStringAsFixed(2), Icons.star_rounded,
                color: AppTheme.ratingColor(avg.round()))),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('レビュー数', '${reviews.length}',
                Icons.rate_review_outlined)),
        const SizedBox(width: 12),
        Expanded(
            child: _statCard('未返信', '$unreplied', Icons.mark_email_unread_outlined,
                color: unreplied > 0 ? const Color(0xFFDC2626) : null)),
      ],
    );
  }

  Widget _statCard(String label, String value, IconData icon, {Color? color}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: color ?? Colors.grey.shade500),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: color ?? Colors.black87)),
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
    final maxCount =
        counts.values.fold<int>(1, (m, v) => v > m ? v : m);
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
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (counts[star] ?? 0) / maxCount,
                        minHeight: 10,
                        backgroundColor: const Color(0xFFEEF2F7),
                        color: AppTheme.ratingColor(star),
                      ),
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
              children: sorted
                  .map((e) => Chip(
                        label: Text(
                            '${topicLabels[e.key] ?? e.key} ${e.value}'),
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.06),
                        side: BorderSide.none,
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
