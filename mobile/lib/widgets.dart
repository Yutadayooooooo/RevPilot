import 'package:flutter/material.dart';

import 'theme.dart';
import 'models.dart';

/// 星評価の表示。
///
/// VoiceOver / TalkBack では星のアイコン5つを個別に読ませず、
/// 「星5つ中3つ」とまとめて読み上げる。
class StarRating extends StatelessWidget {
  final int rating;
  final double size;
  const StarRating(this.rating, {super.key, this.size = 16});

  /// 読み上げ用の文言（rating が 1〜5 以外なら「評価なし」）。
  static String semanticsLabel(int rating) =>
      rating >= 1 && rating <= 5 ? '星5つ中$ratingつ' : '評価なし';

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.ratingColor(rating);
    return Semantics(
      label: semanticsLabel(rating),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(
          5,
          (i) => Icon(
            i < rating ? Icons.star_rounded : Icons.star_outline_rounded,
            size: size,
            color: i < rating ? color : context.borderC,
          ),
        ),
      ),
    );
  }
}

/// トピックのチップ。
class TopicChip extends StatelessWidget {
  final String topic;
  const TopicChip(this.topic, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        topicLabels[topic] ?? topic,
        // 11pt の小さい文字なので、primary ではなく読みやすい濃さのアクセントにする。
        style: TextStyle(
            fontSize: 11,
            color: context.accentTextC,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 読み直しに失敗したときに、前回の内容の上に出す帯。
///
/// 一度読めた内容を、通信の失敗のたびに全画面のエラーへ置き換えない
/// （何もしていないのに画面が消えたように見え、「アプリを追加」などのボタンも消えてしまう）。
class StaleBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const StaleBanner({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 18, color: context.warningTextC),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12.5, height: 1.5),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('再試行')),
        ],
      ),
    );
  }
}

/// 空状態の表示。
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: context.faintC),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.subtleC)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
