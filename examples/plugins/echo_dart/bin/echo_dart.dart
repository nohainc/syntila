import 'dart:async';

import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

/// Echoes the prompt, reports progress and supports cancel and session resume.
/// Copy this file to start a plugin.
class EchoPlugin extends PluginWorker {
  @override
  String get id => 'echo-dart';

  @override
  String get version => '1.0.0';

  @override
  String get name => 'Echo (Dart)';

  @override
  Map<String, Object?> get capabilities => const {
        'progress': true,
        'sessionResume': true,
      };

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    String? sessionState;
    final key = request.sessionKey;
    if (key != null) {
      final sessions = SessionStore(context.dataDirectory);
      if (request.resumeSession) {
        if (!sessions.exists(key)) {
          throw const PluginFailure(
            'session_not_found',
            'No such session',
            retryable: true,
          );
        }
        sessionState = 'resumed';
      } else {
        sessions.write(key, 'seen');
        sessionState = 'created';
      }
    }
    context.progress('Reading the request');
    // Yield so heartbeats and cancel are handled while we "work".
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (context.isCancelled) return const WorkResult('');
    final text = request.prompt.length > 200
        ? '${request.prompt.substring(0, 200)}...'
        : request.prompt;
    return WorkResult('echo: $text', sessionState: sessionState);
  }
}

Future<void> main() => runPlugin(EchoPlugin());
