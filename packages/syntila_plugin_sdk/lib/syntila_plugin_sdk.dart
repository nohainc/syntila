/// Write a Syntila Worker plugin in Dart.
///
/// ```dart
/// Future<void> main() => runPlugin(MyPlugin());
/// ```
///
/// [runPlugin] speaks the Worker Plugin Protocol v1 for you: the handshake,
/// heartbeats, cancel, exactly one terminal frame per request, frame bounds and
/// a clean stdout. You implement [PluginWorker.execute].
library;

export 'src/plugin_worker.dart';
export 'src/run_plugin.dart';
export 'src/session_store.dart';
export 'src/packaging.dart';
export 'src/scaffold.dart';
