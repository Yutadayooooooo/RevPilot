import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_events.dart';
import '../data.dart';
import '../local_notifications.dart';
import '../notification_primer.dart';
import '../notifications.dart';
import '../ui.dart';
import 'reviews_screen.dart';
import 'notifications_screen.dart';
import 'analytics_screen.dart';
import 'review_detail_screen.dart';
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

  /// 通知タブを開くたびに進める（NotificationsScreen はこれが変わると読み直す）。
  int _notifShown = 0;

  /// 一度でも開いたタブだけ実体を生成する（＝初回表示時に入場アニメが再生され、
  /// 以降はマウントし続けて再読み込みを避ける）。
  /// 中身の変化（連携・アプリ・新着・返信・プラン）は各タブが AppEvents を聞いて読み直す。
  final Set<int> _visited = {0};

  static const _reviewsIndex = 0;
  static const _notifIndex = 1;
  static const _analyticsIndex = 2;
  static const _tabCount = 4;

  /// 新着レビューを拾ってバナーを出す前景ポーリング。
  ///
  /// アプリ終了中の通知はリモートpush([PushService])が担当する。
  /// こちらは起動中に画面を開きっぱなしにしている間の即時性を担保するもので、
  /// push が未設定（FIREBASE_* が空）の環境ではこれが唯一の通知経路になる。
  ///
  /// サーバー側の取得が毎時である以上、30秒間隔で問い合わせても新着が増えることはない。
  /// 間隔を詰めるほど利用者の通信量とDBの転送量だけが増えるので、2分に緩める。
  static const _pollInterval = Duration(minutes: 2);
  Timer? _poller;

  /// これ以上バックグラウンドにいたら、復帰時に各タブを読み直させる。
  /// サーバーは毎時取り込むので、短い切り替え（数分）で毎回読み直すのは無駄になる。
  static const _staleAfter = Duration(minutes: 10);
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppEvents.dataChanged.addListener(_onDataChanged);
    // Free の閲覧範囲（30日）はプランで変わるので、未読の数も取り直す。
    AppEvents.planChanged.addListener(_refreshUnread);
    NotifTap.pending.addListener(_onNotifTap);
    // ローカル通知の初期化。許可はここでは求めない（下の説明のあとで求める）。
    // ローカル通知のタップでアプリが起動していれば、その行き先も拾う。
    unawaited(LocalNotifier.takeLaunchTarget());
    // 最初の画面が出てから、何が届くのかを説明したうえで通知の許可を求める。
    // 通知のタップで起動していれば、先にその行き先を開く（許可済みなので説明は出ない）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onNotifTap();
      NotificationPrimer.maybeShow(context);
    });
    _refreshUnread();
    _startPolling();
  }

  @override
  void dispose() {
    _poller?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    AppEvents.dataChanged.removeListener(_onDataChanged);
    AppEvents.planChanged.removeListener(_refreshUnread);
    NotifTap.pending.removeListener(_onNotifTap);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final away = _pausedAt == null
          ? Duration.zero
          : DateTime.now().difference(_pausedAt!);
      _pausedAt = null;
      if (_index != _notifIndex) _refreshUnread();
      // 復帰時に即チェックし、以後の定期チェックも再開する。
      // 長く離れていたら、サーバーの定期取得で新着が入っているかもしれないので、
      // 新着の有無にかかわらず各タブ（一覧・分析・設定の最終取得）に読み直させる。
      _checkNew(refreshTabs: away >= _staleAfter);
      _startPolling();
      // 端末の設定アプリで通知を許可して戻ってきた場合に備え、許可状態を読み直す。
      NotificationPrimer.refresh();
    } else {
      if (state == AppLifecycleState.paused) _pausedAt ??= DateTime.now();
      // 背面では止める（無駄な通信を避ける）。
      _poller?.cancel();
      _poller = null;
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(_pollInterval, (_) => _checkNew());
  }

  /// 未通知のレビューをOSバナーで知らせる。
  Future<void> _checkNew({bool refreshTabs = false}) async {
    final fresh = await NotifStore.takeUnnotified();
    // 一度に大量に出さない。
    for (final r in fresh.take(3)) {
      await LocalNotifier.showReview(r);
    }
    if (!mounted) return;
    // 新着が入った＝サーバーの定期取得が進んだ。開いているタブにも読み直させる
    // （未読バッジは _onDataChanged で取り直す）。
    if (fresh.isNotEmpty || refreshTabs) {
      AppEvents.notifyDataChanged(DataChange.reviews);
    }
  }

  /// 連携・アプリ・新着・返信のどれかが変わったとき。
  void _onDataChanged() {
    final kind = AppEvents.lastChange;
    if (kind == DataChange.stores) return; // 連携だけでは通知の中身は変わらない
    if (_index == _notifIndex) {
      // 通知タブを見ている最中なら既読のままにする。
      unawaited(NotifStore.markSeenNow());
      if (_unread != 0) setState(() => _unread = 0);
    } else {
      _refreshUnread();
    }
    // 「あとで」を選んだ人には、レビューが入ったあと一度だけ通知を聞き直す。
    if (kind == DataChange.reviews) NotificationPrimer.maybeReoffer(context);
  }

  Future<void> _refreshUnread() async {
    final n = await NotifStore.unreadCount();
    // 読み込めなかったときは前回の値のまま（0 にすると「通知が無い」と誤解される）。
    if (n != null && mounted) setState(() => _unread = n);
  }

  Future<void> _onSelect(int i) async {
    if (i != _index) HapticFeedback.selectionClick();
    await _select(i);
  }

  Future<void> _select(int i) async {
    setState(() {
      _index = i;
      _visited.add(i);
      // 通知タブは開くたびに読み直す（設定で対象を変えた直後でも最新になる）。
      if (i == _notifIndex) _notifShown++;
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

  /// 通知（プッシュ・ローカル）がタップされたとき、その行き先を開く。
  Future<void> _onNotifTap() async {
    final target = NotifTap.pending.value;
    if (target == null || !mounted) return;
    NotifTap.pending.value = null;

    if (target.type == 'weekly_summary') {
      _backToHome();
      await _select(_analyticsIndex);
      return;
    }
    if (target.type != 'reviews') return; // テスト通知などは開くだけ

    // 開いた通知は既読にする。
    await NotifStore.markSeenNow();
    if (!mounted) return;
    setState(() => _unread = 0);

    // 1件の通知ならそのレビューの詳細を開く（一覧と同じ列で取り直してから渡す）。
    final reviewId = target.reviewId;
    if (reviewId != null) {
      try {
        final review = await Repo.reviewById(reviewId);
        if (!mounted) return;
        if (review != null) {
          // 通知が届いた＝サーバーが新着を取り込んだ。裏のタブも読み直させる。
          AppEvents.notifyDataChanged(DataChange.reviews);
          await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ReviewDetailScreen(review)));
          return;
        }
      } catch (e) {
        if (mounted) showError(context, e, prefix: 'レビューを開けませんでした');
      }
      if (!mounted) return;
    }

    // まとめての通知（またはレビューが見つからない）なら、そのアプリの未返信を一覧で見せる。
    // 絞り込みを先に渡してから読み直させる（絞る前の一覧が後から届いて上書きしないように）。
    _backToHome();
    if (target.appId != null) NotifTap.reviewsFocus.value = target.appId;
    AppEvents.notifyDataChanged(DataChange.reviews);
    await _select(_reviewsIndex);
  }

  /// 上に開いている画面やシートを閉じてホームに戻る。
  /// 編集中で閉じられない画面（PopScope で止めている画面）があれば、そこで止めて入力を守る。
  void _backToHome() {
    Navigator.of(context).popUntil((route) =>
        route.isFirst || route.popDisposition == RoutePopDisposition.doNotPop);
  }

  Widget _notifIcon(Widget icon) => _unread > 0
      ? Badge(
          label: Text('$_unread', semanticsLabel: '未読$_unread件'),
          child: icon)
      : icon;

  Widget _screen(int i) => switch (i) {
        _reviewsIndex => const ReviewsScreen(),
        _notifIndex => NotificationsScreen(shownCount: _notifShown),
        _analyticsIndex => const AnalyticsScreen(),
        _ => const SettingsScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final children = [
      for (var i = 0; i < _tabCount; i++)
        _visited.contains(i) ? _screen(i) : const SizedBox.shrink(),
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
