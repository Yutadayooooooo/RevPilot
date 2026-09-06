import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../models.dart';
import '../notifications.dart';
import '../theme.dart';
import 'review_detail_screen.dart';

/// アプリ内通知フィード。運営からのお知らせ＋通知対象のレビューを新しい順に表示する。
/// 対象（すべて / ★1〜2のみ）は設定タブの「通知」で切り替える。
/// OSプッシュ（APNs/FCM）ではなく、アプリを開いて確認する通知一覧。
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<_NotifData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_NotifData> _load() async {
    // お知らせは失敗しても画面を落とさない（announcements内部で空フォールバック）。
    final announcements = await Repo.announcements();
    final scope = await NotifStore.scope();
    final reviews = await NotifStore.targetReviews();
    return _NotifData(
        announcements: announcements, reviews: reviews, scope: scope);
  }

  Future<void> _reload() async {
    final data = await _load();
    if (mounted) setState(() => _future = Future.value(data));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: FutureBuilder<_NotifData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data ??
              _NotifData(
                  announcements: const [],
                  reviews: const [],
                  scope: NotifScope.all);
          final isEmpty = data.announcements.isEmpty && data.reviews.isEmpty;
          return RefreshIndicator(
            onRefresh: _reload,
            child: isEmpty
                ? _empty(context)
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (data.announcements.isNotEmpty) ...[
                        _sectionLabel('お知らせ'),
                        for (final a in data.announcements) _announcementCard(context, a),
                        const SizedBox(height: 16),
                      ],
                      if (data.reviews.isNotEmpty) ...[
                        _sectionLabel(data.scope == NotifScope.low
                            ? '低評価レビュー（★1〜2）'
                            : '新着レビュー'),
                        for (final r in data.reviews) _reviewCard(context, r),
                      ],
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => ListView(
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.25),
          Icon(Icons.notifications_none, size: 56, color: context.subtleC),
          const SizedBox(height: 12),
          Center(
            child: Text('新しい通知はありません',
                style: TextStyle(color: context.subtleC)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text('新しいレビューが入るとここに表示されます',
                style: TextStyle(fontSize: 12, color: context.subtleC)),
          ),
        ],
      );

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: context.subtleC)),
      );

  Widget _announcementCard(BuildContext context, Announcement a) {
    final color = switch (a.level) {
      'critical' => AppTheme.danger,
      'warning' => AppTheme.warning,
      _ => AppTheme.primary,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.campaign_outlined, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.title,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (a.body != null && a.body!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(a.body!,
                      style: TextStyle(fontSize: 13, color: context.inkC, height: 1.4)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewCard(BuildContext context, ReviewRow r) {
    final storeLabel = r.store == 'appstore' ? 'App Store' : 'Google Play';
    final date = r.reviewedAt != null ? DateFormat('M/d HH:mm').format(r.reviewedAt!) : '';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ReviewDetailScreen(r))),
        leading: CircleAvatar(
          backgroundColor: AppTheme.danger.withValues(alpha: 0.12),
          child: Text('★${r.rating}',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.danger)),
        ),
        title: Text(
          r.body?.isNotEmpty == true ? r.body! : (r.title ?? '(本文なし)'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [r.appName, storeLabel, date].where((s) => s != null && s.isNotEmpty).join(' ・ '),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: r.hasReply
            ? const Icon(Icons.check_circle, size: 18, color: AppTheme.success)
            : const Icon(Icons.chevron_right),
      ),
    );
  }
}

class _NotifData {
  final List<Announcement> announcements;
  final List<ReviewRow> reviews;
  final NotifScope scope;
  _NotifData(
      {required this.announcements, required this.reviews, required this.scope});
}
