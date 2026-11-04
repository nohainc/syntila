@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';
import 'package:ollama_local/ollama_worker.dart';
import 'package:syntila_plugin_sdk/syntila_plugin_sdk.dart';
import 'package:test/test.dart';

class Context implements WorkContext {
  final stop = Completer<void>();
  @override
  bool get isCancelled => stop.isCompleted;
  @override
  Future<void> get cancelled => stop.future;
  @override
  String get dataDirectory => Directory.systemTemp.path;
  @override
  void progress(String message, {int? percent}) {}
}

void main() {
  late Directory temp;
  late String binary;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('ollama-plugin-test-');
    binary = '${temp.path}/ollama';
  });
  tearDown(() => temp.deleteSync(recursive: true));
  Future<OllamaLocalWorker> fixture(String body) async {
    File(binary).writeAsStringSync('''#!/bin/sh
if [ "\$1" = list ]; then
  printf 'NAME ID SIZE MODIFIED\\nllama3.2:3b abc 2GB now\\n'
  exit 0
fi
$body
''');
    await Process.run('/bin/chmod', ['+x', binary]);
    return OllamaLocalWorker(executable: binary);
  }

  WorkRequest request({Duration deadline = const Duration(seconds: 3)}) =>
      WorkRequest(
          id: 'test',
          prompt: 'Hello \$(touch should-never-exist)',
          workingDirectory: temp.path,
          readOnly: false,
          deadline: deadline);
  test('readiness detects missing executable and model', () async {
    expect(
        (await OllamaLocalWorker(executable: binary).probe(live: false)).state,
        'unavailable');
    await fixture('exit 0');
    expect(
        (await OllamaLocalWorker(executable: binary, model: 'absent')
                .probe(live: false))
            .issueCode,
        'ollama_model_missing');
  });
  test('prompt stays on stdin; endpoint is local and proxies are absent',
      () async {
    final worker = await fixture('''
[ "\$OLLAMA_HOST" = '127.0.0.1:11434' ] || exit 2
[ -z "\$HTTPS_PROXY" ] || exit 3
[ "\$#" = 3 ] || exit 4
/bin/cat
''');
    expect(
        (await worker.execute(request(), Context())).output, request().prompt);
    expect(File('${temp.path}/should-never-exist').existsSync(), false);
  });
  test('cancellation terminates blocked inference', () async {
    final worker = await fixture('exec /bin/sleep 30');
    final context = Context();
    final result = worker.execute(request(), context);
    Timer(const Duration(milliseconds: 150), context.stop.complete);
    await expectLater(
        result,
        throwsA(
            isA<PluginFailure>().having((e) => e.code, 'code', 'cancelled')));
  });
  test('oversized output is refused', () async {
    final worker = await fixture('exec /usr/bin/head -c 800000 /dev/zero');
    await expectLater(
        worker.execute(request(), Context()),
        throwsA(isA<PluginFailure>()
            .having((e) => e.code, 'code', 'output_too_large')));
  });
  test('deadline terminates blocked inference', () async {
    final worker = await fixture('exec /bin/sleep 30');
    await expectLater(
        worker.execute(
            request(deadline: const Duration(milliseconds: 150)), Context()),
        throwsA(isA<PluginFailure>().having((e) => e.code, 'code', 'timeout')));
  });
  test('failed command diagnostics do not expose stderr', () async {
    final worker = await fixture('echo private-token >&2; exit 1');
    await expectLater(
        worker.execute(request(), Context()),
        throwsA(isA<PluginFailure>().having(
            (e) => e.message, 'message', 'Local Ollama command failed')));
  });
}
