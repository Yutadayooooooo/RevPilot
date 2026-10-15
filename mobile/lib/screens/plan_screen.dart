import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data.dart';
import '../iap.dart';
import '../models.dart' show clipMessage;
import '../plan_catalog.g.dart';
import '../theme.dart';
import '../ui.dart';
import '../widgets.dart';

/// どの「壁」から課金画面を開いたか。画面上部の見出しをその理由に合わせる。
///
/// 一般論の「Proはおすすめです」より、今まさに困っていることへの答えを先に見せる方が
/// 納得して選んでもらえる（＝購入後の「思っていたのと違う」も減る）。
enum PaywallReason { general, history, bulk, aiQuota, apps, topics }

/// 課金画面へ遷移する。どの画面からでもこれを使う。
/// [restore] を true にすると、開いてすぐ「購入を復元」を始める（設定画面の「購入を復元」用）。
Future<void> openPlanScreen(
  BuildContext context, {
  PaywallReason reason = PaywallReason.general,
  bool restore = false,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => PlanScreen(reason: reason, restoreOnOpen: restore),
  ),
);

/// Free の上限に当たったエラーなら、課金画面への導線付きで知らせる。
/// それ以外のエラーは通常のエラー表示（英語の技術的な文面は出さない）。
void showErrorWithUpgrade(
  BuildContext context,
  Object error, {
  required PaywallReason reason,
}) {
  if (error is! ApiException || !error.isPlanLimit) {
    showError(context, error);
    return;
  }
  // showSnack は操作ボタン付きでも時間で閉じる（SnackBar の既定のままだと閉じなくなる）。
  showSnack(
    context,
    error.message,
    kind: SnackKind.error,
    actionLabel: 'プランを見る',
    onAction: () => openPlanScreen(context, reason: reason),
    duration: const Duration(seconds: 8),
  );
}

/// サブスクリプションの管理画面（解約・プランや周期の変更）を開く。
///
/// アプリ内課金の契約は各ストアの管理下にあり、こちらからは解約できない。
/// 必ずストアの管理画面へ案内する（以前はStripeのポータルを開こうとして、
/// IAP契約者には「Stripe顧客が未作成です」というエラーが出ていた）。
///
/// iOS はアプリ内の StoreKit シート（AppStore.showManageSubscriptions）を優先する。
/// apps.apple.com のURLはアプリの外へ出てしまううえ、Sandbox の購読は表示されない
/// （テスト時に「App Storeが開くだけで何も起きない」状態になっていた）。
/// シートを出せなかったときだけURLにフォールバックする。
///
/// [store] は契約を請求しているストア（分からなければ null で、この端末のストア）。
/// Google Play で契約した人が iPhone で開いたときなどは、この端末ではなくそのストアの
/// 管理ページを開く（この端末のストアには契約が無く、解約できないため）。
///
/// 戻り値は、アプリ内のシートを表示して閉じたか（true なら、閉じた時点でプランを読み直すとよい）。
/// 設定画面のアカウント削除など、課金画面の外からも使う。
Future<bool> openSubscriptionManagement(
  BuildContext context, {
  BillingStore? store,
}) async {
  HapticFeedback.lightImpact();
  final target = store ?? deviceBillingStore;
  if (Platform.isIOS && target == BillingStore.apple) {
    try {
      final shown = await _subscriptionsChannel.invokeMethod<bool>(
            'showManageSubscriptions',
          ) ??
          false;
      if (shown) return true;
    } catch (_) {}
  }
  final uri = target == BillingStore.apple
      ? Uri.parse('https://apps.apple.com/account/subscriptions')
      : Uri.parse('https://play.google.com/store/account/subscriptions');
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok && context.mounted) {
    showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
  }
  return false;
}

/// この端末で購入するときのストア（iOS は App Store、Android は Google Play）。
BillingStore get deviceBillingStore =>
    Platform.isIOS ? BillingStore.apple : BillingStore.google;

/// ios/Runner/AppDelegate.swift のサブスク管理シート用チャンネル。
const _subscriptionsChannel = MethodChannel('revpilot/subscriptions');

/// 問い合わせ先（設定画面の「お問い合わせ」と同じ）。
const _supportEmail = 'revpilot.hq@gmail.com';

/// プランの上下。アップグレードかダウングレードかで、切り替わる時期と文言が変わる。
const _planRank = {'free': 0, 'pro': 1, 'max': 2, 'team': 3};
int _rankOf(String plan) => _planRank[plan] ?? 0;

String _periodLabel(BillingPeriod p) => p == BillingPeriod.yearly ? '年額' : '月額';

String _md(DateTime d) => DateFormat('M月d日').format(d.toLocal());

/// プランの確認・変更。
///
/// 【決済はアプリ内課金のみ】
/// iOS は App Store Review Guideline 3.1.1、Android は Google Play の課金ポリシーにより、
/// アプリ内のデジタルコンテンツのサブスクは各ストアの課金を使う必要があり、
/// 外部の決済ページへ誘導することはできない。
/// 以前は StoreKit の商品取得に失敗したとき Stripe Checkout をアプリ内ブラウザで開く
/// フォールバックがあったが、これは確実にリジェクトされるため撤去した。
/// 商品を取得できない場合は購入導線そのものを出さない。
///
/// 【画面の考え方】
///   - 冒頭で「なぜ必要か」を一文で示す（開いた理由に合わせて文言を変える）。
///   - 年額を初期表示にする。年額は利用者にとって安く、解約の判断が年1回になり継続率も上がる。
///   - 無料トライアルは対象者にだけ見せ、その後いくら課金されるか・無料期間中の解約なら
///     料金がかからないことをボタン直下に書く（終了前の通知は送らず、購入時に伝えきる）
///     （App Store 3.1.2 は請求額を最も目立つ価格表示にすることを求めている）。
///   - 有料会員には、今の周期（月額・年額）と次回の更新日を見せ、変更がいつ切り替わるかを
///     押す前に書く（Apple はダウングレードと周期の変更を次回の更新日から適用する）。
class PlanScreen extends StatefulWidget {
  const PlanScreen({
    super.key,
    this.reason = PaywallReason.general,
    this.restoreOnOpen = false,
  });

