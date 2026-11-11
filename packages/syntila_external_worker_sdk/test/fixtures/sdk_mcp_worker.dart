// A ExternalWorker run as a Syntila MCP Worker with runMcpWorker. The prompt picks
// the behaviour so Engine-level tests can exercise the whole profile:
//   WAIT  -> waits for context.cancelled (cooperative cancel)
//   FAIL  -> throws a retryable ExternalWorkerFailure(rate_limited)
//   DATA  -> answers with the data directory the Engine gave it
//   other -> reports progress, then echoes the prompt and confirms the session
import 'dart:convert';
import 'package:syntila_external_worker_sdk/syntila_external_worker_sdk.dart';

class SdkEchoWorker extends ExternalWorker {
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
  Future<ExternalWorkerReadiness> probe({required bool live}) async =>
      ExternalWorkerReadiness.ready(checks: [
        ExternalWorkerCheck('sdk',
            ok: true, message: live ? 'live check' : 'passive check'),
      ]);

  @override
  Future<List<ExternalWorkerModel>> discoverModels() async =>
      const [ExternalWorkerModel(id: 'echo:1', name: 'Echo')];

  @override
  Future<WorkResult> execute(WorkRequest request, WorkContext context) async {
    if (request.prompt.contains('REPORT_CONVERSATION')) {
      final conversation = request.conversation;
      return WorkResult(jsonEncode({
        if (request.execution != null)
          'execution': {
            'workflowId': request.execution!.workflowId,
            'workflowVersion': request.execution!.workflowVersion,
            'stepKind': request.execution!.stepKind,
            'access': request.execution!.access,
            'sessionPolicy': request.execution!.sessionPolicy,
            'context': request.execution!.context,
          },
        'request': conversation?.request,
        'instructions': conversation?.instructions,
        'messages': conversation?.messages
            .map((m) => {'role': m.role, 'text': m.text})
            .toList(),
      }));
    }
    if (request.prompt.contains('WAIT')) {
      await context.cancelled;
      return const WorkResult('stopped');
    }
    if (request.prompt.contains('FAIL')) {
      throw const ExternalWorkerFailure('rate_limited', 'try later',
          retryable: true);
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
