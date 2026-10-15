import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:intl/intl.dart';

import '../app_events.dart';
import '../data.dart';
import '../locked_preview.dart';
import '../models.dart';
import '../notifications.dart' show NotifTap;
import '../setup_guide.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'connect_store_screen.dart';
import 'plan_screen.dart';
import 'review_detail_screen.dart';

class ReviewsScreen extends StatefulWidget {
  const ReviewsScreen({super.key});

  @override
  State<ReviewsScreen> createState() => _ReviewsScreenState();
}

class _ReviewsScreenState extends State<ReviewsScreen> {
  /// 1回に読む件数（末尾まで来たら続きを読む）。
  static const _pageSize = 50;

  /// 表示中のレビュー。null はまだ一度も読めていない（スケルトンかエラーを出す）。
  ///
  /// 以前は読み直すたびに FutureBuilder がスケルトンに切り替わり、一覧が作り直されて
  /// 先頭まで戻っていた（20件目を返信して戻ると、毎回スクロールし直しになる）。
  /// 読み直しの間も前の一覧を出したままにし、上端に細いバーだけを出す。
  List<ReviewRow>? _items;
  Object? _error;
  bool _loading = true;
  bool _hasMore = false;
  int _nextOffset = 0;
  bool _loadingMore = false;
  bool _moreFailed = false;

  /// 読み込みの通し番号（古い応答が新しい結果を上書きしないように）。
  int _loadSeq = 0;

  /// 一覧を作り直した回数。入場アニメはこれが変わったときだけ再生する。
  int _listGen = 0;

  /// 引っ張って更新の最中（RefreshIndicator が出ているので上端のバーは出さない）。
  bool _pulling = false;

  List<AppRow> _apps = [];
  List<Announcement> _announcements = [];

  // フィルタ・並び替え
  final Set<int> _ratings = {}; // 空=全評価
  bool _unrepliedOnly = false;
  String? _appId;
  ReviewSort _sort = ReviewSort.newest;

  // キーワード検索（タイトル・本文）
  final _searchCtrl = TextEditingController();
  bool _searchOpen = false;
  String _keyword = '';
  Timer? _searchDebounce;

  String _plan = 'free';
  bool _bulkRunning = false;

  /// ストアから取得中か。[_quietFetch] は引っ張って更新に合わせた裏での確認。
  bool _fetching = false;
  bool _quietFetch = false;
  DateTime? _lastStoreCheck;

  /// 連携済みストア・アプリ一覧を一度でも読み終えたか（読む前に道案内を出さない）。
  bool _metaLoaded = false;
  List<String> _connected = [];

  /// 連携状態を一度でも確認できたか（通信エラーのときに「未連携」と決めつけない）。
  bool _connectedKnown = false;

  /// Free の閲覧範囲より前にある保存済みレビュー（チラ見せ用）。
  LockedPreview _locked = LockedPreview.empty;

  int get _activeCount =>
      _ratings.length + (_unrepliedOnly ? 1 : 0) + (_appId != null ? 1 : 0);

  @override
  void initState() {
    super.initState();
    // 設定タブでの連携・アプリ追加、詳細での返信、購入などを受けて読み直す
    // （各タブは IndexedStack で保持されるので、自分からは気づけない）。
    AppEvents.dataChanged.addListener(_onDataChanged);
    AppEvents.planChanged.addListener(_onPlanChanged);
    // 通知のタップで「このアプリの未返信を見せて」と頼まれたとき（ホーム画面が置く）。
    // タブが作られる前に置かれていることもあるので、最初の読み込みの前にも拾う。
    NotifTap.reviewsFocus.addListener(_onNotifFocus);
    _takeNotifFocus();
    _load(fresh: true);
    _fetchMeta();
  }