  final PaywallReason reason;

  /// 開いたらすぐ「購入を復元」を始める。
  final bool restoreOnOpen;

  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

/// 購入を始めた時点の「どこからどこへ」。完了後の文言を、アップグレード・
/// ダウングレード・周期の変更で分けるのに使う。
class _Change {
  const _Change({
    required this.fromPlan,
    required this.toPlan,
    required this.toPeriod,
    this.renewsAt,
  });

  final String fromPlan;
  final String toPlan;
  final BillingPeriod toPeriod;

  /// 変更前の契約の次回更新日（分からなければ null）。
  final DateTime? renewsAt;
}

class _PlanScreenState extends State<PlanScreen> {
  String _plan = 'free';
  int _aiRepliesUsed = 0;
  String? _trialLine;
  bool _inTrial = false;
  DateTime? _periodEnd;

  /// 今の有料プランを請求しているストア（分からなければ null）。
  BillingStore? _store;
  bool _hasGooglePlay = false;
  bool _loading = true;
  bool _loaded = false;
  Object? _loadError;
  String? _busy;
  BillingPeriod _period = BillingPeriod.yearly;
  bool _periodTouched = false;

  final IapService _iap = IapService();
  bool _iapReady = false;

  /// ストアの商品を読み込み中。この間は「ご利用いただけません」を出さない
  /// （出すと、開くたびに一瞬だけ警告が見えて不安にさせる）。
  bool _iapLoading = IapService.platformSupported;
  Future<void>? _iapInit;

  /// 今の契約（ストアから読めて、サーバーのプランと一致したときだけ）。
  /// サーバーは周期を保存していないので、周期の表示と切り替えボタンはこれで決める。
  ActiveSubscription? _sub;

  _Change? _change;

  /// サーバーで確認中の購入/復元の件数。0 になるまでボタンは押せないままにする。
  int _confirming = 0;

  /// 「購入を復元」を押してから届いた復元の件数。
  int _restoreHits = 0;

  static final _purchasable =
      planCatalog.where((p) => !p.hidden && p.monthly != null).toList();

  @override
  void initState() {
    super.initState();
    Future.wait([_load(), _initIap()]).then((_) async {
      await _loadSubscription();
      if (mounted && widget.restoreOnOpen && _iap.canRestore) _restore();
    });
  }

  @override
  void dispose() {
    _iap.dispose();
    super.dispose();
  }

  /// 解約・変更の手続きをするストア（分からなければこの端末のストア）。
  BillingStore get _manageStore => _store ?? deviceBillingStore;

  /// 有料プランを、この端末とは別のストアで契約している
  /// （Google Play で契約して iPhone で開いた、またはその逆）。
  /// この端末で購入すると変更ではなく別の契約が新しく始まり、二重に請求されるので、
  /// 変更・切り替えのボタンは出さず、契約したストアでの手続きを案内する。
  bool get _otherStore =>
      _plan != 'free' && _store != null && _store != deviceBillingStore;

  String get _manageLabel => _manageStore == BillingStore.google
      ? '定期購入を管理・解約（Google Play）'
      : Platform.isIOS
          ? 'サブスクリプションを管理・解約'
          : 'サブスクリプションを管理・解約（App Store）';

  /// 次回の更新日（過ぎた日付は出さない）。
  DateTime? get _renewsAt {
    final d = _periodEnd;
    return d != null && d.isAfter(DateTime.now()) ? d : null;
  }

  String _fromNextRenewal(DateTime? d) =>
      d == null ? '次回の更新日から' : '次回の更新日（${_md(d)}）から';

  bool get _canRestore => !_iapLoading && _iap.canRestore;

  // ---- 読み込み ----

