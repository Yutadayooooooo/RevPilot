// Supabaseのテーブル行に対応するデータモデル。

class AppRow {
  final String id;
  final String store; // appstore | googleplay
  final String storeAppId;
  final String name;
  final String? description;
  final String replyTone;

  /// 返信スタイル（AI返信の書き出し・結び・ルール）。未設定は null。
  final String? replyOpening;
  final String? replyClosing;
  final String? replyRules;

  AppRow({
    required this.id,
    required this.store,
    required this.storeAppId,
    required this.name,
    this.description,
    required this.replyTone,
    this.replyOpening,
    this.replyClosing,
    this.replyRules,
  });

  factory AppRow.fromJson(Map<String, dynamic> j) => AppRow(
        id: j['id'] as String,
        store: j['store'] as String,
        storeAppId: j['store_app_id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        replyTone: (j['reply_tone'] as String?) ?? 'polite',
        replyOpening: j['reply_opening'] as String?,
        replyClosing: j['reply_closing'] as String?,
        replyRules: j['reply_rules'] as String?,
      );

  /// 返信スタイルを1つでも設定しているか。
  bool get hasReplyStyle => [replyOpening, replyClosing, replyRules]
      .any((s) => s != null && s.trim().isNotEmpty);

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

  /// 下書きを含めて何らかの返信があるか（一覧のバッジ表示用）。
  bool get hasReply => replies.isNotEmpty;

  /// ストアへ投稿済みか。
  bool get isPosted => replies.any((r) => r.status == 'posted');

  /// まだストアに返信していない＝対応が必要なレビュー。
  ///
  /// 一括返信の対象を hasReply で絞ると、「下書きだけ生成」した瞬間に
  /// そのレビューが未返信一覧から消え、二度と一括投稿の対象にならなくなる
  /// （＝下書き一括が行き止まりになる）。対象判定は投稿済みかどうかで行う。
  bool get needsReply => !isPosted;

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

/// Free の閲覧範囲（直近30日）より前にある、保存済みレビューの概要。
/// 本文は冒頭だけが届く（全文はアップグレードで読めるようになる）。
class LockedPreview {
  final int hiddenTotal;

  /// うち★1〜2の件数。
  final int hiddenLow;
  final List<LockedReview> samples;

  const LockedPreview({
    required this.hiddenTotal,
    required this.hiddenLow,
    required this.samples,
  });

  static const empty = LockedPreview(hiddenTotal: 0, hiddenLow: 0, samples: []);

  bool get hasHidden => hiddenTotal > 0;

  factory LockedPreview.fromRows(List rows) {
    if (rows.isEmpty) return empty;
    final first = Map<String, dynamic>.from(rows.first as Map);
    return LockedPreview(
      hiddenTotal: (first['hidden_total'] as num?)?.toInt() ?? 0,
      hiddenLow: (first['hidden_low'] as num?)?.toInt() ?? 0,
      samples: rows
          .map((e) => LockedReview.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

class LockedReview {
  final int rating;
  final DateTime? reviewedAt;
  final String appName;
  final String snippet;

  const LockedReview({
    required this.rating,
    required this.reviewedAt,
    required this.appName,
    required this.snippet,
  });

  factory LockedReview.fromJson(Map<String, dynamic> j) => LockedReview(
        rating: (j['rating'] as num?)?.toInt() ?? 0,
        reviewedAt: _dt(j['reviewed_at']),
        appName: (j['app_name'] as String?) ?? '',
        snippet: (j['snippet'] as String?) ?? '',
      );
}

/// 分析タブの集計（DB側で全件を集計した結果）。
class ReviewSummary {
  final int total;
  final double avgRating;
  final int unreplied;

  /// 星（1〜5）ごとの件数。
  final Map<int, int> byRating;

  /// トピックごとの件数。
  final Map<String, int> topics;

  const ReviewSummary({
    required this.total,
    required this.avgRating,
    required this.unreplied,
    required this.byRating,
    required this.topics,
  });

  factory ReviewSummary.fromJson(Map<String, dynamic> j) {
    Map<String, int> ints(Object? v) => {
          for (final e in ((v as Map?) ?? const {}).entries)
            '${e.key}': (e.value as num).toInt(),
        };
    return ReviewSummary(
      total: (j['total'] as num?)?.toInt() ?? 0,
      avgRating: (j['avg_rating'] as num?)?.toDouble() ?? 0,
      unreplied: (j['unreplied'] as num?)?.toInt() ?? 0,
      byRating: ints(j['by_rating'])
          .map((k, v) => MapEntry(int.tryParse(k) ?? 0, v)),
      topics: ints(j['topics']),
    );
  }

  /// 集計関数が使えない環境向けに、取得済みの一覧から作る（直近200件ぶん）。
  factory ReviewSummary.fromReviews(List<ReviewRow> reviews) {
    final byRating = <int, int>{};
    final topics = <String, int>{};
    for (final r in reviews) {
      byRating[r.rating] = (byRating[r.rating] ?? 0) + 1;
      for (final t in r.topics) {
        topics[t] = (topics[t] ?? 0) + 1;
      }
    }
    return ReviewSummary(
      total: reviews.length,
      avgRating: reviews.isEmpty
          ? 0
          : reviews.map((r) => r.rating).reduce((a, b) => a + b) /
              reviews.length,
      unreplied: reviews.where((r) => !r.hasReply).length,
      byRating: byRating,
      topics: topics,
    );
  }
}
