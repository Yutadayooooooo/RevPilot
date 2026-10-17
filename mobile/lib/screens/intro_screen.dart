import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 初回起動時だけ見せる、左スワイプ式の紹介（3枚）。
///
/// ログイン前に「何が嬉しいアプリか」を伝えておくと、登録後の空の画面で迷わず、
/// 課金画面の訴求（全期間の保存・低評価の即通知・AI返信）とも話がつながる。
/// 枚数を増やすほど離脱が増えるので3枚に絞り、いつでもスキップできるようにする。
class IntroScreen extends StatefulWidget {
  const IntroScreen({super.key, required this.onDone});

  final VoidCallback onDone;

  static const _seenKey = 'intro_seen_v1';

  static Future<bool> seen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_seenKey) ?? false;
    } catch (_) {
      return true; // 読めない端末では出さない（毎回出るよりまし）
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_seenKey, true);
    } catch (_) {}
  }

  /// 紹介を見終えた直後か。このあとのログイン画面を「新規登録」から始めるのに使う
  /// （紹介を見た＝はじめての人なので、ログインから始めると英語のエラーで迷わせてしまう）。
  static bool _justFinished = false;

  /// 一度読んだら false に戻す（ログアウトしたあとのログイン画面まで新規登録にしない）。
  static bool takeJustFinished() {
    final v = _justFinished;
    _justFinished = false;
    return v;
  }

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroPage {
  final IconData icon;
  final String title;
  final String body;
  const _IntroPage(this.icon, this.title, this.body);
}

class _IntroScreenState extends State<IntroScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = [
    _IntroPage(
      Icons.inventory_2_outlined,
      'レビューを、\nすべて残しておく',
      'Google Play が返すのは直近7日ぶんだけです。'
          'RevPilot が毎時取りに行き、App Store のレビューとあわせて保存します。',
    ),
    _IntroPage(
      Icons.notifications_active_outlined,
      '大事な声に、\n早く気づく',
      '★1〜2のレビューが届いたら、プッシュ通知でお知らせします。'
          '困っている利用者に、その日のうちに返せます。',
    ),
    _IntroPage(
      Icons.auto_awesome,
      '返信の下書きは、\nAIにまかせる',
      'レビューの内容にあわせた返信案をAIが用意します。'
          '挨拶や署名をアプリごとに決めておけば、返信の文体もそろいます。',
    ),
  ];

  bool get _isLast => _page == _pages.length - 1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    HapticFeedback.lightImpact();
    await IntroScreen.markSeen();
    IntroScreen._justFinished = true;
    widget.onDone();
  }

  void _next() {
    if (_isLast) {
      _finish();
      return;
    }
    HapticFeedback.selectionClick();
    _controller.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: AnimatedOpacity(
                opacity: _isLast ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: TextButton(
                  onPressed: _isLast ? null : _finish,
                  child: const Text('スキップ'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _IntroPageView(_pages[i]),
              ),
            ),
            _dots(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _next,
                  child: Text(
                    _isLast ? 'はじめる' : '次へ',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < _pages.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == _page ? 22 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: i == _page ? AppTheme.primary : context.borderC,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}

class _IntroPageView extends StatelessWidget {
  const _IntroPageView(this.page);

  final _IntroPage page;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
                width: 132,
                height: 132,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppTheme.primary.withValues(alpha: 0.22),
                      AppTheme.primary.withValues(alpha: 0.06),
                    ],
                  ),
                ),
                child: Icon(page.icon, size: 60, color: AppTheme.primary),
              )
              .animate()
              .fadeIn(duration: 300.ms)
              .scale(
                begin: const Offset(0.85, 0.85),
                end: const Offset(1, 1),
                curve: Curves.easeOutBack,
              ),
          const SizedBox(height: 36),
          Text(
            page.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              height: 1.35,
              fontWeight: FontWeight.w800,
            ),
          ).animate().fadeIn(delay: 80.ms, duration: 300.ms).slideY(
                begin: 0.1,
                end: 0,
              ),
          const SizedBox(height: 16),
          Text(
            page.body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, height: 1.7, color: context.subtleC),
          ).animate().fadeIn(delay: 160.ms, duration: 300.ms),
        ],
      ),
    );
  }
}
