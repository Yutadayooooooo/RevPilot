// ストア掲載用スクリーンショットの生成。使い方は docs/store-listing.md の5章。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:revpilot_mobile/models.dart';
import 'package:revpilot_mobile/screens/analytics_screen.dart';
import 'package:revpilot_mobile/screens/apps_screen.dart';
import 'package:revpilot_mobile/screens/review_detail_screen.dart';
import 'package:revpilot_mobile/screens/reviews_screen.dart';
import 'package:revpilot_mobile/theme.dart';

const out = String.fromEnvironment('OUT');
const fonts = String.fromEnvironment('FONTS');
const sdk = String.fromEnvironment('SDK');

String plan = 'pro';
final now = DateTime.now().toUtc();
String ago(Duration d) => now.subtract(d).toIso8601String();

final apps = [
  {'id': 'a1', 'store': 'appstore', 'store_app_id': '1', 'name': 'MyHabit', 'reply_tone': 'polite',
   'reply_opening': 'MyHabitをご利用いただき、ありがとうございます。', 'reply_closing': '今後ともMyHabitをよろしくお願いいたします。（MyHabit 開発チーム）',
   'reply_rules': '・不具合には謝罪と、次の更新で直すことを伝える\n・個別の連絡先は書かない', 'created_at': ago(const Duration(days: 90))},
  {'id': 'a2', 'store': 'googleplay', 'store_app_id': 'com.example.focus', 'name': 'Focus Timer', 'reply_tone': 'friendly', 'created_at': ago(const Duration(days: 80))},
];

Map<String, dynamic> rv(String id, String app, String store, int rating, String title, String body, Duration age,
        {List<String> topics = const [], String? reply, String status = 'draft', String author = 'user'}) =>
    {
      'id': id, 'app_id': app, 'store': store, 'rating': rating, 'title': title, 'body': body, 'author': author,
      'territory': 'JPN', 'app_version': '2.4.0', 'reviewed_at': ago(age),
      'apps': {'name': app == 'a1' ? 'MyHabit' : 'Focus Timer'},
      'review_topics': [for (final t in topics) {'topic': t}],
      'replies': reply == null ? [] : [
        {'id': 'r$id', 'body': reply, 'status': status, 'source': 'ai', 'created_at': ago(age - const Duration(minutes: 5)),
         if (status == 'posted') 'posted_at': ago(age - const Duration(minutes: 10))}
      ],
    };

const aiDraft = 'MyHabitをご利用いただき、ありがとうございます。\n'
    'アップデート後に記録が表示されなくなり、ご不便をおかけして申し訳ありません。'
    'データは端末とクラウドの両方に残っていますので、消えてはいません。'
    '原因は特定できており、次の更新（数日以内）で修正します。\n'
    '今後ともMyHabitをよろしくお願いいたします。（MyHabit 開発チーム）';

final reviews = [
  rv('1', 'a1', 'appstore', 1, '更新したら記録が消えた', 'アップデート後に起動すると、今までの記録が表示されません。毎日続けていたので悲しいです。早く直してください。',
      const Duration(minutes: 42), topics: ['bug'], reply: aiDraft, author: 'ねこまる'),
  rv('2', 'a2', 'googleplay', 5, '', '集中したい時に最高です。シンプルで広告もなく、毎日使っています。', const Duration(hours: 3),
      topics: ['praise'], reply: 'ありがとうございます！', status: 'posted', author: 'Kenta S.'),
  rv('3', 'a1', 'appstore', 4, 'ウィジェットが欲しい', '使いやすいです。ホーム画面のウィジェットがあれば星5にします。', const Duration(hours: 9),
      topics: ['feature_request'], author: 'mika'),
  rv('4', 'a2', 'googleplay', 2, '', '通知が鳴らない日があります。Android 15 です。', const Duration(hours: 20), topics: ['bug'], author: 'T.Y'),
  rv('5', 'a1', 'appstore', 5, '習慣化できた', '三日坊主の私が3か月続いています。グラフが励みになります。', const Duration(days: 1, hours: 4),
      topics: ['praise'], reply: '3か月、素晴らしいです！', status: 'posted', author: 'あや'),
  rv('6', 'a2', 'googleplay', 3, '', '年額が少し高いと感じます。月額の割引があれば。', const Duration(days: 2), topics: ['price'], author: 'hiro'),
  rv('7', 'a1', 'appstore', 5, '', 'デザインがかわいくて毎日開きたくなる。', const Duration(days: 3), topics: ['praise', 'ux'], author: 'sora'),
];

final summary = {
  'total': 1284, 'avg_rating': 4.32, 'unreplied': 37,
  'by_rating': {'5': 812, '4': 241, '3': 96, '2': 58, '1': 77},
  'topics': {'praise': 640, 'feature_request': 211, 'bug': 154, 'ux': 98, 'price': 41},
};

