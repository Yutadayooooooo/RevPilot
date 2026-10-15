import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data.dart';
import '../theme.dart';
import '../ui.dart';
import 'apps_screen.dart';

/// ストア認証情報の登録。保存はサーバー側で暗号化（API経由）。
/// 連携状態の表示もAPI経由（store_credentials はクライアントから直接読めない）。
class ConnectStoreScreen extends StatefulWidget {
  const ConnectStoreScreen({super.key});

  @override
  State<ConnectStoreScreen> createState() => _ConnectStoreScreenState();
}

class _ConnectStoreScreenState extends State<ConnectStoreScreen> {
  /// 連携済みのストア。確認できなかったら null。
  /// 確認できないのに「未連携」と出すと、鍵が消えたと思って .p8 を探し回ることになる。
  Set<String>? _connected;
  Object? _statusError;
  bool _loading = true;

  /// アプリを登録済みか（連携できたあとの次の手順の出し分けに使う）。分からなければ null。
  bool? _hasApps;

  /// 直前に連携できたストア。カードに「連携しました」と次の手順を出す。
  String? _justConnected;

  /// 連携を解除している最中のストア。
  String? _disconnecting;

  // App Store
  final _issuerId = TextEditingController();
  final _keyId = TextEditingController();
  final _privateKey = TextEditingController();
  bool _savingApple = false;
  bool _editApple = false;
  String? _appleError;

  // Google Play
  final _saJson = TextEditingController();
  bool _savingGoogle = false;
  bool _editGoogle = false;
  String? _googleError;

