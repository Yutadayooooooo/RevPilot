import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_events.dart';
import 'config.dart';
import 'notifications.dart';
import 'push.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/intro_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayFor(brightness));

  if (AppConfig.isConfigured) {
    // anonKey は非推奨（将来のメジャーバージョンで削除予定）。
    // 値の意味は同じで、パラメータ名だけが publishableKey に変わっている。
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
    _watchSignOut();
    await _setUpPush();
  }

  runApp(const RevPilotApp());
}

/// ログアウトしたら、前のアカウントの状態（プラン・通知の行き先）を持ち越さない。
void _watchSignOut() {
  Supabase.instance.client.auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.signedOut) {
      AppEvents.reset();
      NotifTap.clear();
    }
  });
}

/// リモートpush（アプリを終了していても届く通知）の準備。
///
/// 端末トークンはログインしているユーザーに紐づけるので、
/// 起動時のセッションと、以後のサインインの両方で登録する。
/// Firebaseの設定が入っていなければ [PushService] 側で何もしない。
Future<void> _setUpPush() async {
  await PushService.init();
  if (!PushService.configured) return;

  // 許可を求めるのは、ホーム画面で通知の説明（NotificationPrimer）を見せて
  // 「通知をオンにする」を選んでもらったときだけ。起動時・サインイン時は
  // OS で許可済みの端末だけを登録し直し、ダイアログは出さない
  // （ここで許可を求めると、「あとで」を選んだ人にも説明なしのダイアログが出てしまう）。
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession != null) {
    // 起動をブロックしない。
    unawaited(PushService.registerForCurrentUser());
  }
  auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.signedIn) {
      unawaited(PushService.registerForCurrentUser());
    }
  });
}

class RevPilotApp extends StatelessWidget {
  const RevPilotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RevPilot',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: AppConfig.isConfigured ? const AuthGate() : const _ConfigError(),
    );
  }
}

/// ログイン状態を監視し、未ログインならログイン画面、ログイン済みならホームへ。
/// 初回起動（未ログインかつ紹介を見ていない）ときだけ、ログインの前に紹介を挟む。
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool? _introSeen;

  @override
  void initState() {
    super.initState();
    IntroScreen.seen().then((v) {
      if (mounted) setState(() => _introSeen = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        final session = Supabase.instance.client.auth.currentSession;
        final Widget child;
        if (session != null) {
          child = const HomeScreen(key: ValueKey('home'));
        } else if (_introSeen == null) {
          // 端末設定の読み込み待ち（一瞬）。ログイン画面を一度出してから紹介に変わるのを避ける。
          child = const SizedBox.shrink(key: ValueKey('wait'));
        } else if (_introSeen == false) {
          child = IntroScreen(
            key: const ValueKey('intro'),
            onDone: () => setState(() => _introSeen = true),
          );
        } else {
          child = const LoginScreen(key: ValueKey('login'));
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOut,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: child,
          ),
          child: child,
        );
      },
    );
  }
}

class _ConfigError extends StatelessWidget {
  const _ConfigError();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.settings, size: 40, color: Colors.grey),
              SizedBox(height: 12),
              Text(
                'Supabase設定が読み込まれていません',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              SizedBox(height: 8),
              Text(
                'flutter run --dart-define-from-file=config/app_config.json\n'
                'で起動してください。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