final locked = [
  {'hidden_total': 128, 'hidden_low': 17, 'rating': 1, 'reviewed_at': ago(const Duration(days: 41)), 'app_name': 'MyHabit', 'snippet': 'アップデート後に起動しなくなりました。データは残っているのでしょうか'},
  {'hidden_total': 128, 'hidden_low': 17, 'rating': 4, 'reviewed_at': ago(const Duration(days: 52)), 'app_name': 'MyHabit', 'snippet': '毎日使っています。ウィジェットがあると嬉しい'},
  {'hidden_total': 128, 'hidden_low': 17, 'rating': 2, 'reviewed_at': ago(const Duration(days: 67)), 'app_name': 'Focus Timer', 'snippet': '通知が鳴らないことがあります。設定は'},
];

http.Response j(Object o, http.BaseRequest req) => http.Response.bytes(utf8.encode(jsonEncode(o)), 200, request: req, headers: {'content-type': 'application/json; charset=utf-8'});

final client = MockClient((req) async {
  final p = req.url.path;
  final single = (req.headers['Accept'] ?? req.headers['accept'] ?? '').contains('object');
  Object body;
  if (p.endsWith('/rpc/my_review_summary')) {
    body = [summary];
  } else if (p.endsWith('/rpc/locked_reviews_preview')) {
    body = plan == 'free' ? locked : [];
  } else if (p.endsWith('/reviews')) {
    body = plan == 'free' ? reviews.take(2).toList() : reviews;
  } else if (p.endsWith('/apps')) {
    body = apps;
  } else if (p.endsWith('/profiles')) {
    body = {'plan': plan, 'in_trial': plan == 'pro', 'current_period_end': ago(const Duration(days: -24))};
  } else if (p.endsWith('/ai_usage')) {
    body = {'units': 380};
  } else {
    body = [];
  }
  if (single && body is List) body = body.isEmpty ? {} : body.first;
  return j(body, req);
});

Future<void> loadFont(String family, List<String> paths) async {
  final l = FontLoader(family);
  for (final p in paths) {
    l.addFont(Future.value(ByteData.view(File(p).readAsBytesSync().buffer)));
  }
  await l.load();
}

