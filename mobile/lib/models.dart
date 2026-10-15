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

  /// 最後にストアから取得した時刻（成功・失敗とも）。まだ一度も取得していなければ null。
  final DateTime? lastPolledAt;

  /// 直近の取得が失敗したときのサーバー側の文面（成功すると null に戻る）。
  /// 生の英語のことがあるので、画面には [lastErrorText] を出す。
  final String? lastError;
  final DateTime? lastErrorAt;

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
    this.lastPolledAt,
    this.lastError,
    this.lastErrorAt,
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
        lastPolledAt: _dt(j['last_polled_at']),
        lastError: j['last_error'] as String?,
        lastErrorAt: _dt(j['last_error_at']),
      );

  /// 直近の取得が失敗しているか（連携が切れている・権限が足りない など）。
  bool get hasPollError => (lastError ?? '').trim().isNotEmpty;

  /// 取得エラーの理由（短い日本語）。エラーが無ければ null。
  String? get lastErrorText => hasPollError ? storeErrorText(lastError) : null;

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

  bool get isDraft => status == 'draft';

  /// 利用者が「ストアで返信済み」にした行（App Store Connect に貼り付けた など）。
  bool get isCopied => status == 'copied';

  /// ストアでの返信が済んだことを表す行か（API で投稿した posted か、手動の copied）。
  bool get isReplied => status == 'posted' || isCopied;

  /// 返信した日時（投稿日時が無い行は作成日時）。
  DateTime get repliedAt => postedAt ?? createdAt;
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

  /// 返信の履歴（新しい順）。replies は追記だけのテーブルで、AI生成・下書き保存・
  /// 投稿のたびに行が増える。並び順はサーバーに頼らず fromJson でそろえる。
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

  /// いちばん新しい返信の行（状態を問わない）。
  ReplyRow? get latestReply => replies.firstOrNull;

  /// いちばん新しい下書き。
  ReplyRow? get latestDraft => replies.where((r) => r.isDraft).firstOrNull;

  /// ストアへ API で投稿した最新の行（手動の「返信済み」は含まない）。
  ReplyRow? get postedReply =>
      replies.where((r) => r.status == 'posted').firstOrNull;

  /// 返信済みを表す最新の行（posted か copied）。
  ReplyRow? get repliedReply => replies.where((r) => r.isReplied).firstOrNull;

  /// ストアでの返信が済んでいるか（API で投稿した、または手動で返信済みにした）。
  bool get isPosted => repliedReply != null;

  /// 最新の返信済みが、利用者の手動の記録（copied）か。
  /// 一覧のバッジを「返信済み（手動）」にするなどの出し分けに使う。
  bool get isMarkedReplied => repliedReply?.isCopied ?? false;

  /// 返信済みのあとに新しい下書きがあるか（投稿に失敗した下書き・書き直し中など）。
  bool get hasNewerDraft {
    final draft = latestDraft;
    final done = repliedReply;
    if (draft == null) return false;
    return done == null || draft.createdAt.isAfter(done.createdAt);
  }

  /// 返信の編集欄に最初に入れる本文。
  /// いちばん新しい行の本文（投稿済みより新しい下書きがあればそれ、無ければ投稿済みの本文）。
  /// 本文が空の行（本文なしで返信済みにした記録）は飛ばす。
  String get draftBody =>
      replies.where((r) => r.body.trim().isNotEmpty).firstOrNull?.body ?? '';

  /// まだストアに返信していない＝対応が必要なレビュー。
  ///
  /// 一括返信の対象を hasReply で絞ると、「下書きだけ生成」した瞬間に
  /// そのレビューが未返信一覧から消え、二度と一括投稿の対象にならなくなる
  /// （＝下書き一括が行き止まりになる）。対象判定は返信済みかどうかで行う。
  /// 手動で返信済みにしたもの（copied）は対象外にする。含めると一括投稿で
  /// ストアに貼り付けた返信がAIの文面で上書きされてしまう。
  bool get needsReply => !isPosted;

  /// 返信を1件足した写し（保存・返信済みの記録の直後に、画面の表示を更新する用）。
  ReviewRow withReply(ReplyRow reply) => ReviewRow(
        id: id,
        appId: appId,
        store: store,
        rating: rating,
        title: title,
        body: body,
        author: author,
        territory: territory,
        appVersion: appVersion,
        reviewedAt: reviewedAt,
        topics: topics,
        replies: [reply, ...replies]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
        appName: appName,
      );

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
    // 新しい順。埋め込みの replies は順序の指定が無いと実質挿入順になり、
    // replies.first が最初のAI下書きを指してしまう。
    replies.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final app = j['apps'];
    return ReviewRow(
      id: j['id'] as String,
      // 軽量な取得（通知用など）で列が欠けていても、全体を落とさない。
      appId: (j['app_id'] as String?) ?? '',
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

/// レビュー一覧の1ページ分。
class ReviewPage {
  final List<ReviewRow> items;

  /// 続きがありそうか（今回ちょうど上限まで返ってきた）。
  final bool hasMore;

  /// 次のページを読むときに Repo.reviewsPage(offset:) へ渡す値。
  final int nextOffset;

  const ReviewPage({
    required this.items,
    required this.hasMore,
    required this.nextOffset,
  });
}

/// ストアからの手動取得（POST /api/poll）の結果。
///
/// サーバーは一部のアプリで失敗しても 200 を返すので、成功表示の前に
/// [failed] と [errors] を必ず見る。
class PollOutcome {
  /// 新しく取り込んだレビュー件数。
  final int inserted;

  /// 今回取得を試したアプリ数。
  final int apps;

  /// 今回は回らず、次回以降に回したアプリ数（1回の手動取得で回る本数には上限がある）。
  final int skipped;

  /// 取得に失敗したアプリ数。
  final int failed;
  final List<PollError> errors;

  const PollOutcome({
    required this.inserted,
    this.apps = 0,
    this.skipped = 0,
    this.failed = 0,
    this.errors = const [],
  });

  factory PollOutcome.fromJson(Map<String, dynamic> j) {
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final errors = [
      for (final e in (j['errors'] as List?) ?? const []) PollError.fromJson(e),
    ];
    return PollOutcome(
      inserted: n(j['inserted']),
      apps: n(j['apps']),
      skipped: n(j['skipped']),
      failed: n(j['failed']) > errors.length ? n(j['failed']) : errors.length,
      errors: errors,
    );
  }

  bool get hasNew => inserted > 0;
  bool get hasFailures => failed > 0;

  /// 1件も取り込めず、失敗だけがあった（エラーとして見せる）。
  bool get isError => hasFailures && inserted == 0;

  /// 結果の要約（スナックバーの1行目向け）。
  String get headline {
    if (hasFailures) {
      return inserted > 0
          ? '$inserted件を取り込みました（$failed件のアプリで取得に失敗）'
          : '$failed件のアプリでレビューの取得に失敗しました';
    }
    if (hasNew) return '$inserted件の新しいレビューを取り込みました';
    return '新しいレビューはありませんでした';
  }

  /// 回りきれなかったアプリがあるときの添え書き。無ければ null。
  String? get skippedNote => skipped > 0
      ? '残り$skipped件のアプリは自動取得で順次更新します（もう一度取得すると続きを読み込みます）'
      : null;
}

/// アプリごとの取得失敗。
class PollError {
  final String? appId;

  /// アプリ名（サーバーが返さない場合は Repo が apps から補う。分からなければ null）。
  final String? appName;

  /// 利用者向けの短い日本語（[raw] を storeErrorText で置き換えたもの）。
  final String message;

  /// サーバーが返した元の文面（ログ・問い合わせ用。画面には出さない）。
  final String raw;

  const PollError({
    this.appId,
    this.appName,
    required this.message,
    required this.raw,
  });

  /// サーバーは文字列だけ、または {appId, appName?, message} を返す。どちらも受け付ける。
  factory PollError.fromJson(Object? e) {
    if (e is Map) {
      final raw = '${e['message'] ?? e['error'] ?? ''}';
      return PollError(
        appId: e['appId'] as String? ?? e['app_id'] as String?,
        appName: e['appName'] as String? ?? e['app_name'] as String?,
        message: storeErrorText(raw),
        raw: raw,
      );
    }
    final raw = '${e ?? ''}';
    return PollError(message: storeErrorText(raw), raw: raw);
  }

  PollError withAppName(String? name) =>
      PollError(appId: appId, appName: name, message: message, raw: raw);

  /// 「アプリ名：理由」の1行（アプリ名が分からなければ理由だけ）。
  String get line => appName == null ? message : '$appName：$message';
}

/// アプリ追加の結果（POST /api/apps）。
/// サーバーは追加の直後に、そのアプリの最初の取得まで行う（最大15秒待ち、残りは応答のあとで続ける）。
class AddAppResult {
  final AppRow app;

  /// 実際に保存された名前（名前を空で追加したときは、ストアでの名前かパッケージ名）。
  final String name;

  /// 最初の取得の状態。'done'（取り込み済み）| 'failed' | 'pending'（取り込み中）|
  /// 'skipped'（短時間に追加が続いたので毎時の自動取得に任せた）。古いサーバーでは null。
  final String? initialFetch;

  /// 最初の取得で取り込んだ件数。
  final int inserted;

  /// 最初の取得に失敗した理由（短い日本語）。failed のときだけ。
  final String? fetchError;

  const AddAppResult({
    required this.app,
    required this.name,
    this.initialFetch,
    this.inserted = 0,
    this.fetchError,
  });

  factory AddAppResult.fromJson(Map<String, dynamic> j) {
    final app = AppRow.fromJson(Map<String, dynamic>.from(j['app'] as Map));
    final f = j['initial_fetch'];
    final fetch = f is Map ? Map<String, dynamic>.from(f) : const <String, dynamic>{};
    final name = (j['name'] as String?)?.trim() ?? '';
    final error = fetch['error'] as String?;
    return AddAppResult(
      app: app,
      name: name.isEmpty ? app.name : name,
      initialFetch: fetch['status'] as String?,
      inserted: (fetch['inserted'] as num?)?.toInt() ?? 0,
      fetchError: error == null || error.trim().isEmpty ? null : storeErrorText(error),
    );
  }
}

final _japaneseChars = RegExp(r'[\u3040-\u30FF\u3400-\u9FFF\uFF01-\uFF5E]');

/// 日本語（かな・漢字・全角記号）を含む文面か。
/// サーバーが用意した案内文と、ストアや基盤の生のエラー（英語）を見分けるのに使う。
bool looksJapanese(String text) => _japaneseChars.hasMatch(text);

/// 長い文面を画面に収まる長さに切る。
String clipMessage(String text, {int max = 80}) {
  final t = text.trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// ストアAPIの生のエラー文（'ASC 401: {...}' など）を、短い日本語にする。
///
/// サーバーが用意した日本語の案内（「認証情報が未登録です」など）はそのまま使い、
/// 長すぎれば切り詰める。英語やJSONは画面に出さない。
String storeErrorText(String? raw) {
  final text = (raw ?? '').trim();
  final reason = storeErrorReason(text);
  if (reason != null) return reason;
  if (looksJapanese(text)) return clipMessage(text);
  return 'ストアでエラーが発生しました。時間をおいて再度お試しください。';
}

/// 生のエラー文から分かる理由（短い日本語）。日本語の文面や見当がつかないものは null。
String? storeErrorReason(String raw) {
  if (raw.isEmpty || looksJapanese(raw)) return null;
  // 'ASC 403: …' / 'GooglePlay 404: …' / 'GooglePlay reply 401: …' の形なら番号で判断する。
  final head = RegExp(r'^(?:ASC|GooglePlay(?: reply)?)\s+(\d{3})\b').firstMatch(raw);
  final status = int.tryParse(head?.group(1) ?? '');
  final lower = raw.toLowerCase();
  if (status == 429 ||
      lower.contains('rate limit') ||
      lower.contains('too many requests') ||
      lower.contains('quota')) {
    return 'ストアの回数制限に達しました。少し待ってから再度お試しください。';
  }
  if (status == 401 ||
      status == 403 ||
      (status == null &&
          RegExp(r'\b(401|403)\b|unauthori[sz]ed|forbidden|permission|invalid_grant')
              .hasMatch(lower))) {
    return '鍵が失効しているか、権限が足りません。ストア連携をご確認ください。';
  }
  if (status == 404 ||
      (status == null && RegExp(r'\b404\b|not found').hasMatch(lower))) {
    return 'アプリが見つかりません。アプリID（パッケージ名）をご確認ください。';
  }
  if (RegExp(r'fetch failed|network|timed? ?out|econn|enotfound|eai_again|socket')
      .hasMatch(lower)) {
    return 'ストアとの通信に失敗しました。時間をおいて再度お試しください。';
  }
  if ((status != null && status >= 500) ||
      (status == null && RegExp(r'\b5\d\d\b').hasMatch(lower))) {
    return 'ストア側で一時的な障害が起きています。時間をおいて再度お試しください。';
  }
  return null;
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

  /// 未返信の件数だけを差し替えた写し。
  ReviewSummary withUnreplied(int value) => ReviewSummary(
        total: total,
        avgRating: avgRating,
        unreplied: value,
        byRating: byRating,
        topics: topics,
      );

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
      unreplied: reviews.where((r) => r.needsReply).length,
      byRating: byRating,
      topics: topics,
    );
  }
}
