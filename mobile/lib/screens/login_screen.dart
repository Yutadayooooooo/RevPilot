import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../social_auth.dart';
import '../theme.dart';
import '../ui.dart';
import 'intro_screen.dart';

/// メール＋パスワードでのログイン／新規登録。
/// Web側と同じSupabase Authを共有するので、どちらで登録しても相互ログイン可能。
class LoginScreen extends StatefulWidget {
  /// 新規登録モードで始めるか。null なら、紹介を見終えた直後だけ新規登録から始める。
  final bool? initialSignUp;
  const LoginScreen({super.key, this.initialSignUp});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

/// パスワードの最小文字数（Web の登録フォームと同じ）。
const _minPassword = 8;

final _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  late bool _isSignUp;
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  String? _info;
  String? _emailError;
  String? _passwordError;

  /// 確認メールのリンクを待っているアドレス。確認待ちの案内と再送ボタンを出す。
  String? _pendingEmail;

  /// たった今、確認メールを送ったか（false ならログイン時に「確認が済んでいない」と分かった）。
  bool _justSent = false;

  /// 再送できるまでの残り秒数（連打で送信回数の制限に当たらないように）。
  int _resendWait = 0;
  Timer? _resendTimer;

  /// 確認メールのリンクを開いたあとに着地するページ（「アプリに戻ってログイン」の案内）。
  /// 指定しないとサイトのトップに着き、確認が済んだことも次にすべきことも分からない。
  static String? get _confirmedUrl =>
      AppConfig.hasWeb ? '${AppConfig.webUrl}/auth/confirmed' : null;

