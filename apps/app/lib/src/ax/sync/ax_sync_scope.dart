import 'ax_query_key.dart';

/// Recovery identity comes from transport scopes, never the selected route.
class AxSyncScope {
  const AxSyncScope(this.kind, [this.id]);
  final String kind;
  final String? id;

  factory AxSyncScope.fromEvent(Map<String, dynamic> event) {
    final scope = event['scope'];
    final stream = event['stream'];
    String? id(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    if (scope is Map) {
      final kind = scope['kind'];
      final value = switch (kind) {
        'space' => id(scope['spaceId']),
        'thread' => id(scope['threadId']),
        _ => null,
      };
      if (value != null) return AxSyncScope(kind as String, value);
    }
    // The user subscription may report a gap in a narrower durable stream.
    if (stream is Map && stream['kind'] == 'space') {
      final value = id(stream['id']);
      if (value != null) return AxSyncScope(stream['kind'] as String, value);
    }
    // Unknown/malformed narrow scopes must not become session-wide recovery.
    return AxSyncScope(
        scope is Map && scope['kind'] != 'user' ? 'unknown' : 'user');
  }

  bool matches(AxQueryKey key) {
    final p = key.parts;
    final space = (p[0] == 'space') &&
        (p.length == 2 ||
            (p.length == 3 &&
                const {'threads', 'members', 'invitations', 'audit'}
                    .contains(p[2])));
    final workflow = p.length == 2 &&
        (p[0] == 'space-workflow-configurations' ||
            (p[0] == 'workflow-default' && p[1] != 'user'));
    final userWorkflow =
        p.length == 2 && (p[0] == 'workflow-default' && p[1] == 'user');
    final discussion =
        p.length == 3 && (p[0] == 'thread') && p[2] == 'discussion';
    final work = p.length == 3 && (p[0] == 'thread') && p[2] == 'work-requests';
    final workers = p.length == 1 && p[0] == 'workers';
    final archivedSpaces = p.length == 1 && p[0] == 'archived-spaces';
    return switch (kind) {
      'space' => p[0] == 'people' ||
          archivedSpaces ||
          ((space || workflow) && p[1] == id),
      'thread' => (discussion || work) && p[1] == id,
      'user' => p[0] == 'people' ||
          archivedSpaces ||
          space ||
          workflow ||
          userWorkflow ||
          discussion ||
          work ||
          workers,
      _ => false,
    };
  }
}
