import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'models.dart';

/// Supabaseへのデータアクセス。RLSにより自分のデータのみ返る。
/// サーバー秘密鍵が必要な処理（暗号化・AI・課金・ストア投稿/取得）だけAPIを叩き、
/// それ以外（アプリ管理・連携状態の参照・下書き）は直接Supabaseで完結する。
class Repo {
  static SupabaseClient get _db => Supabase.instance.client;

  // ---- 共通: Next.js API 呼び出し（Bearer認証） ----
  static Future<Map<String, dynamic>> _postApi(
      String path, Map<String, dynamic> body) async {
    if (!AppConfig.hasApi) {
      throw const ApiException(
          'この機能はサーバー接続が必要です（設定→APIのURLを設定してください）。');
    }
    final token = _db.auth.currentSession?.accessToken;
    if (token == null) throw const ApiException('ログインが必要です。');
    final res = await http.post(
      Uri.parse('${AppConfig.apiBaseUrl}$path'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );
    Map<String, dynamic> json = {};
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw ApiException(
        (json['error'] as String?) ?? 'エラーが発生しました (${res.statusCode})');
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
    final uid = _db.auth.currentUser?.id;
    if (uid == null) throw const ApiException('ログインが必要です。');
    final max = planMaxApps(await plan());
    if (max != null) {
      final existing = await apps();
      if (existing.length >= max) {
        throw ApiException(
            '現在のプランでは$max件までです。Proにアップグレードすると無制限に連携できます。');
      }
    }
    final row = await _db
        .from('apps')
        .insert({
          'owner': uid,
          'store': store,
          'store_app_id': storeAppId,
          'name': name,
          'description': description,
          'reply_tone': tone,
        })
        .select()
        .single();
    return AppRow.fromJson(Map<String, dynamic>.from(row));
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
    if (unrepliedOnly) listOut = listOut.where((r) => !r.hasReply).toList();
    return listOut;
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
    final json = await _postApi('/api/reply', {
      'reviewId': reviewId,
      'action': 'draft',
    });
    final reply = json['reply'];
    return reply is Map ? (reply['body'] as String? ?? '') : '';
  }

  /// ストアへ返信を投稿（API）。textを渡すとその本文を投稿する。
  static Future<void> postReplyToStore(String reviewId, {String? text}) async {
    await _postApi('/api/reply', {
      'reviewId': reviewId,
      'action': 'post',
      if (text != null && text.trim().isNotEmpty) 'text': text,
    });
  }

  /// 複数レビューへ一括でAI返信を生成（post=trueで投稿まで）。
  /// 返り値: { generated, posted, results:[{reviewId, ok, status?, error?}] }
  static Future<Map<String, dynamic>> bulkReply(
    List<String> reviewIds, {
    bool post = false,
  }) =>
      _postApi('/api/reply/bulk', {
        'reviewIds': reviewIds,
        'action': post ? 'post' : 'draft',
      });

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
      _postApi('/api/poll', {});

  // ---- ストア連携（状態は直接Supabase / 保存はAPIで暗号化） ----
  /// 連携済みストア（'appstore' / 'googleplay'）の一覧。
  static Future<List<String>> connectedStores() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return [];
    final rows =
        await _db.from('store_credentials').select('store').eq('owner', uid);
    return (rows as List).map((e) => e['store'] as String).toList();
  }

  static Future<void> saveAppStoreCredentials({
    required String issuerId,
    required String keyId,
    required String privateKey,
  }) =>
      _postApi('/api/credentials', {
        'store': 'appstore',
        'issuerId': issuerId,
        'keyId': keyId,
        'privateKey': privateKey,
      });

  static Future<void> saveGooglePlayCredentials(String serviceAccountJson) =>
      _postApi('/api/credentials', {
        'store': 'googleplay',
        'serviceAccountJson': serviceAccountJson,
      });

  // ---- 課金（API→URLを外部ブラウザで開く） ----
  static Future<String> checkoutUrl(String plan) async {
    final json = await _postApi('/api/billing/checkout', {'plan': plan});
    final url = json['url'] as String?;
    if (url == null) throw const ApiException('決済URLの取得に失敗しました。');
    return url;
  }

  static Future<String> billingPortalUrl() async {
    final json = await _postApi('/api/billing/portal', {});
    final url = json['url'] as String?;
    if (url == null) throw const ApiException('管理画面URLの取得に失敗しました。');
    return url;
  }

  // ---- プラン ----
  static Future<String> plan() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 'free';
    final row =
        await _db.from('profiles').select('plan').eq('id', uid).maybeSingle();
    return (row?['plan'] as String?) ?? 'free';
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

/// プラン別アプリ数上限（null=無制限）。lib/plan.ts と一致させる。
int? planMaxApps(String plan) => switch (plan) {
      'max' || 'team' => null,
      'pro' => 5,
      _ => 1,
    };

/// 一括返信の1回あたり上限（1=一括不可 / null=無制限）。lib/plan.ts と一致。
int? planBulkLimit(String plan) => switch (plan) {
      'max' || 'team' => null,
      'pro' => 20,
      _ => 1,
    };

String planLabel(String plan) =>
    const {'free': 'Free', 'pro': 'Pro', 'max': 'Max', 'team': 'Team'}[plan] ??
    plan;

/// APIエラー（ユーザー向けメッセージを保持）。
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);
  @override
  String toString() => message;
}
