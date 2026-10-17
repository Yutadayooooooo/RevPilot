import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart' show AuthorizationStatus;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data.dart';
import 'local_notifications.dart';
import 'push.dart';
import 'theme.dart';
import 'ui.dart';

/// OS の通知の許可状態。
/// - [allowed]   : 許可済み（iOS の「目立たない通知」も含む）
/// - [undecided] : まだ聞いていない（Android で一度断られたが、もう一度聞ける場合も含む）
/// - [denied]    : 拒否済み。OS のダイアログはもう出せず、端末の設定アプリでしか戻せない
enum NotifPermission { allowed, undecided, denied }

/// 通知の許可を求める前に、何が届くのかを1画面で説明する。
///
/// OS のダイアログは一度断られると設定アプリからしか戻せない。
/// 「★1〜2が届いたらすぐ知らせる」と先に伝えてから出す方が許可されやすく、
/// このアプリの価値（低評価にすぐ気づける）もここで実感してもらえる。
///
/// 説明での選択（「通知をオンにする」/「あとで」）は OS の許可とは別に保存する。
/// 「あとで」の人には、起動時もサインイン時も OS のダイアログを出さない。
/// 最初にレビューを取り込めたあと一度だけ聞き直し（[maybeReoffer]）、
/// 以後は設定タブから [enable] でいつでもオンにできる。
class NotificationPrimer {
  /// 説明での選択。'allowed' / 'later'。
  static const _choiceKey = 'notif_primer_choice_v2';

  /// 旧バージョンの「説明を見た」印（どちらを選んだかは残っていない）。
  static const _legacyKey = 'notif_primed_v1';

  /// 「あとで」の人に聞き直したか（聞き直すのは一度だけ）。
  static const _reofferedKey = 'notif_primer_reoffered';

  /// OS のダイアログを出したことがあるか。Firebase を使えない構成で、
  /// 「まだ聞いていない」と「拒否済み」を見分けるのに使う。
  static const _askedKey = 'notif_os_asked';

  /// 最後に調べた OS の許可状態（null はまだ調べていない）。
  /// 設定タブの表示に使う。ホーム画面がアプリの復帰ごとに読み直すので、
  /// 端末の設定アプリで許可を変えて戻ってきたときも追従する。
  static final status = ValueNotifier<NotifPermission?>(null);

  /// 説明シートを出している最中か（初回と聞き直しが重ならないように）。
  static bool _showing = false;

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// 説明での選択。まだ説明していなければ null。
  static Future<String?> _choice() async {
    final prefs = await _prefs();
    if (prefs == null) return 'later'; // 読めない端末では説明を出し続けない
    final v = prefs.getString(_choiceKey);
    if (v != null) return v;
    // 旧バージョンで説明を見た人は「あとで」として扱う（許可済みなら OS の状態で分かる）。
    return (prefs.getBool(_legacyKey) ?? false) ? 'later' : null;
  }

  static Future<void> _setChoice(String value) async {
    try {
      await (await _prefs())?.setString(_choiceKey, value);
    } catch (_) {}
  }

  static Future<bool> _flag(String key) async =>
      (await _prefs())?.getBool(key) ?? false;

  static Future<void> _setFlag(String key) async {
    try {
      await (await _prefs())?.setBool(key, true);
    } catch (_) {}
  }

  /// OS の許可状態を、ダイアログを出さずに調べる（[status] も更新する）。
  static Future<NotifPermission> permission() async {
    var p = NotifPermission.undecided;
    try {
      // Firebase が使えるなら「まだ聞いていない」と「拒否済み」を OS から直接読める。
      final fcm = await PushService.authorizationStatus();
      if (fcm != null) {
        p = switch (fcm) {
          AuthorizationStatus.authorized ||
          AuthorizationStatus.provisional =>
            NotifPermission.allowed,
          AuthorizationStatus.notDetermined => NotifPermission.undecided,
          // Android の denied は「一度断られたが、もう一度聞ける」状態。
          AuthorizationStatus.denied => Platform.isAndroid
              ? NotifPermission.undecided
              : NotifPermission.denied,
          AuthorizationStatus.deniedPermanently => NotifPermission.denied,
        };
      } else if (await LocalNotifier.alreadyAllowed()) {
        p = NotifPermission.allowed;
      } else {
        p = await _flag(_askedKey)
            ? NotifPermission.denied
            : NotifPermission.undecided;
      }
    } catch (_) {}
    status.value = p;
    return p;
  }

  /// 許可状態を読み直す。アプリに戻ってきたときにホーム画面から呼ぶ。
  /// 設定アプリで許可して戻ってきた場合は、ここで端末を通知先に登録する。
  static Future<void> refresh() async {
    final before = status.value;
    final now = await permission();
    // 起動直後（before が null）は起動時の登録に任せる。
    if (before != null &&
        before != NotifPermission.allowed &&
        now == NotifPermission.allowed) {
      await _setChoice('allowed');
      unawaited(PushService.registerForCurrentUser());
    }
  }

  /// 初回: まだなら説明を出す。すでに OS で許可済みの人（旧バージョンからの更新）には出さない。
  static Future<void> maybeShow(BuildContext context) async {
    // 説明を済ませた人でも、設定タブの表示と復帰時の比較のために一度読んでおく。
    final p = await permission();
    if (await _choice() != null) return;
    if (p == NotifPermission.allowed) {
      await _setChoice('allowed');
      unawaited(PushService.registerForCurrentUser());
      return;
    }
    if (p == NotifPermission.denied) {
      // OS で拒否済み。説明を出してもダイアログは出ないので、設定タブの案内に任せる。
      await _setChoice('later');
      return;
    }
    if (!context.mounted) return;
    await _offer(context);
  }

