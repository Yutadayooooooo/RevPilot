import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:revpilot_mobile/app_update.dart';
import 'package:revpilot_mobile/format.dart';
import 'package:revpilot_mobile/motion.dart';
import 'package:revpilot_mobile/offline_banner.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ja'));

  group('日付の書式', () {
    final now = DateTime(2026, 11, 19, 15, 0);

    test('今日・昨日・今年・去年より前', () {
      expect(formatListDate(DateTime(2026, 11, 19, 9, 5), now: now), '今日 9:05');
      expect(formatListDate(DateTime(2026, 11, 18, 23, 59), now: now), '昨日');
      expect(formatListDate(DateTime(2026, 10, 12), now: now), '10月12日');
      expect(formatListDate(DateTime(2025, 10, 12), now: now), '2025/10/12');
    });

    test('昨日の 23 時を今日の 0 時すぎに見ても「昨日」（経過時間で数えない）', () {
      final early = DateTime(2026, 11, 19, 0, 30);
      expect(formatListDate(DateTime(2026, 11, 18, 23, 0), now: early), '昨日');
    });

    test('一覧の日時と文の中の日付', () {
      expect(
        formatListDateTime(DateTime(2026, 11, 18, 22, 15), now: now),
        '昨日 22:15',
      );
      expect(
        formatListDateTime(DateTime(2026, 11, 3, 9, 5), now: now),
        '11月3日 9:05',
      );
      expect(formatDateJa(DateTime(2026, 11, 5), now: now), '11月5日');
      expect(formatDateJa(DateTime(2025, 11, 5), now: now), '2025年11月5日');
      expect(
        formatDateTimeJa(DateTime(2026, 11, 5, 10, 0), now: now),
        '11月5日 10:00',
      );
    });

    test('UTC の時刻は端末の時刻に直してから書く', () {
      final utc = DateTime.utc(2026, 11, 19, 1, 0);
      expect(
        formatListDateTime(utc, now: now),
        formatListDateTime(utc.toLocal(), now: now),
      );
    });
  });

  group('アップデートの判定', () {
    test('最低の版より古ければ required、最新より古ければ recommended', () {
      expect(
        decideUpdate(current: '1.0.0', min: '1.0.1', latest: ''),
        AppUpdateStatus.required,
      );
      expect(
        decideUpdate(current: '1.0.1', min: '1.0.1', latest: '1.1'),
        AppUpdateStatus.recommended,
      );
      expect(
        decideUpdate(current: '1.1.0', min: '1.0', latest: '1.1'),
        AppUpdateStatus.upToDate,
      );
    });

    test('空や版の形でない値では止めない', () {
      expect(
        decideUpdate(current: '1.0.0', min: '', latest: ''),
        AppUpdateStatus.upToDate,
      );
      expect(
        decideUpdate(current: '1.0.0', min: 'abc', latest: 'x'),
        AppUpdateStatus.upToDate,
      );
    });

    test('桁の数が違っても比べられる', () {
      expect(compareVersions([1, 2], [1, 2, 0]), 0);
      expect(compareVersions([1, 10], [1, 9, 9]) > 0, isTrue);
    });
  });

  group('視差効果を減らす', () {
    Future<double> opacityAfterPump(WidgetTester tester, bool reduce) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduce),
            child: Builder(
              builder:
                  (context) => const Text(
                    'x',
                  ).motion(context, delay: 300.ms).fadeIn(duration: 500.ms),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      // いちばん内側（Text のすぐ外）の FadeTransition が fadeIn のもの。
      final fade = tester.widget<FadeTransition>(
        find
            .ancestor(
              of: find.text('x'),
              matching: find.byType(FadeTransition),
            )
            .first,
      );
      final value = fade.opacity.value;
      // 待ち（delay）の間は描き直しが無いので、pumpAndSettle の前に時間を進める。
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      return value;
    }

    testWidgets('オフなら出てくる途中', (tester) async {
      expect(await opacityAfterPump(tester, false), lessThan(1));
    });

    testWidgets('オンなら最初から終わりの形', (tester) async {
      expect(await opacityAfterPump(tester, true), 1);
    });
  });

  group('オフラインの帯', () {
    testWidgets('切れて 1.5 秒たったら出し、つながったら消す。下の画面は作り直さない', (tester) async {
      final online = StreamController<bool>();
      addTearDown(online.close);
      await tester.pumpWidget(
        MaterialApp(
          builder:
              (context, child) =>
                  OfflineBanner(online: online.stream, child: child!),
          home: const _Counter(),
        ),
      );
      await tester.tap(find.text('0'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      online.add(false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(kOfflineMessage), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text(kOfflineMessage), findsOneWidget);
      // 帯が出ても下の画面の状態はそのまま。
      expect(find.text('1'), findsOneWidget);

      online.add(true);
      await tester.pumpAndSettle();
      expect(find.text(kOfflineMessage), findsNothing);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('一瞬の切り替わりでは出さない', (tester) async {
      final online = StreamController<bool>();
      addTearDown(online.close);
      await tester.pumpWidget(
        MaterialApp(
          builder:
              (context, child) =>
                  OfflineBanner(online: online.stream, child: child!),
          home: const SizedBox(),
        ),
      );
      online.add(false);
      await tester.pump(const Duration(milliseconds: 800));
      online.add(true);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(kOfflineMessage), findsNothing);
    });
  });

  testWidgets('日本語の部品の文言（戻る・貼り付け）が日本語で出る', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ja', 'JP'),
        supportedLocales: const [Locale('ja', 'JP')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final m = MaterialLocalizations.of(ctx);
    expect(m.backButtonTooltip, '戻る');
    expect(m.pasteButtonLabel, '貼り付け');
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: GestureDetector(
        onTap: () => setState(() => n++),
        child: Text('$n'),
      ),
    ),
  );
}