  @override
  void initState() {
    super.initState();
    _isSignUp = widget.initialSignUp ?? IntroScreen.takeJustFinished();
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// 送信前の確認。問題があれば欄の下に理由を出して false。
  bool _validate() {
    final email = _email.text.trim();
    final password = _password.text;
    final emailError = email.isEmpty
        ? 'メールアドレスを入力してください'
        : !_emailPattern.hasMatch(email)
            ? 'メールアドレスの形式をご確認ください'
            : null;
    // ログインは長さを問わない（以前の設定で作った短いパスワードの人も入れるように）。
    final passwordError = password.isEmpty
        ? 'パスワードを入力してください'
        : _isSignUp && password.length < _minPassword
            ? 'パスワードは$_minPassword文字以上にしてください'
            : null;
    setState(() {
      _emailError = emailError;
      _passwordError = passwordError;
    });
    return emailError == null && passwordError == null;
  }

  Future<void> _submit() async {
    if (_loading) return;
    setState(() {
      _error = null;
      _info = null;
    });
    if (!_validate()) return;
    HapticFeedback.lightImpact();
    setState(() => _loading = true);
    final auth = Supabase.instance.client.auth;
    final email = _email.text.trim();
    try {
      if (_isSignUp) {
        final res = await auth.signUp(
          email: email,
          password: _password.text,
          emailRedirectTo: _confirmedUrl,
        );
        if (!mounted) return;
        if (res.session != null) {
          // 確認メールを使わない設定。そのままホームへ進む（キーチェーンへの保存を促す）。
          TextInput.finishAutofillContext();
          return;
        }
        // 確認メールを有効にしていると、登録済みのアドレスでもエラーにならず、
        // identities が空のユーザーが返る（メールは送られない）。
        if (res.user?.identities?.isEmpty ?? false) {
          setState(() {
            _isSignUp = false;
            _error = 'このメールアドレスは登録済みです。ログインするか、Apple / Google でログインしてください。';
          });
          return;
        }
        TextInput.finishAutofillContext();
        // 確認後はこの画面でそのままログインできるよう、ログインに切り替えておく。
        setState(() {
          _isSignUp = false;
          _pendingEmail = email;
          _justSent = true;
        });
        _startResendWait();
      } else {
        await auth.signInWithPassword(email: email, password: _password.text);
        TextInput.finishAutofillContext();
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _applyAuthError(e, email));
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 認証エラーを画面の状態にする（setState の中で呼ぶ）。
  void _applyAuthError(AuthException e, String email) {
    final code = e.code ?? '';
    if (code == 'email_not_confirmed' ||
        e.message.toLowerCase().contains('email not confirmed')) {
      // 文言だけでなく、確認メールを送り直せるようにする。
      _pendingEmail = email;
      _justSent = false;
      return;
    }
    if (code == 'email_address_not_authorized') {
      // 確認メールを送れないアドレス（メール送信の設定による）。
      _error = '現在、このメールアドレスには確認メールを送れません。Apple または Google でログインしてください。';
      return;
    }
    var message = friendlyError(e);
    if (!_isSignUp &&
        (code == 'invalid_credentials' ||
            e.message.toLowerCase().contains('invalid login credentials'))) {
      message = '$message\nはじめての方は、下の「アカウントを新規作成」から登録してください。';
    }
    _error = message;
  }

  void _startResendWait() {
    _resendTimer?.cancel();
    setState(() => _resendWait = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendWait--);
      if (_resendWait <= 0) t.cancel();
    });
  }

  /// 確認メールの再送。
  Future<void> _resend() async {
    final email = _pendingEmail;
    if (email == null || _loading) return;
    HapticFeedback.lightImpact();
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });
    try {
      await Supabase.instance.client.auth.resend(
        type: OtpType.signup,
        email: email,
        emailRedirectTo: _confirmedUrl,
      );
      if (!mounted) return;
      setState(() => _justSent = true);
      _startResendWait();
      showSnack(context, '確認メールを再送しました', kind: SnackKind.success);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// パスワード再設定メールの送信。
  /// これが無いと、パスワードを忘れた利用者は自力で復帰できず、
  /// 運営が手作業で対応するしかなくなる（有料サービスでは成立しない）。
  Future<void> _sendReset() async {
    final email = _email.text.trim();
    setState(() {
      _error = null;
      _info = null;
      _passwordError = null;
      _emailError = email.isEmpty
          ? '再設定メールの送り先を入力してください'
          : !_emailPattern.hasMatch(email)
              ? 'メールアドレスの形式をご確認ください'
              : null;
    });
    if (_emailError != null) return;
    HapticFeedback.lightImpact();
    setState(() => _loading = true);
    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: AppConfig.hasWeb ? '${AppConfig.webUrl}/reset-password' : null,
      );
      if (mounted) {
        setState(() => _info =
            'パスワード再設定用のメールを送りました。メールのリンクから新しいパスワードを設定し、この画面でログインしてください。');
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleMode() {
    HapticFeedback.selectionClick();
    setState(() {
      _isSignUp = !_isSignUp;
      _error = null;
      _info = null;
      _emailError = null;
      _passwordError = null;
      _pendingEmail = null;
    });
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
                style: TextStyle(fontSize: 12, color: context.subtleC)),
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

  /// 確認メールを待っている間の案内（リンクを開いたらこの画面でログイン）。
  Widget _pendingPanel(String email) {
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.success.withValues(alpha: 0.30)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    _justSent
                        ? Icons.mark_email_read_outlined
                        : Icons.mark_email_unread_outlined,
                    size: 20,
                    color: context.successTextC),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _justSent ? '確認メールを送りました' : 'メールアドレスの確認が済んでいません',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$email に届いたメールのリンクを開いてから、'
              'この画面で「ログイン」を押してください。'
              '届かないときは、迷惑メールフォルダもご確認ください。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _loading || _resendWait > 0 ? null : _resend,
                child: Text(_resendWait > 0
                    ? '再送できるまで$_resendWait秒'
                    : '確認メールを再送'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                  Text('レビュー対応を、ポケットの中で。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.subtleC)),
                  const SizedBox(height: 32),
                  ..._socialButtons(),
                  // パスワードの自動入力・保存（iCloud キーチェーン / Google パスワード マネージャー）を効かせる。
                  AutofillGroup(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          autofillHints: const [AutofillHints.email],
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _passwordFocus.requestFocus(),
                          onChanged: (_) {
                            if (_emailError != null) {
                              setState(() => _emailError = null);
                            }
                          },
                          decoration: InputDecoration(
                            labelText: 'メールアドレス',
                            errorText: _emailError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          focusNode: _passwordFocus,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: [
                            _isSignUp
                                ? AutofillHints.newPassword
                                : AutofillHints.password
                          ],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          onChanged: (_) {
                            if (_passwordError != null) {
                              setState(() => _passwordError = null);
                            }
                          },
                          decoration: InputDecoration(
                            labelText: 'パスワード',
                            helperText:
                                _isSignUp ? '$_minPassword文字以上' : null,
                            errorText: _passwordError,
                            suffixIcon: IconButton(
                              tooltip: _obscure ? 'パスワードを表示' : 'パスワードを隠す',
                              icon: Icon(_obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_pendingEmail != null) _pendingPanel(_pendingEmail!),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(_error!,
                          style: TextStyle(color: context.dangerTextC)),
                    ),
                  ],
                  if (_info != null) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(_info!,
                          style: TextStyle(color: context.successTextC)),
                    ),
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
                    onPressed: _loading ? null : _toggleMode,
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
                      style: TextStyle(fontSize: 11, color: context.subtleC),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => _openLegal('/terms'),
                          child: const Text('利用規約',
                              style: TextStyle(fontSize: 12)),
                        ),
                        Text('·', style: TextStyle(color: context.subtleC)),
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
