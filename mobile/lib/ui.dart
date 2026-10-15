import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart' show IAPError;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data.dart';
import 'models.dart';
import 'theme.dart';

/// 一貫したスナックバー（アイコン＋色）。
enum SnackKind { info, success, error }

/// スナックバーを出す。
///
/// エラーは読み切れるよう長めに出す（既定 7 秒。ほかは 4 秒）。
/// [actionLabel] と [onAction] を渡すと操作ボタン（「再試行」「連携を確認」など）が付く。
/// 操作ボタンがあっても、[duration] が過ぎれば自動で閉じる。
/// ただし VoiceOver / TalkBack の利用中は、操作ボタンへたどり着く前に消えないよう閉じない
/// （閉じるボタンを付ける）。
void showSnack(
  BuildContext context,
  String message, {
  SnackKind kind = SnackKind.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration? duration,
}) {
  final (icon, color) = switch (kind) {
    SnackKind.success => (Icons.check_circle, AppTheme.success),
    SnackKind.error => (Icons.error, AppTheme.danger),
    SnackKind.info => (Icons.info_outline, Colors.white),
  };
  final hasAction = actionLabel != null && onAction != null;
  final persist = hasAction && MediaQuery.accessibleNavigationOf(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      duration: duration ??
          (kind == SnackKind.error
              ? const Duration(seconds: 7)
              : hasAction
                  ? const Duration(seconds: 6)
                  : const Duration(seconds: 4)),
      // 操作ボタン付きは既定で閉じなくなるので、時間で閉じるよう明示する。
      // 読み上げ中だけは残し、閉じるボタンで消せるようにする。
      persist: persist,
      showCloseIcon: persist,
      action: hasAction
          ? SnackBarAction(label: actionLabel, onPressed: onAction)
          : null,
      content: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ));
}