  /// 「あとで」を選んだ人に、レビューを取り込めたあと一度だけ聞き直す。
  ///
  /// 初回の説明はログイン直後（まだストアも連携していない段階）に出るので、
  /// 「何が届くのか」が実感できないまま断られやすい。レビューが入ってから聞き直す。
  /// ホーム画面が見えていないとき（詳細などを開いているとき）は出さず、次の機会に回す。
  static Future<void> maybeReoffer(BuildContext context) async {
    if (_showing || await _prefs() == null) return;
    if (await _choice() != 'later') return;
    if (await _flag(_reofferedKey)) return;
    if (await permission() != NotifPermission.undecided) return;
    try {
      if ((await Repo.reviewsForNotify(limit: 1)).isEmpty) return;
    } catch (_) {
      return;
    }
    if (!context.mounted || ModalRoute.of(context)?.isCurrent == false) return;
    await _setFlag(_reofferedKey);
    if (!context.mounted) return;
    await _offer(context, again: true);
  }

  /// 設定タブから通知をオンにする。操作のあとの許可状態を返す。
  ///
  /// - まだ聞いていない: 説明シートを出し、「通知をオンにする」なら OS のダイアログを出して登録する
  /// - 拒否済み: iPhone は設定アプリ（このアプリの画面）を開く。Android はもう一度聞き、
  ///   それでも出せなければ設定の場所を案内する
  /// - 許可済み: この端末を通知先に登録し直す
  static Future<NotifPermission> enable(BuildContext context) async {
    final p = await permission();
    switch (p) {
      case NotifPermission.allowed:
        await _setChoice('allowed');
        await PushService.registerForCurrentUser();
        return p;
      case NotifPermission.undecided:
        if (!context.mounted) return p;
        return _offer(context);
      case NotifPermission.denied:
        if (Platform.isIOS) {
          // 戻ってきたときに [refresh] で読み直す。
          if (!await openSystemSettings() && context.mounted) {
            showSnack(context, 'iPhoneの「設定 > 通知 > RevPilot」から通知を許可してください');
          }
          return p;
        }
        final now = await _request();
        if (now != NotifPermission.allowed && context.mounted) {
          showSnack(context,
              '端末の「設定 > アプリ > RevPilot > 通知」から通知を許可してください');
        }
        return now;
    }
  }

  /// 端末の設定アプリで、このアプリの画面を開く（iPhone のみ）。開けたら true。
  static Future<bool> openSystemSettings() async {
    if (!Platform.isIOS) return false;
    try {
      return await launchUrl(Uri.parse('app-settings:'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// 説明シートを出し、「通知をオンにする」なら OS の許可を求める。操作のあとの許可状態を返す。
  static Future<NotifPermission> _offer(BuildContext context,
      {bool again = false}) async {
    if (_showing) return status.value ?? NotifPermission.undecided;
    _showing = true;
    try {
      // 先に「あとで」として記録しておく。シートが閉じられない・途中でアプリを終了した、
      // などのどんな場合でも、次の起動で同じシートに閉じ込められないようにするため。
      await _setChoice('later');
      if (!context.mounted) return NotifPermission.undecided;
      final allow = await showModalBottomSheet<bool>(
        context: context,
        // 文字を大きくしている端末でもボタンまで届くよう、高さを画面いっぱいまで許し、
        // 中身はスクロールさせる（既定の 9/16 の高さでは「あとで」が画面外に出ていた）。
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: context.surfaceC,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (ctx) => _PrimerSheet(again: again),
      );
      // 外側のタップやスワイプで閉じた（null）ときは「あとで」のまま。
      if (allow != true) return status.value ?? NotifPermission.undecided;
      HapticFeedback.lightImpact();
      await _setChoice('allowed');
      return await _request();
    } finally {
      _showing = false;
    }
  }

  /// OS のダイアログで許可を求め、許可されたらこの端末を通知先に登録する。
  static Future<NotifPermission> _request() async {
    await _setFlag(_askedKey);
    if (await PushService.authorizationStatus() != null) {
      // Firebase の許可要求は OS のダイアログを兼ねる（ローカル通知の許可も同じ）。
      await PushService.registerForCurrentUser(ask: true);
    } else {
      await LocalNotifier.requestPermission();
    }
    return permission();
  }
}

class _PrimerSheet extends StatelessWidget {
  /// 「あとで」の人への聞き直しか（見出しを変える）。
  final bool again;
  const _PrimerSheet({this.again = false});

  @override
  Widget build(BuildContext context) {
    Widget point(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.primary),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
            ],
          ),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 説明は収まらなければスクロールし、ボタンは常に下に見えるようにする。
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppTheme.primary.withValues(alpha: 0.12),
                        ),
                        child: const Icon(Icons.notifications_active_rounded,
                            size: 36, color: AppTheme.primary),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      again ? '★1〜2が届いたら、お知らせしますか？' : '低評価に、すぐ気づけるように',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 16),
                    point(Icons.star_half_rounded,
                        '★1〜2のレビューが届いたら、その場でお知らせします'),
                    point(Icons.tune_rounded,
                        '「すべて」か「★1〜2だけ」かは、設定からいつでも変えられます'),
                    point(Icons.do_not_disturb_on_outlined, '宣伝の通知は送りません'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('通知をオンにする',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('あとで'),
            ),
          ],
        ),
      ),
    );
  }
}