  @override
  void dispose() {
    AppEvents.dataChanged.removeListener(_onDataChanged);
    AppEvents.planChanged.removeListener(_onPlanChanged);
    NotifTap.reviewsFocus.removeListener(_onNotifFocus);
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onDataChanged() {
    // 返信の変化は一覧だけ。連携・アプリ・取得は、取得エラーや道案内の表示も変わる。
    if (AppEvents.lastChange != DataChange.replies) _fetchMeta();
    _load();
  }

  void _onPlanChanged() {
    // 有料になると30日より前のレビューも読めるようになる（範囲はサーバーの RLS で決まる）。
    _fetchMeta();
    _load();
  }

  void _onNotifFocus() {
    if (_takeNotifFocus()) _load(fresh: true);
  }

  /// 通知から頼まれた絞り込み（そのアプリの未返信）に切り替える。頼まれていなければ false。
  /// 届いたレビューが隠れないよう、ほかの絞り込みと検索は外す。
  bool _takeNotifFocus() {
    final appId = NotifTap.reviewsFocus.value;
    if (appId == null) return false;
    NotifTap.reviewsFocus.value = null;
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    _keyword = '';
    _searchOpen = false;
    _ratings.clear();
    _appId = appId;
    _unrepliedOnly = true;
    return true;
  }

  /// 一覧を読み直す。
  ///
  /// [fresh] は条件（絞り込み・並び替え・検索）を変えたとき。前の条件の一覧が残ると
  /// 誤解を招くので、スケルトンから出し直す。それ以外（詳細から戻った・引っ張って更新・
  /// ほかの画面での変更）は、今の一覧とスクロール位置を残したまま差し替える。
  /// [reportError] は利用者が自分で読み直したとき（引っ張って更新）。一覧を残したまま
  /// 失敗を知らせる。裏での読み直しの失敗は、ほかのタブにいても出ないよう黙っておく。
  Future<void> _load({bool fresh = false, bool reportError = false}) async {
    final seq = ++_loadSeq;
    // 続きを読み込んでいた場合も、その件数ぶんは取り直す（スクロール位置を保つため）。
    final keep = fresh ? 0 : (_items?.length ?? 0);
    setState(() {
      _loading = true;
      if (fresh) {
        _items = null;
        _error = null;
        _hasMore = false;
        _listGen++;
      }
    });
    try {
      final page = await Repo.reviewsPage(
        appId: _appId,
        ratings: _ratings.toList(),
        unrepliedOnly: _unrepliedOnly,
        keyword: _keyword,
        sort: _sort,
        limit: math.max(_pageSize, keep),
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset;
        _error = null;
        _loading = false;
        _loadingMore = false;
        _moreFailed = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      final hadItems = _items != null;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (!hadItems) _error = e;
      });
      // 一覧が出ているなら消さずに残し、読み直せなかったことだけ伝える。
      if (hadItems && reportError) {
        showError(context, e, prefix: '最新の一覧を読み込めませんでした');
      }
    }
  }

  /// 末尾まで来たときに続きを読む。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _items == null) return;
    final seq = _loadSeq;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final page = await Repo.reviewsPage(
        appId: _appId,
        ratings: _ratings.toList(),
        unrepliedOnly: _unrepliedOnly,
        keyword: _keyword,
        sort: _sort,
        offset: _nextOffset,
        limit: _pageSize,
      );
      if (!mounted || seq != _loadSeq) return;
      // 読む合間に新着が入ると境目で重なることがあるので、表示済みの id は除く。
      final shown = {for (final r in _items!) r.id};
      setState(() {
        _items = [..._items!, ...page.items.where((r) => !shown.contains(r.id))];
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  void _fetchMeta() {
    Future.wait([
      Repo.apps().then((a) => _apps = a),
      Repo.connectedStores().then((c) {
        _connected = c;
        _connectedKnown = true;
      }),
    ]).then((_) {
      if (mounted) setState(() => _metaLoaded = true);
    }).catchError((_) {
      if (mounted) setState(() => _metaLoaded = true);
    });
    Repo.announcements().then((a) {
      if (mounted) setState(() => _announcements = a);
    }).catchError((_) {});
    Repo.plan().then((p) {
      if (mounted) setState(() => _plan = p);
      // 有料プランには隠れたレビューがないので問い合わせない。
      return p == 'free' ? Repo.lockedPreview() : Future.value(LockedPreview.empty);
    }).then((l) {
      if (mounted) setState(() => _locked = l);
    }).catchError((_) {});
  }

  /// 道案内の手順を進めたあと：連携状態を取り直す
  /// （連携・アプリ追加をした場合の一覧の読み直しは AppEvents から届く）。
  void _afterSetupStep() => _fetchMeta();

  Future<void> _refresh() async {
    HapticFeedback.mediumImpact();
    _fetchMeta();
    setState(() => _pulling = true);
    try {
      await _load(reportError: true);
    } finally {
      if (mounted) setState(() => _pulling = false);
    }
    // DB の読み直しはすぐ終わらせ、ストアへの確認は裏で行う（最大で1分以上かかるため）。
    _checkStoresQuietly();
  }

  String _appName(String id) {
    for (final a in _apps) {
      if (a.id == id) return a.name;
    }
    return 'アプリ';
  }

  void _openDetail(ReviewRow r) {
    // 戻ったときの読み直しは、返信の変化があったときだけ AppEvents から届く。
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReviewDetailScreen(r),
    ));
  }