/// 例外を利用者向けの文言にしてエラーのスナックバーで出す。
/// [prefix] は「保存できませんでした」のような前置き（文末の「。」は不要）。
void showError(
  BuildContext context,
  Object error, {
  String? prefix,
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final message = friendlyError(error);
  showSnack(
    context,
    prefix == null ? message : '$prefix。$message',
    kind: SnackKind.error,
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

const _offlineMessage = 'インターネットに接続できません。通信環境をご確認ください。';
const _expiredMessage = 'ログインの有効期限が切れました。もう一度ログインしてください。';
const _genericMessage = 'エラーが発生しました。時間をおいて再度お試しください。';

/// 例外を、画面に出せる短い日本語にする。
///
/// 英語の技術的な文面（ClientException・PostgrestException・URL など）は出さない。
/// ApiException はサーバーが用意した日本語の案内なので、そのまま使う。
String friendlyError(Object error) {
  final e = error;
  if (e is ApiException) return e.message;
  // AuthRetryableFetchException は AuthException の一種なので先に見る（中身は通信の失敗）。
  if (e is AuthRetryableFetchException) return _offlineMessage;
  if (e is AuthException) return _authMessage(e);
  if (e is TimeoutException) {
    return '通信がタイムアウトしました。通信環境をご確認のうえ、再度お試しください。';
  }
  if (e is SocketException ||
      e is HandshakeException ||
      e is http.ClientException) {
    return _offlineMessage;
  }
  if (e is PostgrestException) return _postgrestMessage(e);
  if (e is IAPError) return _storeMessage('${e.code} ${e.message}');
  if (e is PlatformException) {
    final raw = '${e.code} ${e.message ?? ''}';
    if (RegExp(r'storekit|billing|purchase', caseSensitive: false).hasMatch(raw)) {
      return _storeMessage(raw);
    }
    if (raw.toLowerCase().contains('network')) return _offlineMessage;
    return _genericMessage;
  }
  // 自前で投げた日本語の例外（Exception('商品を読み込めませんでした…') など）はそのまま使う。
  final text = '$e'.replaceFirst(RegExp(r'^\w*(Exception|Error):\s*'), '');
  if (looksJapanese(text) && !text.contains('http')) {
    return clipMessage(text, max: 120);
  }
  return _genericMessage;
}

String _authMessage(AuthException e) {
  final code = e.code ?? '';
  final msg = e.message.toLowerCase();
  // 古いサーバーは code を返さないので、英語の文面でも見分ける。
  if (code == 'invalid_credentials' || msg.contains('invalid login credentials')) {
    return 'メールアドレスまたはパスワードが正しくありません。';
  }
  if (code == 'email_not_confirmed' || msg.contains('email not confirmed')) {
    return '確認メールのリンクを開いてからログインしてください。';
  }
  if (code == 'user_already_exists' ||
      code == 'email_exists' ||
      msg.contains('already registered')) {
    return 'このメールアドレスは登録済みです。ログインしてください。';
  }
  if (code == 'weak_password' || e is AuthWeakPasswordException) {
    return 'パスワードが簡単すぎます。8文字以上で、英字と数字を組み合わせてください。';
  }
  if (code.startsWith('over_') || e.statusCode == '429' || msg.contains('rate limit')) {
    return '短時間に操作が集中しています。しばらく時間をおいてから再度お試しください。';
  }
  if (code == 'same_password') return '新しいパスワードは、今と別のものにしてください。';
  if (code == 'email_address_invalid' || code == 'validation_failed') {
    return 'メールアドレスの形式をご確認ください。';
  }
  if (code == 'signup_disabled') return '現在、新規登録を受け付けていません。';
  if (code == 'user_banned') return 'このアカウントは現在ご利用いただけません。';
  if (code.endsWith('provider_disabled')) return 'このログイン方法は現在ご利用いただけません。';
  if (e is AuthSessionMissingException ||
      code == 'session_not_found' ||
      code == 'session_expired' ||
      code == 'bad_jwt' ||
      code.startsWith('refresh_token_')) {
    return _expiredMessage;
  }
  return 'ログインできませんでした。時間をおいて再度お試しください。';
}

String _postgrestMessage(PostgrestException e) {
  // DB側で用意した日本語の案内（アプリ数の上限など）はそのまま出す。
  if (looksJapanese(e.message)) return clipMessage(e.message, max: 120);
  final code = e.code ?? '';
  if (code == 'PGRST301' || code == 'PGRST303' || e.message.contains('JWT')) {
    return _expiredMessage;
  }
  if (code == '42501') return 'この操作を行う権限がありません。';
  if (code == '23505') return 'すでに登録されています。';
  return 'サーバーとの通信でエラーが発生しました。時間をおいて再度お試しください。';
}

/// アプリ内課金（StoreKit / Google Play Billing）のエラー。
String _storeMessage(String raw) {
  final s = raw.toLowerCase();
  final store =
      defaultTargetPlatform == TargetPlatform.android ? 'Google Play' : 'App Store';
  if (s.contains('cancel')) return '購入をキャンセルしました。';
  if (s.contains('duplicate_product')) {
    return '前回の購入手続きがまだ終わっていません。少し待ってから再度お試しください。';
  }
  if (s.contains('alreadyowned') || s.contains('already_owned')) {
    return 'すでに購入済みです。「購入を復元」をお試しください。';
  }
  if (s.contains('restore') || s.contains('sync_to_app_store') || s.contains('refreshreceipt')) {
    return '購入の復元に失敗しました。時間をおいて再度お試しください。';
  }
  if (s.contains('unsupported_platform_version')) {
    return 'お使いのOSのバージョンでは購入できません。OSを最新にしてお試しください。';
  }
  if (s.contains('network') ||
      s.contains('no_response') ||
      s.contains('servicedisconnected') ||
      s.contains('serviceunavailable') ||
      s.contains('servicetimeout') ||
      s.contains('billingunavailable') ||
      s.contains('fetch_product') ||
      s.contains('products_error') ||
      s.contains('getproductrequest')) {
    return '$storeに接続できませんでした。通信環境をご確認のうえ、再度お試しください。';
  }
  if (s.contains('storekit') ||
      s.contains('billing') ||
      s.contains('purchase') ||
      s.contains('item')) {
    return '購入手続きを完了できませんでした。時間をおいて再度お試しください。';
  }
  return _genericMessage;
}

/// スケルトン用の1ブロック（シマー付き）。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const SkeletonBox({super.key, this.width, this.height = 12, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.skeletonC,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// レビュー一覧のロード中に見せるスケルトンカード群。
class ReviewListSkeleton extends StatelessWidget {
  const ReviewListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      physics: const NeverScrollableScrollPhysics(),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => const _SkeletonCard(),
    )
        .animate(onPlay: (c) => c.repeat())
        .shimmer(
          duration: 1100.ms,
          // ダークでは白60%だとまぶしい帯になるので、ごく薄くする。
          color: Colors.white.withValues(alpha: context.isDark ? 0.08 : 0.6),
        );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(children: [
              SkeletonBox(width: 90, height: 14),
              Spacer(),
              SkeletonBox(width: 32, height: 12),
            ]),
            SizedBox(height: 12),
            SkeletonBox(width: 180, height: 14),
            SizedBox(height: 8),
            SkeletonBox(height: 12),
            SizedBox(height: 6),
            SkeletonBox(width: 220, height: 12),
            SizedBox(height: 12),
            Row(children: [
              SkeletonBox(width: 54, height: 20, radius: 999),
              Spacer(),
              SkeletonBox(width: 60, height: 20, radius: 999),
            ]),
          ],
        ),
      ),
    );
  }
}
