import 'package:intl/intl.dart';

/// 日付の書式をアプリ全体で 1 か所にまとめる。
///
/// 画面ごとに `DateFormat('M/d')`・`DateFormat('yyyy/M/d')`・`DateFormat('yyyy年M月d日')` が
/// ばらばらに書かれていて、同じレビューの日付が一覧・詳細・通知で違う形で出ていた。
/// 画面では `DateFormat(` を直接書かず、ここの関数を通す。
///
/// | 場面 | 関数 | 例 |
/// |---|---|---|
/// | 文の中の日付 | [formatDateJa] | 11月5日（去年より前は 2025年11月5日） |
/// | 文の中の日時 | [formatDateTimeJa] | 11月5日 10:00 |
/// | 一覧の短い日付 | [formatListDate] | 今日 10:00・昨日・11月3日・2025/11/03 |
/// | 一覧の日時 | [formatListDateTime] | 今日 10:00・昨日 22:15・11月3日 9:05 |
///
/// どれも受け取った時刻を端末の時刻（toLocal）に直してから書く。
DateTime _local(DateTime t) => t.isUtc ? t.toLocal() : t;

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

/// 暦の日でいくつ前か（0 = 今日、1 = 昨日）。未来は負。
int _daysAgo(DateTime t, DateTime now) =>
    _day(now).difference(_day(t)).inHours ~/ 24;

/// 文の中の日付。今年なら「11月5日」、それ以外は「2025年11月5日」。
String formatDateJa(DateTime t, {DateTime? now}) {
  final l = _local(t);
  final n = now ?? DateTime.now();
  return l.year == n.year
      ? DateFormat('M月d日', 'ja').format(l)
      : DateFormat('y年M月d日', 'ja').format(l);
}

/// 文の中の日時。「11月5日 10:00」（今年以外は年を付ける）。
String formatDateTimeJa(DateTime t, {DateTime? now}) {
  final l = _local(t);
  return '${formatDateJa(l, now: now)} ${DateFormat('H:mm', 'ja').format(l)}';
}

/// 一覧の短い日付。今日は「今日 10:00」、昨日は「昨日」、今年は「11月3日」、
/// それより前は「2025/11/03」。
String formatListDate(DateTime t, {DateTime? now}) {
  final l = _local(t);
  final n = now ?? DateTime.now();
  final days = _daysAgo(l, n);
  if (days == 0) return '今日 ${DateFormat('H:mm', 'ja').format(l)}';
  if (days == 1) return '昨日';
  if (l.year == n.year) return DateFormat('M月d日', 'ja').format(l);
  return DateFormat('y/MM/dd', 'ja').format(l);
}

/// 一覧の日時。今日・昨日は「今日 10:00」「昨日 22:15」、それ以外は
/// 「11月3日 9:05」（今年以外は「2025/11/03 9:05」）。
String formatListDateTime(DateTime t, {DateTime? now}) {
  final l = _local(t);
  final n = now ?? DateTime.now();
  final time = DateFormat('H:mm', 'ja').format(l);
  final days = _daysAgo(l, n);
  if (days == 0) return '今日 $time';
  if (days == 1) return '昨日 $time';
  if (l.year == n.year) return '${DateFormat('M月d日', 'ja').format(l)} $time';
  return '${DateFormat('y/MM/dd', 'ja').format(l)} $time';
}
