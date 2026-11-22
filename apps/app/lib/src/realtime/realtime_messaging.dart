import 'realtime_cursors.dart';

/// The wire name of the one protocol humans and Worker Agents share.
const messagingProtocol = 'syntila.messaging/1';

/// What one server frame turned into: events for the app (in the shape the app
/// already consumes) and frames to send back.
class MessagingResult {
  const MessagingResult(this.events, this.replies);
  final List<Map<String, dynamic>> events;
  final List<Map<String, dynamic>> replies;
}

/// `syntila.messaging/1` for the app, with no socket: builds command frames and
/// turns server envelopes into the event maps the app's routers read, so the
/// platform clients stay thin. It never authors an identity; the server derives
/// it from the connection.
class RealtimeMessaging {
  RealtimeMessaging({this.seenLimit = 4096});

  final int seenLimit;
  final cursors = RealtimeCursors();
  int _request = 0;
  String? _userId;
  final _seen = <String>{};
  final _unacked = <String, ({String kind, String id, int sequence})>{};

  Map<String, dynamic> _command(String command, Map<String, Object?> payload) =>
      {
        'protocol': messagingProtocol,
        'requestId': 'req-${++_request}',
        'type': 'command',
        'command': command,
        'payload': payload,
      };

  Map<String, dynamic> ping() => _command('session.ping', const {});

  /// Subscribes to a stream, resuming from the last applied sequence when known.
  /// The stream id `me` names the caller's own user stream; the server resolves
  /// it from the credential and answers with the real id.
  Map<String, dynamic> subscribe(String kind, String id) {
    final cursor =
        cursors.of(kind, kind == 'user' && id == 'me' ? (_userId ?? id) : id);
    return _command('subscription.subscribe', {
      'stream': {'kind': kind, 'id': id},
      if (cursor != null) 'cursor': cursor,
    });
  }

  Map<String, dynamic> unsubscribe(String kind, String id) =>
      _command('subscription.unsubscribe', {
        'stream': {'kind': kind, 'id': id},
      });

  /// The acknowledgements owed since the last call, one per stream.
  List<Map<String, dynamic>> flushAcks() {
    final pending = _unacked.values.toList();
    _unacked.clear();
    return [
      for (final ack in pending)
        _command('event.ack', {
          'stream': {'kind': ack.kind, 'id': ack.id},
          'sequence': ack.sequence,
        }),
    ];
  }

  static const _contextKeys = [
    'spaceId',
    'threadId',
    'runId',
    'taskId',
    'attemptId',
    'assignmentId',
    'workspaceRuntimeId',
  ];

  /// Handles one decoded server frame. Frames of another protocol are ignored.
  MessagingResult receive(Object? decoded) {
    const none = MessagingResult([], []);
    if (decoded is! Map || decoded['protocol'] != messagingProtocol) {
      return none;
    }
    final type = decoded['type'];
    final streamValue = decoded['stream'];
    final kind = streamValue is Map ? streamValue['kind'] : null;
    final id = streamValue is Map ? streamValue['id'] : null;
    final payload = decoded['payload'] is Map
        ? Map<String, dynamic>.from(decoded['payload'] as Map)
        : <String, dynamic>{};
    if (type is! String || kind is! String || id is! String) return none;
    if (kind == 'user') _userId = id;

    switch (type) {
      case 'session.pong':
        return const MessagingResult([
          {'type': 'realtime.pong'},
        ], []);
      case 'subscription.ready':
        final head = payload['headSequence'];
        if (payload['resumed'] == true || head is! int) {
          // The server replayed what was missed; nothing to reload.
          return none;
        }
        // A fresh start: the app reloads this stream over HTTP (it does so on
        // `realtime.ready`), and the head is where live events continue from.
        cursors.record(kind, id, head);
        return MessagingResult(
          [
            if (kind == 'user') {'type': 'realtime.ready'},
          ],
          [
            _command('subscription.snapshot_applied', {
              'stream': {'kind': kind, 'id': id},
              'snapshotSequence': head,
            }),
          ],
        );
      case 'sync.required':
        return MessagingResult([
          {
            'type': 'sync.required',
            'stream': {'kind': kind, 'id': id},
            'scope': _scopeOf(kind, id),
            'reason': payload['reason'],
          },
        ], const []);
      case 'subscription.denied':
      case 'subscription.ended':
      case 'error':
        return none;
    }

    final sequence = decoded['sequence'];
    if (sequence is int && sequence >= 0) {
      cursors.record(kind, id, sequence);
      _unacked[RealtimeCursors.key(kind, id)] =
          (kind: kind, id: id, sequence: sequence);
    }
    // A Space event also reaches the Thread it belongs to, with the same id.
    final eventId = decoded['eventId'];
    if (eventId is String) {
      if (!_seen.add(eventId)) return none;
      if (_seen.length > seenLimit) _seen.remove(_seen.first);
    }
    final context = decoded['context'] is Map
        ? Map<String, dynamic>.from(decoded['context'] as Map)
        : const <String, dynamic>{};
    return MessagingResult([
      {
        'eventId': eventId,
        'type': type,
        'version': '1.1',
        'timestamp': decoded['occurredAt'],
        'stream': {'kind': kind, 'id': id},
        'sequence': sequence is int ? sequence : 0,
        for (final key in _contextKeys)
          if (context[key] is String) key: context[key],
        'payload': payload,
      },
    ], const []);
  }

  static Map<String, dynamic> _scopeOf(String kind, String id) =>
      switch (kind) {
        'space' => {'kind': 'space', 'spaceId': id},
        'thread' => {'kind': 'thread', 'threadId': id},
        _ => {'kind': 'user'},
      };
}
