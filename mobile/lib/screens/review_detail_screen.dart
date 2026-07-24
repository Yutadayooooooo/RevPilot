import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../data.dart';
import '../models.dart';
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
    setState(() => _saving = true);
    try {
      await Repo.saveManualReply(widget.review.id, _reply.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('下書きを保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存に失敗: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _generateAi() async {
    setState(() => _generating = true);
    try {
      final body = await Repo.generateAiReply(widget.review.id);
      if (body.isNotEmpty && mounted) {
        setState(() => _reply.text = body);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('AIが返信を生成しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  void _copyReply() {
    Clipboard.setData(ClipboardData(text: _reply.text));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('返信をコピーしました。ストアの管理画面に貼り付けてください。')));
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
                      StarRating(r.rating, size: 20),
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
          ),
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
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _reply,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'お客様への返信を入力…',
              alignLabelWithHint: true,
            ),
          ),
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
          ),
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
