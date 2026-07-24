import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data.dart';
import '../models.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<_SettingsData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_SettingsData> _load() async {
    final plan = await Repo.plan();
    final apps = await Repo.apps();
    return _SettingsData(plan: plan, apps: apps);
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
      appBar: AppBar(
        title: const Text('設定', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: FutureBuilder<_SettingsData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snap.data;
          final plan = data?.plan ?? 'free';
          final apps = data?.apps ?? [];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card(
                title: 'アカウント',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('メール', email),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text('プラン',
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(width: 12),
                        _planBadge(plan),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _card(
                title: '連携アプリ（${apps.length}）',
                child: apps.isEmpty
                    ? Text('まだアプリが連携されていません。',
                        style: TextStyle(color: Colors.grey.shade600))
                    : Column(
                        children: apps
                            .map((a) => Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 6),
                                  child: Row(
                                    children: [
                                      Icon(
                                          a.store == 'appstore'
                                              ? Icons.apple
                                              : Icons.android,
                                          size: 18,
                                          color: Colors.grey.shade700),
                                      const SizedBox(width: 10),
                                      Expanded(
                                          child: Text(a.name,
                                              overflow:
                                                  TextOverflow.ellipsis)),
                                      Text(a.storeLabel,
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.grey.shade500)),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
              ),
              const SizedBox(height: 16),
              _card(
                title: 'ストア連携の設定',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ストアの認証情報の登録や新規アプリの追加は、現在Webダッシュボードから行います。',
                      style: TextStyle(
                          color: Colors.grey.shade700, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _signOut,
                icon: const Icon(Icons.logout, size: 18),
                label: const Text('ログアウト'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
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
    final labels = {'free': 'Free', 'pro': 'Pro', 'team': 'Team'};
    final isPaid = plan != 'free';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: isPaid
            ? AppTheme.primary.withValues(alpha: 0.12)
            : Colors.grey.shade200,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        labels[plan] ?? plan,
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
  _SettingsData({required this.plan, required this.apps});
}
