import 'package:flutter/material.dart';

import 'theme.dart';
import 'models.dart';

/// 星評価の表示。
class StarRating extends StatelessWidget {
  final int rating;
  final double size;
  const StarRating(this.rating, {super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.ratingColor(rating);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        5,
        (i) => Icon(
          i < rating ? Icons.star_rounded : Icons.star_outline_rounded,
          size: size,
          color: i < rating ? color : Colors.grey.shade300,
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
        style: const TextStyle(
            fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w600),
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
            Icon(icon, size: 44, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}
