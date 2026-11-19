import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'theme.dart';

/// アップデートのお願いとメンテナンスの知らせ（Firebase Remote Config）。
///
/// 出したあとのアプリに、課金やストア連携を壊す不具合が見つかっても、
/// これまでは古い版を使い続ける人を止める手段がなかった。
/// コンソールで値を変えるだけで、アプリを出し直さずに次のことができる。
///
/// | キー | 意味 |
/// |---|---|
/// | `ios_min_version` / `android_min_version` | これより古い版は使えなくし、アップデートを求める |
/// | `ios_latest_version` / `android_latest_version` | これより古い版には、起動時に 1 回だけすすめる（閉じられる） |
/// | `update_message` | 上の 2 つの画面に添える一言（例: 「購入の不具合を直しました」） |
/// | `maintenance_message` | 空でなければ、メンテナンスの画面でアプリ全体をふさぐ |
/// | `ios_store_url` | App Store のページ（未設定なら [AppConfig.appStoreId] から作る） |
///
/// 空や版の形でない値は「求めない」と扱うので、設定を誤ってもアプリは止まらない。
/// Firebase の設定が無い・取得に失敗したときも、何もしない。
enum AppUpdateStatus { upToDate, recommended, required }

/// 版（`1.2.3` など）を数の並びにする。版の形でなければ null。
List<int>? parseVersion(String value) {
  final m = RegExp(r'^\s*(\d+(?:\.\d+)*)').firstMatch(value);
  if (m == null) return null;
  return m.group(1)!.split('.').map(int.parse).toList();
}

/// a が b より古ければ負、同じなら 0、新しければ正。足りない桁は 0 とみなす。
int compareVersions(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 今の版と、求める最低の版・最新の版から状態を決める。
AppUpdateStatus decideUpdate({
  required String current,
  required String min,
  required String latest,
}) {
  final cur = parseVersion(current);
  if (cur == null) return AppUpdateStatus.upToDate;
  final minV = parseVersion(min);
  if (minV != null && compareVersions(cur, minV) < 0) {
    return AppUpdateStatus.required;
  }
  final latestV = parseVersion(latest);
  if (latestV != null && compareVersions(cur, latestV) < 0) {
    return AppUpdateStatus.recommended;
  }
  return AppUpdateStatus.upToDate;
}

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.status = AppUpdateStatus.upToDate,
    this.message = '',
    this.maintenance = '',
    this.storeUrl,
  });

  final AppUpdateStatus status;
  final String message;
  final String maintenance;
  final Uri? storeUrl;
}

class AppUpdate {
  AppUpdate._();

  static final state = ValueNotifier(const AppUpdateState());
  static bool _started = false;
  static DateTime? _lastFetch;
  static StreamSubscription<RemoteConfigUpdate>? _realtime;

  /// Firebase を初期化したあとに一度だけ呼ぶ。待たずに戻る。
  static void start() {
    if (_started || Firebase.apps.isEmpty) return;
    _started = true;
    unawaited(_load());
  }

  /// 裏から戻ったときに取り直す（1 時間に 1 回まで）。
  static void refreshIfStale() {
    if (!_started) return;
    final last = _lastFetch;
    if (last != null && DateTime.now().difference(last).inHours < 1) return;
    unawaited(_load());
  }

  static Future<void> _load() async {
    try {
      final rc = FirebaseRemoteConfig.instance;
      await rc.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 10),
          minimumFetchInterval:
              kDebugMode
                  ? const Duration(minutes: 1)
                  : const Duration(hours: 1),
        ),
      );
      await rc.setDefaults(const {
        'ios_min_version': '',
        'ios_latest_version': '',
        'android_min_version': '',
        'android_latest_version': '',
        'update_message': '',
        'maintenance_message': '',
        'ios_store_url': '',
      });
      // 前回取れた値で先に判定し、取り直した値で上書きする（起動を待たせない）。
      await rc.activate();
      await _apply(rc);
      _lastFetch = DateTime.now();
      await rc.fetchAndActivate();
      await _apply(rc);
      _realtime ??= rc.onConfigUpdated.listen((_) async {
        await rc.activate();
        await _apply(rc);
      }, onError: (_) {});
    } catch (e) {
      if (kDebugMode) debugPrint('[update] remote config failed: $e');
    }
  }

  static Future<void> _apply(FirebaseRemoteConfig rc) async {
    final info = await PackageInfo.fromPlatform();
    final ios = Platform.isIOS;
    final status = decideUpdate(
      current: info.version,
      min: rc.getString(ios ? 'ios_min_version' : 'android_min_version'),
      latest: rc.getString(
        ios ? 'ios_latest_version' : 'android_latest_version',
      ),
    );
    state.value = AppUpdateState(
      status: status,
      message: rc.getString('update_message').trim(),
      maintenance: rc.getString('maintenance_message').trim(),
      storeUrl: _storeUrl(rc.getString('ios_store_url').trim()),
    );
  }

  static Uri? _storeUrl(String iosOverride) {
    if (Platform.isAndroid) {
      return Uri.parse(
        'https://play.google.com/store/apps/details?id=${AppConfig.iosBundleId}',
      );
    }
    if (iosOverride.isNotEmpty) return Uri.tryParse(iosOverride);
    if (AppConfig.appStoreId.isNotEmpty) {
      return Uri.parse(
        'https://apps.apple.com/jp/app/id${AppConfig.appStoreId}',
      );
    }
    return null;
  }
}

