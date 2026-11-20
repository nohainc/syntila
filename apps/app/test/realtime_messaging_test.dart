import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/realtime/realtime_messaging.dart';

Map<String, dynamic> envelope(
  String type,
  String kind,
  String id, {
  int? sequence,
  String? eventId,
  Map<String, dynamic> payload = const {},
  Map<String, dynamic>? context,
}) =>
    {
      'protocol': messagingProtocol,
      'eventId': eventId ?? 'evt-$type-${sequence ?? 0}',
      'type': type,
      'stream': {'kind': kind, 'id': id},
      if (sequence != null) 'sequence': sequence,
      'occurredAt': '2026-11-20T10:00:00.000Z',
      if (context != null) 'context': context,
      'payload': payload,
    };

void main() {
  test('commands carry the protocol, a request id and no identity', () {
    final m = RealtimeMessaging();
    final a = m.subscribe('space', 's1');
    final b = m.ping();
    expect(a['protocol'], messagingProtocol);
    expect(a['command'], 'subscription.subscribe');
    expect(a['payload'], {
      'stream': {'kind': 'space', 'id': 's1'},
    });
    expect(a['requestId'], isNot(b['requestId']));
    for (final key in ['actor', 'actorId', 'userId', 'principal']) {
      expect(a.containsKey(key), isFalse);
      expect((a['payload'] as Map).containsKey(key), isFalse);
    }
  });

  test('a durable event becomes the event the app reads, with its context ids',
      () {
    final m = RealtimeMessaging();
    final result = m.receive(envelope('message.created', 'space', 's1',
        sequence: 7,
        context: {'spaceId': 's1', 'threadId': 't1', 'bogus': 'x'},
        payload: {'entityId': 'm1'}));
    expect(result.replies, isEmpty);
    expect(result.events.single, {
      'eventId': 'evt-message.created-7',
      'type': 'message.created',
      'version': '1.1',
      'timestamp': '2026-11-20T10:00:00.000Z',
      'stream': {'kind': 'space', 'id': 's1'},
      'sequence': 7,
      'spaceId': 's1',
      'threadId': 't1',
      'payload': {'entityId': 'm1'},
    });
    expect(m.cursors.of('space', 's1'), 7);
  });

  test('the Thread copy of a Space event is delivered once but still acknowledged',
      () {
    final m = RealtimeMessaging();
    expect(
        m
            .receive(envelope('message.created', 'space', 's1',
                sequence: 7, eventId: 'e1'))
            .events,
        hasLength(1));
    final thread = m.receive(envelope('message.created', 'thread', 't1',
        sequence: 7, eventId: 'e1'));
    expect(thread.events, isEmpty);
    expect(m.cursors.of('thread', 't1'), 7);
    final acks = m.flushAcks();
    expect(acks.map((a) => (a['payload'] as Map)['stream']), [
      {'kind': 'space', 'id': 's1'},
      {'kind': 'thread', 'id': 't1'},
    ]);
    expect(m.flushAcks(), isEmpty);
  });

  test('a fresh subscription asks the app to reload and applies the snapshot',
      () {
    final m = RealtimeMessaging();
    final user = m.receive(envelope('subscription.ready', 'user', 'alice',
        payload: {'headSequence': 5}));
    expect(user.events, [
      {'type': 'realtime.ready'}
    ]);
    expect(user.replies.single['command'], 'subscription.snapshot_applied');
    expect(user.replies.single['payload'], {
      'stream': {'kind': 'user', 'id': 'alice'},
      'snapshotSequence': 5,
    });
    final space = m.receive(envelope('subscription.ready', 'space', 's1',
        payload: {'headSequence': 9}));
    expect(space.events, isEmpty);
    expect(m.cursors.of('space', 's1'), 9);
  });

  test('a resumed subscription reloads nothing, and the next one sends the cursor',
      () {
    final m = RealtimeMessaging();
    m.receive(envelope('message.created', 'space', 's1', sequence: 12));
    final resumed = m.receive(envelope('subscription.ready', 'space', 's1',
        payload: {'headSequence': 15, 'resumed': true}));
    expect(resumed.events, isEmpty);
    expect(resumed.replies, isEmpty);
    expect((m.subscribe('space', 's1')['payload'] as Map)['cursor'], 12);
    // `me` finds the cursor of the user stream the server named.
    m.receive(envelope('user.updated', 'user', 'alice', sequence: 3));
    expect((m.subscribe('user', 'me')['payload'] as Map)['cursor'], 3);
  });

  test('sync.required reaches the app in the shape its recovery reads', () {
    final m = RealtimeMessaging();
    final result = m.receive(envelope('sync.required', 'thread', 't1',
        payload: {'reason': 'cursor_too_old'}));
    expect(result.events.single, {
      'type': 'sync.required',
      'stream': {'kind': 'thread', 'id': 't1'},
      'scope': {'kind': 'thread', 'threadId': 't1'},
      'reason': 'cursor_too_old',
    });
  });

  test('pong, errors and frames of another protocol are not events', () {
    final m = RealtimeMessaging();
    expect(m.receive(envelope('session.pong', 'user', 'alice')).events, [
      {'type': 'realtime.pong'}
    ]);
    expect(m.receive(envelope('error', 'user', 'alice')).events, isEmpty);
    expect(m.receive({'type': 'realtime.ready'}).events, isEmpty);
    expect(m.receive('not a map').events, isEmpty);
  });
}
