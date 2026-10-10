import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';

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
class IapService {
  /// プラン → ストアの商品ID。
  /// iOS: ios/Runner/RevPilot.storekit と App Store Connect
  /// Android: Play Console の定期購入ID
  /// サーバー側の lib/iap-apple.ts / lib/iap-google.ts とも一致させること。
  static const Map<String, String> productIds = {
    'pro': 'jp.revpilot.app.pro.monthly',
    'max': 'jp.revpilot.app.max.monthly',
  };

  /// IAP対象プラットフォーム。iOS / Android の両方。
  static bool get platformSupported => Platform.isIOS || Platform.isAndroid;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _products = {};

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

    final resp = await _iap.queryProductDetails(productIds.values.toSet());
    if (resp.error != null) lastError = resp.error!.message;
    if (resp.notFoundIDs.isNotEmpty) {
      lastError = '未登録の商品ID: ${resp.notFoundIDs.join(", ")}';
    }
    _products
      ..clear()
      ..addEntries(resp.productDetails.map((p) => MapEntry(p.id, p)));

    _sub ??= _iap.purchaseStream.listen((purchases) {
      for (final pd in purchases) {
        switch (pd.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            final key = _planForProduct(pd.productID);
            if (key != null) {
              final data = pd.verificationData.serverVerificationData;
              onPurchased(IapResult(
                planKey: key,
                productId: pd.productID,
                transactionId: pd.purchaseID,
                verificationData: data.isEmpty ? null : data,
                restored: pd.status == PurchaseStatus.restored,
              ));
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

  /// 過去の購入を復元する。結果は init の onPurchased（restored=true）に届く。
  /// Appleの審査要件（購入の復元手段の提供）であり、Androidでも機種変更時に必要。
  Future<void> restore() async {
    if (!platformSupported) return;
    await _iap.restorePurchases();
  }

  String? _planForProduct(String productId) {
    for (final e in productIds.entries) {
      if (e.value == productId) return e.key;
    }
    return null;
  }

  ProductDetails? productFor(String planKey) => _products[productIds[planKey]];

  /// 表示用の価格（ストアが返すローカライズ済みの文字列）。
  /// ハードコードした価格ではなくこちらを優先すると、為替や地域価格とズレない。
  String? priceFor(String planKey) => productFor(planKey)?.price;

  /// 購入開始。OSのネイティブ購入シートが表示される。結果は init の onPurchased/onError に届く。
  Future<void> buy(String planKey) async {
    final pd = productFor(planKey);
    if (pd == null) {
      throw Exception('商品を読み込めませんでした。時間をおいて再度お試しください。');
    }
    // 定期購入は非消費型として扱う（プラン変更は同一サブスクグループ内でストアが処理）。
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: pd));
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
