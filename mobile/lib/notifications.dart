import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'models.dart';

/// アプリ内通知の状態管理。
/// - 未読バッジ: 「最後に通知タブを開いた時刻」以降に来た低評価レビュー数。
/// - バナー通知: 一度バナーを出したレビューIDを覚えて、同じものを二度出さない。
class NotifStore {
  static const _seenKey = 'notifications_last_seen';
  static const _notifiedKey = 'notifications_notified_ids';
  static const _maxRemembered = 500;

  /// 最終閲覧時刻（未設定なら null）。
  static Future<DateTime?> lastSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_seenKey);
      return s == null ? null : DateTime.tryParse(s)?.toLocal();
    } catch (_) {
      return null;
    }
  }

  /// 今を既読位置として記録する（通知タブを開いたとき）。
  static Future<void> markSeenNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_seenKey, DateTime.now().toUtc().toIso8601String());
    } catch (_) {
      // 保存失敗はバッジが消えないだけなので握りつぶす。
    }
  }

  /// 未読の低評価レビュー件数。初回（未閲覧）は既存の低評価を未読として提示する。
  static Future<int> unreadCount() async {
    try {
      final reviews = await lowRatingReviews();
      final seen = await lastSeen();
      if (seen == null) return reviews.length;
      return reviews
          .where((r) => r.reviewedAt != null && r.reviewedAt!.isAfter(seen))
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// 通知対象の低評価レビュー（★1〜2）を新しい順で取得。
  static Future<List<ReviewRow>> lowRatingReviews() =>
      Repo.reviews(ratings: const [1, 2], sort: ReviewSort.newest);

  /// まだバナーを出していない低評価レビューを返し、同時に「通知済み」として記録する。
  ///
  /// 初回起動時は既存分をすべて通知済み扱いにして、過去のレビューで
  /// バナーが大量に出るのを防ぐ（＝以降の新着だけ通知する）。
  static Future<List<ReviewRow>> takeUnnotified() async {
    try {
      final reviews = await lowRatingReviews();
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_notifiedKey);

      if (stored == null) {
        await _remember(const [], reviews.map((r) => r.id));
        return const [];
      }

      final known = stored.toSet();
      final fresh = reviews.where((r) => !known.contains(r.id)).toList();
      if (fresh.isNotEmpty) {
        await _remember(stored, fresh.map((r) => r.id));
      }
      return fresh;
    } catch (_) {
      return const [];
    }
  }

  /// 通知済みIDを追記保存する（古い順に切り詰めて上限を保つ）。
  static Future<void> _remember(
      List<String> existing, Iterable<String> added) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final merged = [...existing, ...added];
      final trimmed = merged.length <= _maxRemembered
          ? merged
          : merged.sublist(merged.length - _maxRemembered);
      await prefs.setStringList(_notifiedKey, trimmed);
    } catch (_) {
      // 保存失敗時は次回また通知されるだけなので握りつぶす。
    }
  }
}
