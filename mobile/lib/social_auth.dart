import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

/// Apple / Google でのログイン。
///
/// メール＋パスワード＋確認メールは登録の途中で離脱が最も多い。
/// 端末にすでにあるアカウントで1タップ登録できるようにする。
///
/// どちらも各OSのネイティブ画面で ID トークンを受け取り、Supabase に渡して
/// セッションに交換する（ブラウザへの遷移やディープリンクを使わない）。
/// iOS では Google ログインを出すなら Sign in with Apple も必須（審査ガイドライン 4.8）。
class SocialAuth {
  /// 利用者が自分で閉じた（エラーとして表示しない）。
  static const cancelled = 'cancelled';

  static bool get appleAvailable => Platform.isIOS;

  static bool get googleAvailable =>
      AppConfig.googleWebClientId.isNotEmpty &&
      (!Platform.isIOS || AppConfig.googleIosClientId.isNotEmpty);

  /// Sign in with Apple。
  ///
  /// nonce は「このログイン要求のために発行したトークンか」を Supabase が確かめるためのもの。
  /// Apple には SHA-256 したものを、Supabase には元の値を渡す。
  static Future<void> signInWithApple() async {
    final rawNonce = _nonce();
    final hashed = sha256.convert(utf8.encode(rawNonce)).toString();
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: hashed,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) throw cancelled;
      rethrow;
    }
    final idToken = credential.identityToken;
    if (idToken == null) throw 'Apple から認証情報を受け取れませんでした。';
    await Supabase.instance.client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: idToken,
      nonce: rawNonce,
    );
    // アカウント削除時に Apple 側の連携も取り消せるよう、認可コードをサーバーに預ける
    // （App Store の要件。失敗してもログイン自体は成立させる）。
    await _registerAppleAuthCode(credential.authorizationCode);
  }

  static bool _googleReady = false;

  static Future<void> signInWithGoogle() async {
    final google = GoogleSignIn.instance;
    if (!_googleReady) {
      await google.initialize(
        clientId: Platform.isIOS ? AppConfig.googleIosClientId : null,
        serverClientId: AppConfig.googleWebClientId,
      );
      _googleReady = true;
    }
    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) throw cancelled;
      rethrow;
    }
    final idToken = account.authentication.idToken;
    if (idToken == null) throw 'Google から認証情報を受け取れませんでした。';
    await Supabase.instance.client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
    );
  }

  /// ログアウト時に呼ぶ。次回のGoogleログインでアカウントを選び直せるようにする。
  static Future<void> signOutProviders() async {
    if (!_googleReady) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  static Future<void> _registerAppleAuthCode(String code) async {
    if (!AppConfig.hasApi || code.isEmpty) return;
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null) return;
    try {
      await http
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}/api/auth/apple'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'authorizationCode': code}),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  static String _nonce([int length = 32]) {
    const chars =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// 例外を利用者向けの文言にする。null はキャンセル（表示しない）。
  static String? messageFor(Object e) {
    if (e == cancelled) return null;
    if (e is AuthException) return e.message;
    if (e is PlatformException) return 'ログインできませんでした（${e.code}）';
    if (e is String) return e;
    return 'ログインできませんでした。時間をおいて再度お試しください。';
  }
}
