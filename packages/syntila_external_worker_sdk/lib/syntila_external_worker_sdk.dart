/// Write a Syntila External Worker in Dart.
///
/// ```dart
/// Future<void> main() => runMcpWorker(MyWorker());
/// ```
///
/// [runMcpWorker] serves the Syntila MCP Worker profile
/// (MCP_WORKER_PROFILE_V1) over stdio for you. You implement
/// [ExternalWorker.execute].
library;

export 'src/external_worker.dart';
export 'src/run_mcp_worker.dart';
export 'src/session_store.dart';
export 'src/packaging.dart';
export 'src/scaffold.dart';
