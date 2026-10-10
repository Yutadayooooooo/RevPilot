import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'config.dart';
import 'data.dart';
import 'local_notifications.dart';

/// アプリが起動していないときに届いた通知の処理。
///
/// バックグラウンド用のハンドラは**トップレベル関数**でなければならない。
/// アプリとは別のisolateで実行されるため、`vm:entry-point` を付けて
/// リリースビルドのツリーシェイクから守る必要がある。
///
/// ここでは何もしない。`notification` を含むメッセージはOSが自動で表示するので、
/// このハンドラは「受信できていること」を確認する以上の役割を持たない。
/// 余計な初期化をここで走らせると、通知が来るたびに無駄な処理が動く。
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {}

/// リモートプッシュ通知（FCM）。
///
/// ローカル通知（[LocalNotifier]）との違いは「アプリを終了していても届く」こと。
/// レビュー取得はサーバー側のcronが毎時回しているので、
/// 端末が起きている必要はなく、サーバーから直接届く。
///
/// Firebaseの設定（FIREBASE_* の dart-define）が入っていなければ
/// 何も初期化せず、従来どおりローカル通知だけで動く。
class PushService {
  static bool _initialized = false;
  static String? _currentToken;

  /// デバッグ表示用。初期化や登録に失敗した理由を残す。
  static String? lastError;

  /// この端末でリモートpushを使える構成になっているか。
  static bool get configured =>
      (Platform.isIOS || Platform.isAndroid) &&
      AppConfig.firebaseProjectId.isNotEmpty &&
      AppConfig.firebaseSenderId.isNotEmpty &&
      _appId.isNotEmpty &&
      _apiKey.isNotEmpty;

  static String get _appId => Platform.isIOS
      ? AppConfig.firebaseAppIdIos
      : AppConfig.firebaseAppIdAndroid;

  static String get _apiKey => Platform.isIOS
      ? AppConfig.firebaseApiKeyIos
      : AppConfig.firebaseApiKeyAndroid;

  /// Firebaseの初期化。main() から一度だけ呼ぶ。失敗しても例外は投げない
  /// （pushが使えないだけで、アプリは動かし続ける）。
  static Future<void> init() async {
    if (_initialized || !configured) return;
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: AppConfig.firebaseSenderId,
          projectId: AppConfig.firebaseProjectId,
          iosBundleId: Platform.isIOS ? AppConfig.iosBundleId : null,
        ),
      );

      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

      // iOSはフォアグラウンドでも自前で出さずOSに任せられる。
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );

      // Androidはフォアグラウンド中の通知をOSが表示しないので、自前で出す。
      FirebaseMessaging.onMessage.listen(_showForeground);

      // 端末側でトークンが再発行されることがある（再インストール・復元など）。
      // 追従しないと、その端末には二度と通知が届かなくなる。
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        _currentToken = token;
        _register(token);
      });

      _initialized = true;
    } catch (e) {
      lastError = '$e';
      if (kDebugMode) debugPrint('[push] init failed: $e');
    }
  }

  /// 通知の許可を求め、この端末を通知先として登録する。ログイン後に呼ぶ。
  static Future<void> registerForCurrentUser() async {
    if (!_initialized) await init();
    if (!_initialized) return;

    try {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        lastError = '通知が許可されていません';
        return;
      }

      final token = await _obtainToken();
      if (token == null) {
        lastError = 'トークンを取得できませんでした';
        return;
      }
      _currentToken = token;
      await _register(token);
    } catch (e) {
      lastError = '$e';
      if (kDebugMode) debugPrint('[push] register failed: $e');
    }
  }

  /// FCMトークンを取得する。
  ///
  /// iOSでは、APNsが端末トークンを返すまで getToken() が null を返す。
  /// 起動直後は間に合わないことが多いので、少し待って数回試す。
  /// （ここを1回で諦めると「初回起動では通知が来ない」という再現しにくい不具合になる）
  static Future<String?> _obtainToken() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      if (Platform.isIOS) {
        final apns = await FirebaseMessaging.instance.getAPNSToken();
        if (apns == null) {
          await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
          continue;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) return token;
      await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
    }
    return null;
  }

  static Future<void> _register(String token) async {
    try {
      await Repo.registerPushToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
    } catch (e) {
      lastError = '$e';
      if (kDebugMode) debugPrint('[push] token upload failed: $e');
    }
  }

  /// この端末を通知先から外す。**ログアウトの前**に呼ぶこと。
  /// （認証が切れてからでは自分の行を消せず、次の利用者に通知が届き続ける）
  static Future<void> unregister() async {
    final token = _currentToken;
    if (token == null) return;
    try {
      await Repo.unregisterPushToken(token);
    } catch (_) {
      // 消せなくても、サーバー側は別アカウントの登録で後勝ちに上書きされる。
    }
    _currentToken = null;
  }

  /// フォアグラウンド受信時の表示（Android向け）。
  static Future<void> _showForeground(RemoteMessage message) async {
    if (!Platform.isAndroid) return; // iOSはOSが出す
    final n = message.notification;
    if (n == null) return;
    await LocalNotifier.showRaw(
      id: message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
      title: n.title ?? '新しいレビュー',
      body: n.body ?? '',
    );
  }
}
