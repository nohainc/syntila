import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:flutter_test/flutter_test.dart';

AxThread _thread(String id, {Map<String, dynamic> metadata = const {}}) =>
    AxThread(
      id: id,
      spaceId: 's',
      name: id,
      lead: 'u',
      status: 'active',
      brief: '',
      queueStatus: 'Idle',
      metadata: metadata,
    );

void main() {
  test('Thread metadata viewState parses and merges, null clears a key', () {
    final thread = AxThread.fromJson({
      'id': 't',
      'spaceId': 's',
      'name': 't',
      'metadata': {
        'viewState': {'tabIndex': 1, 'model': 'sonnet', 'workerId': 'w'},
      },
    });
    expect(thread.viewState['tabIndex'], 1);
    final next = thread.copyWith(viewState: {'model': null, 'tabIndex': 0});
    expect(next.viewState, {'tabIndex': 0, 'workerId': 'w'});
    expect(thread.viewState['model'], 'sonnet');
    expect(_thread('x').viewState, isEmpty);
  });

  test('stored threadOrder keeps listed Threads in order after new ones', () {
    final sorted = [_thread('new'), _thread('a'), _thread('b'), _thread('c')];
    expect(
      applyAxThreadOrder(sorted, ['c', 'a', 'gone', 'b']).map((t) => t.id),
      ['new', 'c', 'a', 'b'],
    );
    expect(applyAxThreadOrder(sorted, null), same(sorted));
    expect(applyAxThreadOrder(sorted, const []), same(sorted));
  });
}
