// Supabaseのテーブル行に対応するデータモデル。

class AppRow {
  final String id;
  final String store; // appstore | googleplay
  final String storeAppId;
  final String name;
  final String? description;
  final String replyTone;

  AppRow({
    required this.id,
    required this.store,
    required this.storeAppId,
    required this.name,
    this.description,
    required this.replyTone,
  });

  factory AppRow.fromJson(Map<String, dynamic> j) => AppRow(
        id: j['id'] as String,
        store: j['store'] as String,
        storeAppId: j['store_app_id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        replyTone: (j['reply_tone'] as String?) ?? 'polite',
      );

  String get storeLabel => store == 'appstore' ? 'App Store' : 'Google Play';
}

class ReplyRow {
  final String id;
  final String body;
  final String status; // draft | posted | copied
  final String source; // ai | manual
  final DateTime? postedAt;
  final DateTime createdAt;

  ReplyRow({
    required this.id,
    required this.body,
    required this.status,
    required this.source,
    this.postedAt,
    required this.createdAt,
  });

  factory ReplyRow.fromJson(Map<String, dynamic> j) => ReplyRow(
        id: j['id'] as String,
        body: (j['body'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'draft',
        source: (j['source'] as String?) ?? 'ai',
        postedAt: _dt(j['posted_at']),
        createdAt: _dt(j['created_at']) ?? DateTime.now(),
      );
}

class ReviewRow {
  final String id;
  final String appId;
  final String store;
  final int rating;
  final String? title;
  final String? body;
  final String? author;
  final String? territory;
  final String? appVersion;
  final DateTime? reviewedAt;
  final List<String> topics;
  final List<ReplyRow> replies;
  final String? appName;

  ReviewRow({
    required this.id,
    required this.appId,
    required this.store,
    required this.rating,
    this.title,
    this.body,
    this.author,
    this.territory,
    this.appVersion,
    this.reviewedAt,
    this.topics = const [],
    this.replies = const [],
    this.appName,
  });

  bool get hasReply => replies.isNotEmpty;
  bool get isPosted => replies.any((r) => r.status == 'posted');

  factory ReviewRow.fromJson(Map<String, dynamic> j) {
    final topics = <String>[];
    final rawTopics = j['review_topics'];
    if (rawTopics is List) {
      for (final t in rawTopics) {
        if (t is Map && t['topic'] != null) topics.add(t['topic'] as String);
      }
    }
    final replies = <ReplyRow>[];
    final rawReplies = j['replies'];
    if (rawReplies is List) {
      for (final r in rawReplies) {
        if (r is Map) replies.add(ReplyRow.fromJson(Map<String, dynamic>.from(r)));
      }
    }
    final app = j['apps'];
    return ReviewRow(
      id: j['id'] as String,
      appId: j['app_id'] as String,
      store: (j['store'] as String?) ?? 'appstore',
      rating: (j['rating'] as num?)?.toInt() ?? 0,
      title: j['title'] as String?,
      body: j['body'] as String?,
      author: j['author'] as String?,
      territory: j['territory'] as String?,
      appVersion: j['app_version'] as String?,
      reviewedAt: _dt(j['reviewed_at']),
      topics: topics,
      replies: replies,
      appName: app is Map ? app['name'] as String? : null,
    );
  }
}

DateTime? _dt(dynamic v) {
  if (v == null) return null;
  if (v is String) return DateTime.tryParse(v)?.toLocal();
  return null;
}

/// 運営からのお知らせ。
class Announcement {
  final String id;
  final String title;
  final String? body;
  final String level; // info | warning | critical

  Announcement({
    required this.id,
    required this.title,
    this.body,
    this.level = 'info',
  });

  factory Announcement.fromJson(Map<String, dynamic> j) => Announcement(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? '',
        body: j['body'] as String?,
        level: (j['level'] as String?) ?? 'info',
      );
}

/// トピックの日本語ラベル（Web分析画面と統一）。
const topicLabels = {
  'bug': '不具合',
  'feature_request': '要望',
  'ux': '使い勝手',
  'price': '価格',
  'praise': '称賛',
  'other': 'その他',
};
