import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_events.dart';
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
  }) =>
      _request('POST', path, body: body, timeout: timeout);

  static const _offlineMessage =
      'サーバーに接続できませんでした。通信環境をご確認のうえ、時間をおいて再度お試しください。';
  static const _expiredMessage = 'ログインの有効期限が切れました。もう一度ログインしてください。';

  /// API を呼ぶ共通処理。
  ///
  /// アクセストークンは期限切れなら先に更新し、それでも 401 なら一度だけ更新して送り直す
  /// （長くバックグラウンドにしていた直後は、自動更新より先に送ってしまうことがある）。
  /// サーバーは認証を最初に確認するので、送り直しても処理が二重になることはない。
  static Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 30),
    String? fallbackError,
  }) async {
    if (!AppConfig.hasApi) {
      throw const ApiException('この機能はご利用いただけません。時間をおいて再度お試しください。');
    }
    var res = await _send(method, path, await _accessToken(), body, timeout);
    if (res.statusCode == 401) {
      res = await _send(
          method, path, await _accessToken(refresh: true), body, timeout);
    }
    Map<String, dynamic> json = {};
    try {
      json = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    throw ApiException(
        _serverMessage(json['error'] as String?, res.statusCode, fallbackError),
        statusCode: res.statusCode);
  }

  static Future<http.Response> _send(
    String method,
    String path,
    String token,
    Map<String, dynamic>? body,
    Duration timeout,
  ) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}$path');
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
    final encoded = body == null ? null : jsonEncode(body);
    try {
      return await switch (method) {
        'GET' => http.get(uri, headers: headers),
        'DELETE' => http.delete(uri, headers: headers, body: encoded),
        _ => http.post(uri, headers: headers, body: encoded),
      }
          .timeout(timeout);
    } catch (_) {
      // 接続失敗/タイムアウトは生の ClientException を出さず、利用者向けの文言に。
      throw const ApiException(_offlineMessage);
    }
  }

  /// 送信に使うアクセストークン。期限切れ（間近）なら先に更新する。
  static Future<String> _accessToken({bool refresh = false}) async {
    final auth = _db.auth;
    final session = auth.currentSession;
    if (session == null) throw const ApiException('ログインが必要です。', statusCode: 401);
    if (!refresh && !session.isExpired) return session.accessToken;
    try {
      final res = await auth.refreshSession();
      return res.session?.accessToken ?? session.accessToken;
    } on AuthRetryableFetchException {
      // 電波が悪いだけ。ログアウトはさせずに通信エラーとして伝える。
      throw const ApiException(_offlineMessage);
    } on AuthException {
      // 更新トークンが無効＝ログインし直すしかない（gotrue がログアウトを通知する）。
      throw const ApiException(_expiredMessage, statusCode: 401);
    }
  }

  /// サーバーの error 文を利用者向けにそろえる。
  /// 日本語の案内はそのまま使い、英語（"unauthorized" や Supabase の生のエラー）は
  /// 状態コードに応じた日本語に置き換える。
  static String _serverMessage(String? raw, int status, String? fallback) {
    final text = (raw ?? '').trim();
    if (looksJapanese(text)) {
      // 日本語の案内の末尾に、ストアの生の応答（'ASC 403: {...}' など）が
      // 「（…）」で付くことがある。理由が分かれば短い日本語に、分からなければ外す。
      return text.replaceFirstMapped(RegExp(r'（([^（）]*)）\s*$'), (m) {
        final inner = m.group(1)!;
        // 日本語や番号だけ（「（500）」など）はそのままでよい。
        if (looksJapanese(inner) || !RegExp(r'[A-Za-z]').hasMatch(inner)) {
          return m.group(0)!;
        }
        final reason = storeErrorReason(inner);
        return reason == null ? '' : '（$reason）';
      });
    }
    if (fallback != null) return fallback;
    return switch (status) {
      401 => _expiredMessage,
      403 => 'この操作を行う権限がありません。',
      404 => '対象が見つかりませんでした。画面を更新してから再度お試しください。',
      429 => 'リクエストが多すぎます。少し時間をおいて再度お試しください。',
      >= 500 => 'サーバーでエラーが発生しました。時間をおいて再度お試しください。',
      _ => 'エラーが発生しました。時間をおいて再度お試しください。',
    };
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
  ///
  /// サーバーは追加の直後に、そのアプリの最初の取得まで行う（結果は [AddAppResult]）。
  /// 続けて [refreshFromStores] を呼ぶと「新しいレビューはありませんでした」になるので呼ばない。
  /// [name] は App Store なら空でよい（ストアに登録されている名前が使われる）。
  static Future<AddAppResult> addApp({
    required String store,
    required String storeAppId,
    required String name,
    String? description,
    String tone = 'polite',
    String? replyOpening,
    String? replyClosing,
    String? replyRules,
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
        'reply_opening': replyOpening,
        'reply_closing': replyClosing,
        'reply_rules': replyRules,
      },
      timeout: const Duration(seconds: 45), // ストアへの疎通確認と最初の取得（最大15秒）を含む
    );
    final result = AddAppResult.fromJson(json);
    AppEvents.notifyDataChanged(DataChange.apps);
    // 最初の取得でレビューが入った：一覧・通知・分析も読み直させる。
    if (result.inserted > 0) AppEvents.notifyDataChanged(DataChange.reviews);
    return result;
  }

  /// アプリの編集。[style] は変更した欄だけを渡す（null の値は「空にする」）。
  /// 触っていない列を送らないのは、返信スタイルの列が未適用のDBでも
  /// 名前やトーンの編集が失敗しないようにするため。
  static Future<void> updateApp(
    String id, {
    required String name,
    String? description,
    required String tone,
    Map<String, String?> style = const {},
  }) async {
    await _db.from('apps').update({
      'name': name,
      'description': description,
      'reply_tone': tone,
      ...style,
    }).eq('id', id);
    AppEvents.notifyDataChanged(DataChange.apps);
  }

  static Future<void> deleteApp(String id) async {
    await _db.from('apps').delete().eq('id', id);
    AppEvents.notifyDataChanged(DataChange.apps);
  }

  // ---- レビュー ----
  /// 一覧・詳細で使う列（返信の履歴とトピックを含む）。
  static const _reviewSelect =
      '*, apps!inner(name), replies(*), review_topics(topic)';

  /// レビュー一覧。星（複数可）・アプリ・ストア・未返信フィルタ・キーワードと並び替えに対応。
  /// 続きを読むときは [offset] を進める（[reviewsPage] の nextOffset を使うと確実）。
  static Future<List<ReviewRow>> reviews({
    String? appId,
    String? store,
    List<int>? ratings,
    bool unrepliedOnly = false,
    String? keyword,
    ReviewSort sort = ReviewSort.newest,
    int offset = 0,
    int limit = 200,
  }) async =>
      (await reviewsPage(
        appId: appId,
        store: store,
        ratings: ratings,
        unrepliedOnly: unrepliedOnly,
        keyword: keyword,
        sort: sort,
        offset: offset,
        limit: limit,
      ))
          .items;

  /// レビュー一覧の1ページ。[reviews] と同じ条件で、続きがあるかと次の offset も返す。
  ///
  /// 「未返信のみ」はサーバー側で絞る。以前は新しい200件を取ってから端末で絞っていたため、
  /// 201件目より古い未返信が「未返信のみ」にしても一切出なかった。
  static Future<ReviewPage> reviewsPage({
    String? appId,
    String? store,
    List<int>? ratings,
    bool unrepliedOnly = false,
    String? keyword,
    ReviewSort sort = ReviewSort.newest,
    int offset = 0,
    int limit = 50,
  }) async {
    Future<List<Map<String, dynamic>>> fetch({required bool serverUnreplied}) {
      // 未返信の絞り込みは、返信済み（posted / copied）の行だけを別名 done で埋め込み、
      // それが空のレビューだけを残す（PostgREST の anti-join）。
      var query = _db.from('reviews').select(
          serverUnreplied ? '$_reviewSelect, done:replies(id)' : _reviewSelect);
      if (appId != null) query = query.eq('app_id', appId);
      if (store != null) query = query.eq('store', store);
      if (ratings != null && ratings.isNotEmpty) {
        query = query.inFilter('rating', ratings);
      }
      final q = keyword?.trim() ?? '';
      if (q.isNotEmpty) {
        final v = _ilikeValue(q);
        query = query.or('title.ilike.$v,body.ilike.$v');
      }
      if (serverUnreplied) {
        query = query
            .inFilter('done.status', ['posted', 'copied'])
            .isFilter('done', null);
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
      // 同じ日時のレビューがページの境目で重複・欠落しないよう、最後に id でも並べる。
      return ordered.order('id', ascending: true).range(offset, offset + limit - 1);
    }

    List<Map<String, dynamic>> rows;
    var filtered = false;
    if (unrepliedOnly) {
      try {
        rows = await fetch(serverUnreplied: true);
        filtered = true;
      } on PostgrestException {
        // 埋め込みへの null 絞り込みに対応していない古い PostgREST 向け。
        // 従来どおり取得後に端末で絞る（このときは古い未返信が漏れうる）。
        rows = await fetch(serverUnreplied: false);
      }
    } else {
      rows = await fetch(serverUnreplied: false);
    }
    var items = rows.map(ReviewRow.fromJson).toList();
    // サーバーで絞れなかった場合は端末で絞る（判定は needsReply にそろえる）。
    if (unrepliedOnly && !filtered) {
      items = items.where((r) => r.needsReply).toList();
    }
    return ReviewPage(
      items: items,
      hasMore: rows.length >= limit,
      nextOffset: offset + rows.length,
    );
  }

  /// レビュー1件を一覧と同じ列（返信の履歴・トピック込み）で取り直す。
  /// 通知から詳細を開くときなど、軽量な行しか手元にない場合に使う。見つからなければ null。
  static Future<ReviewRow?> reviewById(String id) async {
    final row = await _db
        .from('reviews')
        .select(_reviewSelect)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : ReviewRow.fromJson(row);
  }

  /// キーワード検索の値を PostgREST の or= に埋め込める形にする。
  /// LIKE の記号（% _ \）は文字として扱い、区切りになる , ( ) を含んでも壊れないよう
  /// 値全体を "" で囲む（"" の中では \ と " を \ でエスケープする）。
  static String _ilikeValue(String keyword) {
    final like = keyword.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');
    final quoted = '%$like%'.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '"$quoted"';
  }

  /// 分析タブの集計。DB 側で全件を集計する（端末で200件だけ平均すると数字がずれるため）。
  /// 集計関数が未作成のDBでは、従来どおり一覧から計算する。
  static Future<ReviewSummary> reviewSummary({String? appId, String? store}) async {
    try {
      final unrepliedFuture = unrepliedCount(appId: appId, store: store);
      final rows = await _db.rpc('my_review_summary',
          params: {'p_app': appId, 'p_store': store});
      final list = rows as List;
      if (list.isNotEmpty) {
        final summary =
            ReviewSummary.fromJson(Map<String, dynamic>.from(list.first as Map));
        // 集計関数の「未返信」は返信の行が1つも無いもので、下書きだけでも返信済みに
        // 数えてしまう。一覧の「未返信のみ」と同じ定義（posted / copied が無い）の件数で上書きする。
        final unreplied = await unrepliedFuture;
        return unreplied == null ? summary : summary.withUnreplied(unreplied);
      }
    } catch (_) {}
    return ReviewSummary.fromReviews(await reviews(appId: appId, store: store));
  }

  /// 未返信（posted / copied の返信が無い）レビューの件数。一覧の「未返信のみ」と同じ定義。
  /// 数えられない環境（古い PostgREST など）では null。
  static Future<int?> unrepliedCount({String? appId, String? store}) async {
    try {
      var query = _db.from('reviews').select('id, done:replies(id)');
      if (appId != null) query = query.eq('app_id', appId);
      if (store != null) query = query.eq('store', store);
      final res = await query
          .inFilter('done.status', ['posted', 'copied'])
          .isFilter('done', null)
          .limit(1)
          .count(CountOption.exact);
      return res.count;
    } catch (_) {
      return null;
    }
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
    // app_id は ReviewRow に必須なので必ず含める（欠けると全件の読み込みが失敗し、
    // 通知タブが常に空・未読バッジが常に0になっていた）。
    // replies は返信済みの判定に使う最小限の列だけ（ReplyRow は id が必須）。
    var query = _db.from('reviews').select(
        'id, app_id, store, rating, title, body, reviewed_at, apps!inner(name), '
        'replies(id, status, created_at)');
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

  /// Free の閲覧範囲より前にある、保存済みレビューの件数と抜粋。
  /// 関数が未作成（スキーマ未適用）でも画面を落とさないよう、失敗時は空を返す。
  static Future<LockedPreview> lockedPreview({int limit = 3}) async {
    try {
      final rows = await _db
          .rpc('locked_reviews_preview', params: {'p_limit': limit});
      return LockedPreview.fromRows(rows as List);
    } catch (_) {
      return LockedPreview.empty;
    }
  }

  /// 保存済みレビューのうち、まだ分類されていないものをAIで分類させる（API）。
  ///
  /// 分類は取り込みのときにしか走らず、そのときのプランが対象でなければ行われない。
  /// そのため Free で使っていた人が契約しても、トピック傾向は空のままになる。
  /// 分析タブはこれを呼んで、契約した直後から傾向が出るようにする。
  /// 戻り値: 今回分類できた件数と、まだ分類できていない件数。
  static Future<({int classified, int remaining})> backfillTopics() async {
    final json = await _postApi(
      '/api/analytics/topics',
      {},
      timeout: const Duration(seconds: 120), // 60件ぶんのAI分類で最大1分強かかる
    );
    return (
      classified: (json['classified'] as num?)?.toInt() ?? 0,
      remaining: (json['remaining'] as num?)?.toInt() ?? 0,
    );
  }

  /// AI返信の生成（API）。生成文は replies に保存され本文が返る。
  static Future<String> generateAiReply(String reviewId) async {
    final json = await _postApi(
      '/api/reply',
      {'reviewId': reviewId, 'action': 'draft'},
      timeout: const Duration(seconds: 60), // AI生成は数秒〜十数秒かかる
    );
    AppEvents.notifyDataChanged(DataChange.replies);
    final reply = json['reply'];
    return reply is Map ? (reply['body'] as String? ?? '') : '';
  }

  /// ストアへ返信を投稿（API）。textを渡すとその本文を投稿する。
  /// 投稿に失敗した場合（502）も、サーバーは本文を下書きとして保存している。
  static Future<void> postReplyToStore(String reviewId, {String? text}) async {
    try {
      await _postApi(
        '/api/reply',
        {
          'reviewId': reviewId,
          'action': 'post',
          if (text != null && text.trim().isNotEmpty) 'text': text,
        },
        timeout: const Duration(seconds: 60),
      );
    } on ApiException catch (e) {
      if (e.statusCode == 502) AppEvents.notifyDataChanged(DataChange.replies);
      rethrow;
    }
    AppEvents.notifyDataChanged(DataChange.replies);
  }

  /// 複数レビューへ一括でAI返信を生成（post=trueで投稿まで）。
  /// 返り値: { generated, posted, skipped, results:[{reviewId, ok, status?, error?}] }
  ///
  /// サーバーは最大300秒かけて処理し、時間内に終わらなかった分を skipped として返す。
  /// クライアントのタイムアウトはそれより長くしておく必要がある。
  static Future<Map<String, dynamic>> bulkReply(
    List<String> reviewIds, {
    bool post = false,
  }) async {
    final json = await _postApi(
      '/api/reply/bulk',
      {
        'reviewIds': reviewIds,
        'action': post ? 'post' : 'draft',
      },
      timeout: const Duration(seconds: 320),
    );
    AppEvents.notifyDataChanged(DataChange.replies);
    return json;
  }

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
    AppEvents.notifyDataChanged(DataChange.replies);
    return ReplyRow.fromJson(Map<String, dynamic>.from(row));
  }

  /// ストアの管理画面（App Store Connect など）で直接返信したことを記録する（直接Supabase）。
  ///
  /// status 'copied' の行を追加する。これで未返信の一覧・一括返信の対象から外れ、
  /// 手動で入れた返信がAIの文面で上書きされることを防ぐ。
  /// replies は追記だけのテーブルなので、取り消すには新しい下書きを保存する
  /// （hasNewerDraft が true になる）か、ストアに投稿し直す。
  /// [body] には貼り付けた本文を渡す（分からなければ空でよい）。
  static Future<ReplyRow> markReplied(String reviewId, {String body = ''}) async {
    final row = await _db
        .from('replies')
        .insert({
          'review_id': reviewId,
          'body': body,
          'status': 'copied',
          'source': 'manual',
          'posted_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select()
        .single();
    AppEvents.notifyDataChanged(DataChange.replies);
    return ReplyRow.fromJson(Map<String, dynamic>.from(row));
  }

  // ---- ストアから取得（手動更新 / API） ----
  static bool get canRefresh => AppConfig.hasApi;

  /// ストアAPIから新着レビューを取り込む。
  ///
  /// サーバーは一部のアプリで失敗しても 200 を返すので、結果は必ず [PollOutcome] で見る
  /// （failed / errors を見ずに「取得しました」と出すと、連携が切れていても気づけない）。
  /// 1分に2回を超えると ApiException（429）になる。
  static Future<PollOutcome> refreshFromStores() async {
    final json =
        await _postApi('/api/poll', {}, timeout: const Duration(seconds: 90));
    var outcome = PollOutcome.fromJson(json);
    // サーバーがアプリ名を返さない場合は、手元のアプリ一覧から補う。
    if (outcome.errors.any((e) => e.appName == null && e.appId != null)) {
      try {
        final names = {for (final a in await apps()) a.id: a.name};
        outcome = PollOutcome(
          inserted: outcome.inserted,
          apps: outcome.apps,
          skipped: outcome.skipped,
          failed: outcome.failed,
          errors: [
            for (final e in outcome.errors)
              e.appName == null ? e.withAppName(names[e.appId]) : e,
          ],
        );
      } catch (_) {}
    }
    // 新着が無くても、各アプリの最終取得時刻・エラーは変わっている。
    AppEvents.notifyDataChanged(DataChange.reviews);
    return outcome;
  }

  // ---- ストア連携（保存も参照もAPI経由） ----
  /// 連携済みストア（'appstore' / 'googleplay'）の一覧。
  ///
  /// store_credentials はクライアントから直接読めないようRLSで閉じてあるため、
  /// （暗号化済みとはいえ資格情報をクライアントに配る理由がない）APIから取得する。
  /// 確認できなかったとき（通信エラーなど）は ApiException を投げる。
  /// 以前は空を返していたため、電波が悪いだけで「未連携」と表示されていた。
  static Future<List<String>> connectedStores() async {
    if (!AppConfig.hasApi) return [];
    if (_db.auth.currentSession == null) return [];
    final json = await _request('GET', '/api/credentials',
        timeout: const Duration(seconds: 20));
    return ((json['connected'] as List?) ?? []).cast<String>();
  }

  /// ストア連携を解除する（保存済みの鍵を削除する）。取得済みのレビューは残る。
  /// 以後、そのストアのアプリは毎時の取得で「認証情報が未登録です」のエラーになる。
  static Future<void> disconnectStore(String store) async {
    await _request(
      'DELETE',
      '/api/credentials',
      body: {'store': store},
      timeout: const Duration(seconds: 20),
      fallbackError: '連携を解除できませんでした。時間をおいて再度お試しください。',
    );
    AppEvents.notifyDataChanged(DataChange.stores);
  }

  // 資格情報の保存はサーバー側で実際にストアAPIへ疎通確認してから行われる。
  // 検証に失敗した場合は保存されず、理由が ApiException として返る。
  static Future<void> saveAppStoreCredentials({
    required String issuerId,
    required String keyId,
    required String privateKey,
  }) async {
    await _postApi(
      '/api/credentials',
      {
        'store': 'appstore',
        'issuerId': issuerId,
        'keyId': keyId,
        'privateKey': privateKey,
      },
      timeout: const Duration(seconds: 45),
    );
    AppEvents.notifyDataChanged(DataChange.stores);
  }

  static Future<void> saveGooglePlayCredentials(String serviceAccountJson) async {
    await _postApi(
      '/api/credentials',
      {
        'store': 'googleplay',
        'serviceAccountJson': serviceAccountJson,
      },
      timeout: const Duration(seconds: 45),
    );
    AppEvents.notifyDataChanged(DataChange.stores);
  }

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
    final confirmed = PurchaseConfirmation.fromJson(json);
    AppEvents.updatePlan(confirmed.plan, force: true);
    return confirmed;
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
    final confirmed = PurchaseConfirmation.fromJson(json);
    AppEvents.updatePlan(confirmed.plan, force: true);
    return confirmed;
  }

  // ---- アカウント削除（退会 / Apple審査要件） ----
  /// アカウントと関連データを完全に削除する。成功後はサインアウトすること。
  static Future<void> deleteAccount() async {
    if (!AppConfig.hasApi) {
      throw const ApiException('この機能はサーバー接続が必要です。');
    }
    await _request(
      'DELETE',
      '/api/account',
      // 全データの削除は数十秒かかることがある。先に切れると「失敗」と出るのに
      // サーバーでは削除が進み、やり直すと 401 になってしまう。
      timeout: const Duration(seconds: 45),
      fallbackError: 'アカウントを削除できませんでした。時間をおいて再度お試しください。',
    );
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

  /// サーバーに保存されている通知対象（'all' / 'low' / 'off'）。未ログイン・未設定なら null。
  /// 機種変更・再インストールのあとに、端末の設定をサーバーの値に合わせるのに使う。
  static Future<String?> pushScope() async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    // 自分の profiles は RLS で読める（plan と同じ読み方）。
    final row = await _db
        .from('profiles')
        .select('push_scope')
        .eq('id', uid)
        .maybeSingle();
    return row?['push_scope'] as String?;
  }

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
    final plan = (row?['plan'] as String?) ?? 'free';
    AppEvents.updatePlan(plan);
    return plan;
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
    // トライアル・アプリ内課金の列は後から足したので、無いDBでも課金画面を落とさないよう別に読む。
    Map<String, dynamic>? trial;
    try {
      trial = await _db
          .from('profiles')
          .select('in_trial, current_period_end, '
              'apple_original_transaction_id, apple_expires_at, '
              'google_purchase_token, google_expires_at')
          .eq('id', uid)
          .maybeSingle();
    } catch (_) {}
    final plan = (results[0]?['plan'] as String?) ?? 'free';
    AppEvents.updatePlan(plan);
    return BillingStatus(
      plan: plan,
      aiUnitsUsed: (results[1]?['units'] as num?)?.toInt() ?? 0,
      inTrial: trial?['in_trial'] == true,
      periodEnd: DateTime.tryParse((trial?['current_period_end'] as String?) ?? ''),
      store: plan == 'free' ? null : _billingStore(trial),
    );
  }

  /// 有料プランを請求しているストア。期限内の購入がどちらか一方にだけあるときに決める。
  ///
  /// サーバーは購入を確認したストアの列だけを書き、もう一方の列は消さない。
  /// 期限の過ぎた古い購入は数えない。両方とも期限内・どちらも無いときは決めつけず null。
  static BillingStore? _billingStore(Map<String, dynamic>? p) {
    if (p == null) return null;
    final now = DateTime.now();
    bool active(String idKey, String expiresKey) {
      final id = p[idKey];
      if (id is! String || id.isEmpty) return false;
      final expires = DateTime.tryParse((p[expiresKey] as String?) ?? '');
      return expires == null || expires.isAfter(now);
    }

    final apple = active('apple_original_transaction_id', 'apple_expires_at');
    final google = active('google_purchase_token', 'google_expires_at');
    if (apple == google) return null;
    return apple ? BillingStore.apple : BillingStore.google;
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

/// アプリ内課金のストア。
enum BillingStore { apple, google }

extension BillingStoreLabel on BillingStore {
  String get label => this == BillingStore.apple ? 'App Store' : 'Google Play';
}

/// 課金画面で使う、利用者の契約状況。
class BillingStatus {
  final String plan;

  /// 今月使ったAIの units（ai_usage）。
  final int aiUnitsUsed;

  /// 無料トライアル中か。中なら [periodEnd] が無料期間の終わり（＝初回請求日）。
  final bool inTrial;
  final DateTime? periodEnd;

  /// 今の有料プランを請求しているストア（分からなければ null）。
  /// Google Play で契約した人が iPhone で開いたときなど、この端末のストアと違うことがある。
  final BillingStore? store;

  const BillingStatus({
    required this.plan,
    required this.aiUnitsUsed,
    this.inTrial = false,
    this.periodEnd,
    this.store,
  });

  /// 「Pro 無料トライアル中・10月12日まで」のような一文。トライアル中でなければ null。
  String? get trialLine {
    if (!inTrial || plan == 'free') return null;
    final end = periodEnd?.toLocal();
    final until = end == null ? '' : '・${end.month}月${end.day}日まで';
    return '${planLabel(plan)} 無料トライアル中$until';
  }

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
