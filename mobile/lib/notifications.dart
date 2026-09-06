import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'models.dart';

/// アプリ内通知の既読管理。OSプッシュ（APNs/FCM）ではなく、アプリ内の通知フィード用。
/// 「最後に通知タブを開いた時刻」をローカル保存し、それ以降に来た低評価レビューを未読として数える。
class NotifStore {
  static const _key = 'notifications_last_seen';

  /// 最終閲覧時刻（未設定なら null）。
  static Future<DateTime?> lastSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = prefs.getString(_key);
      return s == null ? null : DateTime.tryParse(s)?.toLocal();
    } catch (_) {
      return null;
    }
  }

  /// 今を既読位置として記録する（通知タブを開いたとき）。
  static Future<void> markSeenNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, DateTime.now().toUtc().toIso8601String());
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
}
