import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data.dart';
import 'plan_screen.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

/// 連携アプリの一覧・追加・編集・削除。すべて直接Supabase（RLSで自分のみ）。
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  late Future<List<AppRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = Repo.apps();
  }

  void _reload() => setState(() => _future = Repo.apps());

  Future<void> _openEditor([AppRow? app]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AppEditScreen(existing: app)),
    );
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('連携アプリ')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('アプリを追加'),
      ),
      body: FutureBuilder<List<AppRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final apps = snap.data ?? [];
          if (apps.isEmpty) {
            return EmptyState(
              icon: Icons.apps_outlined,
              title: 'まだアプリがありません',
              subtitle: '「アプリを追加」から監視したいアプリを登録します。',
              action: FilledButton(
                onPressed: () => _openEditor(),
                child: const Text('アプリを追加'),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: apps.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              final a = apps[i];
              return Card(
                child: ListTile(
                  onTap: () => _openEditor(a),
                  leading: Icon(
                      a.store == 'appstore' ? Icons.apple : Icons.android,
                      color: Colors.grey.shade800),
                  title: Text(a.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${a.storeLabel}・${a.storeAppId}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: const Icon(Icons.chevron_right),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// アプリの追加 / 編集フォーム。
class AppEditScreen extends StatefulWidget {
  final AppRow? existing;
  const AppEditScreen({super.key, this.existing});

  @override
  State<AppEditScreen> createState() => _AppEditScreenState();
}

class _AppEditScreenState extends State<AppEditScreen> {
  late String _store;
  late final TextEditingController _appId;
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late String _tone;
  late final TextEditingController _opening;
  late final TextEditingController _closing;
  late final TextEditingController _rules;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _store = e?.store ?? 'appstore';
    _appId = TextEditingController(text: e?.storeAppId ?? '');
    _name = TextEditingController(text: e?.name ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
    _tone = e?.replyTone ?? 'polite';
    _opening = TextEditingController(text: e?.replyOpening ?? '');
    _closing = TextEditingController(text: e?.replyClosing ?? '');
    _rules = TextEditingController(text: e?.replyRules ?? '');
  }

  @override
  void dispose() {
    _appId.dispose();
    _name.dispose();
    _desc.dispose();
    _opening.dispose();
    _closing.dispose();
    _rules.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || (!_isEdit && _appId.text.trim().isEmpty)) {
      showSnack(context, 'アプリ名とID/パッケージ名は必須です', kind: SnackKind.error);
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        final e = widget.existing!;
        final style = <String, String?>{
          if (_trimmed(_opening) != _blankToNull(e.replyOpening))
            'reply_opening': _trimmed(_opening),
          if (_trimmed(_closing) != _blankToNull(e.replyClosing))
            'reply_closing': _trimmed(_closing),
          if (_trimmed(_rules) != _blankToNull(e.replyRules))
            'reply_rules': _trimmed(_rules),
        };
        await Repo.updateApp(e.id,
            name: _name.text.trim(),
            description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
            tone: _tone,
            style: style);
      } else {
        await Repo.addApp(
          store: _store,
          storeAppId: _appId.text.trim(),
          name: _name.text.trim(),
          description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          tone: _tone,
          replyOpening: _trimmed(_opening),
          replyClosing: _trimmed(_closing),
          replyRules: _trimmed(_rules),
        );
      }
      HapticFeedback.lightImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showErrorWithUpgrade(context, e, reason: PaywallReason.apps);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  static String? _trimmed(TextEditingController c) => _blankToNull(c.text);

  /// 迷わず始められるよう、よくある形の例を入れる（入力済みの欄は上書きしない）。
  void _fillExample() {
    HapticFeedback.selectionClick();
    final name = _name.text.trim().isEmpty ? 'アプリ' : _name.text.trim();
    setState(() {
      if (_opening.text.trim().isEmpty) {
        _opening.text = '$nameをご利用いただき、ありがとうございます。';
      }
      if (_closing.text.trim().isEmpty) {
        _closing.text = '今後とも$nameをよろしくお願いいたします。（$name 開発チーム）';
      }
      if (_rules.text.trim().isEmpty) {
        _rules.text = '不具合の報告には、設定画面の「お問い合わせ」から詳細を送ってもらうよう案内する。'
            '「検討します」だけで終わらせない。';
      }
    });
  }

  Widget _replyStyleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('返信スタイル（任意）',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            TextButton(onPressed: _fillExample, child: const Text('例を入れる')),
          ],
        ),
        Text(
          'AIが作る返信の書き出し・結び・守ってほしいことを決めておくと、'
          'どの返信も同じ調子にそろいます。',
          style: TextStyle(fontSize: 12, height: 1.5, color: context.subtleC),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _opening,
          maxLength: 100,
          decoration: const InputDecoration(
            labelText: '書き出し',
            hintText: '例: ○○をご利用いただきありがとうございます。',
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _closing,
          maxLength: 100,
          decoration: const InputDecoration(
            labelText: '結び・署名',
            hintText: '例: ○○開発チーム',
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _rules,
          maxLines: 3,
          maxLength: 300,
          decoration: const InputDecoration(
            labelText: '守ってほしいこと',
            hintText: '例: 問い合わせ先は support@example.com を案内する',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アプリを削除'),
        content: Text('「${widget.existing!.name}」の連携とレビュー履歴を削除します。よろしいですか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      await Repo.deleteApp(widget.existing!.id);
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final idLabel =
        _store == 'appstore' ? 'App ID（数字）' : 'パッケージ名';
    final idHint = _store == 'appstore'
        ? '例: 6480001111'
        : '例: com.example.app';
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'アプリを編集' : 'アプリを追加')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_isEdit) ...[
            const Text('ストア', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'appstore',
                    label: Text('App Store'),
                    icon: Icon(Icons.apple)),
                ButtonSegment(
                    value: 'googleplay',
                    label: Text('Google Play'),
                    icon: Icon(Icons.android)),
              ],
              selected: {_store},
              onSelectionChanged: (s) => setState(() => _store = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _appId,
              decoration: InputDecoration(labelText: idLabel, hintText: idHint),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'アプリ名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _desc,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'アプリ概要（AI返信の文脈に使用・任意）',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 16),
          const Text('返信のトーン', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'polite', label: Text('丁寧')),
              ButtonSegment(value: 'casual', label: Text('親しみ')),
              ButtonSegment(value: 'apologetic', label: Text('謝罪重視')),
            ],
            selected: {_tone},
            onSelectionChanged: (s) => setState(() => _tone = s.first),
          ),
          const SizedBox(height: 24),
          _replyStyleSection(),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(_isEdit ? '保存' : '追加'),
          ),
          if (_isEdit) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _saving ? null : _delete,
              icon: const Icon(Icons.delete_outline, color: AppTheme.danger),
              label: const Text('このアプリを削除',
                  style: TextStyle(color: AppTheme.danger)),
            ),
          ],
        ],
      ),
    );
  }
}
