import 'dart:async';
import 'package:syntila_app/src/realtime/realtime_client.dart';

/// In-process transport keeps widget regressions independent of live Cloud.
class TestRealtime implements RealtimeClient {
  final controller =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<void> connect(Uri endpoint) async {}
  @override
  Future<void> setScopes({
    String? spaceId,
    String? threadId,
    String? runId,
  }) async {}
  void emit(Map<String, dynamic> event) => controller.add(event);
  @override
  Future<void> close() => controller.close();
}