  /// 契約状況を読む。失敗しても読み込み中のまま止めない（再試行できるようにする）。
  Future<void> _load() async {
    // 見出しの出し分け用（Google Play のアプリがあるときだけ7日制限の話をする）。
    final hasGooglePlay = Repo.apps()
        .then((a) => a.any((x) => x.store == 'googleplay'))
        .catchError((_) => false);
    try {
      final s = await Repo.billingStatus();
      final gp = await hasGooglePlay;
      if (!mounted) return;
      setState(() {
        _plan = s.plan;
        _aiRepliesUsed = s.aiRepliesUsed;
        _trialLine = s.trialLine;
        _inTrial = s.trialLine != null;
        _periodEnd = s.periodEnd;
        _store = s.store;
        _hasGooglePlay = gp;
        _loaded = true;
        _loadError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  /// 引っ張って更新・再試行。商品の読み込みに失敗していれば、ストアも読み直す。
  Future<void> _refresh() async {
    await Future.wait([_load(), if (!_iapReady) _initIap()]);
    await _loadSubscription();
    if (mounted && _loaded && _loadError != null) {
      showError(context, _loadError!, prefix: 'プランを読み込めませんでした');
    }
  }

  Future<void> _retryLoad() async {
    setState(() => _loading = true);
    await _refresh();
  }

  /// ストアの商品を読み込む。重ねて呼ばれても1回にまとめる。
  Future<void> _initIap() {
    if (!IapService.platformSupported) return Future.value();
    return _iapInit ??= _doInitIap().whenComplete(() => _iapInit = null);
  }

  Future<void> _doInitIap() async {
    if (!_iapLoading && mounted) setState(() => _iapLoading = true);
    try {
      await _iap.init(
        onPurchased: _onPurchased,
        onError: _onPurchaseError,
        onCanceled: _onPurchaseCanceled,
        onPending: _onPurchasePending,
      );
    } catch (e) {
      _iap.lastError = '$e';
    }
    if (!mounted) return;
    setState(() {
      _iapLoading = false;
      _iapReady = _iap.isReady;
      // 年額を販売していない（ストアで未作成）なら月額を初期表示にする。
      if (_iapReady &&
          !_periodTouched &&
          !_purchasable.any(
            (p) => _iap.hasPeriod(p.key, BillingPeriod.yearly),
          )) {
        _period = BillingPeriod.monthly;
      }
    });
  }

  Future<void> _retryIap() async {
    HapticFeedback.lightImpact();
    await _initIap();
    await _loadSubscription();
  }

  /// 今の契約の周期（月額・年額）をストアから読む。
  Future<void> _loadSubscription() async {
    if (_plan == 'free') {
      if (_sub != null && mounted) setState(() => _sub = null);
      return;
    }
    final sub = await _iap.activeSubscription();
    if (!mounted) return;
    setState(() {
      // 端末のストアアカウントが別の契約を持っていることもあるので、プランが一致するときだけ使う。
      _sub = sub?.planKey == _plan ? sub : null;
      // 有料会員には、自分の周期の価格を初めから見せる。
      if (_sub != null && !_periodTouched) _period = _sub!.period;
    });
  }

  // ---- 購入・復元 ----

  /// 購入/復元が成立 → サーバーがストアに問い合わせて検証し、プランを確定する。
  /// 確認には最大45秒かかるので、終わるまでボタンは押せないままにする。
  /// 他のタブへは Repo が AppEvents.planChanged で知らせる。
  /// [change] は「もう一度反映する」で送り直すとき、最初の購入の向きを引き継ぐのに使う。
  Future<void> _onPurchased(IapResult result, {_Change? change}) async {
    if (result.restored) _restoreHits++;
    _confirming++;
    if (mounted && _busy == null) setState(() => _busy = 'confirm');
    change ??= _change;
    try {
      final confirmed =
          Platform.isIOS
              ? await Repo.confirmApplePurchase(
                productId: result.productId,
                transactionId: result.transactionId,
                verificationData: result.verificationData,
              )
              : await Repo.confirmGooglePurchase(
                productId: result.productId,
                purchaseToken: result.verificationData ?? '',
              );
      if (mounted) setState(() => _plan = confirmed.plan);
      // 次回の更新日・トライアルの終わり・周期を取り直す。
      await _load();
      await _loadSubscription();
      if (!mounted) return;
      // トライアル開始時は、いつまで無料か・それまでに解約すれば無料であることを
      // 閉じるまで残るダイアログで伝える（終了前の通知は送らないので、ここで見逃させない）。
      if (confirmed.inTrial && confirmed.expiresAt != null && !result.restored) {
        _showTrialStarted(confirmed);
      } else {
        showSnack(
          context,
          _successMessage(confirmed, result, change),
          kind: SnackKind.success,
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      if (mounted) _showConfirmFailed(result, e, change);
    } finally {
      _confirming--;
      _settle();
    }
  }

  /// 確認中のものが無ければ、ボタンを押せる状態に戻す。
  void _settle() {
    if (!mounted || _confirming > 0) return;
    setState(() {
      _busy = null;
      _change = null;
    });
  }

  /// 購入シートを閉じた。本人が止めたので、何も言わずに元へ戻す。
  void _onPurchaseCanceled() => _settle();

  /// 承認待ち（ファミリー共有の「承認と購入のリクエスト」、コンビニ払いなど）。
  /// 購入ストリームはこの画面を開いている間しか聞いていないので、
  /// 「自動で反映されます」とは書かず、「購入を復元」へ案内する。
  void _onPurchasePending() {
    _settle();
    if (!mounted) return;
    showSnack(
      context,
      Platform.isIOS
          ? '購入の承認待ちです。承認されたら、この画面の「購入を復元」を押すとプランに反映されます。'
          : 'お支払いの完了待ちです。完了したら、この画面の「購入を復元」を押すとプランに反映されます。',
      duration: const Duration(seconds: 8),
    );
  }

  void _onPurchaseError(Object error) {
    _settle();
    if (mounted) _showPurchaseError(error);
  }

  /// 購入の失敗を日本語で伝える（ストアの英語やスタックトレースは出さない）。
  void _showPurchaseError(Object error) {
    final raw = '$error'.toLowerCase();
    // StoreKit がキャンセルを例外で返すこともある。本人が止めたので何も出さない。
    if (raw.contains('usercancel') ||
        raw.contains('canceled') ||
        raw.contains('cancelled')) {
      return;
    }
    // 前回の取引が終わっていない（同じ商品の未完了の取引がある）、またはすでに購入済み。
    // どちらも復元すればサーバーで確認され、プランに反映される。
    final pending = raw.contains('duplicate_product');
    if (pending ||
        raw.contains('alreadyowned') ||
        raw.contains('already_owned')) {
      final nav = Navigator.of(context);
      showSnack(
        context,
        pending
            ? '前回の購入手続きが完了していません。「購入を復元」を押すと、プランに反映されます。'
            : 'すでに購入済みです。「購入を復元」を押すと、プランに反映されます。',
        kind: SnackKind.error,
        actionLabel: '購入を復元',
        // スナックバーはアプリ全体で共有なので、この画面を閉じたあとにも押せる。
        // そのときは課金画面を開き直して復元する（閉じた画面では購入の結果を受け取れない）。
        onAction: () => mounted
            ? _restore()
            : openPlanScreen(nav.context, restore: true),
        duration: const Duration(seconds: 10),
      );
      return;
    }
    var message = friendlyError(error);
    // 開発中は原因を追えるよう、元の文言も添える。
    if (kDebugMode) message = '$message\n[debug] ${clipMessage('$error', max: 160)}';
    showSnack(context, message, kind: SnackKind.error);
  }

  Future<void> _buy(String plan, BillingPeriod period) async {
    if (_busy != null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _busy = plan;
      _change = _Change(
        fromPlan: _plan,
        toPlan: plan,
        toPeriod: period,
        renewsAt: _renewsAt,
      );
    });
    try {
      await _iap.buy(plan, period);
      // 結果は購入ストリーム（_onPurchased / キャンセル / 承認待ち / 失敗）に届く。
    } catch (e) {
      if (!mounted) return;
      _settle();
      _showPurchaseError(e);
    }
  }

  /// 過去の購入を復元（Apple審査要件。Androidでも機種変更時に必要）。
  ///
  /// 結果は購入ストリーム（_onPurchased）に別に届き、有効な購入が無ければ何も届かない。
  /// 少し待っても届かなければ「見つからない」と伝える（何も起きないと壊れているように見える）。
  /// 届いたときは、サーバーでの確認が終わるまでスピナーを回したままにする。
  Future<void> _restore() async {
    if (!mounted || _busy != null) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = 'restore');
    _restoreHits = 0;
    try {
      await _iap.restore();
      // iOS は restore() から戻った少し後に結果が届く。
      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (e) {
      if (!mounted) return;
      _settle();
      showSnack(
        context,
        '購入を復元できませんでした。通信環境をご確認のうえ、再度お試しください。'
        '${kDebugMode ? '\n[debug] ${clipMessage('$e', max: 160)}' : ''}',
        kind: SnackKind.error,
      );
      return;
    }
    if (!mounted || _restoreHits > 0) return;
    _settle();
    showSnack(
      context,
      Platform.isIOS
          ? '復元できる購入が見つかりませんでした。購入時と同じ Apple アカウントでサインインしているかご確認ください。'
              '有効期限が切れた購入は復元できません。'
          : '復元できる購入が見つかりませんでした。購入時と同じ Google アカウントでログインしているかご確認ください。'
              '有効期限が切れた購入は復元できません。',
      duration: const Duration(seconds: 8),
    );
  }

  /// 購入完了の文言。Apple はアップグレードだけすぐに切り替え、ダウングレードと
  /// 周期の変更は次回の更新日から適用する（それまでは今のプランのまま）。
  String _successMessage(
    PurchaseConfirmation c,
    IapResult result,
    _Change? change,
  ) {
    final name = planLabel(c.plan);
    if (result.restored) return '購入を復元しました（$name）。';
    if (change == null) return '$nameのご購入をプランに反映しました。';
    if (change.fromPlan == 'free') return '$nameにアップグレードしました。';
    final target = '${planLabel(change.toPlan)}（${_periodLabel(change.toPeriod)}）';
    final upgrade = _rankOf(change.toPlan) > _rankOf(change.fromPlan);
    // サーバーが変更前のプランを返したとき（新しい契約がまだ始まっていない）も同じ扱い。
    if (Platform.isIOS && (!upgrade || c.plan != change.toPlan)) {
      return '変更を受け付けました。${_fromNextRenewal(change.renewsAt)}$targetに切り替わります。'
          'それまでは今のプランをご利用いただけます。';
    }
    return '$targetに切り替えました。';
  }

  void _showTrialStarted(PurchaseConfirmation c) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.card_giftcard_rounded, color: AppTheme.success),
        title: Text('${planLabel(c.plan)}の無料トライアルを開始しました'),
        content: Text(
          '${_md(c.expiresAt!)}までに解約すれば、料金はかかりません。'
          'この日はプラン画面でいつでも確認できます。\n\n'
          '解約は、この画面の「$_manageLabel」から行えます。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// ストアでの支払いは済んだのに、サーバーでの反映に失敗したとき。
  /// 消えるスナックバーではなく、次の手順（もう一度反映・購入を復元・お問い合わせ）を示す。
  Future<void> _showConfirmFailed(
    IapResult result,
    Object error,
    _Change? change,
  ) async {
    final status = error is ApiException ? error.statusCode : null;
    final account = Platform.isIOS ? 'Apple アカウント' : 'Google アカウント';
    final String title;
    final String body;
    var retryable = false;
    if (status == 409) {
      // 同じ購入が別の RevPilot アカウントに紐づいている。送り直しても結果は同じ。
      title = 'この購入は別のアカウントで使われています';
      body = 'この$accountでの購入は、別の RevPilot アカウントで使われています。'
          '購入したときと同じ方法でログインし直してください。';
    } else {
      // 通信の失敗・タイムアウト・サーバーやストアの一時的な不調は、送り直せば通ることがある。
      retryable =
          status == null || status == 401 || status == 408 || status == 429 || status >= 500;
      // 期限切れ・返金済みなど、サーバーが購入を無効と判断したときは「支払い済み」とは書かない。
      title = result.restored
          ? '購入を復元できませんでした'
          : (retryable ? 'お支払いは完了しています' : 'プランに反映できませんでした');
      final reason = friendlyError(error);
      body = result.restored
          ? '$reason\n\n'
              '${retryable ? '通信環境をご確認のうえ、［もう一度反映する］を押してください。' : ''}'
              '直らない場合はお問い合わせください。'
          : '${retryable ? 'プランへの反映に失敗しました。' : ''}$reason\n\n'
              '${retryable ? '通信環境をご確認のうえ、［もう一度反映する］を押してください。' : ''}'
              '直らない場合は、この画面の「購入を復元」をお試しいただくか、お問い合わせください。';
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'contact'),
            child: const Text('お問い合わせ'),
          ),
          if (retryable)
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'retry'),
              child: const Text('もう一度反映する'),
            )
          else
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('閉じる'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'retry') {
      _onPurchased(result, change: change);
    } else if (action == 'contact') {
      _contact(result);
    }
  }

  /// 購入の反映について問い合わせる（メールアプリを開く）。取引IDを添えて調べやすくする。
  Future<void> _contact(IapResult result) async {
    final subject = Uri.encodeComponent('RevPilot 購入の反映について');
    final body = Uri.encodeComponent(
      [
        'ご購入のプランと購入日時をお知らせください。',
        if (result.transactionId != null) '取引ID: ${result.transactionId}',
        '商品ID: ${result.productId}',
      ].join('\n'),
    );
    var ok = false;
    try {
      ok = await launchUrl(
        Uri.parse('mailto:$_supportEmail?subject=$subject&body=$body'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!ok && mounted) {
      showSnack(context, '$_supportEmail までご連絡ください', kind: SnackKind.info);
    }
  }

  Future<void> _openUrl(Uri uri, {bool external = false}) async {
    final mode =
        external ? LaunchMode.externalApplication : LaunchMode.inAppBrowserView;
    final ok = await launchUrl(uri, mode: mode);
    if (!ok) {
      final fallback = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!fallback && mounted) {
        showSnack(context, 'ブラウザを開けませんでした', kind: SnackKind.error);
      }
    }
  }

  Future<void> _openLegal(String path) async {
    if (!AppConfig.hasWeb) return;
    await _openUrl(Uri.parse('${AppConfig.webUrl}$path'));
  }

  /// 解約・プラン管理。シートで解約・変更された可能性があるので、閉じたらプランを読み直す。
  Future<void> _manage() async {
    final shown = await openSubscriptionManagement(context, store: _store);
    if (shown && mounted) await _refresh();
  }

  // ---- 価格の表示 ----
  //
  // ストアが返すローカライズ済みの価格を優先し、取れないときだけ定義の円価格を出す。

  static String _yen(int v) => '¥${NumberFormat('#,###').format(v)}';

  PlanPrice? _catalogPrice(PlanDef p, BillingPeriod period) =>
      period == BillingPeriod.yearly ? p.yearly : p.monthly;

  bool _hasPeriod(PlanDef p, BillingPeriod period) =>
      _iapReady
          ? _iap.hasPeriod(p.key, period)
          : _catalogPrice(p, period)?.productId != null;

  String _price(PlanDef p, BillingPeriod period) {
    final store = _iap.priceFor(p.key, period);
    final unit = period == BillingPeriod.yearly ? '年' : '月';
    if (store != null) return '$store / $unit';
    final c = _catalogPrice(p, period);
    return c == null ? '' : '${_yen(c.yen)} / $unit';
  }

  String? _monthlyEquivalent(PlanDef p) {
    final store = _iap.monthlyEquivalentFor(p.key);
    if (store != null) return store;
    final y = p.yearly;
    return y == null ? null : _yen((y.yen / 12).round());
  }

  int? _discountPct(PlanDef p) {
    final store = _iap.yearlyDiscountPct(p.key);
    if (store != null) return store;
    final m = p.monthly, y = p.yearly;
    if (m == null || y == null) return null;
    final pct = ((1 - y.yen / (m.yen * 12)) * 100).round();
    return pct > 0 ? pct : null;
  }

  bool _trial(PlanDef p, BillingPeriod period) =>
      _iapReady && p.trialLabel != null && _iap.trialAvailable(p.key, period);

  int? get _maxDiscountPct {
    final values = _purchasable.map(_discountPct).whereType<int>();
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('プラン')),
      body:
          _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: _refresh,
                child:
                    _loadError != null && !_loaded
                        ? _loadFailed()
                        : _content(),
              ),
    );
  }

