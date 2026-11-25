import 'dart:async';

/// Fetches a single-use ticket for the backend realtime endpoint. Browsers
/// cannot send an Authorization header on a WebSocket upgrade, so each
/// connect and reconnect redeems a fresh ticket (`?ticket=`).
Future<String> Function()? realtimeTicketProvider;

abstract interface class RealtimeClient {
  Stream<Map<String, dynamic>> get events;
  Future<void> connect(Uri endpoint);
  Future<void> setScopes({
    String? spaceId,
    String? threadId,
    String? runId,
  });
  Future<void> close();
}

class _StubRealtimeClient implements RealtimeClient {
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect(Uri endpoint) async {}

  @override
  Future<void> setScopes({
    String? spaceId,
    String? threadId,
    String? runId,
  }) async {}

  @override
  Future<void> close() => _events.close();
}

RealtimeClient createRealtimeClient() => _StubRealtimeClient();
