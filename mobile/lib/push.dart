import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'app_events.dart';
import 'config.dart';
import 'data.dart';
import 'local_notifications.dart';
import 'notifications.dart';
import 'ui.dart';

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

  /// 初期化や登録に失敗した理由（利用者に見せられる短い日本語）。
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
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);

      // 通知のタップ。バックグラウンドからの復帰はストリームで、
      // 終了中からの起動は getInitialMessage で届く。行き先はホーム画面がまとめて開く。
      FirebaseMessaging.onMessageOpenedApp.listen(_openFrom);
      unawaited(FirebaseMessaging.instance.getInitialMessage().then((m) {
        if (m != null) _openFrom(m);
      }).catchError((_) {}));

      // 端末側でトークンが再発行されることがある（再インストール・復元など）。
      // 追従しないと、その端末には二度と通知が届かなくなる。
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        _currentToken = token;
        _register(token);
      });

      _initialized = true;
    } catch (e) {
      lastError = friendlyError(e);
      if (kDebugMode) debugPrint('[push] init failed: $e');
    }
  }

  /// OS の通知の許可状態（ダイアログは出さない）。Firebase を使えない構成では null。
  static Future<AuthorizationStatus?> authorizationStatus() async {
    if (!_initialized) await init();
    if (!_initialized) return null;
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus;
    } catch (_) {
      return null;
    }
  }

  /// この端末を通知先として登録する。登録できたら true。
  ///
  /// [ask] が false（既定）なら OS のダイアログは出さず、すでに許可されているときだけ登録する。
  /// 起動時・サインイン時はこちら。ここで許可を求めると、通知の説明で「あとで」を選んだ人にも
  /// 次の起動で説明なしの OS ダイアログが出てしまう（一度断られると設定アプリからしか戻せない）。
  /// [ask] を true にするのは、説明を見て「通知をオンにする」を選んだ直後だけ。
  /// 失敗の理由は [lastError] に残る。
  static Future<bool> registerForCurrentUser({bool ask = false}) async {
    if (!_initialized) await init();
    if (!_initialized) return false;

    lastError = null;
    try {
      final messaging = FirebaseMessaging.instance;
      final settings = ask
          ? await messaging.requestPermission()
          : await messaging.getNotificationSettings();
      final status = settings.authorizationStatus;
      if (status != AuthorizationStatus.authorized &&
          status != AuthorizationStatus.provisional) {
        lastError = '通知が許可されていません';
        return false;
      }

      final token = await _obtainToken();
      if (token == null) {
        // 利用者には仕組みの名前（APNs・トークン）を出さず、何が起きたかだけを伝える。
        lastError = 'この端末を通知先に登録できませんでした。しばらくしてからもう一度お試しください。';
        if (kDebugMode) {
          debugPrint('[push] no token'
              '${Platform.isIOS && await messaging.getAPNSToken() == null ? ' (APNs token is null)' : ''}');
        }
        return false;
      }
      _currentToken = token;
      return await _register(token);
    } catch (e) {
      lastError = friendlyError(e);
      if (kDebugMode) debugPrint('[push] register failed: $e');
      return false;
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

  static Future<bool> _register(String token) async {
    try {
      await Repo.registerPushToken(
        token: token,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
      return true;
    } catch (e) {
      lastError = friendlyError(e);
      if (kDebugMode) debugPrint('[push] token upload failed: $e');
      return false;
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

  /// 通知をタップして開いたとき。
  static void _openFrom(RemoteMessage message) {
    NotifTap.open(NotifTarget.fromData(message.data) ?? const NotifTarget());
  }

  /// フォアグラウンドで受け取ったとき。
  static Future<void> _onForegroundMessage(RemoteMessage message) async {
    final target = NotifTarget.fromData(message.data);
    // 新着レビューの通知＝サーバーが取り込んだ合図。開いているタブ・未読バッジを読み直させる。
    if (target?.type == 'reviews') {
      AppEvents.notifyDataChanged(DataChange.reviews);
    }
    await _showForeground(message, target);
  }

  /// フォアグラウンド受信時の表示（Android向け）。
  static Future<void> _showForeground(
      RemoteMessage message, NotifTarget? target) async {
    if (!Platform.isAndroid) return; // iOSはOSが出す
    final n = message.notification;
    if (n == null) return;
    await LocalNotifier.showRaw(
      id: message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
      title: n.title ?? '新しいレビュー',
      body: n.body ?? '',
      target: target,
    );
  }
}
