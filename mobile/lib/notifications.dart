import 'package:shared_preferences/shared_preferences.dart';

import 'data.dart';
import 'models.dart';

/// 通知の対象範囲。
/// - [all] : すべての新着レビュー（既定）
/// - [low] : ★1〜2 の低評価だけ
enum NotifScope { all, low }

/// アプリ内通知の状態管理。
/// - 通知対象: すべて / ★1〜2のみ（設定タブで切り替え。バナー・バッジ・通知タブで共通）。
/// - 未読バッジ: 「最後に通知タブを開いた時刻」以降に来たレビュー数。
/// - バナー通知: 一度バナーを出したレビューIDを覚えて、同じものを二度出さない。
class NotifStore {
  static const _seenKey = 'notifications_last_seen';
  static const _notifiedKey = 'notifications_notified_ids';
  static const _scopeKey = 'notifications_scope';
  static const _maxRemembered = 500;

  /// 通知タブのフィードに並べる最大件数（すべて対象だと際限なく増えるため）。
  static const feedLimit = 50;

  /// 現在の通知対象（未設定なら「すべて」）。
  static Future<NotifScope> scope() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_scopeKey) == 'low' ? NotifScope.low : NotifScope.all;
    } catch (_) {
      return NotifScope.all;
    }
  }

  /// 通知対象を保存する。
  static Future<void> setScope(NotifScope s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_scopeKey, s == NotifScope.low ? 'low' : 'all');
    } catch (_) {
      // 保存失敗時は既定（すべて）のままなので握りつぶす。
    }
  }

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

  /// 未読レビュー件数。初回（未閲覧）は既存分を未読として提示する。
  static Future<int> unreadCount() async {
    try {
      final reviews = await targetReviews();
      final seen = await lastSeen();
      if (seen == null) return reviews.length;
      return reviews
          .where((r) => r.reviewedAt != null && r.reviewedAt!.isAfter(seen))
          .length;
    } catch (_) {
      return 0;
    }
  }

  /// 通知対象のレビューを新しい順で取得（フィード表示用に上限あり）。
  static Future<List<ReviewRow>> targetReviews() async {
    final s = await scope();
    final rows = await Repo.reviews(
      ratings: s == NotifScope.low ? const [1, 2] : null,
      sort: ReviewSort.newest,
    );
    return rows.length <= feedLimit ? rows : rows.sublist(0, feedLimit);
  }

  /// まだバナーを出していないレビューを返し、同時に「通知済み」として記録する。
  ///
  /// 初回起動時は既存分をすべて通知済み扱いにして、過去のレビューで
  /// バナーが大量に出るのを防ぐ（＝以降の新着だけ通知する）。
  static Future<List<ReviewRow>> takeUnnotified() async {
    try {
      final reviews = await targetReviews();
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
