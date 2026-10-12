import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'models.dart';
import 'plan_catalog.g.dart';

/// Supabaseへのデータアクセス。RLSにより自分のデータのみ返る。
/// サーバー秘密鍵が必要な処理（暗号化・AI・課金・ストア投稿/取得）だけAPIを叩き、
/// それ以外（アプリ管理・連携状態の参照・下書き）は直接Supabaseで完結する。
class Repo {
  static SupabaseClient get _db => Supabase.instance.client;

  // ---- 共通: Next.js API 呼び出し（Bearer認証） ----
  //
  // タイムアウトは処理の重さに合わせて呼び出し側が指定する。
  // 以前は一律15秒だったため、AI生成を伴う処理（1件でも数秒、一括なら分単位）が
  // 必ずクライアント側で先に切れていた。サーバーは処理を続けるので、
  // 利用者にはエラーが見えるのに課金だけ発生し、再実行で二重課金になっていた。
  static Future<Map<String, dynamic>> _postApi(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!AppConfig.hasApi) {
      throw const ApiException('この機能はご利用いただけません。時間をおいて再度お試しください。');
    }
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) throw const ApiException('ログインが必要です。');
    final http.Response res;
    try {
      res = await http
          .post(
            Uri.parse('${AppConfig.apiBaseUrl}$path'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (_) {
      // 接続失敗/タイムアウトは生の ClientException を出さず、利用者向けの文言に。
      throw const ApiException(
          'サーバーに接続できませんでした。通信環境をご確認のうえ、時間をおいて再度お試しください。');
    }
    Map<String, dynamic> json = {};
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw ApiException(
        (json['error'] as String?) ?? 'エラーが発生しました (${res.statusCode})',
        statusCode: res.statusCode);
  }

  // ---- アプリ（直接Supabase / RLSで自分のみ） ----
  static Future<List<AppRow>> apps() async {
    final rows = await _db
        .from('apps')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .map((e) => AppRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// アプリを追加。プラン別のアプリ数上限をクライアント側でも確認する。
  static Future<AppRow> addApp({
    required String store,
    required String storeAppId,
    required String name,
    String? description,
    String tone = 'polite',
  }) async {
    // アプリ追加はAPI経由にする。
    // 追加の時点でストア側のアクセス権（App IDの誤り・権限不足）を確認できるため、
    // 「1時間後もレビューが0件」になって初めて気づく、という事態を防げる。
    // 件数上限のチェックもサーバー側（およびDBトリガ）で行う。
    final json = await _postApi(
      '/api/apps',
      {
        'store': store,
        'store_app_id': storeAppId,
        'name': name,
        'description': description,
        'reply_tone': tone,
      },
      timeout: const Duration(seconds: 45), // ストアへの疎通確認を含む
    );
    return AppRow.fromJson(Map<String, dynamic>.from(json['app'] as Map));
  }

  static Future<void> updateApp(
    String id, {
    required String name,
    String? description,
    required String tone,
  }) async {
    await _db.from('apps').update({
      'name': name,
      'description': description,
      'reply_tone': tone,
    }).eq('id', id);
  }

  static Future<void> deleteApp(String id) async {
    await _db.from('apps').delete().eq('id', id);
  }

  // ---- レビュー ----
  /// レビュー一覧。星（複数可）・アプリ・ストア・未返信フィルタと並び替えに対応。
  static Future<List<ReviewRow>> reviews({
    String? appId,
    String? store,
    List<int>? ratings,
    bool unrepliedOnly = false,
    ReviewSort sort = ReviewSort.newest,
  }) async {
    var query = _db.from('reviews').select(
        '*, apps!inner(name), replies(*), review_topics(topic)');

    if (appId != null) query = query.eq('app_id', appId);
    if (store != null) query = query.eq('store', store);
    if (ratings != null && ratings.isNotEmpty) {
      query = query.inFilter('rating', ratings);
    }

    final ordered = switch (sort) {
      ReviewSort.newest => query.order('reviewed_at', ascending: false),
      ReviewSort.oldest => query.order('reviewed_at', ascending: true),
      ReviewSort.highest => query
          .order('rating', ascending: false)
          .order('reviewed_at', ascending: false),
      ReviewSort.lowest => query
          .order('rating', ascending: true)
          .order('reviewed_at', ascending: false),
    };

    final rows = await ordered.limit(200);
    var listOut = (rows as List)
        .map((e) => ReviewRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    // 「未返信」は「ストアに投稿していない」で判定する（下書きだけの状態も対象に残す）。
    if (unrepliedOnly) listOut = listOut.where((r) => r.needsReply).toList();
    return listOut;
  }

  /// 通知の判定・バナー表示に使う軽量なレビュー取得。
  ///
  /// 通知チェックは定期的に走るため、一覧用の重いクエリ
  /// （200件 × replies(*) × review_topics）を使うと、アプリを開いている間ずっと
  /// 大量の通信が発生し、利用者のデータ通信量とDBの転送量を圧迫する。
  /// 通知に必要な列だけを、必要な件数だけ取る。
  static Future<List<ReviewRow>> reviewsForNotify({
    List<int>? ratings,
    int limit = 50,
  }) async {
    var query = _db
        .from('reviews')
        .select('id, store, rating, title, body, reviewed_at, apps!inner(name)');
    if (ratings != null && ratings.isNotEmpty) {
      query = query.inFilter('rating', ratings);
    }
    final rows = await query.order('reviewed_at', ascending: false).limit(limit);
    return (rows as List)
        .map((e) => ReviewRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 運営からのお知らせ（有効かつ期間内のものだけRLSで返る）。
  /// テーブル未作成などでも画面を落とさないよう、失敗時は空を返す。
  static Future<List<Announcement>> announcements() async {
    try {
      final rows = await _db
          .from('announcements')
          .select('id, title, body, level')
          .order('created_at', ascending: false)
          .limit(5);
      return (rows as List)
          .map((e) => Announcement.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// AI返信の生成（API）。生成文は replies に保存され本文が返る。
  static Future<String> generateAiReply(String reviewId) async {
    final json = await _postApi(
      '/api/reply',
      {'reviewId': reviewId, 'action': 'draft'},
      timeout: const Duration(seconds: 60), // AI生成は数秒〜十数秒かかる
    );
    final reply = json['reply'];
    return reply is Map ? (reply['body'] as String? ?? '') : '';
  }

  /// ストアへ返信を投稿（API）。textを渡すとその本文を投稿する。
  static Future<void> postReplyToStore(String reviewId, {String? text}) async {
    await _postApi(
      '/api/reply',
      {
        'reviewId': reviewId,
        'action': 'post',
        if (text != null && text.trim().isNotEmpty) 'text': text,
      },
      timeout: const Duration(seconds: 60),
    );
  }

  /// 複数レビューへ一括でAI返信を生成（post=trueで投稿まで）。
  /// 返り値: { generated, posted, skipped, results:[{reviewId, ok, status?, error?}] }
  ///
  /// サーバーは最大300秒かけて処理し、時間内に終わらなかった分を skipped として返す。
  /// クライアントのタイムアウトはそれより長くしておく必要がある。
  static Future<Map<String, dynamic>> bulkReply(
    List<String> reviewIds, {
    bool post = false,
  }) =>
      _postApi(
        '/api/reply/bulk',
        {
          'reviewIds': reviewIds,
          'action': post ? 'post' : 'draft',
        },
        timeout: const Duration(seconds: 320),
      );

  /// レビューへの返信ドラフトを保存（直接Supabase）。
  static Future<ReplyRow> saveManualReply(String reviewId, String body) async {
    final row = await _db
        .from('replies')
        .insert({
          'review_id': reviewId,
          'body': body,
          'status': 'draft',
          'source': 'manual',
        })
        .select()
        .single();
    return ReplyRow.fromJson(Map<String, dynamic>.from(row));
  }

  // ---- ストアから取得（手動更新 / API） ----
  static bool get canRefresh => AppConfig.hasApi;

  /// ストアAPIから新着レビューを取り込む。取り込み件数などのマップを返す。
  static Future<Map<String, dynamic>> refreshFromStores() =>
      _postApi('/api/poll', {}, timeout: const Duration(seconds: 90));

  // ---- ストア連携（保存も参照もAPI経由） ----
  /// 連携済みストア（'appstore' / 'googleplay'）の一覧。
  ///
  /// store_credentials はクライアントから直接読めないようRLSで閉じてあるため、
  /// （暗号化済みとはいえ資格情報をクライアントに配る理由がない）APIから取得する。
  static Future<List<String>> connectedStores() async {
    if (!AppConfig.hasApi) return [];
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) return [];
    try {
      final res = await http.get(
        Uri.parse('${AppConfig.apiBaseUrl}/api/credentials'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 20));
      if (res.statusCode < 200 || res.statusCode >= 300) return [];
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      return ((json['connected'] as List?) ?? []).cast<String>();
    } catch (_) {
      return [];
    }
  }

  // 資格情報の保存はサーバー側で実際にストアAPIへ疎通確認してから行われる。
  // 検証に失敗した場合は保存されず、理由が ApiException として返る。
  static Future<void> saveAppStoreCredentials({
    required String issuerId,
    required String keyId,
    required String privateKey,
  }) =>
      _postApi(
        '/api/credentials',
        {
          'store': 'appstore',
          'issuerId': issuerId,
          'keyId': keyId,
          'privateKey': privateKey,
        },
        timeout: const Duration(seconds: 45),
      );

  static Future<void> saveGooglePlayCredentials(String serviceAccountJson) =>
      _postApi(
        '/api/credentials',
        {
          'store': 'googleplay',
          'serviceAccountJson': serviceAccountJson,
        },
        timeout: const Duration(seconds: 45),
      );

  // ---- 課金 ----
  //
  // 決済は各OSのアプリ内課金のみ。外部決済（Stripe）への導線は持たない。
  //   - iOS: App Store Review Guideline 3.1.1 が外部課金への誘導を禁じている
  //   - Android: Google Play の課金ポリシーも同様
  // 以前は StoreKit の商品取得に失敗したとき Stripe Checkout をアプリ内ブラウザで
  // 開くフォールバックがあり、これは確実にリジェクトされる実装だった。

  /// iOSのIAP購入/復元をサーバーで確定し、profiles.plan に反映する。
  static Future<PurchaseConfirmation> confirmApplePurchase({
    required String productId,
    String? transactionId,
    String? verificationData,
  }) async {
    final json = await _postApi(
      '/api/billing/iap/apple',
      {
        'productId': productId,
        if (transactionId != null) 'transactionId': transactionId,
        if (verificationData != null) 'verificationData': verificationData,
      },
      timeout: const Duration(seconds: 45), // Appleへの問い合わせを含む
    );
    return PurchaseConfirmation.fromJson(json);
  }

  /// AndroidのGoogle Play課金をサーバーで確定し、profiles.plan に反映する。
  /// verificationData は purchaseToken。
  static Future<PurchaseConfirmation> confirmGooglePurchase({
    required String productId,
    required String purchaseToken,
  }) async {
    final json = await _postApi(
      '/api/billing/iap/google',
      {'productId': productId, 'purchaseToken': purchaseToken},
      timeout: const Duration(seconds: 45), // Googleへの問い合わせを含む
    );
    return PurchaseConfirmation.fromJson(json);
  }

  // ---- アカウント削除（退会 / Apple審査要件） ----
  /// アカウントと関連データを完全に削除する。成功後はサインアウトすること。
  static Future<void> deleteAccount() async {
    if (!AppConfig.hasApi) {
      throw const ApiException('この機能はサーバー接続が必要です。');
    }
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) throw const ApiException('ログインが必要です。');
    final http.Response res;
    try {
      res = await http
          .delete(
            Uri.parse('${AppConfig.apiBaseUrl}/api/account'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw ApiException(
          'サーバーに接続できませんでした。接続先(${AppConfig.apiBaseUrl})を確認してください。');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    Map<String, dynamic> json = {};
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    throw ApiException(
        (json['error'] as String?) ?? 'アカウント削除に失敗しました (${res.statusCode})');
  }

  // ---- リモートpush通知 ----

  /// この端末を通知先として登録する。
  /// 端末トークンは service_role でしか書けないためAPI経由（RLSではなくサーバーで所有者を付け替える）。
  static Future<void> registerPushToken({
    required String token,
    required String platform,
  }) =>
      _postApi(
        '/api/push/devices',
        {'token': token, 'platform': platform},
        timeout: const Duration(seconds: 20),
      ).then((_) {});

  /// この端末を通知先から外す（ログアウト時）。
  static Future<void> unregisterPushToken(String token) => _postApi(
        '/api/push/devices',
        {'token': token, 'remove': true},
        timeout: const Duration(seconds: 20),
      ).then((_) {});

  /// 通知対象（all / low / off）をサーバーにも保存する。
  /// 端末内(SharedPreferences)だけではサーバーが知り得ず、
  /// 「★1〜2のみ」にしていてもリモートpushは全件届いてしまう。
  static Future<void> savePushScope(String scope) => _postApi(
        '/api/settings',
        {'push_scope': scope},
        timeout: const Duration(seconds: 20),
      ).then((_) {});

  /// 自分の端末にテスト通知を送る（設定が正しいかの確認用）。
  static Future<void> sendTestPush() => _postApi(
        '/api/push/test',
        const {},
        timeout: const Duration(seconds: 30),
      ).then((_) {});

  // ---- プラン ----
  static Future<String> plan() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 'free';
    final row =
        await _db.from('profiles').select('plan').eq('id', uid).maybeSingle();
    return (row?['plan'] as String?) ?? 'free';
  }

  /// 課金画面用の契約状況（プランと今月のAI使用量）。
  static Future<BillingStatus> billingStatus() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return const BillingStatus(plan: 'free', aiUnitsUsed: 0);
    final now = DateTime.now().toUtc();
    final ym = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final results = await Future.wait([
      _db.from('profiles').select('plan').eq('id', uid).maybeSingle(),
      _db
          .from('ai_usage')
          .select('units')
          .eq('user_id', uid)
          .eq('ym', ym)
          .maybeSingle()
          .catchError((_) => null),
    ]);
    return BillingStatus(
      plan: (results[0]?['plan'] as String?) ?? 'free',
      aiUnitsUsed: (results[1]?['units'] as num?)?.toInt() ?? 0,
    );
  }
}

/// レビューの並び替え順。
enum ReviewSort { newest, oldest, highest, lowest }

extension ReviewSortLabel on ReviewSort {
  String get label => switch (this) {
        ReviewSort.newest => '新しい順',
        ReviewSort.oldest => '古い順',
        ReviewSort.highest => '評価が高い順',
        ReviewSort.lowest => '評価が低い順',
      };
}

/// プラン定義（shared/plans.json から生成）。未知の値は Free 扱い。
PlanDef planDef(String plan) => planCatalog.firstWhere(
      (p) => p.key == plan,
      orElse: () => planCatalog.firstWhere((p) => p.key == 'free'),
    );

/// プラン別アプリ数上限（null=無制限）。
/// 有料プランは無制限（アプリ数は原価にほぼ影響せず、制限しても離脱を招くだけのため）。
int? planMaxApps(String plan) => planDef(plan).limits.maxApps;

/// プラン別のレビュー履歴の閲覧範囲（日数）。null=無期限。
///
/// 実際の制限はサーバー側（reviews のRLSポリシー）で強制されている。
/// ここはUIで「これ以上前は表示されない」と伝えるための写し。
int? planHistoryDays(String plan) => planDef(plan).limits.historyDays;

/// 一括返信の1回あたり上限（1=一括不可）。
///
/// 「無制限」は廃止した。1リクエストで無制限に処理させると、関数の実行時間上限を
/// 超えて中途半端に打ち切られ、課金だけ発生して結果が返らない事故になるため。
int planBulkLimit(String plan) => planDef(plan).limits.bulkReplyLimit;

/// 返信ドラフト1件あたりの units。lib/plan.ts の AI_UNITS.reply と一致させる。
const aiUnitsPerReply = 10;

/// 月あたりのAI返信件数（units を返信件数に換算）。
int planAiReplies(String plan) =>
    planDef(plan).limits.aiUnitsPerMonth ~/ aiUnitsPerReply;

String planLabel(String plan) =>
    planCatalog.where((p) => p.key == plan).firstOrNull?.name ?? plan;

/// 課金画面で使う、利用者の契約状況。
class BillingStatus {
  final String plan;

  /// 今月使ったAIの units（ai_usage）。
  final int aiUnitsUsed;

  const BillingStatus({required this.plan, required this.aiUnitsUsed});

  int get aiRepliesUsed => aiUnitsUsed ~/ aiUnitsPerReply;
}

/// 購入をサーバーで確定した結果。
class PurchaseConfirmation {
  final String plan;

  /// 無料トライアル中か（終了前のお知らせを予約するのに使う）。
  final bool inTrial;
  final DateTime? expiresAt;

  const PurchaseConfirmation({
    required this.plan,
    required this.inTrial,
    required this.expiresAt,
  });

  factory PurchaseConfirmation.fromJson(Map<String, dynamic> json) =>
      PurchaseConfirmation(
        plan: (json['plan'] as String?) ?? 'free',
        inTrial: json['inTrial'] == true,
        expiresAt: DateTime.tryParse((json['expiresAt'] as String?) ?? ''),
      );
}

/// APIエラー（ユーザー向けメッセージを保持）。
class ApiException implements Exception {
  final String message;

  /// サーバーが返したHTTPステータス（通信前の失敗では null）。
  final int? statusCode;
  const ApiException(this.message, {this.statusCode});

  /// Free の上限（アプリ数・AI枠）に当たったことを示すエラーか。
  /// サーバーは 403 と「Proにアップグレード…」の案内文で返す（lib/plan.ts / app/api/apps）。
  bool get isPlanLimit => statusCode == 403 && message.contains('アップグレード');
  @override
  String toString() => message;
}