  // 保存・解除の失敗理由（_appleError / _googleError）は、数秒で消えるスナックバーではなく
  // カードの中に残す。App Store Connect などに切り替えて直す性質のもので、
  // 戻ってきたときに内容を忘れてしまうため。入力を直したら消す。

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    Repo.apps().then((a) {
      if (mounted) setState(() => _hasApps = a.isNotEmpty);
    }).catchError((_) {});
    try {
      final c = await Repo.connectedStores();
      if (mounted) {
        setState(() {
          _connected = c.toSet();
          _statusError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _statusError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _retryStatus() async {
    HapticFeedback.selectionClick();
    setState(() => _loading = true);
    await _loadStatus();
  }

  @override
  void dispose() {
    _issuerId.dispose();
    _keyId.dispose();
    _privateKey.dispose();
    _saJson.dispose();
    super.dispose();
  }

  bool _isConnected(String store) => _connected?.contains(store) ?? false;

  /// 連携済みかどうか確認できていない（「未連携」と断定しない）。
  bool _isUnknown(String store) => !_isConnected(store) && _statusError != null;

  static String _label(String store) =>
      store == 'appstore' ? 'App Store' : 'Google Play';

  void _clearAppleError() {
    if (_appleError != null) setState(() => _appleError = null);
  }

  void _clearGoogleError() {
    if (_googleError != null) setState(() => _googleError = null);
  }

  /// 連携できたとき：カードを畳み、次の手順を出す。
  void _onConnected(String store) {
    HapticFeedback.lightImpact();
    setState(() {
      _connected = {...?_connected, store};
      _justConnected = store;
      if (store == 'appstore') {
        _editApple = false;
        // 鍵は画面に残しておく理由がないので消す（更新するときは入れ直す）。
        _issuerId.clear();
        _keyId.clear();
        _privateKey.clear();
      } else {
        _editGoogle = false;
        _saJson.clear();
      }
    });
  }

  Future<void> _saveApple() async {
    FocusScope.of(context).unfocus();
    if (_issuerId.text.trim().isEmpty ||
        _keyId.text.trim().isEmpty ||
        _privateKey.text.trim().isEmpty) {
      setState(() => _appleError = 'Issuer ID・Key ID・秘密鍵をすべて入力してください。');
      return;
    }
    setState(() {
      _savingApple = true;
      _appleError = null;
    });
    try {
      await Repo.saveAppStoreCredentials(
        issuerId: _issuerId.text.trim(),
        keyId: _keyId.text.trim(),
        privateKey: _privateKey.text.trim(),
      );
      if (mounted) _onConnected('appstore');
    } catch (e) {
      if (mounted) setState(() => _appleError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _savingApple = false);
    }
  }

  Future<void> _saveGoogle() async {
    FocusScope.of(context).unfocus();
    if (_saJson.text.trim().isEmpty) {
      setState(() => _googleError = 'サービスアカウントJSONを貼り付けてください。');
      return;
    }
    setState(() {
      _savingGoogle = true;
      _googleError = null;
    });
    try {
      await Repo.saveGooglePlayCredentials(_saJson.text.trim());
      if (mounted) _onConnected('googleplay');
    } catch (e) {
      if (mounted) setState(() => _googleError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _savingGoogle = false);
    }
  }

  /// 連携の解除（保存済みの鍵を削除）。取得済みのレビューは残る。
  Future<void> _disconnect(String store) async {
    final label = _label(store);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$labelの連携を解除しますか？'),
        content: Text(
          '保存済みの鍵を削除します。以後、$labelのアプリのレビューは取得されず、'
          '毎時の自動取得はエラーになります。\n\n'
          '取得済みのレビューは残ります。使わなくなったアプリは「連携アプリ」から削除してください。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _disconnecting = store;
      if (store == 'appstore') {
        _appleError = null;
      } else {
        _googleError = null;
      }
    });
    try {
      await Repo.disconnectStore(store);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      setState(() {
        _connected = {...?_connected}..remove(store);
        if (_justConnected == store) _justConnected = null;
      });
      showSnack(context, '$labelの連携を解除しました', kind: SnackKind.success);
    } catch (e) {
      if (!mounted) return;
      final message = friendlyError(e);
      setState(() {
        if (store == 'appstore') {
          _appleError = message;
        } else {
          _googleError = message;
        }
      });
    } finally {
      if (mounted) setState(() => _disconnecting = null);
    }
  }

  /// 連携できたあとの次の手順。アプリが無ければアプリの追加へ進める。
  Future<void> _addApp(String store) async {
    HapticFeedback.selectionClick();
    // この画面と入れ替える（追加し終えたら、連携を始めた画面にそのまま戻れる）。
    await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => AppEditScreen(initialStore: store)));
  }

  /// 鍵ファイル（.p8 / .json）を選んで中身を欄に入れる。
  /// スマホで長い鍵をコピー＆ペーストするのは失敗しやすいので、ファイルのまま読めるようにする。
  /// .p8 のファイル名（AuthKey_XXXXXXXXXX.p8）にはキーIDが含まれるので、それも埋める。
  Future<void> _pickKeyFile({required bool apple}) async {
    HapticFeedback.selectionClick();
    try {
      final files = await FilePicker.pickFiles();
      final file = files.firstOrNull;
      if (file == null) return;
      final text =
          utf8.decode(await file.readAsBytes(), allowMalformed: true).trim();
      setState(() {
        if (apple) {
          _privateKey.text = text;
          final m = RegExp(r'AuthKey_([A-Z0-9]{10})').firstMatch(file.name);
          if (m != null && _keyId.text.trim().isEmpty) _keyId.text = m.group(1)!;
          _appleError = null;
        } else {
          _saJson.text = text;
          _googleError = null;
        }
      });
      if (mounted) {
        showSnack(context, '${file.name} を読み込みました', kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'ファイルを読み込めませんでした', kind: SnackKind.error);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 「詳しい手順」と各コンソールを開くリンクの行。
  Widget _helpRow({required String consoleLabel, required String consoleUrl}) {
    return Wrap(
      spacing: 4,
      children: [
        if (AppConfig.hasWeb)
          TextButton.icon(
            onPressed: () => _open('${AppConfig.webUrl}/help/connect'),
            icon: const Icon(Icons.menu_book_outlined, size: 16),
            label: const Text('詳しい手順', style: TextStyle(fontSize: 12)),
          ),
        TextButton.icon(
          onPressed: () => _open(consoleUrl),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(consoleLabel, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _fileButton({required bool apple}) {
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () => _pickKeyFile(apple: apple),
        icon: const Icon(Icons.upload_file_rounded, size: 18),
        label: Text(apple ? '.p8 ファイルから読み込む' : 'JSON ファイルから読み込む'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ストア連携')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          // 複数行の欄（秘密鍵・JSON）では Return が改行になり、キーボードを閉じられない。
          // 外側のタップとスクロールで閉じられるようにする。
          : GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusScope.of(context).unfocus(),
              child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(16),
                children: [
                  if (!AppConfig.hasApi)
                    Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        '認証情報の保存にはサーバー接続が必要です。設定でAPIのURLを指定すると有効になります。',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  if (_statusError != null) _statusErrorBanner(),
                  _appleCard(),
                  const SizedBox(height: 16),
                  _googleCard(),
                  const SizedBox(height: 16),
                  Text(
                    '認証情報はサーバー側でAES-256-GCMで暗号化して保存されます。',
                    style: TextStyle(fontSize: 12, color: context.subtleC),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _appleCard() {
    const store = 'appstore';
    final connected = _isConnected(store);
    return _storeCard(
      title: 'App Store',
      icon: Icons.apple,
      store: store,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_justConnected == store) _connectedPanel(store),
          if (connected && !_editApple)
            _connectedSummary(
              store: store,
              onEdit: () => setState(() {
                _editApple = true;
                _justConnected = null;
              }),
            )
          else ...[
            // 鍵の取得は App Store Connect 側での作業で、ここが最大の詰まりどころ。
            // 手順を省略せずに書く。
            _steps(const [
              'App Store Connect > ユーザーとアクセス > 統合 を開く',
              '「App Store Connect API」で鍵を生成（App Manager以上の権限）',
              '生成直後に .p8 ファイルをダウンロード（再取得不可）',
              'Issuer ID とキーIDを下欄にコピー',
            ]),
            _helpRow(
              consoleLabel: 'App Store Connect を開く',
              consoleUrl:
                  'https://appstoreconnect.apple.com/access/integrations/api',
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _issuerId,
              // 英数字とハイフンだけの値。日本語入力のまま打たないよう英字キーボードにし、
              // 自動修正・予測変換・先頭の大文字化も切る。
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearAppleError(),
              decoration: const InputDecoration(labelText: 'Issuer ID'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyId,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _clearAppleError(),
              decoration: const InputDecoration(labelText: 'Key ID'),
            ),
            const SizedBox(height: 10),
            _fileButton(apple: true),
            const SizedBox(height: 10),
            TextField(
              controller: _privateKey,
              maxLines: 4,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              onChanged: (_) => _clearAppleError(),
              decoration: const InputDecoration(
                labelText: '秘密鍵（.p8 の中身）',
                hintText: '-----BEGIN PRIVATE KEY----- ...',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            if (_appleError != null) _errorBox(_appleError!),
            FilledButton(
              onPressed: _savingApple ? null : _saveApple,
              child: _savingApple
                  ? const _Spinner()
                  : Text(_saveLabel(store)),
            ),
            if (connected)
              TextButton(
                onPressed: _savingApple
                    ? null
                    : () => setState(() {
                          _editApple = false;
                          _appleError = null;
                        }),
                child: const Text('更新をやめる'),
              ),
          ],
          if (connected) _disconnectButton(store),
        ],
      ),
    );
  }

  Widget _googleCard() {
    const store = 'googleplay';
    final connected = _isConnected(store);
    return _storeCard(
      title: 'Google Play',
      icon: Icons.android,
      store: store,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_justConnected == store) _connectedPanel(store),
          if (connected && !_editGoogle)
            _connectedSummary(
              store: store,
              onEdit: () => setState(() {
                _editGoogle = true;
                _justConnected = null;
              }),
            )
          else ...[
            _steps(const [
              'Google Cloud でサービスアカウントを作成しJSONキーを発行',
              'Play Console > ユーザーと権限 でそのアカウントを招待',
              '対象アプリへのアクセスと「レビューの表示・返信」権限を付与',
              'JSONの中身を丸ごと下欄に貼り付け',
            ]),
            _helpRow(
              consoleLabel: 'Play Console を開く',
              consoleUrl:
                  'https://play.google.com/console/users-and-permissions',
            ),
            const SizedBox(height: 4),
            _fileButton(apple: false),
            const SizedBox(height: 10),
            TextField(
              controller: _saJson,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              onChanged: (_) => _clearGoogleError(),
              decoration: const InputDecoration(
                labelText: 'サービスアカウントJSON',
                hintText: '{ "type": "service_account", ... }',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            if (_googleError != null) _errorBox(_googleError!),
            FilledButton(
              onPressed: _savingGoogle ? null : _saveGoogle,
              child: _savingGoogle
                  ? const _Spinner()
                  : Text(_saveLabel(store)),
            ),
            if (connected)
              TextButton(
                onPressed: _savingGoogle
                    ? null
                    : () => setState(() {
                          _editGoogle = false;
                          _googleError = null;
                        }),
                child: const Text('更新をやめる'),
              ),
          ],
          if (connected) _disconnectButton(store),
        ],
      ),
    );
  }

  String _saveLabel(String store) {
    if (_isConnected(store)) return '更新する';
    if (_isUnknown(store)) return '保存する';
    return '連携する';
  }

  /// 連携済みのカードの中身（入力欄は畳んでおく）。
  Widget _connectedSummary({
    required String store,
    required VoidCallback onEdit,
  }) {
    final busy = _disconnecting == store;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '毎時、この鍵で${_label(store)}のレビューを取り込んでいます。',
          style: TextStyle(fontSize: 13, height: 1.5, color: context.subtleC),
        ),
        const SizedBox(height: 10),
        if (store == 'appstore' && _appleError != null) _errorBox(_appleError!),
        if (store == 'googleplay' && _googleError != null)
          _errorBox(_googleError!),
        OutlinedButton.icon(
          onPressed: busy ? null : onEdit,
          icon: const Icon(Icons.key_outlined, size: 18),
          label: const Text('鍵を更新する'),
        ),
      ],
    );
  }

  Widget _disconnectButton(String store) {
    final busy = _disconnecting == store;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed:
              _disconnecting != null ? null : () => _disconnect(store),
          style: TextButton.styleFrom(foregroundColor: context.dangerTextC),
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.link_off_rounded, size: 18),
          label: Text(busy ? '解除しています…' : '連携を解除'),
        ),
      ),
    );
  }

  /// 連携できた直後の案内。次にやること（アプリの追加）へそのまま進めるようにする。
  Widget _connectedPanel(String store) {
    final needsApp = _hasApps != true;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.success.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.check_circle_rounded,
                    color: AppTheme.success, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${_label(store)}を連携しました',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.successTextC)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              needsApp
                  ? '次は、監視するアプリを追加しましょう。'
                  : '以後は毎時、自動でレビューを取り込みます。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: needsApp
                  ? FilledButton.icon(
                      onPressed: () => _addApp(store),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('アプリを追加'),
                    )
                  : FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('完了'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 保存・解除の失敗理由。入力を直すまで残す。
  Widget _errorBox(String message) {
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

  /// 連携状態を確認できなかったとき（通信エラーなど）。「未連携」とは出さない。
  Widget _statusErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
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
              '連携状態を確認できませんでした。${friendlyError(_statusError!)}',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
          TextButton(onPressed: _retryStatus, child: const Text('再試行')),
        ],
      ),
    );
  }

  Widget _storeCard({
    required String title,
    required IconData icon,
    required String store,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: context.inkC),
                const SizedBox(width: 8),
                // 文字を大きくしている人でもはみ出さないよう、バッジは次の行へ折り返せるようにする
                // （1行に収まるときは右端に寄せる）。
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                      _badge(store),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Widget _badge(String store) {
    final connected = _isConnected(store);
    final (label, fill, text) = connected
        ? ('連携済み', AppTheme.success, context.successTextC)
        : _isUnknown(store)
            ? ('確認できません', context.subtleC, context.subtleC)
            : ('未連携', context.subtleC, context.subtleC);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: fill.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, color: text, fontWeight: FontWeight.w700)),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
}

/// 手順の箇条書き。連携は外部サービスでの作業を伴うので、画面内に手順を出す。
Widget _steps(List<String> items) {
  return Builder(
    builder: (context) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1}. ',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.subtleC)),
                  Expanded(
                    child: Text(items[i],
                        style: TextStyle(
                            fontSize: 12, height: 1.5, color: context.subtleC)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Text('入力後、その場でストアへ疎通確認を行います。失敗した場合は保存されません。',
              style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                  color: context.subtleC)),
        ],
      ),
    ),
  );
}