  /// 契約状況を読めなかったとき。Free と決めつけて購入ボタンを出すと、
  /// 有料会員が二重に購入しようとしてしまうので、再試行だけを出す。
  Widget _loadFailed() {
    return ListView(
      children: [
        const SizedBox(height: 80),
        EmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'プランを読み込めませんでした',
          subtitle: friendlyError(_loadError!),
          action: FilledButton.tonal(
            onPressed: _retryLoad,
            child: const Text('再試行'),
          ),
        ),
      ],
    );
  }

  Widget _content() {
    final isPaid = _plan != 'free';
    final showYearlyToggle = _purchasable.any(
      (p) => _hasPeriod(p, BillingPeriod.yearly),
    );
    final free = planDef('free');
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (isPaid) _current() else _hero(),
        // 以前に買った人（機種変更・再インストール）が最初に探す場所に置く。
        if (!isPaid && _canRestore)
          Align(
            alignment: Alignment.centerRight,
            child: _restoreButton('以前に購入した方は「購入を復元」'),
          ),
        if (_busy == 'confirm') _confirmingNotice(),
        // 開発時の切り分け用。リリースビルドには出さない。
        if (kDebugMode) _iapDebugStatus(),
        if (!_iapLoading && !_iapReady) _iapUnavailableNotice(),
        if (!isPaid) ...[
          const SizedBox(height: 12),
          _freeUsage(free),
        ],
        const SizedBox(height: 20),
        if (showYearlyToggle) ...[
          _periodToggle(),
          const SizedBox(height: 14),
        ],
        for (final p in _purchasable) ...[
          _planCard(p),
          const SizedBox(height: 12),
        ],
        _freeCard(free),
        const SizedBox(height: 16),
        _reassurance(),
        if (isPaid) ...[
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _manage,
            icon: Icon(
              Platform.isIOS && _manageStore == BillingStore.apple
                  ? Icons.manage_accounts
                  : Icons.open_in_new,
              size: 18,
            ),
            label: Text(_manageLabel),
          ),
        ],
        if (_canRestore) ...[
          const SizedBox(height: 8),
          Center(child: _restoreButton('購入を復元')),
        ],
        const SizedBox(height: 20),
        _disclosure(),
        const SizedBox(height: 12),
        // 購入画面から規約・プライバシーへ到達できるようにする
        // （App Store Review Guideline 3.1.2 の要件。Playも同様に求められる）。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => _openLegal('/terms'),
              child: const Text('利用規約', style: TextStyle(fontSize: 12)),
            ),
            Text('·', style: TextStyle(color: context.subtleC)),
            TextButton(
              onPressed: () => _openLegal('/privacy'),
              child: const Text(
                'プライバシーポリシー',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _restoreButton(String label) {
    return TextButton.icon(
      onPressed: _busy == null ? _restore : null,
      icon:
          _busy == 'restore'
              ? const _MiniSpinner()
              : const Icon(Icons.restore, size: 18),
      label: Text(label),
    );
  }

  /// 画面を開いた直後などに、前回の購入がストアから届いて確認しているとき。
  Widget _confirmingNotice() {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          const _MiniSpinner(),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'ご購入の内容を確認しています…',
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
          ),
        ],
      ),
    );
  }

  /// 冒頭の一文。開いた理由ごとに「今困っていること」への答えを出す。
  Widget _hero() {
    final pro = planDef('pro');
    final proReplies = planAiReplies('pro');
    final days = planHistoryDays('free') ?? 30;
    // Google Play の API は直近7日ぶんしか返さないので、RevPilot が集めて保存している。
    // App Store だけの人には当てはまらないので、Google Play のアプリがあるときだけ書く。
    const playNote =
        'Google Play の API は直近7日ぶんのレビューしか取得できないため、'
        'RevPilot が毎時集めて保存しています。';
    final (icon, title, body) = switch (widget.reason) {
      PaywallReason.history => (
        Icons.history,
        '$days日より前のレビューも、保存してあります',
        '${pro.name}にすると、これまでRevPilotが集めたレビューを今すぐ全期間表示します。'
            '${_hasGooglePlay ? playNote : ''}',
      ),
      PaywallReason.topics => (
        Icons.insights_outlined,
        'レビューを自動で分類して、次に直すことが分かる',
        '${pro.name}なら、AIがレビューを不具合・要望・使い勝手などに自動で分類し、'
            '傾向をまとめて表示します。',
      ),
      PaywallReason.bulk => (
        Icons.done_all,
        '未返信のレビューを、まとめて片付ける',
        '${pro.name}は一度に最大${planBulkLimit('pro')}件、'
            'Maxは最大${planBulkLimit('max')}件をAIがまとめて返信案にします。',
      ),
      PaywallReason.aiQuota => (
        Icons.auto_awesome,
        '今月のAI返信を使い切りました',
        '${pro.name}なら月$proReplies件まで。返信文を考える時間をAIに任せられます。',
      ),
      PaywallReason.apps => (
        Icons.apps,
        'すべてのアプリを、1か所で',
        '${pro.name}はアプリ数が無制限です。小さなアプリをいくつ持っていても料金は変わりません。',
      ),
      PaywallReason.general =>
        _hasGooglePlay
            ? (
              Icons.inventory_2_outlined,
              'レビューを全期間、1か所に残す',
              '$playNote'
                  '${pro.name}なら全期間いつでも読み返せて、AI返信も月$proReplies件まで使えます。',
            )
            : (
              Icons.auto_awesome,
              'AI返信を月$proReplies件まで、アプリ数は無制限に',
              '${pro.name}なら、全期間のレビューの閲覧と、AIによるトピック分析も使えます。',
            ),
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.primary, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(fontSize: 13, height: 1.6, color: context.inkC),
          ),
        ],
      ),
    );
  }

  /// Free の今月の使用状況。上限に近いことを、押し付けずに事実として見せる。
  Widget _freeUsage(PlanDef free) {
    final limit = planAiReplies('free');
    final used = _aiRepliesUsed.clamp(0, limit);
    final ratio = limit == 0 ? 0.0 : used / limit;
    final full = used >= limit;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.borderC),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${free.name}・今月のAI返信',
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                ),
              ),
              Text(
                '$used / $limit件',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: full ? context.warningTextC : context.inkC,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 6,
              backgroundColor: context.trackC,
              color: full ? AppTheme.warning : AppTheme.primary,
            ),
          ),
          if (free.limits.historyDays != null) ...[
            const SizedBox(height: 8),
            Text(
              'レビューの表示は直近${free.limits.historyDays}日ぶん（それ以前も保存しています）',
              style: TextStyle(fontSize: 11, color: context.subtleC),
            ),
          ],
        ],
      ),
    );
  }

  Widget _periodToggle() {
    final pct = _maxDiscountPct;
    return Center(
      child: SegmentedButton<BillingPeriod>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: BillingPeriod.yearly,
            label: Text(pct == null ? '年額' : '年額（最大$pct%お得）'),
          ),
          const ButtonSegment(value: BillingPeriod.monthly, label: Text('月額')),
        ],
        selected: {_period},
        onSelectionChanged: (s) {
          HapticFeedback.selectionClick();
          setState(() {
            _period = s.first;
            _periodTouched = true;
          });
        },
      ),
    );
  }

  /// 有料会員の現在の契約。プラン・周期（分かるとき）・次回の更新日を見せる。
  Widget _current() {
    final sub = _sub;
    final renews = _renewsAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  '現在のプラン',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    sub == null
                        ? planLabel(_plan)
                        : '${planLabel(_plan)}・${_periodLabel(sub.period)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: context.accentTextC,
                    ),
                  ),
                ),
              ],
            ),
            // トライアル中は、いつまで無料かをいつでも確認できるようにする（終了前の通知は送らない）。
            if (_trialLine != null) ...[
              const SizedBox(height: 10),
              _infoLine(
                Icons.card_giftcard_rounded,
                _trialLine!,
                color: AppTheme.success,
              ),
              const SizedBox(height: 4),
              Text(
                'この日までに解約すれば料金はかかりません。解約は下の「$_manageLabel」から。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: context.subtleC,
                ),
              ),
            ] else if (renews != null) ...[
              const SizedBox(height: 10),
              _infoLine(
                Icons.event_repeat_rounded,
                sub?.autoRenewing == false
                    ? '${_md(renews)}までご利用いただけます（自動更新はオフです）'
                    : '次回の更新日：${_md(renews)}',
              ),
              // iOS では自動更新のオン・オフが分からないので、解約済みの場合を書き添える。
              if (sub?.autoRenewing == null) ...[
                const SizedBox(height: 4),
                Text(
                  '解約済みの場合は、この日までご利用いただけます。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: context.subtleC,
                  ),
                ),
              ],
            ],
            if (_otherStore) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: context.subtleC,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _store == BillingStore.google
                          ? 'このご契約は Google Play で管理されています。'
                              '変更・解約は Google Play から行えます。'
                          : 'このご契約は App Store で管理されています。'
                              '変更・解約は、ご契約の iPhone などの'
                              '「設定 > 一番上のお名前 > サブスクリプション」から行えます。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: context.inkC,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoLine(IconData icon, String text, {Color? color}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color ?? context.subtleC),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _planCard(PlanDef p) {
    final isCurrent = _plan == p.key;
    var period =
        _hasPeriod(p, _period) ? _period : BillingPeriod.monthly; // 年額未販売なら月額
    // 利用中のプランは、トグルではなく実際の契約の周期で見せる。
    final subPeriod = isCurrent ? _sub?.period : null;
    if (subPeriod != null) period = subPeriod;
    final yearly = period == BillingPeriod.yearly;
    final trial = !isCurrent && !_otherStore && _trial(p, period);
    final discount = yearly ? _discountPct(p) : null;
    final perMonth = yearly ? _monthlyEquivalent(p) : null;
    final price = _price(p, period);

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceC,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: p.popular ? AppTheme.primary : context.borderC,
          width: p.popular ? 1.8 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 文字を大きくしている人でもはみ出さないよう、バッジは折り返せるようにする。
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  p.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (p.popular) const _Pill('おすすめ', filled: true),
                if (trial) _Pill('${p.trialLabel}無料'),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              p.tagline,
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
            const SizedBox(height: 10),
            // 請求額を最も目立つ価格表示にする（月あたりの換算は補足として小さく）。
            Text(
              price,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: context.accentTextC,
              ),
            ),
            if (perMonth != null || discount != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [
                    if (perMonth != null) '月あたり $perMonth',
                    if (discount != null) '月額より$discount%お得',
                  ].join('・'),
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                ),
              ),
            const SizedBox(height: 12),
            for (final f in p.features)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: AppTheme.success,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: _planAction(p, isCurrent, trial),
            ),
            if (!isCurrent && _iapReady && !_otherStore) ...[
              const SizedBox(height: 6),
              _note(_buyNote(p, trial, price)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _note(String text) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(fontSize: 11, height: 1.5, color: context.subtleC),
  );

  /// 購入ボタンの下の注記。いくら・いつから切り替わるかを、押す前に伝える。
  /// Apple はアップグレードだけすぐに切り替え、ダウングレードは次回の更新日から適用する。
  /// Google Play は日割りで調整してすぐに切り替える（iap.dart の ReplacementMode.withTimeProration）。
  String _buyNote(PlanDef p, bool trial, String price) {
    if (_plan == 'free') {
      return trial
          ? '${p.trialLabel}無料、その後 $price（自動更新）。'
              '無料期間中に解約すれば料金はかかりません。'
          : '$price（自動更新）。いつでも解約できます。';
    }
    if (Platform.isAndroid) {
      return '$price（自動更新）。すぐに切り替わり、残り期間分は日割りで調整されます。';
    }
    if (_rankOf(p.key) > _rankOf(_plan)) {
      return _inTrial
          ? '$price（自動更新）。${planLabel(_plan)}の無料トライアルは終了し、すぐに料金が発生します。'
          : '$price（自動更新）。すぐに切り替わり、残り期間分は Apple が日割りで調整します。';
    }
    return '$price（自動更新）。${_fromNextRenewal(_renewsAt)}切り替わります。'
        'それまでは今のプランをご利用いただけます。';
  }

  /// 同じプランの月額⇄年額の切り替えの注記。Apple は次回の更新日から適用する。
  String _switchNote(PlanDef p, BillingPeriod to) {
    final price = _price(p, to);
    if (Platform.isAndroid) {
      return '$price（自動更新）。すぐに切り替わり、残り期間分は日割りで調整されます。';
    }
    return '$price（自動更新）。${_fromNextRenewal(_renewsAt)}切り替わります。';
  }

  Widget _planAction(PlanDef p, bool isCurrent, bool trial) {
    if (isCurrent) {
      final sub = _sub;
      final other =
          sub == null
              ? null
              : (sub.period == BillingPeriod.yearly
                  ? BillingPeriod.monthly
                  : BillingPeriod.yearly);
      final canSwitch = other != null &&
          !_otherStore &&
          _iapReady &&
          _iap.hasPeriod(p.key, other);
      return Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: null,
              child: Text(
                sub == null ? '利用中' : '利用中（${_periodLabel(sub.period)}）',
              ),
            ),
          ),
          // 同じプランの月額⇄年額の切り替え。今の周期が分かるときだけ、反対側を出す
          // （同じ周期を押すとストアが「購読中」と出して止まるため、推測では出さない）。
          if (canSwitch) ...[
            TextButton(
              onPressed: _busy == null ? () => _buy(p.key, other) : null,
              child:
                  _busy == p.key
                      ? const _MiniSpinner()
                      : Text('${_periodLabel(other)}に切り替える'),
            ),
            _note(_switchNote(p, other)),
          ] else if (sub == null &&
              (_otherStore || (_iapReady && Platform.isIOS))) ...[
            const SizedBox(height: 6),
            _note('月額・年額の切り替えは、下の「$_manageLabel」から行えます。'),
          ],
        ],
      );
    }

    // 別のストアの契約は、この端末からは変更できない（購入すると別の契約になる）。
    if (_otherStore) {
      return OutlinedButton(
        onPressed: null,
        child: Text('${_store!.label} で変更できます'),
      );
    }
    // 読み込み中は押せないまま待ってもらう（「ご利用いただけません」は出さない）。
    if (_iapLoading) {
      return const OutlinedButton(
        onPressed: null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [_MiniSpinner(), SizedBox(width: 8), Text('読み込み中…')],
        ),
      );
    }
    // 商品が取れないときは購入ボタンを無効化する。
    // ここで外部決済へ誘導すると 3.1.1 / Play課金ポリシー違反になる。
    if (!_iapReady) {
      return const OutlinedButton(onPressed: null, child: Text('現在ご利用いただけません'));
    }
    final label =
        trial
            ? '${p.trialLabel}無料で試す'
            : (_rankOf(p.key) > _rankOf(_plan)
                ? '${p.name}にアップグレード'
                : '${p.name}に変更');
    return FilledButton(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: _busy == null ? () => _buy(p.key, _cardPeriod(p)) : null,
      child:
          _busy == p.key
              ? const _MiniSpinner()
              : Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
    );
  }

  /// プランカードで選ばれている周期（年額を販売していなければ月額）。
  BillingPeriod _cardPeriod(PlanDef p) =>
      _hasPeriod(p, _period) ? _period : BillingPeriod.monthly;

  /// Free は比較用に小さく出す。有料からの移行（解約）はストアでの手続きになる。
  Widget _freeCard(PlanDef free) {
    final isCurrent = _plan == 'free';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                free.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Text('¥0', style: TextStyle(color: context.subtleC)),
              const Spacer(),
              if (isCurrent)
                Text(
                  '利用中',
                  style: TextStyle(fontSize: 12, color: context.subtleC),
                )
              else
                TextButton(
                  onPressed: _manage,
                  child: Text(
                    _manageStore == BillingStore.google
                        ? '解約手続き（Google Play）'
                        : Platform.isIOS
                            ? '解約手続き'
                            : '解約手続き（App Store）',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            free.features.join('・'),
            style: TextStyle(fontSize: 12, color: context.subtleC),
          ),
        ],
      ),
    );
  }

  /// 購入前の不安を先回りして消す。
  Widget _reassurance() {
    Widget item(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: context.subtleC),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: context.subtleC),
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        // カードが無いと買えないと思われないように（支払い方法は購入シートで選べる）。
        item(
          Icons.payment_outlined,
          Platform.isIOS
              ? 'お支払いは Apple アカウントに登録した方法（クレジットカード・PayPay・キャリア決済など）で行えます'
              : 'お支払いは Google Play に登録した方法（クレジットカード・Google Play 残高など）で行えます',
        ),
        item(Icons.event_available_outlined, 'いつでも解約できます（解約後も期間終了まで使えます）'),
        item(Icons.lock_outline, 'Freeに戻してもレビューの記録は消えません'),
        item(Icons.swap_horiz, 'プランや年額・月額はあとから変更できます'),
      ],
    );
  }

  /// 自動更新サブスクの開示（Apple / Google の両ストアで必須の記載）。
  /// iOS 18 以降は「Apple ID」が「Apple アカウント」になり、設定の一番上は自分の名前になった。
  Widget _disclosure() {
    final store = Platform.isIOS ? 'Apple アカウント' : 'Google アカウント';
    final path =
        Platform.isIOS
            ? '「設定 > 一番上のお名前 > サブスクリプション」'
            : 'Google Play ストアの「お支払いと定期購入 > 定期購入」';
    final trial = _purchasable
        .map((p) => p.trialLabel)
        .whereType<String>()
        .firstOrNull;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.subtleSurfaceC,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        'サブスクリプションは月額または年額で、選択した期間ごとに自動更新されます。'
        'お支払いは購入確定時に$storeへ請求されます。'
        '${trial != null ? '無料トライアルの対象となる方は、無料期間（$trial）の終了時に初回の料金が請求されます。無料トライアルはお一人様1回限りです。' : ''}'
        '解約しない限り期間終了時に自動更新され、更新料は現在の期間終了の24時間前に請求されます。'
        '自動更新は購入後、$pathからいつでも解約できます。'
        '${trial != null ? '無料期間中に解約した場合、料金はかかりません。' : ''}'
        '解約後も、その課金期間の終了までは有料機能をご利用いただけます。',
        style: TextStyle(fontSize: 12, color: context.subtleC, height: 1.5),
      ),
    );
  }

  /// 商品を取得できないとき。外部決済には絶対に落とさない。
  Widget _iapUnavailableNotice() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppTheme.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // スクリーンタイムで App 内課金を止めている端末は、通信を確かめても直らない。
                  _iap.restricted
                      ? 'この端末ではApp内課金が制限されています。'
                          '「設定 > スクリーンタイム > コンテンツとプライバシーの制限」をご確認ください。'
                      : 'ただいま購入手続きをご利用いただけません。'
                          '通信環境をご確認のうえ、再読み込みしてください。',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.inkC,
                    height: 1.4,
                  ),
                ),
                TextButton.icon(
                  onPressed: _retryIap,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('再読み込み'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// デバッグビルド専用の状態表示。
  Widget _iapDebugStatus() {
    final ok = _iapReady;
    final color = ok || _iapLoading ? AppTheme.success : AppTheme.warning;
    final hint =
        Platform.isIOS
            ? 'StoreKit設定を確認し、Xcodeの▶から起動してください。'
            : 'Play Console で定期購入を作成し、内部テスト版として署名済みビルドで起動してください。';
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        _iapLoading
            ? '[debug] IAP商品を読み込み中…'
            : ok
            ? '[debug] IAP商品を取得済み。ネイティブ購入シートが使えます。'
                '${_iap.lastError != null ? '（${_iap.lastError}）' : ''}'
            : '[debug] IAP商品を取得できていません（${_iap.lastError ?? "理由不明"}）。$hint',
        style: TextStyle(fontSize: 11, color: context.inkC, height: 1.4),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.filled = false});

  final String text;
  final bool filled;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      // 白い小さな文字を載せるので、primary より一段濃い色にする（4.5:1 以上）。
      color:
          filled
              ? AppTheme.accentText
              : AppTheme.success.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: filled ? Colors.white : context.successTextC,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _MiniSpinner extends StatelessWidget {
  const _MiniSpinner();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 18,
    width: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
