import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'models.dart';

/// 低評価レビューをOSのバナー通知で知らせる（ローカル通知）。
///
/// リモートpush(APNs/FCM)と違い **Apple Developer登録が不要**で、無料の署名でも動く。
/// ただし「アプリが起動している間に検知したものを通知する」仕組みなので、
/// アプリを完全終了している間に届いたレビューは（リモートpushを入れるまで）通知されない。
class LocalNotifier {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channelId = 'low_rating';
  static const _channelName = '低評価レビュー';
  static const _channelDesc = '★1〜2のレビューが届いたときにお知らせします';

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

  /// 低評価レビュー1件をバナー表示する。
  static Future<void> showLowRating(ReviewRow r) async {
    await init();
    final store = r.store == 'appstore' ? 'App Store' : 'Google Play';
    final app = r.appName != null && r.appName!.isNotEmpty ? '・${r.appName}' : '';
    final text = (r.body?.trim().isNotEmpty == true)
        ? r.body!.trim()
        : (r.title?.trim().isNotEmpty == true ? r.title!.trim() : '(本文なし)');

    await _plugin.show(
      r.id.hashCode & 0x7fffffff, // 同じレビューは同じIDで上書き
      '★${r.rating} の低評価レビュー$app',
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
