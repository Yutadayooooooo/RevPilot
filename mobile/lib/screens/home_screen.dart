import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notifications.dart';
import 'reviews_screen.dart';
import 'notifications_screen.dart';
import 'analytics_screen.dart';
import 'settings_screen.dart';

/// ボトムナビ：レビュー / 通知 / 分析 / 設定。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _index = 0;
  int _unread = 0; // 通知タブの未読バッジ

  /// 一度でも開いたタブだけ実体を生成する（＝初回表示時に入場アニメが再生され、
  /// 以降はマウントし続けて再読み込みを避ける）。
  final Set<int> _visited = {0};

  static const _notifIndex = 1;

  final _screens = const [
    ReviewsScreen(),
    NotificationsScreen(),
    AnalyticsScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshUnread();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 復帰時にバッジを更新（バックグラウンド中に新着があるかもしれない）。
    if (state == AppLifecycleState.resumed && _index != _notifIndex) {
      _refreshUnread();
    }
  }

  Future<void> _refreshUnread() async {
    final n = await NotifStore.unreadCount();
    if (mounted) setState(() => _unread = n);
  }

  Future<void> _onSelect(int i) async {
    if (i != _index) HapticFeedback.selectionClick();
    setState(() {
      _index = i;
      _visited.add(i);
    });
    if (i == _notifIndex) {
      // 通知タブを開いたら既読化してバッジを消す。
      await NotifStore.markSeenNow();
      if (mounted) setState(() => _unread = 0);
    } else {
      // 他タブへ移ったタイミングでバッジを取り直す。
      _refreshUnread();
    }
  }

  Widget _notifIcon(Widget icon) =>
      _unread > 0 ? Badge(label: Text('$_unread'), child: icon) : icon;

  @override
  Widget build(BuildContext context) {
    final children = [
      for (var i = 0; i < _screens.length; i++)
        _visited.contains(i) ? _screens[i] : const SizedBox.shrink(),
    ];
    return Scaffold(
      body: _FadeIndexedStack(index: _index, children: children),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _onSelect,
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.rate_review_outlined),
              selectedIcon: Icon(Icons.rate_review),
              label: 'レビュー'),
          NavigationDestination(
              icon: _notifIcon(const Icon(Icons.notifications_outlined)),
              selectedIcon: _notifIcon(const Icon(Icons.notifications)),
              label: '通知'),
          const NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: '分析'),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '設定'),
        ],
      ),
    );
  }
}

/// タブ切替時に新しい画面をフェードインさせる IndexedStack。
/// 全タブを常時マウントしたまま（＝再読み込みなし）でフェードのみ行うため軽量。
/// 静止時は opacity=1 で合成レイヤも発生しない。
class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  const _FadeIndexedStack({required this.index, required this.children});

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void didUpdateWidget(_FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
