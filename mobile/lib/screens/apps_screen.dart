import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app_events.dart';
import '../data.dart';
import 'connect_store_screen.dart';
import 'plan_screen.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

/// 「12分前」のような最終取得の表示。1日以上前は日時にする。
String fetchedAgo(DateTime at) {
  final local = at.toLocal();
  final d = DateTime.now().difference(local);
  if (d.inMinutes < 1) return 'たった今';
  if (d.inMinutes < 60) return '${d.inMinutes}分前';
  if (d.inHours < 24) return '${d.inHours}時間前';
  return DateFormat('M月d日 H:mm').format(local);
}

/// 連携アプリの一覧・追加・編集・削除。
/// 一覧・編集・削除は直接Supabase（RLSで自分のみ）、追加はストアへの疎通確認があるのでAPI経由。
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  late Future<List<AppRow>> _future;

  /// 最後に読めた一覧。FutureBuilder は読み直しに失敗すると前回の値を捨てるので、
  /// 自分で持っておき、失敗しても一覧と「アプリを追加」を出したままにする。
  List<AppRow>? _last;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
    // 追加・編集・削除と、取得の結果（最終取得・エラー）が変わったら読み直す。
    AppEvents.dataChanged.addListener(_onDataChanged);
  }

  @override
  void dispose() {
    AppEvents.dataChanged.removeListener(_onDataChanged);
    super.dispose();
  }

  void _onDataChanged() {
    if (AppEvents.lastChange == DataChange.replies) return;
    _reload();
  }

  Future<List<AppRow>> _fetch() => Repo.apps().then((a) => _last = a);

  void _reload() => setState(() => _future = _fetch());

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    final f = _fetch();
    setState(() => _future = f);
    try {
      await f;
    } catch (_) {
      // 失敗はエラー表示に任せる。
    }
  }

  Future<void> _openEditor([AppRow? app]) async {
    // 保存・削除のあとの読み直しは AppEvents から届く。
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => AppEditScreen(existing: app)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<AppRow>>(
      future: _future,
      builder: (context, snap) {
        // 読み直しの間も、失敗したときも、前回の一覧を出したままにする。
        final apps = snap.data ?? _last;
        return Scaffold(
          appBar: AppBar(title: const Text('連携アプリ')),
          // 一覧を読めていないときは追加ボタンを出さない
          // （登録済みのアプリが見えないまま、同じアプリを二重に追加してしまう）。
          floatingActionButton: apps == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _openEditor(),
                  icon: const Icon(Icons.add),
                  label: const Text('アプリを追加'),
                ),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: _body(snap),
          ),
        );
      },
    );
  }

  Widget _body(AsyncSnapshot<List<AppRow>> snap) {
    final apps = snap.data ?? _last;
    // 一覧は出せているが、読み直しには失敗した。
    final stale = snap.hasError && apps != null
        ? StaleBanner(
            message: '最新の情報を取得できませんでした。${friendlyError(snap.error!)}',
            onRetry: _reload,
          )
        : null;
    if (apps == null) {
      if (snap.hasError) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            EmptyState(
              icon: Icons.wifi_off_rounded,
              title: '読み込みに失敗しました',
              subtitle: friendlyError(snap.error!),
              action: FilledButton.tonal(
                onPressed: _reload,
                child: const Text('再試行'),
              ),
            ),
          ],
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (apps.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (stale != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: stale,
            ),
          const SizedBox(height: 80),
          EmptyState(
            icon: Icons.apps_outlined,
            title: 'まだアプリがありません',
            subtitle: '「アプリを追加」から監視したいアプリを登録します。',
            action: FilledButton(
              onPressed: () => _openEditor(),
              child: const Text('アプリを追加'),
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      itemCount: apps.length + (stale != null ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (stale != null && i == 0) return stale;
        final a = apps[stale != null ? i - 1 : i];
        return Card(
          child: ListTile(
            onTap: () => _openEditor(a),
            leading: Icon(
                a.store == 'appstore' ? Icons.apple : Icons.android,
                color: context.inkC),
            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${a.storeLabel}・${a.storeAppId}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                _fetchStatus(a),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
          ),
        );
      },
    );
  }

  /// 最終取得の時刻か、取得エラーの理由。
  /// サーバーは失敗の理由を apps.last_error に残しているが、以前はどこにも出ず、
  /// 「新着が無い」のか「連携が壊れている」のか区別できなかった。
  Widget _fetchStatus(AppRow a) {
    if (a.hasPollError) {
      return Text(
        '取得エラー：${a.lastErrorText}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: context.dangerTextC),
      );
    }
    final at = a.lastPolledAt;
    return Text(
      at == null ? 'まだ取得していません' : '最終取得 ${fetchedAgo(at)}',
      style: TextStyle(fontSize: 12, color: context.subtleC),
    );
  }
}

/// アプリの追加 / 編集フォーム。
class AppEditScreen extends StatefulWidget {
  final AppRow? existing;

  /// 追加するときに最初に選んでおくストア（ストアを連携した直後に開いたとき）。
  final String? initialStore;
  const AppEditScreen({super.key, this.existing, this.initialStore});

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

  /// 連携済みのストア（追加のときだけ読む）。分からない・1つも無いときは null。
  Set<String>? _connected;

  /// 利用者がストアを自分で選んだか（あとから届いた連携状態で選び直さない）。
  bool _storeTouched = false;

  String? _appIdError;
  String? _nameError;

  /// 保存の失敗理由（App ID の誤り・権限不足など）。長い案内になるので、ボタンの上に残す。
  String? _saveError;

  bool get _isEdit => widget.existing != null;

  /// 名前を空欄にできるか。App Store の追加だけは、空ならストアに登録されている名前を
  /// サーバーが入れる（Google Play は API から名前を取れないので必須のまま）。
  bool get _nameOptional => !_isEdit && _store == 'appstore';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _store = e?.store ?? widget.initialStore ?? 'appstore';
    _appId = TextEditingController(text: e?.storeAppId ?? '');
    _name = TextEditingController(text: e?.name ?? '');
    _desc = TextEditingController(text: e?.description ?? '');
    _tone = e?.replyTone ?? 'polite';
    _opening = TextEditingController(text: e?.replyOpening ?? '');
    _closing = TextEditingController(text: e?.replyClosing ?? '');
    _rules = TextEditingController(text: e?.replyRules ?? '');
    if (!_isEdit) _loadConnected();
  }

  /// 連携済みのストアに合わせて、ストアの初期値と選べるストアを決める。
  /// 片方しか連携していないのに既定の App Store のまま追加して
  /// 「先に App Store Connect の連携を…」で失敗する、を防ぐ。
  Future<void> _loadConnected() async {
    try {
      final c = (await Repo.connectedStores()).toSet();
      // 空は「未連携」とも「確認できなかった」とも取れるので、選択は絞らない
      // （両方を選べなくすると先に進めなくなる。未連携ならサーバーが案内を返す）。
      if (!mounted || c.isEmpty) return;
      setState(() {
        _connected = c;
        if (!_storeTouched && !c.contains(_store)) _store = c.first;
      });
    } catch (_) {}
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

  /// ストアのURLから、ストアとIDを取り出す。URLでなければ null。
  /// 例: https://apps.apple.com/jp/app/xxx/id6480001111 → (appstore, 6480001111)
  ///     https://play.google.com/store/apps/details?id=com.example.app → (googleplay, com.example.app)
  static (String, String)? _parseStoreUrl(String raw) {
    final t = raw.trim();
    final play =
        RegExp(r'play\.google\.com/.*[?&]id=([A-Za-z0-9_.]+)').firstMatch(t);
    if (play != null) return ('googleplay', play.group(1)!);
    final apple =
        RegExp(r'(?:apps\.apple\.com/.*?/|^)id(\d{5,})').firstMatch(t);
    if (apple != null) return ('appstore', apple.group(1)!);
    return null;
  }

  /// ストアのURLや「id123…」を貼り付けたら、IDだけにする（違うストアのURLならストアも切り替える）。
  void _onAppIdChanged(String raw) {
    if (_appIdError != null || _saveError != null) {
      setState(() {
        _appIdError = null;
        _saveError = null;
      });
    }
    final parsed = _parseStoreUrl(raw);
    if (parsed == null) return;
    final (store, id) = parsed;
    _appId.value = TextEditingValue(
      text: id,
      selection: TextSelection.collapsed(offset: id.length),
    );
    if (store != _store && (_connected?.contains(store) ?? true)) {
      setState(() {
        _store = store;
        _storeTouched = true;
      });
    }
  }

  /// 入力の確認。問題があれば欄の下に理由を出して false。
  bool _validate() {
    final id = _appId.text.trim();
    String? idError;
    if (!_isEdit) {
      if (_store == 'appstore') {
        if (id.isEmpty) {
          idError = 'Apple ID（数字）を入力してください';
        } else if (!RegExp(r'^\d+$').hasMatch(id)) {
          idError = 'App Store は数字のIDです（Bundle ID ではありません）。'
              'App Store Connect の「App情報」にある Apple ID を入力してください';
        }
      } else {
        if (id.isEmpty) {
          idError = 'パッケージ名を入力してください';
        } else if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$')
            .hasMatch(id)) {
          idError = 'パッケージ名は「com.example.app」の形で入力してください';
        }
      }
    }
    final nameError = _name.text.trim().isEmpty && !_nameOptional
        ? 'アプリ名を入力してください'
        : null;
    setState(() {
      _appIdError = idError;
      _nameError = nameError;
    });
    return idError == null && nameError == null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saveError = null);
    if (!_validate()) return;
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
        // 画面を閉じるだけだと保存できたか分からない（スナックバーは閉じたあとも残る）。
        if (mounted) showSnack(context, '保存しました', kind: SnackKind.success);
      } else {
        final added = await Repo.addApp(
          store: _store,
          storeAppId: _appId.text.trim(),
          name: _name.text.trim(),
          description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
          tone: _tone,
          replyOpening: _trimmed(_opening),
          replyClosing: _trimmed(_closing),
          replyRules: _trimmed(_rules),
        );
        if (mounted) _announceAdded(added);
      }
      HapticFeedback.lightImpact();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.isPlanLimit) {
        // Free の上限：プランの案内を付けて出す。
        showErrorWithUpgrade(context, e, reason: PaywallReason.apps);
      } else {
        setState(() => _saveError = friendlyError(e));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 追加の結果を伝える（スナックバーはアプリ全体で共有なので、閉じたあとも残る）。
  /// サーバーは追加の直後に最初の取得まで済ませている。ここで改めて取得を頼むと
  /// 「新しいレビューはありませんでした」になるので頼まない。
  void _announceAdded(AddAppResult r) {
    final nav = Navigator.of(context);
    final name = '「${r.name}」';
    switch (r.initialFetch) {
      case 'done':
        showSnack(
          context,
          r.inserted > 0
              ? '$nameを追加し、${r.inserted}件のレビューを取り込みました'
              : '$nameを追加しました。取り込めるレビューはまだありません'
                  '${_store == 'googleplay' ? '（Google Play は直近7日ぶんのみ取得できます）' : ''}',
          kind: SnackKind.success,
        );
      case 'failed':
        showSnack(
          context,
          '$nameを追加しましたが、レビューを取得できませんでした。${r.fetchError ?? ''}',
          kind: SnackKind.error,
          actionLabel: '連携を確認',
          onAction: () => nav.push(MaterialPageRoute(
              builder: (_) => const ConnectStoreScreen())),
        );
      case 'pending':
        showSnack(
          context,
          '$nameを追加しました。レビューを取り込んでいます。しばらくすると一覧に表示されます',
          kind: SnackKind.success,
        );
      default:
        // 短時間に追加が続いた・古いサーバー：毎時の自動取得に任せる。
        showSnack(
          context,
          '$nameを追加しました。レビュータブの「今すぐ取得」ですぐに取り込めます',
          kind: SnackKind.success,
        );
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
      if (!mounted) return;
      showSnack(context, '「${widget.existing!.name}」を削除しました',
          kind: SnackKind.success);
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e, prefix: '削除できませんでした');
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 編集時：直近の取得が失敗していれば、理由と連携の確認先を出す。
  Widget _pollErrorBox(AppRow a) {
    final at = a.lastErrorAt ?? a.lastPolledAt;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            at == null
                ? 'レビューを取得できていません'
                : 'レビューを取得できていません（${fetchedAgo(at)}）',
            style: TextStyle(
                fontWeight: FontWeight.w700, color: context.dangerTextC),
          ),
          const SizedBox(height: 4),
          Text(a.lastErrorText ?? '',
              style: const TextStyle(fontSize: 13, height: 1.5)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ConnectStoreScreen())),
              child: const Text('ストア連携を確認'),
            ),
          ),
        ],
      ),
    );
  }

  /// 保存の失敗理由（入力を直すまで残す）。
  Widget _saveErrorBox(String message) {
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.danger.withValues(alpha: 0.30)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: AppTheme.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: TextStyle(
                      fontSize: 13, height: 1.5, color: context.dangerTextC)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final apple = _store == 'appstore';
    final idLabel = apple ? 'Apple ID（数字）' : 'パッケージ名';
    final idHint = apple ? '例: 6480001111' : '例: com.example.app';
    final idHelp = apple
        ? 'App Store Connect の「アプリ > App情報」にある Apple ID です。'
            'App Store のURLを貼り付けても読み取ります。'
        : 'Play Console のアプリ一覧に出ているパッケージ名です。'
            'Google Play のURLを貼り付けても読み取ります。';
    // 連携していないストア（連携状態が分かったときだけ）。
    final missing = [
      for (final s in const ['appstore', 'googleplay'])
        if (_connected != null && !_connected!.contains(s)) s,
    ];
    final existing = widget.existing;
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'アプリを編集' : 'アプリを追加')),
      // 複数行の欄（アプリ概要・守ってほしいこと）では Return が改行になり、キーボードを閉じられない。
      // 外側のタップとスクロールで閉じられるようにする。
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(16),
          children: [
            if (existing != null && existing.hasPollError)
              _pollErrorBox(existing),
            if (!_isEdit) ...[
              const Text('ストア', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'appstore',
                      label: const Text('App Store'),
                      icon: const Icon(Icons.apple),
                      enabled: _connected?.contains('appstore') ?? true),
                  ButtonSegment(
                      value: 'googleplay',
                      label: const Text('Google Play'),
                      icon: const Icon(Icons.android),
                      enabled: _connected?.contains('googleplay') ?? true),
                ],
                selected: {_store},
                onSelectionChanged: (s) => setState(() {
                  _store = s.first;
                  _storeTouched = true;
                  _appIdError = null;
                  _nameError = null;
                  _saveError = null;
                }),
              ),
              for (final s in missing) ...[
                const SizedBox(height: 6),
                Text(
                  '${s == 'appstore' ? 'App Store' : 'Google Play'} は未連携です。'
                  '使う場合は先に「ストア連携」から連携してください。',
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _appId,
                // App Store は数字だけ。数字キーボードでも長押しでURLを貼り付けられる。
                keyboardType:
                    apple ? TextInputType.number : TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.next,
                onChanged: _onAppIdChanged,
                decoration: InputDecoration(
                  labelText: idLabel,
                  hintText: idHint,
                  helperText: idHelp,
                  helperMaxLines: 3,
                  errorText: _appIdError,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _name,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              decoration: InputDecoration(
                labelText: _nameOptional ? 'アプリ名（任意）' : 'アプリ名',
                helperText: _nameOptional
                    ? '空欄なら App Store に登録されている名前を使います'
                    : null,
                errorText: _nameError,
              ),
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
            if (_saveError != null) _saveErrorBox(_saveError!),
            // 追加はストアへの確認と最初の取り込みまで行うので、十数秒かかることがある。
            if (_saving && !_isEdit)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'ストアへの接続を確認し、レビューを取り込んでいます…（30秒ほどかかることがあります）',
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                ),
              ),
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
                icon: Icon(Icons.delete_outline, color: context.dangerTextC),
                label: Text('このアプリを削除',
                    style: TextStyle(color: context.dangerTextC)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
