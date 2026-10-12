import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'data.dart';
import 'screens/apps_screen.dart';
import 'screens/connect_store_screen.dart';
import 'theme.dart';
import 'ui.dart';

/// 登録直後の「最初のレビューが届くまで」の道案内。
///
/// 以前はレビュータブに「アプリを連携し、ストアから取得すると表示されます」とだけ出て、
/// 連携の入口が設定タブの奥にあったため、何をすればいいか分からないまま離脱しうる。
/// やることを3つの手順に並べ、その場から各画面に飛べるようにする。
class SetupGuide extends StatefulWidget {
  const SetupGuide({
    super.key,
    required this.storeConnected,
    required this.hasApp,
    required this.onChanged,
  });

  final bool storeConnected;
  final bool hasApp;

  /// 手順を進めたあとに呼ぶ（一覧と連携状態を取り直してもらう）。
  final VoidCallback onChanged;

  @override
  State<SetupGuide> createState() => _SetupGuideState();
}

class _SetupGuideState extends State<SetupGuide> {
  bool _fetching = false;

  Future<void> _push(Widget screen) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    widget.onChanged();
  }

  Future<void> _fetch() async {
    HapticFeedback.lightImpact();
    setState(() => _fetching = true);
    try {
      await Repo.refreshFromStores();
      if (mounted) {
        showSnack(context, 'ストアからレビューを取得しました', kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _fetching = false);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final step1 = widget.storeConnected;
    final step2 = widget.hasApp;
    final steps = [
      _Step(
        title: 'ストアと連携する',
        body: 'App Store Connect か Google Play Console の鍵を登録します。',
        done: step1,
        enabled: true,
        actionLabel: '連携する',
        onTap: () => _push(const ConnectStoreScreen()),
      ),
      _Step(
        title: '監視するアプリを追加する',
        body: 'App ID かパッケージ名を入れるだけです。',
        done: step2,
        enabled: step1,
        actionLabel: '追加する',
        onTap: () => _push(const AppEditScreen()),
      ),
      _Step(
        title: 'レビューを取り込む',
        body: '以後は毎時自動で取り込み、★1〜2はすぐに通知します。',
        done: false,
        enabled: step1 && step2,
        actionLabel: '今すぐ取得',
        busy: _fetching,
        onTap: _fetch,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('はじめの3ステップ',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('終わればここにレビューが並びます。数分で済みます。',
              style: TextStyle(color: context.subtleC)),
          const SizedBox(height: 16),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _StepCard(index: i + 1, step: steps[i]),
            )
                .animate(delay: (70 * i).ms)
                .fadeIn(duration: 260.ms)
                .slideY(begin: 0.06, end: 0, curve: Curves.easeOutCubic),
        ],
      ),
    );
  }
}

class _Step {
  final String title;
  final String body;
  final bool done;
  final bool enabled;
  final String actionLabel;
  final bool busy;
  final VoidCallback onTap;
  const _Step({
    required this.title,
    required this.body,
    required this.done,
    required this.enabled,
    required this.actionLabel,
    required this.onTap,
    this.busy = false,
  });
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.index, required this.step});

  final int index;
  final _Step step;

  @override
  Widget build(BuildContext context) {
    final active = step.enabled && !step.done;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? AppTheme.primary : context.borderC,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: step.done
                  ? AppTheme.success
                  : (active
                      ? AppTheme.primary
                      : context.subtleSurfaceC),
            ),
            child: step.done
                ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                : Text('$index',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: active ? Colors.white : context.subtleC)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: step.enabled || step.done
                            ? context.inkC
                            : context.subtleC,
                        decoration:
                            step.done ? TextDecoration.lineThrough : null)),
                const SizedBox(height: 2),
                Text(step.body,
                    style: TextStyle(
                        fontSize: 12, height: 1.4, color: context.subtleC)),
              ],
            ),
          ),
          if (active) ...[
            const SizedBox(width: 8),
            FilledButton(
              onPressed: step.busy ? null : step.onTap,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 38),
              ),
              child: step.busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(step.actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}
