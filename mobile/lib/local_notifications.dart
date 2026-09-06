import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

/// 新着レビューをOSのバナー通知で知らせる（ローカル通知）。
///
/// リモートpush(APNs/FCM)と違い **Apple Developer登録もFirebaseも不要**で、
/// 無料の署名のまま iOS / Android どちらでも本物のバナーが出る。
/// ただし「アプリが起動している間に検知したものを通知する」仕組みなので、
/// アプリを完全終了している間に届いたレビューは（リモートpushを入れるまで）通知されない。
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
}
