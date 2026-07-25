import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../data.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

class ReviewDetailScreen extends StatefulWidget {
  final ReviewRow review;
  const ReviewDetailScreen(this.review, {super.key});

  @override
  State<ReviewDetailScreen> createState() => _ReviewDetailScreenState();
}

class _ReviewDetailScreenState extends State<ReviewDetailScreen> {
  late final TextEditingController _reply;
  bool _saving = false;
  bool _generating = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    final existing =
        widget.review.replies.isNotEmpty ? widget.review.replies.first.body : '';
    _reply = TextEditingController(text: existing);
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _saveDraft() async {
    if (_reply.text.trim().isEmpty) return;
    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    try {
      await Repo.saveManualReply(widget.review.id, _reply.text.trim());
      if (mounted) {
        showSnack(context, '下書きを保存しました', kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, '保存に失敗: $e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generateAi() async {
    HapticFeedback.lightImpact();
    setState(() => _generating = true);
    try {
      final body = await Repo.generateAiReply(widget.review.id);
      if (body.isNotEmpty && mounted) {
        HapticFeedback.mediumImpact();
        setState(() => _reply.text = body);
        showSnack(context, 'AIが返信を生成しました', kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _postToStore() async {
    if (_reply.text.trim().isEmpty) {
      showSnack(context, '投稿する返信を入力してください', kind: SnackKind.error);
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _posting = true);
    try {
      await Repo.postReplyToStore(widget.review.id, text: _reply.text.trim());
      HapticFeedback.mediumImpact();
      if (mounted) {
        showSnack(context, 'Google Playに投稿しました', kind: SnackKind.success);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _copyReply() {
    if (_reply.text.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    Clipboard.setData(ClipboardData(text: _reply.text));
    showSnack(context, '返信をコピーしました。ストアの管理画面に貼り付けてください。',
        kind: SnackKind.success);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review;
    final date = r.reviewedAt != null
        ? DateFormat('yyyy年M月d日').format(r.reviewedAt!)
        : '';
    return Scaffold(
      appBar: AppBar(title: const Text('レビュー詳細')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      StarRating(r.rating, size: 20)
                          .animate()
                          .scale(
                            begin: const Offset(0.7, 0.7),
                            end: const Offset(1, 1),
                            duration: 500.ms,
                            curve: Curves.elasticOut,
                          )
                          .fadeIn(duration: 200.ms),
                      const Spacer(),
                      Text(date,
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 12)),
                    ],
                  ),
                  if (r.title != null && r.title!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(r.title!,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                  if (r.body != null && r.body!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(r.body!, style: const TextStyle(height: 1.5)),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (r.author != null && r.author!.isNotEmpty)
                        _meta(Icons.person_outline, r.author!),
                      if (r.appName != null)
                        _meta(Icons.apps, r.appName!),
                      if (r.appVersion != null && r.appVersion!.isNotEmpty)
                        _meta(Icons.tag, 'v${r.appVersion!}'),
                      if (r.territory != null && r.territory!.isNotEmpty)
                        _meta(Icons.public, r.territory!),
                    ],
                  ),
                  if (r.topics.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: r.topics.map((t) => TopicChip(t)).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ).animate().fadeIn(duration: 260.ms).slideY(
              begin: 0.04, end: 0, curve: Curves.easeOut),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('返信',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const Spacer(),
              if (AppConfig.hasApi)
                TextButton.icon(
                  onPressed: _generating ? null : _generateAi,
                  icon: _generating
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(_generating ? '生成中…' : 'AIで生成'),
                )
              else
                Text('AI生成はサーバー接続後に有効',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ).animate(delay: 120.ms).fadeIn(duration: 240.ms),
          const SizedBox(height: 8),
          Stack(
            children: [
              TextField(
                controller: _reply,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: 'お客様への返信を入力…',
                  alignLabelWithHint: true,
                ),
              ),
              // AI生成中は入力欄にシマーを重ねて「生成中」を表現。
              if (_generating)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    )
                        .animate(onPlay: (c) => c.repeat())
                        .shimmer(
                          duration: 1000.ms,
                          color: AppTheme.primary.withValues(alpha: 0.10),
                        ),
                  ),
                ),
            ],
          ).animate(delay: 180.ms).fadeIn(duration: 240.ms).slideY(
              begin: 0.05, end: 0, curve: Curves.easeOut),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyReply,
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('コピー'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saving ? null : _saveDraft,
                  icon: _saving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('下書き保存'),
                ),
              ),
            ],
          ).animate(delay: 240.ms).fadeIn(duration: 240.ms),
          if (r.store == 'googleplay') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _posting ? null : _postToStore,
                icon: _posting
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: const Text('Google Playに投稿'),
              ),
            ).animate(delay: 300.ms).fadeIn(duration: 240.ms),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              'App Storeは自動投稿に対応していないため、コピーしてApp Store Connectに貼り付けてください。',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
          ],
        ],
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }
}
