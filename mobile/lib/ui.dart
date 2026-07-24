import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import 'theme.dart';

/// 一貫したスナックバー（アイコン＋色）。
enum SnackKind { info, success, error }

void showSnack(BuildContext context, String message, {SnackKind kind = SnackKind.info}) {
  final (icon, color) = switch (kind) {
    SnackKind.success => (Icons.check_circle, AppTheme.success),
    SnackKind.error => (Icons.error, AppTheme.danger),
    SnackKind.info => (Icons.info_outline, Colors.white),
  };
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    ));
}

/// スケルトン用の1ブロック（シマー付き）。
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const SkeletonBox({super.key, this.width, this.height = 12, this.radius = 6});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFFE9EEF5),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// レビュー一覧のロード中に見せるスケルトンカード群。
class ReviewListSkeleton extends StatelessWidget {
  const ReviewListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: 6,
      physics: const NeverScrollableScrollPhysics(),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, __) => const _SkeletonCard(),
    )
        .animate(onPlay: (c) => c.repeat())
        .shimmer(
          duration: 1100.ms,
          color: Colors.white.withValues(alpha: 0.6),
        );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Row(children: [
              SkeletonBox(width: 90, height: 14),
              Spacer(),
              SkeletonBox(width: 32, height: 12),
            ]),
            SizedBox(height: 12),
            SkeletonBox(width: 180, height: 14),
            SizedBox(height: 8),
            SkeletonBox(height: 12),
            SizedBox(height: 6),
            SkeletonBox(width: 220, height: 12),
            SizedBox(height: 12),
            Row(children: [
              SkeletonBox(width: 54, height: 20, radius: 999),
              Spacer(),
              SkeletonBox(width: 60, height: 20, radius: 999),
            ]),
          ],
        ),
      ),
    );
  }
}
