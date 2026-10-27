import 'package:bilisail/features/playback/domain/comment_window.dart';
import 'package:bilisail/features/playback/domain/playback_repository.dart';
import 'package:flutter_test/flutter_test.dart';

TimedComment _comment(String id, int milliseconds) => TimedComment(
  id: id,
  position: Duration(milliseconds: milliseconds),
  text: id,
  mode: 1,
  color: 0xffffff,
  fontSize: 24,
);

void main() {
  test(
    'binary slices merge inclusive boundaries and preserve equal-time order',
    () {
      final segments = [
        CommentSegment([
          _comment('after', 301),
          _comment('a', 100),
          _comment('b', 100),
        ]),
        CommentSegment([
          _comment('c', 100),
          _comment('end', 300),
          _comment('before', 99),
        ]),
        CommentSegment([_comment('middle', 200)]),
      ];
      expect(
        mergeCommentWindow(
          segments,
          const Duration(milliseconds: 100),
          const Duration(milliseconds: 300),
        ).map((comment) => comment.id),
        ['a', 'b', 'c', 'middle', 'end'],
      );
      expect(
        mergeCommentWindow(
          segments,
          const Duration(seconds: 1),
          const Duration(seconds: 2),
        ),
        isEmpty,
      );
    },
  );

  test('appended inserts the sent-danmaku echo in position order', () {
    final segment = CommentSegment([_comment('b', 200), _comment('a', 100)]);
    final appended = segment
        .appended(_comment('mid', 150))
        .appended(_comment('head', 50))
        .appended(_comment('tail', 250));
    expect(
      mergeCommentWindow(
        [appended],
        Duration.zero,
        const Duration(minutes: 5),
      ).map((comment) => comment.id),
      ['head', 'a', 'mid', 'b', 'tail'],
    );
  });

  test('three dense segments retain the complete authoritative window', () {
    final segments = [
      for (var segment = 0; segment < 3; segment++)
        CommentSegment([
          for (var i = 5999; i >= 0; i--) _comment('$segment:$i', i * 10),
        ]),
    ];
    final window = mergeCommentWindow(
      segments,
      const Duration(seconds: 10),
      const Duration(seconds: 20),
    ).toList();
    expect(window, hasLength(3003));
    expect(window.first.position, const Duration(seconds: 10));
    expect(window.last.position, const Duration(seconds: 20));
    for (var i = 1; i < window.length; i++) {
      expect(window[i].position, greaterThanOrEqualTo(window[i - 1].position));
    }
  });
}
