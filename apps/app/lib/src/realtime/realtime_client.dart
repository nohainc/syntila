import 'realtime_client_stub.dart'
    if (dart.library.html) 'realtime_client_web.dart' as implementation;
import 'realtime_client_stub.dart' show RealtimeClient;

export 'realtime_client_stub.dart' show RealtimeClient, realtimeTicketProvider;

RealtimeClient createRealtimeClient() => implementation.createRealtimeClient();

Uri realtimeEndpointForApi(String apiBaseUrl) {
  final configured = Uri.parse(apiBaseUrl);
  final base = configured.hasScheme ? configured : Uri.base.resolve(apiBaseUrl);
  final path = base.path.endsWith('/api')
      ? '${base.path}/realtime'
      : '${base.path.replaceFirst(RegExp(r'\/$'), '')}/api/realtime';
  return base
      .replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: path,
        query: '',
      )
      .removeFragment();
}
