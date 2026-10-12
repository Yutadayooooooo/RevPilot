import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../social_auth.dart';
import '../theme.dart';

/// メール＋パスワードでのログイン／新規登録。
/// Web側と同じSupabase Authを共有するので、どちらで登録しても相互ログイン可能。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _isSignUp = false;
  bool _loading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    HapticFeedback.lightImpact();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
        );
        if (res.session == null && mounted) {
          setState(() => _info = '確認メールを送信しました。メール内のリンクから認証してください。');
        }
      } else {
        await auth.signInWithPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '通信エラーが発生しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// パスワード再設定メールの送信。
  /// これが無いと、パスワードを忘れた利用者は自力で復帰できず、
  /// 運営が手作業で対応するしかなくなる（有料サービスでは成立しない）。
  Future<void> _sendReset() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'メールアドレスを入力してから実行してください。');
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: AppConfig.hasWeb ? '${AppConfig.webUrl}/reset-password' : null,
      );
      if (mounted) {
        setState(() => _info = 'パスワード再設定用のメールを送信しました。受信箱をご確認ください。');
      }
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '通信エラーが発生しました');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _social(Future<void> Function() signIn) async {
    HapticFeedback.lightImpact();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await signIn();
    } catch (e) {
      final msg = SocialAuth.messageFor(e);
      if (mounted && msg != null) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Apple / Google のボタン。使えるものがなければ何も出さない。
  List<Widget> _socialButtons() {
    final apple = SocialAuth.appleAvailable;
    final google = SocialAuth.googleAvailable;
    if (!apple && !google) return const [];
    final dark = Theme.of(context).brightness == Brightness.dark;
    return [
      if (apple)
        // Apple のガイドラインに沿った見た目（黒地／ダーク時は白地に Apple ロゴ）。
        FilledButton.icon(
          onPressed: _loading ? null : () => _social(SocialAuth.signInWithApple),
          style: FilledButton.styleFrom(
            backgroundColor: dark ? Colors.white : Colors.black,
            foregroundColor: dark ? Colors.black : Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Icon(Icons.apple, size: 22),
          label: const Text('Appleでサインイン',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      if (apple && google) const SizedBox(height: 10),
      if (google)
        OutlinedButton.icon(
          onPressed:
              _loading ? null : () => _social(SocialAuth.signInWithGoogle),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          icon: const Text('G',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF4285F4))),
          label: const Text('Googleでログイン',
              style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      const SizedBox(height: 18),
      Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text('またはメールで',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          const Expanded(child: Divider()),
        ],
      ),
      const SizedBox(height: 14),
    ];
  }

  Future<void> _openLegal(String path) async {
    if (!AppConfig.hasWeb) return;
    final uri = Uri.parse('${AppConfig.webUrl}$path');
    if (!await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.reviews, color: AppTheme.primary, size: 28),
                      SizedBox(width: 8),
                      Text('RevPilot',
                          style: TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                    ],
                  )
                      .animate()
                      .fadeIn(duration: 400.ms)
                      .scale(
                          begin: const Offset(0.85, 0.85),
                          end: const Offset(1, 1),
                          curve: Curves.easeOutBack),
                  const SizedBox(height: 6),
                  const Text('レビュー対応を、ポケットの中で。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 32),
                  ..._socialButtons(),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'メールアドレス'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'パスワード',
                      helperText: '8文字以上',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: const TextStyle(color: Color(0xFFDC2626))),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Text(_info!,
                        style: const TextStyle(color: Color(0xFF16A34A))),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_isSignUp ? '新規登録' : 'ログイン'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _loading
                        ? null
                        : () => setState(() {
                              _isSignUp = !_isSignUp;
                              _error = null;
                              _info = null;
                            }),
                    child: Text(_isSignUp
                        ? 'アカウントをお持ちの方はログイン'
                        : 'アカウントを新規作成'),
                  ),
                  if (!_isSignUp)
                    TextButton(
                      onPressed: _loading ? null : _sendReset,
                      child: const Text('パスワードをお忘れですか？',
                          style: TextStyle(fontSize: 13)),
                    ),
                  const SizedBox(height: 8),
                  // 登録時に規約・プライバシーへ到達できるようにする（ストア審査でも確認される）。
                  if (AppConfig.hasWeb) ...[
                    const Divider(height: 24),
                    Text(
                      '登録・ログインすることで、以下に同意したものとみなされます。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => _openLegal('/terms'),
                          child: const Text('利用規約',
                              style: TextStyle(fontSize: 12)),
                        ),
                        const Text('·', style: TextStyle(color: Colors.grey)),
                        TextButton(
                          onPressed: () => _openLegal('/privacy'),
                          child: const Text('プライバシーポリシー',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
