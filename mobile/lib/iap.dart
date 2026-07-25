import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';

/// App内課金（IAP）。当面は Xcode の StoreKit ローカルテスト用（Apple Developer登録なしで
/// ネイティブ購入シートを動作確認できる）。本番の“安全な購入確定”はサーバー側レシート検証
/// （RevenueCat等）が必要で、Apple Developer登録後に対応する。
class IapService {
  /// プラン → ストアの商品ID。StoreKit設定ファイル(ios/Runner/RevPilot.storekit)と一致させる。
  static const Map<String, String> productIds = {
    'pro': 'com.yutatomatsu.revpilot.pro.monthly',
    'max': 'com.yutatomatsu.revpilot.max.monthly',
    'team': 'com.yutatomatsu.revpilot.team.monthly',
  };

  /// IAP対象プラットフォーム。当面はiOSのローカルテストのみ。
  static bool get platformSupported => Platform.isIOS;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final Map<String, ProductDetails> _products = {};

  /// StoreKitから商品を取得できていれば true（＝IAPで購入可能な状態）。
  bool get isReady => _products.isNotEmpty;

  /// 初期化。商品を取得し購入ストリームを購読する。
  /// onPurchased: 購入/復元が成立したプランキー。onError: 失敗時の文言。
  Future<void> init({
    required void Function(String planKey) onPurchased,
    required void Function(String message) onError,
  }) async {
    if (!platformSupported) return;
    if (!await _iap.isAvailable()) return;

    final resp = await _iap.queryProductDetails(productIds.values.toSet());
    _products
      ..clear()
      ..addEntries(resp.productDetails.map((p) => MapEntry(p.id, p)));

    _sub ??= _iap.purchaseStream.listen((purchases) {
      for (final pd in purchases) {
        switch (pd.status) {
          case PurchaseStatus.purchased:
          case PurchaseStatus.restored:
            final key = _planForProduct(pd.productID);
            if (key != null) onPurchased(key);
            break;
          case PurchaseStatus.error:
            onError(pd.error?.message ?? '購入に失敗しました');
            break;
          case PurchaseStatus.canceled:
          case PurchaseStatus.pending:
            break;
        }
        // 購入処理の完了通知（未完了だと再送され続けるため必須）。
        if (pd.pendingCompletePurchase) {
          _iap.completePurchase(pd);
        }
      }
    });
  }

  String? _planForProduct(String productId) {
    for (final e in productIds.entries) {
      if (e.value == productId) return e.key;
    }
    return null;
  }

  ProductDetails? productFor(String planKey) => _products[productIds[planKey]];

  /// 購入開始。OSのネイティブ購入シートが表示される。結果は init の onPurchased/onError に届く。
  Future<void> buy(String planKey) async {
    final pd = productFor(planKey);
    if (pd == null) {
      throw Exception('商品を読み込めていません（StoreKit設定 / 商品IDを確認してください）');
    }
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: pd));
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
