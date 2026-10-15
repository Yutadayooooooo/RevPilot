import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_events.dart';
import '../config.dart';
import '../social_auth.dart';
import '../data.dart';
import '../models.dart';
import '../notification_primer.dart';
import '../notifications.dart';
import '../push.dart';
import '../setup_guide.dart' show showPollOutcome;
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';
import 'apps_screen.dart';
import 'connect_store_screen.dart';
import 'plan_screen.dart';

/// 問い合わせ先。
const _supportEmail = 'revpilot.hq@gmail.com';

/// アプリのバージョン（pubspec の version の「1.0.0」と「1」）。
/// Flutter 3.47 以降のビルドツールが埋め込む値。古いツールでビルドした場合は null
/// （services.dart の appBuildName を使うとそのツールではビルドできないので、直接読む）。
const String? _buildName = bool.hasEnvironment('FLUTTER_BUILD_NAME')
    ? String.fromEnvironment('FLUTTER_BUILD_NAME')
    : null;
const String? _buildNumber = bool.hasEnvironment('FLUTTER_BUILD_NUMBER')
    ? String.fromEnvironment('FLUTTER_BUILD_NUMBER')
    : null;

/// 「1.0.0 (1)」の形。分からなければ null。
String? get _versionLabel {
  const name = _buildName, number = _buildNumber;
  if (name == null || name.isEmpty) return null;
  return number == null || number.isEmpty ? name : '$name ($number)';
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// 最後に読めた内容。読み直しに失敗しても消さずに出し続ける
  /// （通信エラーのたびに「Free・0件・未連携」と出ると、契約や連携が消えたように見える）。
  _SettingsData? _data;

  /// 直近の読み込みの失敗（成功したら null）。
  Object? _loadError;
  bool _loading = true;
  int _loadSeq = 0;

  bool _refreshing = false;
  bool _deleting = false;
  NotifScope _notifScope = NotifScope.all;
  bool _savingScope = false;
  bool _sendingTest = false;
  bool _enablingNotif = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadNotifScope();
    // 設定タブは作られたまま保持されるので、ほかの画面での変化（連携・アプリ追加・取得・購入）を
    // 聞いて裏で読み直す。サブ画面から戻ったときもこれで最新になる。
    AppEvents.dataChanged.addListener(_onDataChanged);
    AppEvents.planChanged.addListener(_onPlanChanged);
    // 通知の許可状態。ホーム画面が起動時と復帰のたびに読むが、まだなら読んでおく。
    if (NotificationPrimer.status.value == null) NotificationPrimer.permission();
  }

  @override
  void dispose() {
    AppEvents.dataChanged.removeListener(_onDataChanged);
    AppEvents.planChanged.removeListener(_onPlanChanged);
    super.dispose();
  }

  void _onDataChanged() {
    // 返信は設定の表示（件数・連携・最終取得）に関係しない。
    if (AppEvents.lastChange == DataChange.replies) return;
    _load();
  }

  void _onPlanChanged() => _load();

  /// 表示中の内容を残したまま読み直す。初回だけ全体をくるくるにする。
  Future<void> _load() async {
    final seq = ++_loadSeq;
    if (!_loading && mounted) setState(() => _loading = true);
    try {
      final data = await _fetch();
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _data = data;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  Future<_SettingsData> _fetch() async {
    // 互いに関係しないので並べて読む（順番に待つと、電波が弱いときに長く待たされる）。
    final r = await Future.wait<Object?>([
      Repo.billingStatus(),
      Repo.apps(),
      _connectedStores(),
    ]);
    return _SettingsData(
      billing: r[0] as BillingStatus,
      apps: r[1] as List<AppRow>,
      connected: r[2] as List<String>?,
    );
  }

  /// 連携済みのストア。確認できなかったら null（「未連携」と区別する）。
  static Future<List<String>?> _connectedStores() async {
    try {
      return await Repo.connectedStores();
    } catch (_) {
      return null;
    }
  }

  Future<void> _pullToRefresh() async {
    HapticFeedback.mediumImpact();
    await Future.wait([
      _load(),
      NotificationPrimer.permission(),
      _loadNotifScope(),
    ]);
  }

  Future<void> _loadNotifScope() async {
    final local = await NotifStore.scope();
    if (mounted && !_savingScope) setState(() => _notifScope = local);
    // 機種変更・再インストールのあとは端末の値が初期値に戻っているので、サーバーの値に合わせる。
    final synced = await NotifStore.syncScopeFromServer();
    if (mounted && !_savingScope && synced != _notifScope) {
      setState(() => _notifScope = synced);
    }
  }

  /// 自分の端末にテスト通知を送り、リモートpushが実際に届くか確かめる。
  Future<void> _sendTestPush() async {
    if (_sendingTest) return;
    // 通知が許可されていなければ、送っても届かない（サーバーは古い登録へ送れて「送信しました」に
    // なることもある）。先に許可を求め、許可されたときだけ送る。
    if (await NotificationPrimer.permission() != NotifPermission.allowed) {
      await _enableNotifications();
      if (!mounted ||
          NotificationPrimer.status.value != NotifPermission.allowed) {
        return;
      }
    }
    setState(() => _sendingTest = true);
    try {
      // 登録に失敗したままの端末でも、ここで登録し直してから送る。
      await PushService.registerForCurrentUser();
      await Repo.sendTestPush();
      if (mounted) {
        showSnack(context, 'テスト通知を送信しました', kind: SnackKind.success);
      }
    } catch (e) {
      // 端末側で登録に失敗した理由があれば添える（サーバーの文言だけでは原因が分からない）。
      // 通信できないときなどは同じ文言になるので、重ねて出さない。
      final reason = PushService.lastError;
      final message = friendlyError(e);
      final msg = reason == null || reason == message
          ? message
          : '$message\n$reason';
      final off = NotificationPrimer.status.value != NotifPermission.allowed;
      if (mounted) {
        showSnack(
          context,
          msg,
          kind: SnackKind.error,
          actionLabel: off ? '通知をオンにする' : null,
          onAction: off ? _enableNotifications : null,
        );
      }
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  /// 通知をオンにする（まだ聞いていなければ説明→OSの許可、拒否済みなら端末の設定を開く）。
  /// 説明で「あとで」を選んだ人や、OS で一度断った人が、ここから戻せるようにする。
  Future<void> _enableNotifications() async {
    if (_enablingNotif) return;
    HapticFeedback.selectionClick();
    setState(() => _enablingNotif = true);
    try {
      final p = await NotificationPrimer.enable(context);
      if (mounted && p == NotifPermission.allowed) {
        showSnack(context, '通知をオンにしました', kind: SnackKind.success);
      }
    } finally {
      if (mounted) setState(() => _enablingNotif = false);
    }
  }

  /// 通知対象（すべて / ★1〜2のみ）を切り替える。
  /// バナー・未読バッジ・通知タブ・リモートpushのすべてに共通で効く。
  /// サーバーに保存できなければスイッチを元に戻す（画面と実際に届く通知を食い違わせない）。
  Future<void> _setNotifScope(bool lowOnly) async {
    if (_savingScope) return;
    final prev = _notifScope;
    final next = lowOnly ? NotifScope.low : NotifScope.all;
    HapticFeedback.selectionClick();
    setState(() {
      _notifScope = next;
      _savingScope = true;
    });
    final ok = await NotifStore.setScope(next);
    if (!mounted) return;
    setState(() {
      _savingScope = false;
      if (!ok) _notifScope = prev;
    });
    if (!ok) {
      showSnack(context, '通知設定を保存できませんでした。通信環境をご確認のうえ、もう一度お試しください。',
          kind: SnackKind.error);
    }
  }

  Future<void> _open(Widget screen) async {
    // 戻ったあとの読み直しは AppEvents から届く（連携・アプリ・購入のどれも）。
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen));
  }

  Future<void> _refreshFromStores() async {
    if (_refreshing) return;
    final apps = _data?.apps;
    if (apps != null && apps.isEmpty) {
      showSnack(
        context,
        '監視するアプリがまだありません。先にアプリを追加してください。',
        actionLabel: 'アプリを追加',
        onAction: () => _open(const AppEditScreen()),
      );
      return;
    }
    setState(() => _refreshing = true);
    PollOutcome? outcome;
    try {
      outcome = await Repo.refreshFromStores();
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
    // 中身を見て出し分ける（一部のアプリで失敗しても、サーバーは成功として返すため）。
    if (outcome != null && mounted) {
      await showPollOutcome(
        context,
        outcome,
        googlePlay: (apps ?? const []).any((a) => a.store == 'googleplay'),
      );
    }
  }

  /// 規約・ポリシー等をアプリ内ブラウザで開く。Web(Next.js)側で公開しているページ。
  ///
  /// APIのURL（開発中はLANのIPを指すことがある）ではなく WEB_URL を使う。
  /// 規約ページがリンク切れだとストア審査で落ちるため。
  Future<void> _openLegal(String path) async {
    if (!AppConfig.hasWeb) {
      showSnack(context, 'ページを開けませんでした', kind: SnackKind.error);
      return;
    }
    final uri = Uri.parse('${AppConfig.webUrl}$path');
    final ok = await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    if (!ok && mounted) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 問い合わせ（メールアプリを開く）。有料サービスにサポート導線が無いのは避ける。
  Future<void> _contact() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      // queryParameters を使うと空白が「+」になり、メールアプリで件名が
      // 「RevPilot+お問い合わせ」と出る。%20 になるよう自分でエンコードする。
      query: 'subject=${Uri.encodeComponent('RevPilot お問い合わせ')}'
          '&body=${Uri.encodeComponent(_supportBody())}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        showSnack(context, '$_supportEmail までご連絡ください',
            kind: SnackKind.info);
      }
    }
  }

  /// 問い合わせメールの本文の下書き。
  /// どのアカウント・どの版かが分からないと本人を特定できず、やり取りが増える
  /// （Apple の「メールを非公開」で登録した人は、普段のアドレスから送ってくるので特に）。
  String _supportBody() {
    final user = Supabase.instance.client.auth.currentUser;
    final plan = _data?.billing.plan;
    return [
      '（お問い合わせ内容をご記入ください）',
      '',
      '',
      '',
      '---- 以下は調査に使います。消さずにお送りください ----',
      if (user?.email != null && user!.email!.isNotEmpty)
        'アカウント: ${user.email}',
      if (user != null) 'ユーザーID: ${user.id}',
      if (user != null) 'ログイン方法: ${_providerLabel(user)}',
      if (plan != null) 'プラン: ${planLabel(plan)}',
      if (_versionLabel != null) 'アプリ: $_versionLabel',
      'OS: ${Platform.isIOS ? 'iOS' : Platform.isAndroid ? 'Android' : Platform.operatingSystem}'
          ' ${Platform.operatingSystemVersion}',
    ].join('\n');
  }

  /// 登録に使ったログイン方法（別の端末でどの方法を使ったか思い出せるように）。
  static String _providerLabel(User user) =>
      switch (user.appMetadata['provider']) {
        'apple' => 'Apple',
        'google' => 'Google',
        'email' => 'メールアドレス',
        final String other => other,
        _ => '不明',
      };

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
      // 通知先の解除は**サインアウトの前**に行う。
      // 後だと認証が切れていて自分の端末を外せず、
      // 同じ端末を使う次の利用者にこのアカウント宛の通知が届き続ける。
      await PushService.unregister();
      await SocialAuth.signOutProviders();
      await Supabase.instance.client.auth.signOut();
    }
  }

  /// 有料プラン・トライアル中（または確認できない）なら、削除の前にストアでの解約を案内する。
  /// アカウントを削除してもストアの契約は続き、請求が止まらないため。
  /// 戻り値は削除へ進むか。
  Future<bool> _confirmSubscriptionBeforeDelete(BillingStatus? billing) async {
    // 契約したストアで案内する（Google Play で契約して iPhone から削除する人もいる）。
    // 分からなければこの端末のストア。
    final store = billing?.store ?? deviceBillingStore;
    final apple = store == BillingStore.apple;
    final trial = billing != null && billing.inTrial;
    final end = billing?.periodEnd?.toLocal();
    final status = billing == null
        ? 'ご契約状況を確認できませんでした。有料プランをご契約中の場合はご注意ください。'
        : trial
            ? '${planLabel(billing.plan)}の無料トライアル中です'
                '${end == null ? '' : '（${end.month}月${end.day}日まで）'}。'
            : '${planLabel(billing.plan)}プランをご契約中です。';
    final subscription =
        apple ? 'App Store のサブスクリプション' : 'Google Play の定期購入';
    final where = apple
        ? (Platform.isIOS
            ? 'iPhone の「設定 > 一番上のお名前 > サブスクリプション」'
            : 'ご契約の iPhone などの「設定 > 一番上のお名前 > サブスクリプション」')
        : (Platform.isAndroid
            ? 'Google Play ストアの「お支払いと定期購入 > 定期購入」'
            : 'Google Play のウェブサイト（play.google.com）の「お支払いと定期購入 > 定期購入」');
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('先にサブスクリプションを解約してください'),
        content: SingleChildScrollView(
          child: Text(
            '$status\n\n'
            'アカウントを削除しても、$subscriptionは解約されません。'
            '${trial ? '解約しないと、無料期間のあとに料金が請求されます。' : '解約しないと、料金の請求が続きます。'}\n\n'
            '「サブスクリプションを管理」から解約してから、削除してください。'
            '$whereからも解約できます。',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('キャンセル')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: ctx.dangerTextC),
            onPressed: () => Navigator.pop(ctx, 'proceed'),
            child: const Text('解約済みなので削除へ進む'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'manage'),
            child: const Text('サブスクリプションを管理'),
          ),
        ],
      ),
    );
    if (choice == 'manage' && mounted) {
      // 管理シートで解約された可能性があるので、閉じたら契約状況を読み直す。
      if (await openSubscriptionManagement(context, store: store)) _load();
      return false;
    }
    return choice == 'proceed';
  }

  /// アカウントの完全削除（退会）。App Store ガイドライン 5.1.1(v) の必須要件。
  Future<void> _deleteAccount() async {
    if (_deleting) return;
    final billing = _data?.billing;
    final maySubscribe =
        billing == null || billing.plan != 'free' || billing.inTrial;
    if (maySubscribe) {
      if (!await _confirmSubscriptionBeforeDelete(billing) || !mounted) return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アカウントを削除'),
        content: Text(
          'アカウントと、連携アプリ・取得したレビュー・返信・ストア連携などの'
          'すべてのデータが完全に削除されます。この操作は取り消せません。'
          '${maySubscribe ? '\n\nストアのサブスクリプションは、この操作では解約されません。' : ''}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await Repo.deleteAccount();
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.statusCode == 401) {
        // ログインが切れている（前回の削除がサーバーでは終わっていた場合も含む）。
        // この端末からはもう操作できないので、ログインし直してもらう。
        showSnack(context,
            'アカウントはすでに削除されたか、ログインの有効期限が切れています。もう一度ログインしてご確認ください。',
            kind: SnackKind.error);
        await _signOutLocally();
        return;
      }
      setState(() => _deleting = false);
      showError(context, e);
      return;
    }
    HapticFeedback.heavyImpact();
    // 通知先（device_tokens）はアカウントと一緒にサーバーで消えるので、外し直さない
    // （削除の前に外すと、削除に失敗したときに通知まで止まってしまう）。
    // スナックバーはアプリ全体で共有しているので、ログイン画面に切り替わっても表示される。
    if (mounted) {
      showSnack(context, 'アカウントを削除しました。ご利用ありがとうございました。',
          kind: SnackKind.success);
    }
    await _signOutLocally();
    // 以降は認証状態の変化でログイン画面へ遷移する。
  }

  /// 削除済みユーザーはサーバーでのサインアウトが失敗し得るため、端末のセッションだけを確実に破棄する。
  Future<void> _signOutLocally() async {
    await SocialAuth.signOutProviders();
    await Supabase.instance.client.auth.signOut(scope: SignOutScope.local);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: RefreshIndicator(
        onRefresh: _pullToRefresh,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    final data = _data;
    if (data == null) {
      if (_loadError == null) {
        return const Center(child: CircularProgressIndicator());
      }
      // 一度も読めていない：「Free・0件・未連携」と出さず、失敗したことと再試行を出す。
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 80),
          EmptyState(
            icon: Icons.wifi_off_rounded,
            title: '読み込みに失敗しました',
            subtitle: friendlyError(_loadError!),
            action: FilledButton.tonal(
              onPressed: _loading ? null : _load,
              child: const Text('再試行'),
            ),
          ),
        ],
      );
    }
    final user = Supabase.instance.client.auth.currentUser;
    final email = user?.email ?? '';
    final plan = data.billing.plan;
    final apps = data.apps;
    final broken = apps.where((a) => a.hasPollError).length;
    final polled = apps
        .map((a) => a.lastPolledAt)
        .whereType<DateTime>()
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (_loadError != null) _staleBanner(_loadError!),

        // アカウント
        _card(
          title: 'アカウント',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('メール', email),
              if (user != null) ...[
                const SizedBox(height: 6),
                _kv('ログイン', _providerLabel(user)),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Text('プラン', style: TextStyle(color: context.subtleC)),
                  const SizedBox(width: 12),
                  _planBadge(plan),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _open(const PlanScreen()),
                    child: const Text('変更'),
                  ),
                ],
              ),
              if (data.billing.trialLine != null) ...[
                const SizedBox(height: 4),
                Text(data.billing.trialLine!,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: context.successTextC)),
              ],
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
            subtitle: broken > 0
                ? '${apps.length}件・$broken件で取得エラー'
                : '${apps.length}件',
            warn: broken > 0,
            onTap: () => _open(const AppsScreen()),
          ),
          _divider(),
          _navTile(
            icon: Icons.link,
            title: 'ストア連携',
            subtitle: _connectedLabel(data.connected),
            onTap: () => _open(const ConnectStoreScreen()),
          ),
          _divider(),
          _navTile(
            icon: Icons.workspace_premium_outlined,
            title: 'プラン',
            subtitle: planLabel(plan),
            onTap: () => _open(const PlanScreen()),
          ),
          _divider(),
          // 機種変更・再インストールのあとに探されやすいので、課金画面の奥だけでなくここにも置く。
          // 復元できたプランは AppEvents.planChanged で届く。
          _navTile(
            icon: Icons.restore_rounded,
            title: '購入を復元',
            subtitle: '機種変更や再インストールのあとにお使いください',
            onTap: () => openPlanScreen(context, restore: true),
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
              !AppConfig.hasApi
                  ? 'サーバー接続が必要です'
                  : polled == null
                      ? '各ストアの新着を今すぐ取り込みます'
                      : '最終取得 ${fetchedAgo(polled)}・各ストアの新着を今すぐ取り込みます',
              style: const TextStyle(fontSize: 12),
            ),
            onTap: _refreshing ? null : _refreshFromStores,
          ),
        ]),
        const SizedBox(height: 16),

        // 通知
        _sectionLabel('通知'),
        _navCard([
          ValueListenableBuilder<NotifPermission?>(
            valueListenable: NotificationPrimer.status,
            builder: (context, permission, _) => Column(
              children: [
                if (permission != null) ...[
                  _permissionTile(permission),
                  _divider(),
                ],
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_active_outlined),
                  title: const Text('★1〜2のときだけ通知する'),
                  subtitle: Text(
                    permission != null && permission != NotifPermission.allowed
                        ? '通知が許可されていないため、今は届きません'
                        : _notifScope == NotifScope.low
                            ? '★1〜2のレビューだけお知らせします'
                            : 'すべての新着レビューをお知らせします',
                    style: TextStyle(
                        fontSize: 12,
                        color: permission != null &&
                                permission != NotifPermission.allowed
                            ? context.warningTextC
                            : null),
                  ),
                  value: _notifScope == NotifScope.low,
                  onChanged: _setNotifScope,
                ),
              ],
            ),
          ),
          // 届くかどうかは実際に送ってみないと分からない。
          // 通知の許可を拒否している・鍵の設定が誤っている場合は
          // どれも無言で失敗するので、確認手段を UI に置く。
          if (PushService.configured) ...[
            _divider(),
            _navTile(
              icon: Icons.notifications_none,
              title: _sendingTest ? '送信中…' : 'テスト通知を送る',
              subtitle: 'この端末に通知が届くか確認します',
              onTap: _sendingTest ? () {} : _sendTestPush,
            ),
          ],
        ]),
        const SizedBox(height: 16),

        // 情報・法務
        _sectionLabel('情報・サポート'),
        _navCard([
          _navTile(
            icon: Icons.mail_outline,
            title: 'お問い合わせ',
            subtitle: _supportEmail,
            onTap: _contact,
          ),
          _divider(),
          _navTile(
            icon: Icons.sell_outlined,
            title: '料金プラン',
            subtitle: '',
            onTap: () => _openLegal('/pricing'),
          ),
          _divider(),
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
          onPressed: _deleting ? null : _signOut,
          icon: const Icon(Icons.logout, size: 18),
          label: const Text('ログアウト'),
          // 文字に使うので、塗り用の danger ではなく文字用の濃さにする（ダークでも 4.5:1 以上）。
          style: OutlinedButton.styleFrom(
            foregroundColor: context.dangerTextC,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 12),
        // アカウント削除（退会）。Apple審査で必須の導線。
        TextButton.icon(
          onPressed: _deleting ? null : _deleteAccount,
          icon: _deleting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.delete_forever_outlined, size: 18),
          label: Text(_deleting ? '削除しています…' : 'アカウントを削除'),
          style: TextButton.styleFrom(
            foregroundColor: context.dangerTextC,
            minimumSize: const Size.fromHeight(44),
          ),
        ),
        if (_versionLabel != null) ...[
          const SizedBox(height: 12),
          Text('バージョン $_versionLabel',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.subtleC)),
        ],
      ],
    )
        .animate()
        .fadeIn(duration: 300.ms)
        .slideY(begin: 0.03, end: 0, curve: Curves.easeOut);
  }

  /// 読み直しに失敗したとき（前回の内容は出したまま）。
  Widget _staleBanner(Object error) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: StaleBanner(
        message: '最新の情報を取得できませんでした。${friendlyError(error)}',
        onRetry: _loading ? null : _load,
      ),
    );
  }

  /// OS の通知の許可状態と、オンにする操作。
  Widget _permissionTile(NotifPermission p) {
    final ios = Platform.isIOS;
    final (IconData icon, String title, String subtitle, String? action) =
        switch (p) {
      NotifPermission.allowed => (
          Icons.notifications_active_rounded,
          'プッシュ通知：オン',
          'この端末に新着レビューをお知らせします',
          null,
        ),
      NotifPermission.undecided => (
          Icons.notifications_off_outlined,
          'プッシュ通知がオフです',
          '★1〜2のレビューにすぐ気づけるよう、通知をオンにしましょう',
          '通知をオンにする',
        ),
      NotifPermission.denied => (
          Icons.notifications_off_outlined,
          '通知が許可されていません',
          ios
              ? 'iPhoneの設定アプリで、RevPilot の通知を許可してください'
              : '端末の設定で、RevPilot の通知を許可してください',
          // iPhone は設定アプリを開く。Android はもう一度聞き、出せなければ設定の場所を案内する。
          ios ? '設定を開く' : '通知を許可する',
        ),
    };
    final on = p == NotifPermission.allowed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  color: on ? AppTheme.success : context.warningTextC),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, height: 1.4, color: context.subtleC)),
                  ],
                ),
              ),
            ],
          ),
          if (action != null)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: FilledButton.tonal(
                  onPressed: _enablingNotif ? null : _enableNotifications,
                  child: Text(action),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _connectedLabel(List<String>? connected) {
    if (connected == null) return '確認できませんでした';
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
                color: context.subtleC)),
      );

  Widget _navCard(List<Widget> children) => Card(
        child: Column(children: children),
      );

  Widget _navTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool warn = false,
  }) =>
      ListTile(
        leading: Icon(icon, color: AppTheme.primary),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: warn ? FontWeight.w600 : null,
                    color: warn ? context.dangerTextC : null)),
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
    final label = Text(k, style: TextStyle(color: context.subtleC));
    // 見出しの欄は 68pt 固定なので、文字を大きくすると「ログイン」が折り返してしまう。
    // 収まらない大きさでは、見出しを値の上に置く。
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    if (scale > 1.2) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [label, Text(v)],
      );
    }
    return Row(
      children: [
        SizedBox(width: 68, child: label),
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
          color: isPaid ? context.accentTextC : context.subtleC,
        ),
      ),
    );
  }
}

class _SettingsData {
  final BillingStatus billing;
  final List<AppRow> apps;

  /// 連携済みのストア。確認できなかったら null。
  final List<String>? connected;
  _SettingsData({
    required this.billing,
    required this.apps,
    required this.connected,
  });
}
