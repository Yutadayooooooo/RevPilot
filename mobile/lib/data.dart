import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'models.dart';

/// Supabaseへのデータアクセス。RLSにより自分のデータのみ返る。
class Repo {
  static SupabaseClient get _db => Supabase.instance.client;

  static Future<List<AppRow>> apps() async {
    final rows = await _db
        .from('apps')
        .select()
        .order('created_at', ascending: false);
    return (rows as List)
        .map((e) => AppRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// レビュー一覧。星・アプリ・未返信でのフィルタに対応。
  static Future<List<ReviewRow>> reviews({
    String? appId,
    int? minRating,
    int? maxRating,
    bool unrepliedOnly = false,
  }) async {
    var query = _db.from('reviews').select(
        '*, apps!inner(name), replies(*), review_topics(topic)');

    if (appId != null) query = query.eq('app_id', appId);
    if (minRating != null) query = query.gte('rating', minRating);
    if (maxRating != null) query = query.lte('rating', maxRating);

    final rows = await query.order('reviewed_at', ascending: false).limit(200);
    var list = (rows as List)
        .map((e) => ReviewRow.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    if (unrepliedOnly) list = list.where((r) => !r.hasReply).toList();
    return list;
  }

  /// 手動更新（ストアから新着レビュー取得）はNext.js API連携後に実装予定。
  static bool get canRefresh => AppConfig.hasApi;

  /// プラン情報。
  static Future<String> plan() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return 'free';
    final row =
        await _db.from('profiles').select('plan').eq('id', uid).maybeSingle();
    return (row?['plan'] as String?) ?? 'free';
  }

  /// レビューへの返信ドラフトをローカル保存（AI生成はAPI接続後）。
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
}
