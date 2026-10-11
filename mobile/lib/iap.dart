import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart'
    show ReplacementMode;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:intl/intl.dart';

import 'plan_catalog.g.dart';

/// 支払い周期。商品IDは shared/plans.json で周期ごとに分かれている。
enum BillingPeriod { monthly, yearly }

/// 購入/復元の成立結果。サーバー検証に渡す材料を持つ。
class IapResult {
  final String planKey;
  final String productId;

  /// iOS: transactionId / Android: orderId（参考情報）
  final String? transactionId;

  /// サーバー検証に使う値。
  /// iOS   … JWS署名付きトランザクション（serverVerificationData）
  /// Android … purchaseToken（serverVerificationData）
  final String? verificationData;

  final bool restored;

  const IapResult({
    required this.planKey,
    required this.productId,
    this.transactionId,
    this.verificationData,
    this.restored = false,
  });
}

/// App内課金（IAP）。iOS の StoreKit と Android の Google Play Billing の両対応。
///
/// 購入の確定はサーバー側検証に委ねる:
///   iOS     → POST /api/billing/iap/apple   （App Store Server API に問い合わせ）
///   Android → POST /api/billing/iap/google  （Play Developer API に問い合わせ）
/// クライアントが「買えた」と言っただけではプランを変えない。
///
/// 【無料トライアル】
/// トライアルはストアの機能（iOS: 導入オファー / Android: 無料トライアル付きオファー）で、
/// 課金の開始はストアが自動で行う。アプリは「対象者にだけトライアルと表示する」ことに責任を持つ。
/// 対象外の人に「無料」と見せて購入シートで有料だと知る、という体験は不信の元になる。
///   - Android: Play は対象者にだけトライアル付きオファーを返すので、その有無で判定する。
///   - iOS:     StoreKit 2 の isEligibleForIntroOffer（同じサブスクグループで未使用か）で判定する。
class IapService {
  /// プラン → 周期 → ストアの商品ID。shared/plans.json から生成した定義を使う。
  /// iOS: ios/Runner/RevPilot.storekit と App Store Connect
  /// Android: Play Console の定期購入ID
  static final Map<String, Map<BillingPeriod, String>> productIds = {
    for (final p in planCatalog)
      if (!p.hidden)
        p.key: {
          if (p.monthly?.productId != null)
            BillingPeriod.monthly: p.monthly!.productId!,
          if (p.yearly?.productId != null)
            BillingPeriod.yearly: p.yearly!.productId!,
        },
  }..removeWhere((_, v) => v.isEmpty);

  static Set<String> get _allProductIds => {
    for (final m in productIds.values) ...m.values,
  };

  /// IAP対象プラットフォーム。iOS / Android の両方。
  static bool get platformSupported => Platform.isIOS || Platform.isAndroid;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;

  /// 商品ID → 通常価格の商品（Android は基本プラン）。価格表示と通常購入に使う。
  final Map<String, ProductDetails> _products = {};

  /// 商品ID → 無料トライアル付きオファー（Android のみ。対象者にだけ Play が返す）。
  final Map<String, GooglePlayProductDetails> _trialOffers = {};

  /// トライアル対象の商品ID（iOS のみ。StoreKit 2 で判定）。
  final Set<String> _introEligible = {};

  /// ストアから商品を取得できていれば true（＝IAPで購入可能な状態）。
  bool get isReady => _products.isNotEmpty;

  /// 商品を取得できなかった理由（デバッグ表示用）。
  String? lastError;

  /// 初期化。商品を取得し購入ストリームを購読する。
  /// onPurchased: 購入/復元が成立したときの結果（サーバー検証に渡す）。onError: 失敗時の文言。
  Future<void> init({
    required void Function(IapResult result) onPurchased,
    required void Function(String message) onError,
  }) async {
    if (!platformSupported) return;
    if (!await _iap.isAvailable()) {
      lastError = 'ストアに接続できません';
      return;
    }

    final resp = await _iap.queryProductDetails(_allProductIds);
    if (resp.error != null) lastError = resp.error!.message;
    if (resp.notFoundIDs.isNotEmpty) {
      lastError = '未登録の商品ID: ${resp.notFoundIDs.join(", ")}';
    }
    _products.clear();
    _trialOffers.clear();
    for (final p in resp.productDetails) {
      if (p is GooglePlayProductDetails && p.subscriptionIndex != null) {
        // Android の定期購入は「基本プラン」と「オファー」が別々の要素で返る。
        // 基本プラン（offerId なし）を通常価格に、初回が無料のオファーをトライアルに振り分ける。
        final offer =
            p.productDetails.subscriptionOfferDetails![p.subscriptionIndex!];
        if (offer.offerId == null) {
          _products[p.id] = p;
        } else if (offer.pricingPhases.first.priceAmountMicros == 0) {
          _trialOffers[p.id] = p;
        }
      } else {
        _products[p.id] = p;
      }
    }

    if (Platform.isIOS) await _loadIntroEligibility();

    _sub ??= _iap.purchaseStream.listen((purchases) {
      for (final pd in purchases) {
        switch (pd.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            final key = _planForProduct(pd.productID);
            if (key != null) {
              final data = pd.verificationData.serverVerificationData;
              onPurchased(
                IapResult(
                  planKey: key,
                  productId: pd.productID,
                  transactionId: pd.purchaseID,
                  verificationData: data.isEmpty ? null : data,
                  restored: pd.status == PurchaseStatus.restored,
                ),
              );
            }
            break;
          case PurchaseStatus.error:
            onError(pd.error?.message ?? '購入に失敗しました');
            break;
          case PurchaseStatus.canceled:
          case PurchaseStatus.pending:
            break;
        }
        // 購入処理の完了通知。
        // Android では completePurchase が acknowledge を兼ねており、
        // 3日以内に確認しないとGoogleが自動返金するため必須。
        // （取りこぼしに備えてサーバー側でも acknowledge している）
        if (pd.pendingCompletePurchase) {
          _iap.completePurchase(pd);
        }
      }
    });
  }

