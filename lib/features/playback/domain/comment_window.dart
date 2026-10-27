import 'playback_repository.dart';

/// A bounded protocol segment, indexed once when its response arrives.
final class CommentSegment {
  CommentSegment(Iterable<TimedComment> comments) {
    final indexed = comments.take(6000).indexed.toList();
    indexed.sort((a, b) {
      final time = a.$2.position.compareTo(b.$2.position);
      return time != 0 ? time : a.$1.compareTo(b.$1);
    });
    _comments = [for (final (_, comment) in indexed) comment];
  }

  late final List<TimedComment> _comments;

  Iterable<TimedComment> between(Duration start, Duration end) =>
      _comments.getRange(_bound(start), _bound(end, after: true));

  /// Returns a copy with [comment] inserted in position order. Server
  /// segments are immutable; only the local echo of a just-sent danmaku
  /// appends, before the server delivers it through a later refetch.
  CommentSegment appended(TimedComment comment) {
    final index = _bound(comment.position);
    return CommentSegment([
      ..._comments.take(index),
      comment,
      ..._comments.skip(index),
    ]);
  }

  int _bound(Duration position, {bool after = false}) {
    var low = 0;
    var high = _comments.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_comments[mid].position < position ||
          after && _comments[mid].position == position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

/// Merge only the requested slices. The session retains at most three segments.
/// Do not truncate the result to the renderer's pending capacity: its active
/// comments still need the full authoritative window for identity validation.
Iterable<TimedComment> mergeCommentWindow(
  Iterable<CommentSegment> segments,
  Duration start,
  Duration end,
) sync* {
  final cursors = [
    for (final segment in segments) segment.between(start, end).iterator,
  ]..removeWhere((cursor) => !cursor.moveNext());
  while (cursors.isNotEmpty) {
    var earliest = 0;
    for (var index = 1; index < cursors.length; index++) {
      if (cursors[index].current.position <
          cursors[earliest].current.position) {
        earliest = index;
      }
    }
    final cursor = cursors[earliest];
    yield cursor.current;
    if (!cursor.moveNext()) cursors.removeAt(earliest);
  }
}