  void _openConnectStore() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const ConnectStoreScreen(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final broken = _apps.where((a) => a.hasPollError).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('レビュー'),
        actions: [
          IconButton(
            onPressed: _toggleSearch,
            tooltip: _searchOpen ? '検索を閉じる' : '検索',
            icon: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded),
          ),
          IconButton(
            onPressed: _bulkRunning ? null : _bulkAction,
            tooltip: '一括AI返信',
            icon: _bulkRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome_motion_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_announcements.isNotEmpty) _announcementBanner(),
          if (broken.isNotEmpty) _pollErrorBanner(broken),
          if (_searchOpen) _searchField(),
          _bar(),
          if (_activeCount > 0) _activeChips(),
          if (_fetching) _fetchingStrip(),
          Expanded(
            child: Stack(
              children: [
                RefreshIndicator(
                  onRefresh: _refresh,
                  child: _listArea(),
                ),
                // 一覧を出したまま読み直している間は、上端に細いバーだけを出す。
                if (_loading && _items != null && !_pulling)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _listArea() {
    final reviews = _items;
    if (reviews == null) {
      if (_error == null) return const ReviewListSkeleton();
      return ListView(children: [
        const SizedBox(height: 80),
        EmptyState(
          icon: Icons.wifi_off_rounded,
          title: '読み込みに失敗しました',
          subtitle: friendlyError(_error!),
          action: FilledButton.tonal(
            onPressed: () => _load(fresh: true),
            child: const Text('再試行'),
          ),
        ),
      ]);
    }
    if (reviews.isEmpty) {
      final filtered = _activeCount > 0 || _keyword.isNotEmpty;
      return ListView(
        key: const PageStorageKey('reviews-empty'),
        padding: !filtered && _locked.hasHidden
            ? const EdgeInsets.all(16)
            : EdgeInsets.zero,
        children: [_emptyBody()],
      );
    }
    // Freeで閲覧範囲より前にもレビューがあるときは、末尾でチラ見せする（全部読み終えてから）。
    final showLocked = _locked.hasHidden && !_hasMore;
    final extra = (_hasMore ? 1 : 0) + (showLocked ? 1 : 0);
    return ListView.separated(
      key: const PageStorageKey('reviews-list'),
      padding: const EdgeInsets.all(16),
      itemCount: reviews.length + extra,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (i >= reviews.length) {
          if (_hasMore) return _loadMoreFooter();
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            // 件数は全アプリの合計なので、アプリで絞っているときはそう明記する。
            child: LockedReviewsTeaser(_locked, acrossAllApps: _appId != null),
          );
        }
        final r = reviews[i];
        final delay = (i < 12 ? i * 45 : 0).ms;
        return _ReviewCard(r, onTap: () => _openDetail(r))
            .animate(key: ValueKey('$_listGen-$i'))
            .fadeIn(duration: 280.ms, delay: delay)
            .slideY(begin: 0.08, end: 0, curve: Curves.easeOutCubic);
      },
    );
  }

  /// 一覧の末尾：見えたら続きを読む。失敗したら再試行ボタン。
  Widget _loadMoreFooter() {
    if (_moreFailed) {
      return Center(
        child: TextButton.icon(
          onPressed: _loadMore,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text('続きを読み込めませんでした。再試行'),
        ),
      );
    }
    if (!_loadingMore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadMore();
      });
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Semantics(
          label: '続きを読み込んでいます',
          child: const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
    );
  }

  /// 一覧が空のときの中身。「データがない」で終わらせず、次にすることを出す。
  ///   1. 絞り込み・検索中 → 条件の解除
  ///   2. Free で30日より前にだけレビューがある → ぼかしたチラ見せ（保存はされている）
  ///   3. 連携かアプリ追加がまだ → はじめの3ステップ
  ///   4. 準備は済んでいるがまだ届いていない → 今すぐ取得
  Widget _emptyBody() {
    if (_activeCount > 0 || _keyword.isNotEmpty) {
      final label = _keyword.isEmpty
          ? '絞り込みを解除'
          : (_activeCount == 0 ? '検索語を消す' : '条件をすべて解除');
      return Padding(
        padding: const EdgeInsets.only(top: 80),
        child: EmptyState(
          icon: _keyword.isEmpty ? Icons.inbox_outlined : Icons.search_off_rounded,
          title: 'レビューがありません',
          subtitle: _keyword.isEmpty
              ? '絞り込み条件に一致するレビューがありません。'
              : '「$_keyword」に一致するレビューがありません。',
          action: TextButton(onPressed: _clearAll, child: Text(label)),
        ),
      );
    }
    if (_locked.hasHidden) return LockedReviewsTeaser(_locked);
    if (!_metaLoaded) return const SizedBox.shrink();
    // 連携状態を確認できなかったときは、アプリがあれば連携済みとみなす
    // （アプリの追加には連携が要る。電波が悪いだけで手順1に戻さない）。
    final storeConnected =
        _connected.isNotEmpty || (!_connectedKnown && _apps.isNotEmpty);
    if (!storeConnected || _apps.isEmpty) {
      return SetupGuide(
        storeConnected: storeConnected,
        hasApp: _apps.isNotEmpty,
        onChanged: _afterSetupStep,
      );
    }
    // アプリを追加しただけで一度も取得していない：1時間待つものと思わせず、今すぐ取り込める
    // ことを先に伝える。
    final neverFetched = _apps.every((a) => a.lastPolledAt == null);
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: EmptyState(
        icon: neverFetched
            ? Icons.download_rounded
            : Icons.hourglass_empty_rounded,
        title: neverFetched ? 'レビューを取り込みましょう' : 'まだレビューが届いていません',
        subtitle: neverFetched
            ? '「今すぐ取得」でストアのレビューを取り込めます。\n'
                '以後は毎時自動で取り込みます。'
            : '新着は毎時自動で取り込みます。\n'
                'Google Play は直近7日ぶんのレビューから取り込まれます。',
        action: FilledButton.tonal(
          onPressed: Repo.canRefresh && !_fetching ? _fetchNow : null,
          child: _fetching
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 10),
                    Text('取り込み中…'),
                  ],
                )
              : const Text('今すぐ取得'),
        ),
      ),
    );
  }

  // ---- ストアからの取得 ----

  /// 「今すぐ取得」。結果は必ず中身を見て出し分ける
  /// （サーバーは一部のアプリで失敗しても 200 を返すので、成功表示だけだと連携切れに気づけない）。
  Future<void> _fetchNow() async {
    if (_fetching) return;
    HapticFeedback.lightImpact();
    setState(() {
      _fetching = true;
      _quietFetch = false;
    });
    _lastStoreCheck = DateTime.now();
    PollOutcome? outcome;
    try {
      // 一覧と取得エラーの読み直しは AppEvents から届く。
      outcome = await Repo.refreshFromStores();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
    // 結果の出し方は道案内・設定タブと共通（失敗があれば理由と連携の確認先をダイアログで）。
    if (outcome != null && mounted) {
      await showPollOutcome(
        context,
        outcome,
        googlePlay: _apps.any((a) => a.store == 'googleplay'),
      );
    }
  }

  /// 引っ張って更新のついでに、ストアの新着も裏で確認する。
  /// 回数制限（1分に2回）に当たったときなどは黙って諦める（DB の読み直しは済んでいる）。
  /// 失敗したアプリは、読み直したあとの警告バナーで分かる。
  Future<void> _checkStoresQuietly() async {
    if (!Repo.canRefresh ||
        _fetching ||
        _connected.isEmpty ||
        _apps.isEmpty ||
        !mounted) {
      return;
    }
    final last = _lastStoreCheck;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return;
    }
    _lastStoreCheck = DateTime.now();
    setState(() {
      _fetching = true;
      _quietFetch = true;
    });
    try {
      final outcome = await Repo.refreshFromStores();
      if (mounted && outcome.hasNew) {
        showSnack(context, outcome.headline, kind: SnackKind.success);
      }
    } catch (_) {
      // 429 や通信の失敗は無視する（次の自動取得で取り込まれる）。
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Widget _fetchingStrip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: Row(
        children: [
          const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _quietFetch
                  ? 'ストアの新着を確認しています…'
                  : 'ストアからレビューを取り込んでいます（30秒ほどかかることがあります）',
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 200.ms);
  }

  // ---- 取得エラーの警告 ----
  /// 毎時の取得が失敗し続けているアプリ（鍵の失効・権限不足など）を知らせる。
  /// サーバーは apps.last_error に理由を残しているのに、以前はアプリのどこにも出ず、
  /// 「新着が無い」のか「連携が壊れている」のか区別できなかった。
  Widget _pollErrorBanner(List<AppRow> broken) {
    final single = broken.length == 1;
    final title = single
        ? '「${broken.first.name}」のレビューを取得できていません'
        : '${broken.length}件のアプリでレビューを取得できていません';
    final lines = single
        ? [broken.first.lastErrorText ?? '']
        : [for (final a in broken.take(3)) '${a.name}：${a.lastErrorText}'];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      decoration: BoxDecoration(
        color: AppTheme.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.danger.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.sync_problem_rounded,
                size: 18, color: AppTheme.danger),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: context.dangerTextC)),
                const SizedBox(height: 2),
                for (final l in lines)
                  Text(l,
                      style: TextStyle(
                          fontSize: 12, height: 1.4, color: context.inkC)),
                if (broken.length > 3)
                  Text('ほか${broken.length - 3}件',
                      style: TextStyle(fontSize: 12, color: context.subtleC)),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _openConnectStore,
                    style: TextButton.styleFrom(
                      foregroundColor: context.accentTextC,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                    ),
                    child: const Text('連携を確認'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 250.ms);
  }

  // ---- お知らせバナー ----
  Widget _announcementBanner() {
    return Column(
      children: _announcements.map((a) {
        // 見出しは小さめの太字なので、塗り用の色ではなく文字用の濃さにする。
        final (bg, fg, icon) = switch (a.level) {
          'critical' => (
              AppTheme.danger.withValues(alpha: 0.10),
              context.dangerTextC,
              Icons.error_outline
            ),
          'warning' => (
              AppTheme.warning.withValues(alpha: 0.12),
              context.warningTextC,
              Icons.warning_amber_rounded
            ),
          _ => (
              AppTheme.primary.withValues(alpha: 0.08),
              context.accentTextC,
              Icons.campaign_outlined
            ),
        };
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.title,
                        style: TextStyle(
                            fontWeight: FontWeight.w700, color: fg)),
                    if (a.body != null && a.body!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(a.body!,
                          style: TextStyle(fontSize: 13, color: context.inkC)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 250.ms);
      }).toList(),
    );
  }

  // ---- キーワード検索 ----
  void _toggleSearch() {
    HapticFeedback.selectionClick();
    if (!_searchOpen) {
      setState(() => _searchOpen = true);
      return;
    }
    // 閉じたら検索もやめる（見えない条件で絞り込まれたままにしない）。
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    setState(() => _searchOpen = false);
    if (_keyword.isNotEmpty) {
      _keyword = '';
      _load(fresh: true);
    }
  }

  void _onSearchChanged(String value) {
    setState(() {}); // 消去ボタンの出し入れ
    _searchDebounce?.cancel();
    // 1文字ごとに問い合わせないよう、入力が止まってから検索する。
    _searchDebounce = Timer(
        const Duration(milliseconds: 400), () => _applyKeyword(value));
  }

  void _applyKeyword(String value) {
    _searchDebounce?.cancel();
    final k = value.trim();
    if (!mounted || k == _keyword) return;
    _keyword = k;
    _load(fresh: true);
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        controller: _searchCtrl,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onChanged: _onSearchChanged,
        onSubmitted: _applyKeyword,
        decoration: InputDecoration(
          hintText: 'タイトル・本文で検索',
          isDense: true,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '検索語を消す',
                  icon: const Icon(Icons.close_rounded, size: 20),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() {});
                    _applyKeyword('');
                  },
                ),
        ),
      ),
    ).animate().fadeIn(duration: 180.ms);
  }

  // ---- 絞り込み / 並び替え バー ----
  Widget _bar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: _barButton(
              icon: Icons.tune_rounded,
              label: '絞り込み',
              badge: _activeCount > 0 ? '$_activeCount' : null,
              active: _activeCount > 0,
              onTap: _openFilterSheet,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _barButton(
              icon: Icons.swap_vert_rounded,
              label: _sort.label,
              active: _sort != ReviewSort.newest,
              onTap: _openSortSheet,
            ),
          ),
        ],
      ),
    );
  }

  Widget _barButton({
    required IconData icon,
    required String label,
    String? badge,
    required bool active,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.primary.withValues(alpha: 0.12)
              : context.surfaceC,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: active ? AppTheme.primary : context.borderC),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 18, color: active ? AppTheme.primary : context.inkC),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? AppTheme.primary : context.inkC)),
            ),
            if (badge != null) ...[
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: const BoxDecoration(
                    color: AppTheme.primary, shape: BoxShape.circle),
                child: Text(badge,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- 適用中フィルタのチップ（個別解除） ----
  Widget _activeChips() {
    final chips = <Widget>[];
    for (final r in _ratings.toList()..sort()) {
      chips.add(_activeChip(
        '★$r',
        () {
          _ratings.remove(r);
          _load(fresh: true);
        },
        semanticsLabel: '星$rつ',
      ));
    }
    if (_unrepliedOnly) {
      chips.add(_activeChip('未返信', () {
        _unrepliedOnly = false;
        _load(fresh: true);
      }));
    }
    if (_appId != null) {
      chips.add(_activeChip(_appName(_appId!), () {
        _appId = null;
        _load(fresh: true);
      }));
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...chips,
          TextButton(
            onPressed: _clearFilters,
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 44)),
            child: const Text('すべて解除'),
          ),
        ],
      ),
    );
  }

  /// 適用中の条件1つ（タップで解除）。見た目は小さいピルのまま、押せる範囲は高さ44pt にする。
  /// 長いアプリ名は省略して、画面からはみ出さないようにする。
  Widget _activeChip(String label, VoidCallback onRemove,
      {String? semanticsLabel}) {
    return Semantics(
      button: true,
      label: '${semanticsLabel ?? label}の絞り込みを解除',
      excludeSemantics: true,
      onTap: onRemove,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onRemove();
        },
        borderRadius: BorderRadius.circular(999),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Center(
            widthFactor: 1,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.close, size: 14, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 絞り込みだけを解除する（検索語はそのまま）。
  void _clearFilters() {
    _ratings.clear();
    _unrepliedOnly = false;
    _appId = null;
    _load(fresh: true);
  }

  /// 絞り込みと検索をまとめて解除する。
  void _clearAll() {
    _searchDebounce?.cancel();
    _searchCtrl.clear();
    _keyword = '';
    _searchOpen = false;
    _clearFilters();
  }

  /// 「Proは初回◯日間無料」の一文（トライアルを設定していなければ空）。
  /// 対象かどうかはストアに聞かないと分からないので「対象の方のみ」と添える。
  String _proTrialNote() {
    final trial = planDef('pro').trialLabel;
    return trial == null ? '' : 'Proは初回$trial無料でお試しいただけます（対象の方のみ）。';
  }

  /// 一括投稿でそのまま使える下書きがあるか（サーバーも同じく最新の下書きを使う）。
  static bool _hasUsableDraft(ReviewRow r) =>
      r.hasNewerDraft && r.draftBody.trim().isNotEmpty;

  // ---- 一括AI返信（プラン別ゲート） ----
  Future<void> _bulkAction() async {
    HapticFeedback.selectionClick();
    final limit = planBulkLimit(_plan); // 1=不可

    // Free（一括不可）はアップセル
    if (limit == 1) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('一括返信はProプランから'),
          content: Text(
              'Proは一度に最大${planBulkLimit('pro')}件、'
              'Maxは最大${planBulkLimit('max')}件をまとめてAI返信できます。'
              '${_proTrialNote()}'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('あとで')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('プランを見る')),
          ],
        ),
      );
      if (go == true && mounted) {
        await openPlanScreen(context, reason: PaywallReason.bulk);
      }
      return;
    }

    // 対象は今の条件（絞り込み・検索）に合う未返信。読み込み済みのページに関係なく、
    // サーバーで未返信だけを上限+1件まで取る（+1件は上限で切ったかどうかの判定用）。
    setState(() => _bulkRunning = true);
    List<ReviewRow> unreplied;
    try {
      unreplied = await Repo.reviews(
        appId: _appId,
        ratings: _ratings.toList(),
        unrepliedOnly: true,
        keyword: _keyword,
        sort: _sort,
        limit: limit + 1,
      );
    } catch (e) {
      if (mounted) {
        setState(() => _bulkRunning = false);
        showError(context, e, prefix: '対象のレビューを読み込めませんでした');
      }
      return;
    }
    if (!mounted) return;
    setState(() => _bulkRunning = false);
    if (unreplied.isEmpty) {
      showSnack(context, '未返信のレビューはありません');
      return;
    }
    final capped = unreplied.length > limit;
    final targets = capped ? unreplied.sublist(0, limit) : unreplied;
    final withDraft = targets.where(_hasUsableDraft).length;
    final noDraft = targets.length - withDraft;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.surfaceC,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final note = TextStyle(fontSize: 13, color: context.subtleC);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('未返信 ${targets.length} 件に一括返信',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (withDraft > 0)
                  Text('下書きのある $withDraft 件は、その下書きを使います（AI返信の枠は使いません）。',
                      style: note),
                if (noDraft > 0)
                  Text('下書きのない $noDraft 件は、AIが返信を作成します。', style: note),
                if (capped)
                  Text('現在のプランでは一度に $limit 件までです。残りはもう一度実行してください。',
                      style: note),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'post'),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text('${targets.length}件をストアに投稿'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed:
                      noDraft == 0 ? null : () => Navigator.pop(ctx, 'draft'),
                  icon: const Icon(Icons.drafts_outlined, size: 18),
                  label: Text(noDraft == 0
                      ? '下書きはすべて作成済みです'
                      : '下書きのない$noDraft件だけ作成'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || !mounted) return;

    final post = choice == 'post';
    // 下書きだけ作る場合は、下書きの無いレビューだけを送る。
    final ids = [
      for (final r in targets)
        if (post || !_hasUsableDraft(r)) r.id,
    ];
    setState(() => _bulkRunning = true);
    try {
      final res = await Repo.bulkReply(ids, post: post);
      HapticFeedback.mediumImpact();
      // 一覧の読み直しは AppEvents から届く。
      if (mounted) _showBulkResult(res, post: post);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  /// 一括返信の結果。失敗や時間切れの残りがあるときは「完了」とは言わず、件数と理由を出す。
  void _showBulkResult(Map<String, dynamic> res, {required bool post}) {
    int n(String key) => (res[key] as num?)?.toInt() ?? 0;
    final generated = n('generated');
    final reused = n('reused');
    final posted = n('posted');
    final skipped = n('skipped');
    final failures = [
      for (final r in (res['results'] as List?) ?? const [])
        if (r is Map && r['ok'] != true) r,
    ];

    if (failures.isEmpty && skipped == 0) {
      final String message;
      if (post) {
        message = reused > 0
            ? '$posted件をストアに投稿しました（下書きを使用 $reused件・AIで作成 $generated件）'
            : '$posted件をストアに投稿しました';
      } else {
        message = '下書きを$generated件作成しました';
      }
      showSnack(context, message, kind: SnackKind.success);
      return;
    }

    // 理由ごとにまとめる（同じ理由で何件も失敗することが多い）。
    final reasons = <String, int>{};
    for (final f in failures) {
      final reason = storeErrorText('${f['error'] ?? ''}');
      reasons[reason] = (reasons[reason] ?? 0) + 1;
    }
    final keptAsDraft = failures.any((f) => f['status'] == 'draft');
    final done = post ? '投稿 $posted件' : '下書きを作成 $generated件';
    final notice = res['notice'] as String?;

    showDialog<void>(
      context: context,
      builder: (ctx) {
        final note = TextStyle(fontSize: 13, color: context.subtleC);
        return AlertDialog(
          title: const Text('一括返信の結果'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    done,
                    if (failures.isNotEmpty) '失敗 ${failures.length}件',
                    if (skipped > 0) '未処理 $skipped件',
                  ].join('・'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                for (final e in reasons.entries.take(4))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                        e.value > 1 ? '・${e.key}（${e.value}件）' : '・${e.key}'),
                  ),
                if (keptAsDraft)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('投稿できなかった返信は下書きとして残っています。', style: note),
                  ),
                if (notice != null && notice.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(notice, style: note),
                  ),
              ],
            ),
          ),
          actions: [
            if (failures.isNotEmpty && !_unrepliedOnly)
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _unrepliedOnly = true;
                  _load(fresh: true);
                },
                child: const Text('未返信を表示'),
              ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('閉じる')),
          ],
        );
      },
    );
  }

  // ---- 絞り込みシート ----
  Future<void> _openFilterSheet() async {
    final tempRatings = {..._ratings};
    var tempUnreplied = _unrepliedOnly;
    var tempApp = _appId;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surfaceC,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheet) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.borderC,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: const Text('絞り込み',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 18)),
                  ),
                  const SizedBox(height: 16),
                  const Text('評価（複数選択可）',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in [5, 4, 3, 2, 1])
                        _sheetToggle(
                          label: '★$r',
                          semanticsLabel: '星$rつ',
                          selected: tempRatings.contains(r),
                          onTap: () => setSheet(() {
                            tempRatings.contains(r)
                                ? tempRatings.remove(r)
                                : tempRatings.add(r);
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('状態', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  _sheetToggle(
                    label: '未返信のみ',
                    selected: tempUnreplied,
                    onTap: () => setSheet(() => tempUnreplied = !tempUnreplied),
                  ),
                  if (_apps.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    const Text('アプリ',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _sheetToggle(
                          label: '全アプリ',
                          selected: tempApp == null,
                          exclusive: true,
                          onTap: () => setSheet(() => tempApp = null),
                        ),
                        for (final a in _apps)
                          _sheetToggle(
                            label: a.name,
                            selected: tempApp == a.id,
                            exclusive: true,
                            onTap: () => setSheet(() => tempApp = a.id),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setSheet(() {
                            tempRatings.clear();
                            tempUnreplied = false;
                            tempApp = null;
                          }),
                          child: const Text('リセット'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            _ratings
                              ..clear()
                              ..addAll(tempRatings);
                            _unrepliedOnly = tempUnreplied;
                            _appId = tempApp;
                            _load(fresh: true);
                            Navigator.pop(ctx);
                          },
                          child: const Text('適用'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  /// 絞り込みシートの選択肢。読み上げでは「ボタン・選択中」が伝わるようにし、
  /// 押せる範囲は高さ44pt 以上にする。[exclusive] はどれか1つだけ選ぶ組（アプリ）。
  Widget _sheetToggle({
    required String label,
    String? semanticsLabel,
    required bool selected,
    bool exclusive = false,
    required VoidCallback onTap,
  }) {
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: exclusive,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppTheme.primary : context.surfaceC,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: selected ? AppTheme.primary : context.borderC),
          ),
          child: Center(
            widthFactor: 1,
            child: Text(label,
                semanticsLabel: semanticsLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : context.inkC)),
          ),
        ),
      ),
    );
  }

  // ---- 並び替えシート ----
  Future<void> _openSortSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.surfaceC,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: context.borderC,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('並び替え',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              for (final s in ReviewSort.values)
                ListTile(
                  selected: _sort == s,
                  title: Text(s.label,
                      style: TextStyle(
                        fontWeight:
                            _sort == s ? FontWeight.w700 : FontWeight.w500,
                        color: _sort == s ? context.accentTextC : context.inkC,
                      )),
                  trailing: _sort == s
                      ? Icon(Icons.check_rounded, color: context.accentTextC)
                      : null,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _sort = s;
                    _load(fresh: true);
                    Navigator.pop(ctx);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

class _ReviewCard extends StatelessWidget {
  final ReviewRow review;
  final VoidCallback onTap;
  const _ReviewCard(this.review, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final date = review.reviewedAt != null
        ? DateFormat('M/d').format(review.reviewedAt!)
        : '';
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StarRating(review.rating),
                  const SizedBox(width: 8),
                  if (review.appName != null)
                    Expanded(
                      child: Text(review.appName!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: context.subtleC)),
                    )
                  else
                    const Spacer(),
                  Text(date,
                      style: TextStyle(fontSize: 12, color: context.subtleC)),
                ],
              ),
              if (review.title != null && review.title!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(review.title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
              if (review.body != null && review.body!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(review.body!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: context.inkC)),
              ],
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 文字を大きくしてもはみ出さないよう、トピックは折り返す。
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in review.topics.take(3)) TopicChip(t),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _statusBadge(context),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状態バッジ。小さい文字なので、文字色は塗り用ではなく文字用の濃さにする。
  Widget _statusBadge(BuildContext context) {
    final (text, base, fg) = review.isPosted
        ? (
            review.isMarkedReplied ? '返信済み（手動）' : '返信済み',
            AppTheme.success,
            context.successTextC
          )
        : review.hasReply
            ? ('下書きあり', AppTheme.warning, context.warningTextC)
            : ('未返信', context.subtleC, context.subtleC);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          style:
              TextStyle(fontSize: 11, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}