  /// iOS: トライアルを設定したプランの商品について、導入オファーの対象者か確認する。
  /// 判定に失敗したら「対象外」として扱う（無料と誤って見せないことを優先）。
  Future<void> _loadIntroEligibility() async {
    _introEligible.clear();
    for (final p in planCatalog) {
      if (p.trialDays == null) continue;
      for (final id in productIds[p.key]?.values ?? const <String>[]) {
        if (!_products.containsKey(id)) continue;
        try {
          if (await SK2Product.isIntroductoryOfferEligible(id)) {
            _introEligible.add(id);
          }
        } catch (_) {}
      }
    }
  }

  /// 過去の購入を復元する。結果は init の onPurchased（restored=true）に届く。
  /// Appleの審査要件（購入の復元手段の提供）であり、Androidでも機種変更時に必要。
  Future<void> restore() async {
    if (!platformSupported) return;
    await _iap.restorePurchases();
  }

  String? _planForProduct(String productId) {
    for (final e in productIds.entries) {
      if (e.value.containsValue(productId)) return e.key;
    }
    return null;
  }

  /// その周期を販売しているか（ストアから商品を取得できたか）。
  bool hasPeriod(String planKey, BillingPeriod period) =>
      productFor(planKey, period) != null;

  ProductDetails? productFor(String planKey, BillingPeriod period) =>
      _products[productIds[planKey]?[period]];

  /// 表示用の価格（ストアが返すローカライズ済みの文字列）。
  /// ハードコードした価格ではなくこちらを優先すると、為替や地域価格とズレない。
  String? priceFor(String planKey, BillingPeriod period) =>
      productFor(planKey, period)?.price;

  /// 年額の「月あたり」表示（例: ¥1,233）。ストアの価格と通貨から計算する。
  String? monthlyEquivalentFor(String planKey) {
    final p = productFor(planKey, BillingPeriod.yearly);
    if (p == null) return null;
    final digits = p.currencyCode == 'JPY' ? 0 : 2;
    return NumberFormat.currency(
      locale: 'ja_JP',
      symbol: p.currencySymbol,
      decimalDigits: digits,
    ).format(p.rawPrice / 12);
  }

  /// 年額が月額12か月ぶんより何%安いか（ストアの価格から計算）。
  int? yearlyDiscountPct(String planKey) {
    final m = productFor(planKey, BillingPeriod.monthly);
    final y = productFor(planKey, BillingPeriod.yearly);
    if (m == null || y == null || m.rawPrice <= 0) return null;
    final pct = ((1 - y.rawPrice / (m.rawPrice * 12)) * 100).round();
    return pct > 0 ? pct : null;
  }

  /// この利用者がこの商品で無料トライアルを受けられるか。
  bool trialAvailable(String planKey, BillingPeriod period) {
    final id = productIds[planKey]?[period];
    if (id == null) return false;
    if (Platform.isAndroid) return _trialOffers.containsKey(id);
    return _introEligible.contains(id);
  }

  /// 購入開始。OSのネイティブ購入シートが表示される。結果は init の onPurchased/onError に届く。
  Future<void> buy(String planKey, BillingPeriod period) async {
    final pd = productFor(planKey, period);
    if (pd == null) {
      throw Exception('商品を読み込めませんでした。時間をおいて再度お試しください。');
    }

    if (Platform.isAndroid) {
      // トライアルの対象者にはトライアル付きオファーで購入させる（基本プランで買うと即課金になる）。
      final offer = _trialOffers[pd.id] ?? pd as GooglePlayProductDetails;
      // Google Play は別の定期購入を買うと「並行して2本契約」になってしまう。
      // 既に契約中なら、プラン変更として旧契約を置き換える（残り期間は日割りで繰り越し）。
      final old = await _currentAndroidSubscription(exceptProductId: pd.id);
      await _iap.buyNonConsumable(
        purchaseParam: GooglePlayPurchaseParam(
          productDetails: offer,
          offerToken: offer.offerToken,
          changeSubscriptionParam:
              old == null
                  ? null
                  : ChangeSubscriptionParam(
                    oldPurchaseDetails: old,
                    replacementMode: ReplacementMode.withTimeProration,
                  ),
        ),
      );
      return;
    }

    // iOS はプラン変更（同一サブスクグループ内）も導入オファーの適用もストアが処理する。
    await _iap.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: pd),
    );
  }

  /// Android で現在契約中の RevPilot の定期購入（購入しようとしている商品以外）。
  Future<GooglePlayPurchaseDetails?> _currentAndroidSubscription({
    required String exceptProductId,
  }) async {
    try {
      final addition =
          _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final resp = await addition.queryPastPurchases();
      for (final p in resp.pastPurchases) {
        if (p.productID != exceptProductId &&
            _allProductIds.contains(p.productID)) {
          return p;
        }
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
