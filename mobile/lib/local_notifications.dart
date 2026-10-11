import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';

/// 新着レビューをOSのバナー通知で知らせる（ローカル通知）。
///
/// 役割はリモートpush([PushService])との住み分け:
///   - 起動中に前景ポーリングが拾った新着 → ここ
///   - Androidで前景受信した push の表示    → ここ（OSが出してくれないため）
///   - アプリ終了中の新着                    → リモートpush
/// Firebaseを設定していない環境では、これが唯一の通知経路になる。
class LocalNotifier {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'reviews';
  static const _channelName = 'レビュー通知';
  static const _channelDesc = '新しいレビューが届いたときにお知らせします';

  /// 旧バージョンで作った低評価専用チャンネル（見出し変更に伴い廃止）。
  static const _legacyChannelId = 'low_rating';

  /// 初期化と通知許可のリクエスト。多重呼び出しは安全。
  static Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );

    if (Platform.isAndroid) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ は実行時許可が必要。チャンネルは事前に作っておく。
      await impl?.deleteNotificationChannel(_legacyChannelId);
      await impl?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ),
      );
      await impl?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
    _ready = true;
  }

  /// 任意の見出し・本文でバナーを出す。
  ///
  /// リモートpush（FCM）をフォアグラウンドで受け取ったときに使う。
  /// Androidは起動中のメッセージをOSが表示しないため、自前で出す必要がある。
  static Future<void> showRaw({
    required int id,
    required String title,
    required String body,
  }) async {
    await init();
    await _plugin.show(
      id & 0x7fffffff,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      ),
    );
  }

  /// 新着レビュー1件をバナー表示する。
  /// 見出しは「新しいレビュー ★n・アプリ名」で、評価の高低で文言は変えない。
  static Future<void> showReview(ReviewRow r) async {
    await init();
    final store = r.store == 'appstore' ? 'App Store' : 'Google Play';
    final app = r.appName != null && r.appName!.isNotEmpty ? '・${r.appName}' : '';
    final text = (r.body?.trim().isNotEmpty == true)
        ? r.body!.trim()
        : (r.title?.trim().isNotEmpty == true ? r.title!.trim() : '(本文なし)');

    await _plugin.show(
      r.id.hashCode & 0x7fffffff, // 同じレビューは同じIDで上書き
      '新しいレビュー ★${r.rating}$app',
      '$store｜$text',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
        // iOSはフォアグラウンドでもバナーを出す
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      ),
    );
  }

  /// トライアル終了のお知らせの通知ID（1件だけ予約し、再購入時は上書きする）。
  static const _trialReminderId = 0x7e1a1;

  /// 無料トライアルが終わる2日前にお知らせを予約する。
  ///
  /// ストアはトライアル終了時に自動で課金を始めるが、事前に知らせてはくれない。
  /// 「気づいたら課金されていた」は返金依頼と低評価レビューの典型的な原因なので、
  /// 続けるかどうかを判断できるタイミングでこちらから知らせる。
  static Future<void> scheduleTrialReminder({
    required DateTime trialEndsAt,
    required String planName,
  }) async {
    final at = trialEndsAt.toUtc().subtract(const Duration(days: 2));
    if (at.isBefore(DateTime.now().toUtc())) return;
    await init();
    final manage = Platform.isIOS
        ? '「設定 > Apple ID > サブスクリプション」'
        : 'Google Play の「定期購入」';
    await _plugin.zonedSchedule(
      _trialReminderId,
      '$planNameの無料期間はあと2日です',
      '続ける場合は手続き不要です。不要なら$manageから解約すると料金はかかりません。',
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentSound: true,
        ),
      ),
      // 正確な時刻は不要（数分ずれても問題ない）。exact にすると Android 14+ で
      // SCHEDULE_EXACT_ALARM の許可が必要になるため使わない。
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}
