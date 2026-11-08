import 'dart:io';

import 'package:syntila_cli_worker_engine/src/provider_images.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('images'));
  tearDown(() => root.delete(recursive: true));

  const stdout =
      '{"type":"thread.started","thread_id":"01a1bab2-2ed6-70c2"}\n'
      '{"type":"turn.completed"}\n';

  test('reads the Codex thread id', () {
    expect(codexThreadId(stdout), '01a1bab2-2ed6-70c2');
    expect(codexThreadId('{"type":"thread.started","thread_id":"../x"}'),
        isNull);
  });

  test('copies images Codex generated during the run', () async {
    final home = Directory('${root.path}/codex');
    final generated =
        await Directory('${home.path}/generated_images/01a1bab2-2ed6-70c2')
            .create(recursive: true);
    final old = File('${generated.path}/old.png')..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime(2020));
    File('${generated.path}/new.png').writeAsBytesSync([1, 2, 3]);
    File('${generated.path}/notes.txt').writeAsStringSync('x');
    final work = await Directory('${root.path}/work').create();

    final copied = await captureCodexImages(
      stdout: stdout,
      workingDirectory: work.path,
      assignmentId: 'asg-1',
      since: DateTime.now().subtract(const Duration(minutes: 1)),
      environment: {'CODEX_HOME': home.path},
    );

    expect(copied, 1);
    final outputs = Directory(outputImagesDirectory(work.path, 'asg-1'));
    expect(outputs.listSync().map((e) => e.uri.pathSegments.last),
        ['new.png']);
  });

  test('copies nothing without a thread id', () async {
    expect(
      await captureCodexImages(
        stdout: '{"type":"turn.completed"}',
        workingDirectory: root.path,
        assignmentId: 'asg-1',
        since: DateTime(2020),
      ),
      0,
    );
  });
}
