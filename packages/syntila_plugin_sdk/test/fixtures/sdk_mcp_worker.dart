// A PluginWorker run as a Syntila MCP Worker with runMcpWorker. The prompt picks
// the behaviour so Engine-level tests can exercise the whole profile:
//   WAIT  -> waits for context.cancelled (cooperative cancel)
//   FAIL  -> throws a retryable PluginFailure(rate_limited)
//   DATA  -> answers with the data directory the Engine gave it
//   other -> reports progress, then echoes the prompt and confirms the session
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';

class SdkEchoWorker extends PluginWorker {
  @override
  String get id => 'sdk-echo';

  @override
  String get version => '1.0.0';

  @override
  Map<String, Object?> get capabilities => const {
        'progress': true,
        'modelDiscovery': true,
      };

  @override
  Future<PluginReadiness> probe({required bool live}) async =>
      PluginReadiness.ready(checks: [
        PluginCheck('sdk',
            ok: true, message: live ? 'live check' : 'passive check'),
      ]);

  @override
  Future<List<PluginModel>> discoverModels() async =>
      const [PluginModel(id: 'echo:1', name: 'Echo')];

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    if (request.prompt.contains('WAIT')) {
      await context.cancelled;
      return const WorkResult('stopped');
    }
    if (request.prompt.contains('FAIL')) {
      throw const PluginFailure('rate_limited', 'try later', retryable: true);
    }
    if (request.prompt.contains('DATA')) {
      return WorkResult('data=${context.dataDirectory}');
    }
    context.progress('step one', percent: 25);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    context.progress('step two', percent: 75);
    return WorkResult(
      'sdk echo: ${request.prompt} (model ${request.model}, readOnly ${request.readOnly})',
      sessionState: request.sessionKey == null
          ? null
          : (request.resumeSession ? 'resumed' : 'created'),
    );
  }
}

Future<void> main() => runMcpWorker(SdkEchoWorker());
