// RevPilot モバイルの基本的なスモークテスト。
import 'package:flutter_test/flutter_test.dart';

import 'package:revpilot_mobile/models.dart';

void main() {
  test('ReviewRow.fromJson がトピックと返信を展開する', () {
    final r = ReviewRow.fromJson({
      'id': 'r1',
      'app_id': 'a1',
      'store': 'appstore',
      'rating': 5,
      'title': 'Great',
      'body': 'Love it',
      'review_topics': [
        {'topic': 'praise'}
      ],
      'replies': [
        {'id': 'p1', 'body': 'Thanks', 'status': 'posted', 'source': 'ai'}
      ],
    });
    expect(r.rating, 5);
    expect(r.topics, contains('praise'));
    expect(r.hasReply, isTrue);
    expect(r.isPosted, isTrue);
  });

  test('topicLabels は日本語ラベルを持つ', () {
    expect(topicLabels['bug'], '不具合');
  });
}
