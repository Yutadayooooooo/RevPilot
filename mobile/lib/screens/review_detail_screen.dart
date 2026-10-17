import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_events.dart';
import '../config.dart';
import '../data.dart';
import 'apps_screen.dart';
import 'plan_screen.dart';
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
  /// ストアの返信の文字数上限。Google Play は超えた分がサーバー側で黙って切られていたので、
  /// 入力欄で先に知らせる。数え方はサーバーと同じ UTF-16 の長さ（String.length）。
  static const _googlePlayMax = 350;
  static const _appStoreMax = 5970;

  late final TextEditingController _reply;

  /// 表示中のレビュー（下書きの保存などで返信の履歴が増えたら差し替える）。
  late ReviewRow _review;

  /// 最後に保存した本文（下書き保存・AI生成・投稿のいずれか）。入力がこれと違えば未保存。
  String _savedText = '';

  bool _saving = false;
  bool _generating = false;
  bool _posting = false;
  bool _marking = false;

  /// 入力に合わせて表示を更新したときの値（同じなら作り直さない）。
  int _shownLength = -1;
  bool _shownDirty = false;

  /// 今月のAI返信の残り（読み込み前・取得失敗時は null で何も出さない）。
  int? _aiLeft;
  String _plan = 'free';

  bool get _isGooglePlay => _review.store == 'googleplay';
  String get _storeLabel => _isGooglePlay ? 'Google Play' : 'App Store';
  String get _consoleLabel =>
      _isGooglePlay ? 'Google Play Console' : 'App Store Connect';
  int get _maxLength => _isGooglePlay ? _googlePlayMax : _appStoreMax;
  int get _length => _reply.text.trim().length;
  bool get _overLimit => _length > _maxLength;
  String get _limitMessage =>
      '$_storeLabelの返信は${NumberFormat('#,##0').format(_maxLength)}文字までです'
      '（現在$_length文字）';

  /// 保存していない編集があるか。空にしただけは含めない（返信は追記だけなので空は保存できない）。
  bool get _dirty {
    final text = _reply.text.trim();
    return text.isNotEmpty && text != _savedText.trim();
  }

  /// 返信済みにする操作を出すか（未返信、または返信後に新しい下書きがある）。
  bool get _canMarkReplied => !_review.isPosted || _review.hasNewerDraft;

  Future<void> _loadAiLeft() async {
    try {
      final s = await Repo.billingStatus();
      final left = (planAiReplies(s.plan) - s.aiRepliesUsed).clamp(0, 1 << 30);
      if (mounted) {
        setState(() {
          _plan = s.plan;
          _aiLeft = left;
        });
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _review = widget.review;
    // 編集欄には最新の本文を入れる（投稿済みより新しい下書きがあればそれ、無ければ投稿した本文）。
    // 以前は replies.first（＝最初のAI下書き）を入れていたため、手直しして保存しても
    // 開き直すと元のAI文に戻って見えた。
    _savedText = _review.draftBody;
    _reply = TextEditingController(text: _savedText)
      ..addListener(_onTextChanged);
    AppEvents.planChanged.addListener(_onPlanChanged);
    _loadAiLeft();
  }

  @override
  void dispose() {
    AppEvents.planChanged.removeListener(_onPlanChanged);
    _reply.dispose();
    super.dispose();
  }

  /// 購入・解約でプランが変わったら、AI返信の残りを取り直す。
  void _onPlanChanged() => _loadAiLeft();

  /// 文字数の表示・投稿ボタン・戻る確認を、入力に合わせて更新する。
  void _onTextChanged() {
    final length = _length;
    final dirty = _dirty;
    if (length == _shownLength && dirty == _shownDirty) return;
    setState(() {
      _shownLength = length;
      _shownDirty = dirty;
    });
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  /// 下書きを保存する。保存できたら true。
  Future<bool> _saveDraft() async {
    final text = _reply.text.trim();
    if (text.isEmpty) return false;
    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    try {
      final row = await Repo.saveManualReply(_review.id, text);
      if (mounted) {
        setState(() {
          _savedText = text;
          _review = _review.withReply(row);
        });
        showSnack(context, '下書きを保存しました', kind: SnackKind.success);
      }
      return true;
    } catch (e) {
      if (mounted) showError(context, e, prefix: '下書きを保存できませんでした');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 手元の表示用に、サーバーが保存した下書きの行を足す
  /// （AI生成・投稿失敗のときは本文しか返らないので、同じ内容で行を作る）。
  void _addLocalDraft(String body, {required String source}) {
    _review = _review.withReply(ReplyRow(
      id: 'local-${DateTime.now().microsecondsSinceEpoch}',
      body: body,
      status: 'draft',
      source: source,
      createdAt: DateTime.now(),
    ));
  }

  Future<void> _generateAi() async {
    final before = _reply.text;
    // 手直しした文面を黙って消さない（AI返信も1件使うので、置き換える前に確かめる）。
    if (_dirty) {
      final ok = await _confirm(
        title: '入力中の返信を置き換えますか？',
        body: '保存していない編集があります。AIの新しい案で置き換えます（AI返信を1件使います）。',
        action: '置き換える',
      );
      if (!ok || !mounted) return;
    }
    HapticFeedback.lightImpact();
    setState(() => _generating = true);
    try {
      final body = await Repo.generateAiReply(_review.id);
      if (body.isNotEmpty && mounted) {
        HapticFeedback.mediumImpact();
        // 生成した本文はサーバーが下書きとして保存済みなので、未保存の扱いにしない。
        setState(() {
          _savedText = body;
          _addLocalDraft(body, source: 'ai');
        });
        _reply.text = body;
        final canUndo =
            before.trim().isNotEmpty && before.trim() != body.trim();
        showSnack(
          context,
          'AIが返信を生成しました',
          kind: SnackKind.success,
          actionLabel: canUndo ? '元に戻す' : null,
          onAction: canUndo
              ? () {
                  if (mounted) _reply.text = before;
                }
              : null,
        );
        _loadAiLeft();
      }
    } catch (e) {
      if (mounted) {
        if (e is ApiException && e.isPlanLimit) {
          showErrorWithUpgrade(context, e, reason: PaywallReason.aiQuota);
        } else {
          showError(context, e);
        }
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// 「今月のAI返信 あとN件」。Free で残りが少ないときは Pro への導線を添える。
  /// 上限に当たってから知るより、手前で見えている方が納得してアップグレードできる。
  Widget _aiLeftLine() {
    final left = _aiLeft!;
    final low = left <= 1;
    final isFree = _plan == 'free';
    return Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            left == 0 ? '今月のAI返信は使い切りました' : '今月のAI返信 あと$left件',
            style: TextStyle(
              fontSize: 11,
              fontWeight: low ? FontWeight.w700 : FontWeight.w500,
              color: low ? context.warningTextC : context.subtleC,
            ),
          ),
          if (isFree && low)
            TextButton(
              onPressed: () =>
                  openPlanScreen(context, reason: PaywallReason.aiQuota),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 28),
              ),
              child: Text('Proなら月${planAiReplies('pro')}件',
                  style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  /// このレビューのアプリの返信スタイル（書き出し・結び・ルール）を編集する。
  /// AI返信を見たその場で「毎回こう書いてほしい」を直せるようにする。
  Future<void> _openReplyStyle() async {
    HapticFeedback.selectionClick();
    try {
      final apps = await Repo.apps();
      final app = apps.where((a) => a.id == _review.appId).firstOrNull;
      if (app == null || !mounted) return;
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => AppEditScreen(existing: app)),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _postToStore() async {
    final text = _reply.text.trim();
    if (text.isEmpty) {
      showSnack(context, '投稿する返信を入力してください', kind: SnackKind.error);
      return;
    }
    if (_overLimit) {
      showSnack(context, _limitMessage, kind: SnackKind.error);
      return;
    }
    // ストアの返信は1件だけで、投稿し直すと公開中の返信が置き換わる。
    if (_review.isPosted) {
      final ok = await _confirm(
        title: '公開中の返信を上書きしますか？',
        body: '$_storeLabelで公開されている返信が、この文面に置き換わります。',
        action: '上書きして投稿',
      );
      if (!ok || !mounted) return;
    }
    HapticFeedback.lightImpact();
    setState(() => _posting = true);
    try {
      await Repo.postReplyToStore(_review.id, text: text);
      HapticFeedback.mediumImpact();
      if (mounted) {
        _savedText = text;
        showSnack(context, '$_storeLabelに投稿しました', kind: SnackKind.success);
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      // 502 はストアへの投稿だけが失敗した。本文はサーバーが下書きとして保存している。
      final storeFailed = e is ApiException && e.statusCode == 502;
      if (storeFailed) {
        setState(() {
          _savedText = text;
          _addLocalDraft(text, source: 'manual');
        });
      }
      // App Store は、コピーして App Store Connect に貼り付ければ返信できる。
      final offerCopy = storeFailed && !_isGooglePlay;
      showError(
        context,
        e,
        actionLabel: offerCopy ? 'コピーして開く' : null,
        onAction: offerCopy ? () => _copyAndOpenConnect(text) : null,
      );
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  void _copyReply() {
    if (_reply.text.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    Clipboard.setData(ClipboardData(text: _reply.text));
    final canMark = _canMarkReplied;
    showSnack(
      context,
      '返信をコピーしました。ストアの管理画面に貼り付けてください。',
      kind: SnackKind.success,
      actionLabel: canMark ? '返信済みにする' : null,
      onAction: canMark ? () => _markReplied(confirm: false) : null,
    );
  }

  Future<void> _copyAndOpenConnect(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    await _openAppStoreConnect();
  }

  /// App Store Connect などで直接返信したレビューを、返信済みとして記録する。
  /// 記録しないと「未返信」に残り続け、一括投稿でAIの文面に上書きされうる。
  Future<void> _markReplied({bool confirm = true}) async {
    if (_marking || !mounted) return;
    if (confirm) {
      final ok = await _confirm(
        title: 'ストアで返信済みにしますか？',
        body: '$_consoleLabelで直接返信したレビューを、返信済みとして記録します。'
            'ストアへの投稿は行いません。',
        action: '返信済みにする',
      );
      if (!ok || !mounted) return;
    }
    final text = _reply.text.trim();
    setState(() => _marking = true);
    try {
      await Repo.markReplied(_review.id, body: text);
      if (!mounted) return;
      _savedText = text;
      showSnack(context, '返信済みにしました', kind: SnackKind.success);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e, prefix: '返信済みにできませんでした');
    } finally {
      if (mounted) setState(() => _marking = false);
    }
  }

  Future<void> _openAppStoreConnect() async {
    final uri = Uri.parse('https://appstoreconnect.apple.com/apps');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
    }
  }

  /// 保存していない編集があるまま戻ろうとしたとき（戻るボタン・Android の戻る操作）。
  /// iOS の戻るスワイプは、編集中は効かなくなるので、左上の戻るからここに来る。
  Future<void> _confirmLeave() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('編集中の返信があります'),
        content: const Text('保存していない変更があります。下書きに保存してから戻りますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'stay'),
              child: const Text('編集を続ける')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'discard'),
              style:
                  TextButton.styleFrom(foregroundColor: context.dangerTextC),
              child: const Text('破棄して戻る')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('保存して戻る')),
        ],
      ),
    );
    if (!mounted) return;
    // Navigator.pop は PopScope を通らないので、そのまま閉じられる。
    if (choice == 'discard') {
      Navigator.pop(context);
    } else if (choice == 'save' && await _saveDraft() && mounted) {
      Navigator.pop(context);
    }
  }

  void _dismissKeyboard() => FocusScope.of(context).unfocus();

  @override
  Widget build(BuildContext context) {
    final r = _review;
    final date = r.reviewedAt != null
        ? DateFormat('yyyy年M月d日').format(r.reviewedAt!)
        : '';
    final replied = r.repliedReply;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('レビュー詳細')),
        // 余白タップでキーボードを閉じる（スクロールでも閉じる）。
        body: GestureDetector(
          onTap: _dismissKeyboard,
          behavior: HitTestBehavior.translucent,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                        const SizedBox(width: 8),
                        // 文字を大きくしても星とはみ出さないよう、残りの幅に収める。
                        Expanded(
                          child: Text(date,
                              textAlign: TextAlign.end,
                              style: TextStyle(
                                  color: context.subtleC, fontSize: 12)),
                        ),
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
            if (replied != null) ...[
              const SizedBox(height: 16),
              _repliedBanner(replied),
            ],
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
                      style: TextStyle(fontSize: 11, color: context.subtleC)),
              ],
            ).animate(delay: 120.ms).fadeIn(duration: 240.ms),
            if (AppConfig.hasApi && _aiLeft != null) _aiLeftLine(),
            const SizedBox(height: 8),
            Stack(
              children: [
                TextField(
                  controller: _reply,
                  maxLines: 6,
                  decoration: InputDecoration(
                    hintText: 'お客様への返信を入力…',
                    alignLabelWithHint: true,
                    // Google Play は350文字までなので、常に文字数を出す。
                    counterText:
                        _isGooglePlay ? '$_length/$_googlePlayMax' : null,
                    errorText: _overLimit ? _limitMessage : null,
                    errorMaxLines: 2,
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
            if (AppConfig.hasApi)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _openReplyStyle,
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('返信スタイルを設定',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
            const SizedBox(height: 4),
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _posting || _overLimit ? null : _postToStore,
                icon: _posting
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                // 投稿済みなら、公開中の返信を置き換えることが分かる文言にする。
                label: Text(
                    r.isPosted ? '返信を更新して投稿' : '$_storeLabelに投稿'),
              ),
            ).animate(delay: 300.ms).fadeIn(duration: 240.ms),
            if (r.store == 'appstore') ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _openAppStoreConnect,
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('App Store Connectを開く'),
              ),
              const SizedBox(height: 8),
              Text(
                'App Store側の返信APIは不安定な場合があります。自動投稿に失敗するときは'
                '「コピー」で本文をコピーし、App Store Connectのこのレビューに貼り付けてください。',
                style: TextStyle(fontSize: 12, color: context.subtleC),
              ),
            ],
            if (_canMarkReplied) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _marking ? null : _markReplied,
                  icon: _marking
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.task_alt_rounded, size: 18),
                  label: const Text('ストアで返信済みにする'),
                ),
              ),
              Text(
                '$_consoleLabelで直接返信したときに押すと、未返信の一覧から外れます。',
                style: TextStyle(fontSize: 12, color: context.subtleC),
              ),
            ],
          ],
          ),
        ),
      ),
    );
  }

  /// ストアで返信済みの内容。何がいつ公開されたかを、編集欄とは別に読み取り専用で出す。
  Widget _repliedBanner(ReplyRow done) {
    final when = DateFormat('M月d日 H:mm').format(done.repliedAt);
    final title = done.isCopied
        ? '$_storeLabelで返信済み（手動で記録）'
        : '$_storeLabelに投稿済み';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 18, color: AppTheme.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$title・$when',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: context.successTextC)),
              ),
            ],
          ),
          if (done.body.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(done.body,
                style: TextStyle(height: 1.5, color: context.inkC)),
          ],
          if (_review.hasNewerDraft) ...[
            const SizedBox(height: 8),
            Text('このあとに作った下書きを、下の入力欄に表示しています。',
                style: TextStyle(fontSize: 12, color: context.subtleC)),
          ],
        ],
      ),
    ).animate().fadeIn(duration: 240.ms);
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: context.faintC),
        const SizedBox(width: 4),
        // 長いアプリ名・投稿者名でもカードからはみ出さないよう省略する。
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: context.subtleC)),
        ),
      ],
    );
  }
}
