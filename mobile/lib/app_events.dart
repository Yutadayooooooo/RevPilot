import 'package:flutter/foundation.dart';

/// 何が変わったか（聞く側が、自分に関係ある変化だけ拾えるように）。
enum DataChange {
  /// ストア連携の保存・解除。
  stores,

  /// アプリの追加・編集・削除。
  apps,

  /// ストアからのレビュー取得（apps の最終取得時刻・エラーも変わる）。
  reviews,

  /// 返信の生成・下書き保存・投稿・返信済みの記録。
  replies,
}

/// タブをまたいだ「中身が変わった」のお知らせ。
///
/// ホームの各タブは IndexedStack で保持され、State が作り直されない。
/// そのため、設定タブで連携やアプリ追加をしても、レビュータブや分析タブは
/// 引っ張って更新するまで古いままだった。プランを買った後も同じ。
///
/// 変化を起こす処理（Repo）がここを進めるので、画面側は
/// initState で addListener、dispose で removeListener して読み直すだけでよい。
class AppEvents {
  AppEvents._();

  /// 連携・アプリ・レビュー・返信のどれかが変わるたびに 1 ずつ進む。
  static final dataChanged = ValueNotifier<int>(0);

  /// 直近の変化の種類。dataChanged のリスナーの中で読む
  /// （通知は同期で届くので、その時点では必ず今回の変化を指している）。
  static DataChange lastChange = DataChange.reviews;

  /// プランが変わるたびに 1 ずつ進む（購入・復元・解約の反映）。
  static final planChanged = ValueNotifier<int>(0);

  /// 最後に読んだプラン（'free' / 'pro' / 'max'）。まだ読んでいなければ null。
  static final plan = ValueNotifier<String?>(null);

  static void notifyDataChanged(DataChange kind) {
    lastChange = kind;
    dataChanged.value++;
  }

  /// 読み直したプランを反映する。前回と違えば planChanged を進める。
  /// [force] は購入の確定直後など、同じプランでも画面を読み直させたいとき。
  static void updatePlan(String value, {bool force = false}) {
    final prev = plan.value;
    plan.value = value;
    if (force || (prev != null && prev != value)) planChanged.value++;
  }

  /// ログアウト時に呼ぶ（次のアカウントのプランと混ざらないように）。
  static void reset() {
    plan.value = null;
  }
}
