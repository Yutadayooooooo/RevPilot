import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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

  /// 初期化。多重呼び出しは安全。
  ///
  /// 通知の許可はここでは求めない。何のための通知か分からないまま OS のダイアログを出すと
  /// 断られやすく、一度断られると設定アプリからしか戻せないため、
  /// 説明の画面（[NotificationPrimer]）で同意を得てから [requestPermission] を呼ぶ。
  static Future<void> init() async {
    if (_ready) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
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
    }
    _ready = true;
  }

  /// OS の通知許可ダイアログを出す（すでに決まっていれば出ない）。
  static Future<bool> requestPermission() async {
    await init();
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin>()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                  IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, badge: true, sound: true) ??
          false;
    }
    return false;
  }

  /// ダイアログを出さずに、すでに許可されているかを調べる。
  static Future<bool> alreadyAllowed() async {
    await init();
    try {
      if (Platform.isAndroid) {
        return await _plugin
                .resolvePlatformSpecificImplementation<
                    AndroidFlutterLocalNotificationsPlugin>()
                ?.areNotificationsEnabled() ??
            false;
      }
      if (Platform.isIOS) {
        final p = await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.checkPermissions();
        return p?.isEnabled ?? false;
      }
    } catch (_) {}
    return false;
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
}
