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
                .probe(live: true))
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
  test('discovers namespaced models and honors a selected model', () async {
    await fixture('exit 0');
    File(binary).writeAsStringSync(r'''#!/bin/sh
if [ "$1" = list ]; then
  printf 'NAME ID SIZE MODIFIED\nllama3.2:3b abc 2GB now\nteam/custom:8b def 5GB now\nremote:cloud xxx 0 now\n'
  exit 0
fi
printf '%s' "$2"
''');
    final worker = OllamaLocalWorker(executable: binary);
    final models = await worker.discoverModels();
    expect(models.map((m) => m.name), ['llama3.2:3b', 'team/custom:8b']);
    final chosen = models.last;
    final selected = WorkRequest(
        id: 'select',
        prompt: 'hello',
        workingDirectory: temp.path,
        readOnly: false,
        deadline: const Duration(seconds: 3),
        model: chosen.id);
    expect(
        (await worker.execute(selected, Context())).output, 'team/custom:8b');
    File(binary).writeAsStringSync(r'''#!/bin/sh
printf 'NAME ID SIZE MODIFIED\nllama3.2:3b abc 2GB now\n'
''');
    await expectLater(
        worker.execute(selected, Context()),
        throwsA(isA<PluginFailure>()
            .having((e) => e.code, 'code', 'model_unavailable')));
  });
  test('passive probe never invokes the installed CLI', () async {
    final worker = await fixture('exit 1');
    File(binary).writeAsStringSync('#!/bin/sh\nexit 1\n');
    expect((await worker.probe(live: false)).state, 'ready');
    expect((await worker.probe(live: true)).state, 'unavailable');
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
  test('replayed conversation over 24 KiB reaches the model', () async {
    final worker = await fixture('exec /bin/cat');
    final text = 'conversation ' * 3600;
    expect(text.length, greaterThan(24 * 1024));
    final input = WorkRequest(
        id: 'replay',
        prompt: text,
        workingDirectory: temp.path,
        readOnly: false,
        deadline: const Duration(seconds: 5));
    expect((await worker.execute(input, Context())).output, text.trim());
  });
  test('accepts a prompt above the former 512 KiB limit', () async {
    final worker = await fixture('exec /bin/cat');
    final input = WorkRequest(
        id: 'large',
        prompt: 'x' * (512 * 1024 + 1),
        workingDirectory: temp.path,
        readOnly: false,
        deadline: const Duration(seconds: 10));
    expect((await worker.execute(input, Context())).output.length,
        input.prompt.length);
  });
  test('reports context overflow without leaking stderr', () async {
    final worker =
        await fixture('echo "context length exceeded SECRET" >&2; exit 1');
    await expectLater(
        worker.execute(request(), Context()),
        throwsA(isA<PluginFailure>()
            .having((e) => e.code, 'code', 'context_limit_exceeded')
            .having((e) => e.message, 'message', isNot(contains('SECRET')))));
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