String fakeJwt() {
  String b(Map m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final exp = now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
  return '${b({'alg': 'HS256', 'typ': 'JWT'})}.${b({'sub': 'u1', 'exp': exp, 'role': 'authenticated'})}.sig';
}

/// テスト環境では fontFamily 未指定の明示スタイルが豆腐になるので、日本語フォントを当てる
/// （実機ではOSの標準フォントになる）。
ThemeData fix(ThemeData t) {
  TextStyle? f(TextStyle? s) => s?.copyWith(fontFamily: 'Roboto');
  ButtonStyle? b(ButtonStyle? s) => s?.copyWith(textStyle: WidgetStatePropertyAll(f(s.textStyle?.resolve({})) ?? const TextStyle(fontFamily: 'Roboto')));
  return t.copyWith(
    appBarTheme: t.appBarTheme.copyWith(titleTextStyle: f(t.appBarTheme.titleTextStyle)),
    chipTheme: t.chipTheme.copyWith(labelStyle: f(t.chipTheme.labelStyle)),
    filledButtonTheme: FilledButtonThemeData(style: b(t.filledButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: b(t.outlinedButtonTheme.style)),
  );
}

/// ストア用の1枚：上にキャプション、下に端末画面。
class Shot extends StatelessWidget {
  final String title;
  final String sub;
  final Widget screen;
  final Size device;
  final bool dark;
  const Shot({super.key, required this.title, required this.sub, required this.screen, required this.device, this.dark = false});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phoneW = size.width * 0.80;
    final scale = phoneW / device.width;
    final phoneH = device.height * scale;
    final top = size.height - phoneH + 26;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF3B5BDB), Color(0xFF6741D9)]),
        ),
        child: Stack(children: [
          Positioned(
            left: 20, right: 20, top: size.height * 0.055,
            child: Column(children: [
              Text(title, textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Roboto', fontSize: size.width * 0.072, height: 1.3, fontWeight: FontWeight.w900, color: Colors.white)),
              const SizedBox(height: 10),
              Text(sub, textAlign: TextAlign.center,
                  style: TextStyle(fontFamily: 'Roboto', fontSize: size.width * 0.038, height: 1.45, fontWeight: FontWeight.w500, color: const Color(0xE6FFFFFF))),
            ]),
          ),
          Positioned(
            left: (size.width - phoneW) / 2, top: top, width: phoneW, height: phoneH,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(44 * scale),
                boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 16))],
                border: Border.all(color: const Color(0xFF111111), width: 8 * scale),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(36 * scale),
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox(
                    width: device.width, height: device.height,
                    child: MediaQuery(
                      data: MediaQueryData(size: device, devicePixelRatio: 3, padding: const EdgeInsets.only(top: 50, bottom: 30),
                          viewPadding: const EdgeInsets.only(top: 50, bottom: 30)),
                      child: Stack(children: [
                        Positioned.fill(child: MaterialApp(
                          debugShowCheckedModeBanner: false,
                          theme: fix(AppTheme.light()), darkTheme: fix(AppTheme.dark()),
                          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                          home: screen,
                        )),
                        Positioned(left: 34, top: 16, child: Text('9:41',
                            style: TextStyle(fontFamily: 'Roboto', fontSize: 16, fontWeight: FontWeight.w700, color: dark ? Colors.white : Colors.black))),
                        Positioned(right: 30, top: 18, child: Row(children: [
                          Icon(Icons.signal_cellular_alt, size: 17, color: dark ? Colors.white : Colors.black),
                          const SizedBox(width: 4),
                          Icon(Icons.wifi, size: 17, color: dark ? Colors.white : Colors.black),
                          const SizedBox(width: 4),
                          Icon(Icons.battery_full, size: 17, color: dark ? Colors.white : Colors.black),
                        ])),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class Tabs extends StatelessWidget {
  final int index;
  final Widget body;
  const Tabs(this.index, this.body, {super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: body,
        bottomNavigationBar: NavigationBar(selectedIndex: index, destinations: const [
          NavigationDestination(icon: Icon(Icons.rate_review_outlined), selectedIcon: Icon(Icons.rate_review), label: 'レビュー'),
          NavigationDestination(icon: Icon(Icons.notifications_outlined), selectedIcon: Icon(Icons.notifications), label: '通知'),
          NavigationDestination(icon: Icon(Icons.insights_outlined), selectedIcon: Icon(Icons.insights), label: '分析'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: '設定'),
        ]),
      );
}

void main() {
  // 通常の flutter test では動かさない（OUT・FONTS・SDK を渡したときだけ生成する）。
  if (out.isEmpty) return;
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'intro_seen_v1': true, 'notif_primed_v1': true});
    await loadFont('Roboto', ['$fonts/NotoSansJP_400Regular.ttf', '$fonts/NotoSansJP_500Medium.ttf', '$fonts/NotoSansJP_700Bold.ttf', '$fonts/NotoSansJP_900Black.ttf']);
    await loadFont('FlutterTest', ['$fonts/NotoSansJP_400Regular.ttf', '$fonts/NotoSansJP_500Medium.ttf', '$fonts/NotoSansJP_700Bold.ttf', '$fonts/NotoSansJP_900Black.ttf']);
    await loadFont('MaterialIcons', ['$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    await Supabase.initialize(url: 'https://demo.supabase.co', publishableKey: 'anon', httpClient: client,
        authOptions: const FlutterAuthClientOptions(detectSessionInUri: false, autoRefreshToken: false));
    await Supabase.instance.client.auth.recoverSession(jsonEncode({
      'access_token': fakeJwt(), 'token_type': 'bearer', 'expires_in': 2592000,
      'expires_at': now.add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000,
      'refresh_token': 'r', 'user': {'id': 'u1', 'aud': 'authenticated', 'email': 'dev@example.com', 'app_metadata': {}, 'user_metadata': {}, 'created_at': ago(const Duration(days: 90))},
    }));
  });

  const devices = {'ios69': Size(440, 956), 'android': Size(412, 732)};
  const canvases = {'ios69': Size(1320, 2868), 'android': Size(1080, 1920)};

  for (final d in devices.keys) {
    Future<void> shot(WidgetTester t, String name, String title, String sub, Widget screen, {String p = 'pro', bool dark = false}) async {
      plan = p;
      t.view.physicalSize = canvases[d]!;
      t.view.devicePixelRatio = canvases[d]!.width / 440;
      await t.runAsync(() async {
        await t.pumpWidget(Shot(title: title, sub: sub, screen: screen, device: devices[d]!, dark: dark));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await t.pump(const Duration(milliseconds: 100));
        }
      });
      await t.pump(const Duration(seconds: 3));
      await expectLater(find.byType(Shot), matchesGoldenFile('$out/$d/$name.png'));
    }

    final r1 = ReviewRow.fromJson(reviews.first);
    testWidgets('$d 1', (t) => shot(t, '1_inbox', '2つのストアのレビューを\n一か所に', '毎時自動で取得。★1〜2はすぐ通知します', const Tabs(0, ReviewsScreen())));
    testWidgets('$d 2', (t) => shot(t, '2_ai_reply', 'AIが、あなたの言葉で\n返信を下書き', '書き出し・署名・ルールをアプリごとに設定', ReviewDetailScreen(r1)));
    testWidgets('$d 3', (t) => shot(t, '3_analytics', '何が評価を\n下げているか分かる', '星の分布とトピックを全期間で集計', const Tabs(2, AnalyticsScreen())));
    testWidgets('$d 4', (t) => shot(t, '4_history', '消えるレビューも\n全期間保存', '7日で見えなくなるレビューも残ります\nPro は初回1か月無料', const Tabs(0, ReviewsScreen()), p: 'free'));
    testWidgets('$d 5', (t) => shot(t, '5_style', '返信の形を\nそろえられる', 'どの返信も同じ書き出しと署名に', AppEditScreen(existing: AppRow.fromJson(apps.first))));
    testWidgets('$d 6', (t) => shot(t, '6_dark', 'ダークモードにも対応', '夜の確認も目にやさしく', const Tabs(0, ReviewsScreen()), dark: true));
  }
}
