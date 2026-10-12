import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_notifications.dart';
import 'push.dart';
import 'theme.dart';

/// 通知の許可を求める前に、何が届くのかを1画面で説明する。
///
/// OS のダイアログは一度断られると設定アプリからしか戻せない。
/// 「★1〜2が届いたらすぐ知らせる」と先に伝えてから出す方が許可されやすく、
/// このアプリの価値（低評価にすぐ気づける）もここで実感してもらえる。
class NotificationPrimer {
  static const _key = 'notif_primed_v1';

  /// 説明を見て選んだ（または以前から許可済み）か。
  static Future<bool> done() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> _markDone() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (_) {}
  }

  /// まだなら説明を出す。すでに OS で許可済みの人（旧バージョンからの更新）には出さない。
  static Future<void> maybeShow(BuildContext context) async {
    if (await done()) return;
    if (await LocalNotifier.alreadyAllowed()) {
      await _markDone();
      unawaited(PushService.registerForCurrentUser());
      return;
    }
    if (!context.mounted) return;
    final allow = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: context.surfaceC,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => const _PrimerSheet(),
    );
    await _markDone();
    if (allow == true) {
      HapticFeedback.lightImpact();
      await LocalNotifier.requestPermission();
      unawaited(PushService.registerForCurrentUser());
    }
  }
}

class _PrimerSheet extends StatelessWidget {
  const _PrimerSheet();

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
            const Text(
              '低評価に、すぐ気づけるように',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 16),
            point(Icons.star_half_rounded, '★1〜2のレビューが届いたら、その場でお知らせします'),
            point(Icons.tune_rounded, '「すべて」か「★1〜2だけ」かは、設定からいつでも変えられます'),
            point(Icons.do_not_disturb_on_outlined, '宣伝の通知は送りません'),
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
