import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
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

  /// これより前に書かれたレビューはバナーで知らせない（通知済みとして記録だけする）。
  ///
  /// アプリを追加した直後の取り込みでは過去のレビューがまとめて入る。
  /// サーバーは追加時刻の24時間前より古いものを通知しない（lib/poll.ts の NOTIFY_BACKLOG_GRACE_MS）。
  /// 端末ではここで日時を見ないと、数か月前の★1が「新しいレビュー」としてバナーで出てしまう
  /// （アプリの追加時刻は読んでいないので、今から24時間で区切る）。
  static const _bannerMaxAge = Duration(hours: 24);

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

  /// 通知対象を保存する。保存できたら true。
  ///
  /// リモートpushはサーバーが送るので、先にサーバー（profiles.push_scope）へ保存し、
  /// 成功したときだけ端末にも反映する。通信に失敗したら false を返し、端末の値も変えない
  /// （以前は失敗を握りつぶしていたため、画面は「★1〜2のみ」なのに全件のpushが届き続けた）。
  /// 呼び出し側はスイッチを元に戻し、保存できなかったことを知らせること。
  static Future<bool> setScope(NotifScope s) async {
    final value = s == NotifScope.low ? 'low' : 'all';
    // API が無い構成ではサーバーが通知を送らないので、端末だけで足りる。
    if (AppConfig.hasApi) {
      try {
        await Repo.savePushScope(value);
      } catch (e) {
        if (kDebugMode) debugPrint('[notif] savePushScope failed: $e');
        return false;
      }
    }
    await _saveLocalScope(value);
    return true;
  }

  static Future<void> _saveLocalScope(String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_scopeKey, value);
    } catch (_) {
      // 保存失敗時は既定（すべて）のままなので握りつぶす。
    }
  }

  /// サーバー（profiles.push_scope）の値を端末に取り込み、その値を返す。
  ///
  /// 機種変更・再インストールのあとは端末の初期値「すべて」が表示されるが、
  /// サーバーは「★1〜2のみ」のまま、という食い違いを防ぐ。設定タブを開いたときに呼ぶ。
  /// 読めない・アプリで扱えない値（'off' など）のときは端末の値をそのまま返す。
  static Future<NotifScope> syncScopeFromServer() async {
    final local = await scope();
    try {
      final remote = switch (await Repo.pushScope()) {
        'low' => NotifScope.low,
        'all' => NotifScope.all,
        _ => null,
      };
      if (remote == null || remote == local) return local;
      await _saveLocalScope(remote == NotifScope.low ? 'low' : 'all');
      return remote;
    } catch (_) {
      return local;
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
  /// 読み込めなかったときは null（バッジは前回の値のままにする。0 にすると「通知が無い」と誤解される）。
  static Future<int?> unreadCount() async {
    try {
      final reviews = await targetReviews();
      final seen = await lastSeen();
      if (seen == null) return reviews.length;
      return reviews
          .where((r) => r.reviewedAt != null && r.reviewedAt!.isAfter(seen))
          .length;
    } catch (_) {
      return null;
    }
  }

  /// 通知対象のレビューを新しい順で取得（フィード表示用に上限あり）。
  /// 失敗したら例外をそのまま投げる（通知タブはエラーと再試行を出す）。
  ///
  /// 軽量クエリを使う。ここは定期チェックから繰り返し呼ばれるので、
  /// 一覧用の重いクエリを使うと通信量が積み上がる。
  static Future<List<ReviewRow>> targetReviews() async {
    final s = await scope();
    return Repo.reviewsForNotify(
      ratings: s == NotifScope.low ? const [1, 2] : null,
      limit: feedLimit,
    );
  }

  /// まだバナーを出していないレビューを返し、同時に「通知済み」として記録する。
  ///
  /// 初回起動時は既存分をすべて通知済み扱いにして、過去のレビューで
  /// バナーが大量に出るのを防ぐ（＝以降の新着だけ通知する）。
  /// 初めて見るレビューでも、書かれてから24時間より前のもの（アプリ追加時に取り込んだ過去分）は
  /// 記録だけして返さない。日時が分からないものは新着として扱う（サーバーと同じ）。
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
      final since = DateTime.now().subtract(_bannerMaxAge);
      return fresh
          .where((r) => r.reviewedAt == null || r.reviewedAt!.isAfter(since))
          .toList();
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

/// 通知をタップしたときの行き先。
///
/// リモートpushはサーバーが data に type と app_id（1件だけのときは review_id も）を載せる。
/// ローカル通知は payload に同じ形の JSON を入れる。
class NotifTarget {
  /// 'reviews'（新着レビュー）/ 'weekly_summary'（週次サマリー）/ 'test' など。
  final String type;
  final String? reviewId;
  final String? appId;

  const NotifTarget({this.type = 'reviews', this.reviewId, this.appId});

  /// FCM の data から作る。中身が無ければ null。
  static NotifTarget? fromData(Map<String, dynamic> data) {
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    final type = text(data['type']);
    final reviewId = text(data['review_id']);
    final appId = text(data['app_id']);
    if (type == null && reviewId == null && appId == null) return null;
    return NotifTarget(
        type: type ?? 'reviews', reviewId: reviewId, appId: appId);
  }

  /// ローカル通知の payload から作る。読めなければ null。
  static NotifTarget? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      return fromData(Map<String, dynamic>.from(jsonDecode(payload) as Map));
    } catch (_) {
      return null;
    }
  }

  String toPayload() => jsonEncode({
        'type': type,
        if (reviewId != null) 'review_id': reviewId,
        if (appId != null) 'app_id': appId,
      });
}

/// 通知タップの受け渡し口。
///
/// タップはアプリがどの状態でも届く（終了中からの起動・バックグラウンドからの復帰・起動中）。
/// 受け取る側（push.dart / local_notifications.dart）はここに置くだけにして、
/// 画面の切り替えはホーム画面がまとめて行う。ログイン前に届いた分も、ホームが出たときに拾える。
class NotifTap {
  NotifTap._();

  /// まだ処理していないタップ。ホーム画面が拾って null に戻す。
  static final pending = ValueNotifier<NotifTarget?>(null);

  /// レビュータブへの依頼「このアプリ（app_id）の未返信を表示して」。
  /// ReviewsScreen が拾って絞り込みを切り替え、null に戻す。
  static final reviewsFocus = ValueNotifier<String?>(null);

  static void open(NotifTarget target) => pending.value = target;

  /// ログアウト時に呼ぶ（前のアカウントの行き先を持ち越さない）。
  static void clear() {
    pending.value = null;
    reviewsFocus.value = null;
  }
}
