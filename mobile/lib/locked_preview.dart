import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import 'data.dart';
import 'models.dart';
import 'screens/plan_screen.dart';
import 'theme.dart';
import 'widgets.dart';

/// Free の閲覧範囲より前にある、保存済みレビューのチラ見せ。
///
/// 「データがありません」と出すと、実際は保存されていることが伝わらず
/// アップグレードする理由も見えない。件数・星・日付ははっきり見せ、本文だけぼかして
/// 「Proにすればここが読める」と一目で分かるようにする。
class LockedReviewsTeaser extends StatelessWidget {
  const LockedReviewsTeaser(this.preview, {super.key, this.acrossAllApps = false});

  final LockedPreview preview;

  /// 件数は常に全アプリの合計。アプリやストアで絞り込んでいる画面では、
  /// 「そのアプリにこれだけある」と誤解されないよう、全アプリの件数だと明記する。
  final bool acrossAllApps;

  @override
  Widget build(BuildContext context) {
    final days = planHistoryDays('free') ?? 30;
    final trial = planDef('pro').trialLabel;
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline_rounded,
                  size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${acrossAllApps ? '全アプリで' : ''}'
                  '$days日より前のレビューが ${preview.hiddenTotal}件 保存されています',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (preview.hiddenLow > 0) ...[
            const SizedBox(height: 4),
            Text(
              'うち★1〜2の低評価が ${preview.hiddenLow}件 あります',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.dangerTextC),
            ),
          ],
          const SizedBox(height: 12),
          // 下に行くほど薄くして「まだ続きがある」ことを見せる。
          ShaderMask(
            shaderCallback: (rect) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.55, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: Column(
              children: [
                for (var i = 0; i < preview.samples.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _LockedCard(preview.samples[i]),
                  )
                      .animate(delay: (80 * i).ms)
                      .fadeIn(duration: 260.ms),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () =>
                  openPlanScreen(context, reason: PaywallReason.history),
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: const Text('Proで全期間を見る'),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              trial == null
                  ? 'アップグレードするとすぐに読めます'
                  : 'Proは初回$trial無料（対象の方のみ）・すぐに読めます',
              style: TextStyle(fontSize: 11, color: context.subtleC),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockedCard extends StatelessWidget {
  const _LockedCard(this.review);

  final LockedReview review;

  @override
  Widget build(BuildContext context) {
    final date = review.reviewedAt != null
        ? DateFormat('yyyy/M/d').format(review.reviewedAt!.toLocal())
        : '';
    // 抜粋が短いと1行で終わって「ぼかし」に見えないので、2行ぶんに伸ばす。
    final text = review.snippet.isEmpty
        ? '本文のないレビュー'
        : (review.snippet * 3);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StarRating(review.rating, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(review.appName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: context.subtleC)),
              ),
              Text(date,
                  style: TextStyle(fontSize: 11, color: context.subtleC)),
            ],
          ),
          const SizedBox(height: 6),
          ExcludeSemantics(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.clip,
                style: TextStyle(fontSize: 13, color: context.inkC),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// トピック分析（Pro以上）の見本をぼかして見せるカード。
///
/// Free ではトピック分類を行わないため、空のカードを出すと「壊れている」ように見える。
/// どんな分析が得られるかを形で見せる（数値はダミーで、ぼかして読めないようにする）。
class LockedTopicsCard extends StatelessWidget {
  const LockedTopicsCard({super.key});

  static const _sample = [
    ('不具合', 12),
    ('機能要望', 9),
    ('使い勝手', 6),
    ('称賛', 5),
    ('価格', 2),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('トピック傾向',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('Pro',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: context.accentTextC)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ExcludeSemantics(
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 3, sigmaY: 3),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (label, n) in _sample)
                      Chip(
                        label: Text('$label $n'),
                        backgroundColor:
                            AppTheme.primary.withValues(alpha: 0.06),
                        side: BorderSide.none,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'AIがレビューを「不具合・要望・使い勝手・価格」などに自動で分類し、'
              '次に直すべきことが分かります。',
              style: TextStyle(fontSize: 12, height: 1.5, color: context.subtleC),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                // 見出しを「トピック分析」の話にして開く（履歴の話を出しても答えにならない）。
                onPressed: () =>
                    openPlanScreen(context, reason: PaywallReason.topics),
                child: const Text('Proで分析を見る'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