/// アプリ全体を包み、アップデートが必要なとき・メンテナンス中は画面をふさぐ。
/// すすめるだけのときは、起動後に 1 回だけ下から案内を出す。
///
/// `MaterialApp(builder:)` で使う。ふさいでいるあいだも下の画面は消さずに隠すだけ
/// （購入の途中などの処理は最後まで動く）。
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate>
    with WidgetsBindingObserver {
  bool _offered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdate.state.addListener(_onChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppUpdate.state.removeListener(_onChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) AppUpdate.refreshIfStale();
  }

  void _onChanged() {
    final v = AppUpdate.state.value;
    if (v.status == AppUpdateStatus.required || v.maintenance.isNotEmpty) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (mounted) setState(() {});
    if (v.status == AppUpdateStatus.recommended && !_offered) {
      _offered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _offer(v));
    }
  }

  Future<void> _offer(AppUpdateState v) async {
    // Navigator 自身の context では、その Navigator が見つからないので overlay の context を使う。
    final ctx = widget.navigatorKey.currentState?.overlay?.context;
    if (ctx == null || v.storeUrl == null) return;
    await showModalBottomSheet<void>(
      context: ctx,
      showDragHandle: true,
      builder:
          (c) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '新しいバージョンがあります',
                    style: Theme.of(c).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    v.message.isNotEmpty
                        ? v.message
                        : 'アップデートすると、最新の機能と修正をお使いいただけます。',
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(c).pop();
                      _openStore(ctx, v.storeUrl!);
                    },
                    child: const Text('アップデートする'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(c).pop(),
                    child: const Text('あとで'),
                  ),
                ],
              ),
            ),
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = AppUpdate.state.value;
    final Widget? cover =
        v.maintenance.isNotEmpty
            ? _Blocker(
              icon: Icons.construction_rounded,
              title: 'ただいまメンテナンス中です',
              body: v.maintenance,
            )
            : v.status == AppUpdateStatus.required
            ? _Blocker(
              icon: Icons.system_update_rounded,
              title: 'アップデートをお願いします',
              body:
                  v.message.isNotEmpty
                      ? v.message
                      : 'このバージョンはご利用いただけなくなりました。最新のバージョンにアップデートしてください。',
              storeUrl: v.storeUrl,
            )
            : null;
    return Stack(
      children: [
        // ふさいでいるあいだは下の画面を読み上げ・操作の対象から外す。
        ExcludeSemantics(
          excluding: cover != null,
          child: AbsorbPointer(absorbing: cover != null, child: widget.child),
        ),
        if (cover != null) Positioned.fill(child: cover),
      ],
    );
  }
}

Future<void> _openStore(BuildContext context, Uri url) async {
  final ok = await launchUrl(
    url,
    mode: LaunchMode.externalApplication,
  ).catchError((_) => false);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('ストアを開けませんでした。ストアのアプリで RevPilot を検索して、アップデートしてください。'),
      ),
    );
  }
}

class _Blocker extends StatelessWidget {
  const _Blocker({
    required this.icon,
    required this.title,
    required this.body,
    this.storeUrl,
  });

  final IconData icon;
  final String title;
  final String body;
  final Uri? storeUrl;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: context.bgC,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: AppTheme.primary),
                const SizedBox(height: 16),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.subtleC, height: 1.6),
                ),
                if (storeUrl != null) ...[
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => _openStore(context, storeUrl!),
                    child: const Text('アップデートする'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
