import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data.dart';
import '../models.dart';
import '../theme.dart';
import '../ui.dart';
import 'apps_screen.dart';
import 'connect_store_screen.dart';
import 'plan_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<_SettingsData> _future;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_SettingsData> _load() async {
    final plan = await Repo.plan();
    final apps = await Repo.apps();
    final connected = await Repo.connectedStores();
    return _SettingsData(plan: plan, apps: apps, connected: connected);
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _open(Widget screen) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
    _reload();
  }

  Future<void> _refreshFromStores() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await Repo.refreshFromStores();
      HapticFeedback.mediumImpact();
      if (mounted) {
        showSnack(context, 'ストアから最新レビューを取得しました', kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) showSnack(context, '$e', kind: SnackKind.error);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 規約・ポリシー等をアプリ内ブラウザで開く。Web(Next.js)側で公開しているページ。
  Future<void> _openLegal(String path) async {
    if (!AppConfig.hasApi) {
      showSnack(context, 'サーバーURLが未設定です（config/app_config.json）',
          kind: SnackKind.error);
      return;
    }
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
    final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!ok && mounted) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウト'),
        content: const Text('ログアウトしますか？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ログアウト'),
          ),
        ],
      ),
    );
    if (ok == true) {
      HapticFeedback.mediumImpact();
      await Supabase.instance.client.auth.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: FutureBuilder<_SettingsData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          final plan = data?.plan ?? 'free';
          final apps = data?.apps ?? [];
          final connected = data?.connected ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // アカウント
              _card(
                title: 'アカウント',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('メール', email),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text('プラン',
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 12),
                        _planBadge(plan),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _open(const PlanScreen()),
                          child: const Text('変更'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 管理
              _sectionLabel('管理'),
              _navCard([
                _navTile(
                  icon: Icons.apps,
                  title: '連携アプリ',
                  subtitle: '${apps.length}件',
                  onTap: () => _open(const AppsScreen()),
                ),
                _divider(),
                _navTile(
                  icon: Icons.link,
                  title: 'ストア連携',
                  subtitle: _connectedLabel(connected),
                  onTap: () => _open(const ConnectStoreScreen()),
                ),
                _divider(),
                _navTile(
                  icon: Icons.workspace_premium_outlined,
                  title: 'プラン',
                  subtitle: planLabel(plan),
                  onTap: () => _open(const PlanScreen()),
                ),
              ]),
              const SizedBox(height: 16),

              // レビュー取得
              _sectionLabel('レビュー'),
              _navCard([
                ListTile(
                  leading: _refreshing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync),
                  title: const Text('ストアから最新レビューを取得'),
                  subtitle: Text(
                    AppConfig.hasApi
                        ? '各ストアの新着を今すぐ取り込みます'
                        : 'サーバー接続が必要です',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: _refreshing ? null : _refreshFromStores,
                ),
              ]),
              const SizedBox(height: 16),

              // 情報・法務
              _sectionLabel('情報'),
              _navCard([
                _navTile(
                  icon: Icons.description_outlined,
                  title: '利用規約',
                  subtitle: '',
                  onTap: () => _openLegal('/terms'),
                ),
                _divider(),
                _navTile(
                  icon: Icons.privacy_tip_outlined,
                  title: 'プライバシーポリシー',
                  subtitle: '',
                  onTap: () => _openLegal('/privacy'),
                ),
                _divider(),
                _navTile(
                  icon: Icons.receipt_long_outlined,
                  title: '特定商取引法に基づく表記',
                  subtitle: '',
                  onTap: () => _openLegal('/tokushoho'),
                ),
              ]),
              const SizedBox(height: 28),

              OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('ログアウト'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.danger,
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          )
              .animate()
              .fadeIn(duration: 300.ms)
              .slideY(begin: 0.03, end: 0, curve: Curves.easeOut);
        },
      ),
    );
  }

  String _connectedLabel(List<String> connected) {
    if (connected.isEmpty) return '未連携';
    final names = connected
        .map((s) => s == 'appstore' ? 'App Store' : 'Google Play')
        .join('・');
    return '$names 連携済み';
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade600)),
      );

  Widget _navCard(List<Widget> children) => Card(
        child: Column(children: children),
      );

  Widget _navTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      ListTile(
        leading: Icon(icon, color: AppTheme.primary),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      );

  Widget _divider() =>
      Divider(height: 1, indent: 56, color: context.borderC);

  Widget _card({required String title, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Row(
      children: [
        SizedBox(
            width: 60,
            child: Text(k, style: const TextStyle(color: Colors.grey))),
        Expanded(child: Text(v)),
      ],
    );
  }

  Widget _planBadge(String plan) {
    final isPaid = plan != 'free';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: isPaid
            ? AppTheme.primary.withValues(alpha: 0.12)
            : context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        planLabel(plan),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
          color: isPaid ? AppTheme.primary : Colors.grey.shade700,
        ),
      ),
    );
  }
}

class _SettingsData {
  final String plan;
  final List<AppRow> apps;
  final List<String> connected;
  _SettingsData(
      {required this.plan, required this.apps, required this.connected});
}
