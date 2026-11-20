import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/realtime/realtime_cursors.dart';

void main() {
  test('the same id has independent cursors per stream kind', () {
    final cursors = RealtimeCursors();
    cursors.record('space', 'same', 2);
    cursors.record('user', 'same', 4);
    expect(cursors.of('space', 'same'), 2);
    expect(cursors.of('user', 'same'), 4);
    expect(cursors.of('thread', 'same'), isNull);
  });

  test('a cursor only moves forward', () {
    final cursors = RealtimeCursors();
    cursors.record('space', 'P', 5);
    cursors.record('space', 'P', 3);
    cursors.record('space', 'P', -1);
    expect(cursors.of('space', 'P'), 5);
    cursors.record('space', 'P', 6);
    expect(cursors.of('space', 'P'), 6);
  });
}
