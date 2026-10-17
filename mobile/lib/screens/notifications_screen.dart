import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_events.dart';
import '../data.dart';
import '../models.dart';
import '../notifications.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'review_detail_screen.dart';

/// アプリ内通知フィード。運営からのお知らせ＋通知対象のレビューを新しい順に表示する。
/// 対象（すべて / ★1〜2のみ）は設定タブの「通知」で切り替える。
/// OSプッシュ（APNs/FCM）ではなく、アプリを開いて確認する通知一覧。
class NotificationsScreen extends StatefulWidget {
  /// 通知タブが表示されるたびに変わる値（HomeScreen が渡す）。
  /// 変わったら静かに読み直す（設定で通知対象を変えた直後なども、開けば最新になる）。
  final int shownCount;

  const NotificationsScreen({super.key, this.shownCount = 0});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Announcement> _announcements = const [];
  List<ReviewRow> _reviews = const [];
  NotifScope _scope = NotifScope.all;
  bool _loading = true;

  /// レビューの読み込みに失敗した理由（成功したら null）。
  Object? _error;

  /// 詳細を開くために取り直している行。
  String? _openingId;

  @override
  void initState() {
    super.initState();
    _load();
    AppEvents.dataChanged.addListener(_onDataChanged);
    // Free の閲覧範囲（30日）はプランで変わるので、購入後も読み直す。
    AppEvents.planChanged.addListener(_load);
  }

  @override
  void didUpdateWidget(NotificationsScreen old) {
    super.didUpdateWidget(old);
    if (old.shownCount != widget.shownCount) _load();
  }

  @override
  void dispose() {
    AppEvents.dataChanged.removeListener(_onDataChanged);
    AppEvents.planChanged.removeListener(_load);
    super.dispose();
  }

  void _onDataChanged() {
    // 新着・返信（返信済みの印）・アプリ（名前・削除）が変わったときだけ読み直す。
    if (AppEvents.lastChange != DataChange.stores) _load();
  }

  /// 読み込む。2回目以降は今の表示を残したまま裏で差し替える（スピナーで画面が飛ばない）。
  Future<void> _load() async {
    // お知らせは失敗しても空で返る（announcements 内部で握る）。
    // レビューの失敗とは切り離して、お知らせだけでも出す。
    final announcementsFuture = Repo.announcements();
    final scope = await NotifStore.scope();
    List<ReviewRow>? reviews;
    Object? error;
    try {
      reviews = await NotifStore.targetReviews();
    } catch (e) {
      error = e;
    }
    final announcements = await announcementsFuture;
    if (!mounted) return;
    setState(() {
      _announcements = announcements;
      _scope = scope;
      if (reviews != null) _reviews = reviews;
      _error = error;
      _loading = false;
    });
  }

  Future<void> _retry() async {
    setState(() => _loading = true);
    await _load();
  }

  /// 通知の行は軽量な列しか持たない（返信の本文・トピックが無い）ので、
  /// 一覧と同じ列で取り直してから詳細を開く。そのまま渡すと既存の下書きが空欄で開き、
  /// AI を作り直して枠を無駄に使ってしまう。
  Future<void> _open(ReviewRow r) async {
    if (_openingId != null) return;
    setState(() => _openingId = r.id);
    try {
      final full = await Repo.reviewById(r.id);
      if (!mounted) return;
      if (full == null) {
        showSnack(context, 'このレビューは表示できません。削除されたか、閲覧できる期間を過ぎています。',
            kind: SnackKind.error);
        return;
      }
      setState(() => _openingId = null);
      // 返信すると AppEvents（replies）で読み直されるので、戻ったあとは何もしない。
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => ReviewDetailScreen(full)));
    } catch (e) {
      if (mounted) showError(context, e, prefix: 'レビューを開けませんでした');
    } finally {
      if (mounted && _openingId != null) setState(() => _openingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final hasError = _error != null;
    if (_announcements.isEmpty && _reviews.isEmpty) {
      // 読み込めなかったのか、本当に通知が無いのかを区別して出す。
      return hasError ? _errorState(context) : _empty(context);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_announcements.isNotEmpty) ...[
          _sectionLabel('お知らせ'),
          for (final a in _announcements) _announcementCard(context, a),
          const SizedBox(height: 16),
        ],
        // 読み込めなかったときは、前回の一覧を残したまま上に知らせる。
        if (hasError) _errorCard(context),
        if (_reviews.isNotEmpty) ...[
          _sectionLabel(
              _scope == NotifScope.low ? '低評価レビュー（★1〜2）' : '新着レビュー'),
          for (final r in _reviews) _reviewCard(context, r),
        ],
      ],
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

  /// 何も表示できないときのエラー（「通知はありません」と区別する）。
  Widget _errorState(BuildContext context) => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          Icon(Icons.cloud_off_outlined, size: 56, color: context.subtleC),
          const SizedBox(height: 12),
          const Center(
            child: Text('通知を読み込めませんでした',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Text(friendlyError(_error!),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.subtleC)),
          const SizedBox(height: 16),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('再試行'),
            ),
          ),
        ],
      );

  /// 一覧の上に出すエラー（お知らせや前回の一覧は残す）。
  Widget _errorCard(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: AppTheme.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.danger.withValues(alpha: 0.30)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 18, color: AppTheme.danger),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '通知を読み込めませんでした。${friendlyError(_error!)}',
                style: TextStyle(fontSize: 13, color: context.dangerTextC),
              ),
            ),
            TextButton(onPressed: _retry, child: const Text('再試行')),
          ],
        ),
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
    final opening = _openingId == r.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () => _open(r),
        leading: CircleAvatar(
          backgroundColor: AppTheme.ratingColor(r.rating).withValues(alpha: 0.12),
          child: Text('★${r.rating}',
              semanticsLabel: StarRating.semanticsLabel(r.rating),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.ratingTextC(r.rating))),
        ),
        title: Text(
          r.body?.isNotEmpty == true ? r.body! : (r.title ?? '(本文なし)'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [r.appName, storeLabel, date].where((s) => s != null && s.isNotEmpty).join(' ・ '),
          style: TextStyle(fontSize: 12, color: context.subtleC),
        ),
        // 下書きだけの行は返信済みにしない（投稿済み・返信済みの記録があるものだけ）。
        trailing: opening
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : r.isPosted
                ? const Icon(Icons.check_circle,
                    size: 18, color: AppTheme.success, semanticLabel: '返信済み')
                : const Icon(Icons.chevron_right),
      ),
    );
  }
}
