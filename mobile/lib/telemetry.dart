import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// クラッシュと、画面で拾えなかった例外を Firebase Crashlytics に送る。
///
/// これまでは出したあとのアプリで落ちても、こちらからは何も見えなかった
/// （利用者がレビューに書くまで気づけない）。
/// Firebase を初期化したあと（[PushService.init] のあと）に呼ぶ。
/// Firebase の設定が無い構成・開発版では何もしない。
///
/// 送るのはクラッシュの記録（スタックトレース・端末の種類・OS の版）と、
/// ログイン中の利用者の ID（どの人に起きたか問い合わせで照合するため）。
/// レビュー本文やメールアドレスは送らない。
class Telemetry {
  Telemetry._();

  static bool _enabled = false;
  static bool get enabled => _enabled;

  static Future<void> init() async {
    if (Firebase.apps.isEmpty) return;
    try {
      final c = FirebaseCrashlytics.instance;
      // 開発中のクラッシュで本番の一覧を汚さない。
      await c.setCrashlyticsCollectionEnabled(!kDebugMode);
      if (kDebugMode) return;
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        previous?.call(details);
        unawaited(c.recordFlutterFatalError(details));
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        unawaited(c.recordError(error, stack, fatal: true));
        return true;
      };
      _enabled = true;
    } catch (e) {
      if (kDebugMode) debugPrint('[telemetry] init failed: $e');
    }
  }

  /// ログイン中の利用者を紐づける（ログアウトしたら null）。
  static void setUser(String? userId) {
    if (!_enabled) return;
    unawaited(
      FirebaseCrashlytics.instance
          .setUserIdentifier(userId ?? '')
          .catchError((_) {}),
    );
  }

  /// 落ちてはいないが、知っておきたい失敗（購入の確認の失敗など）を送る。
  static void recordError(Object error, StackTrace? stack, {String? reason}) {
    if (!_enabled) return;
    unawaited(
      FirebaseCrashlytics.instance
          .recordError(error, stack, reason: reason)
          .catchError((_) {}),
    );
  }
}
