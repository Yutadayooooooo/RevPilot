import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../data.dart';
import '../theme.dart';
import '../ui.dart';

/// ストア認証情報の登録。保存はサーバー側で暗号化（API経由）。
/// 連携状態の表示は直接Supabaseから取得するため、サーバー未接続でも確認できる。
class ConnectStoreScreen extends StatefulWidget {
  const ConnectStoreScreen({super.key});

  @override
  State<ConnectStoreScreen> createState() => _ConnectStoreScreenState();
}

class _ConnectStoreScreenState extends State<ConnectStoreScreen> {
  List<String> _connected = [];
  bool _loading = true;

  // App Store
  final _issuerId = TextEditingController();
  final _keyId = TextEditingController();
  final _privateKey = TextEditingController();
  bool _savingApple = false;

  // Google Play
  final _saJson = TextEditingController();
  bool _savingGoogle = false;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final c = await Repo.connectedStores();
      if (mounted) setState(() => _connected = c);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _issuerId.dispose();
    _keyId.dispose();
    _privateKey.dispose();
    _saJson.dispose();
    super.dispose();
  }

  Future<void> _saveApple() async {
    if (_issuerId.text.trim().isEmpty ||
        _keyId.text.trim().isEmpty ||
        _privateKey.text.trim().isEmpty) {
      showSnack(context, 'Issuer ID・Key ID・秘密鍵は必須です', kind: SnackKind.error);
      return;
    }
    setState(() => _savingApple = true);
    try {
      await Repo.saveAppStoreCredentials(
        issuerId: _issuerId.text.trim(),
        keyId: _keyId.text.trim(),
        privateKey: _privateKey.text.trim(),
      );
      HapticFeedback.lightImpact();
      if (mounted) showSnack(context, 'App Storeを連携しました', kind: SnackKind.success);
      await _loadStatus();
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _savingApple = false);
    }
  }

  Future<void> _saveGoogle() async {
    if (_saJson.text.trim().isEmpty) {
      showSnack(context, 'サービスアカウントJSONを貼り付けてください', kind: SnackKind.error);
      return;
    }
    setState(() => _savingGoogle = true);
    try {
      await Repo.saveGooglePlayCredentials(_saJson.text.trim());
      HapticFeedback.lightImpact();
      if (mounted) {
        showSnack(context, 'Google Playを連携しました', kind: SnackKind.success);
      }
      await _loadStatus();
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _savingGoogle = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ストア連携')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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
                _storeCard(
                  title: 'App Store',
                  icon: Icons.apple,
                  connected: _connected.contains('appstore'),
                  child: Column(
                    children: [
                      TextField(
                        controller: _issuerId,
                        decoration:
                            const InputDecoration(labelText: 'Issuer ID'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _keyId,
                        decoration: const InputDecoration(labelText: 'Key ID'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _privateKey,
                        maxLines: 4,
                        decoration: const InputDecoration(
                          labelText: '秘密鍵（.p8 の中身）',
                          hintText: '-----BEGIN PRIVATE KEY----- ...',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _savingApple ? null : _saveApple,
                        child: _savingApple
                            ? const _Spinner()
                            : Text(_connected.contains('appstore')
                                ? '更新する'
                                : '連携する'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _storeCard(
                  title: 'Google Play',
                  icon: Icons.android,
                  connected: _connected.contains('googleplay'),
                  child: Column(
                    children: [
                      TextField(
                        controller: _saJson,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'サービスアカウントJSON',
                          hintText: '{ "type": "service_account", ... }',
                          alignLabelWithHint: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _savingGoogle ? null : _saveGoogle,
                        child: _savingGoogle
                            ? const _Spinner()
                            : Text(_connected.contains('googleplay')
                                ? '更新する'
                                : '連携する'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '認証情報はサーバー側でAES-256-GCMで暗号化して保存されます。',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
    );
  }

  Widget _storeCard({
    required String title,
    required IconData icon,
    required bool connected,
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
                Icon(icon, color: Colors.grey.shade800),
                const SizedBox(width: 8),
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Spacer(),
                _badge(connected),
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Widget _badge(bool connected) {
    final color = connected ? AppTheme.success : Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(connected ? '連携済み' : '未連携',
          style: TextStyle(
              fontSize: 12, color: color, fontWeight: FontWeight.w700)),
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
