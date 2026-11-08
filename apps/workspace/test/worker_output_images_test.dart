import 'dart:io';

import 'package:syntila_workspace/worker_output_images.dart';
import 'package:test/test.dart';

class _RecordingCloud implements WorkerOutputImageCloud {
  final uploaded = <String>[];
  @override
  Future<Map<String, Object?>> upload(String assignmentId, File image) async {
    final name = image.uri.pathSegments.last;
    if (name.startsWith('fail')) throw const HttpException('boom');
    uploaded.add(name);
    return {'kind': 'file', 'fileId': 'wrf-$name', 'name': name};
  }
}

void main() {
  late Directory work;
  setUp(() async => work = await Directory.systemTemp.createTemp('outputs'));
  tearDown(() => work.delete(recursive: true));

  Future<Directory> outputs() =>
      Directory('${work.path}/${workerOutputImagesRelativePath('asg-1')}')
          .create(recursive: true);

  test('prompt names the assignment output directory', () {
    expect(promptWithOutputImages('Draw a fox', 'asg-1'),
        allOf(startsWith('Draw a fox'), contains('.syntila/outputs/asg-1/')));
  });

  test('collects only non-empty image files, in name order', () async {
    final dir = await outputs();
    File('${dir.path}/b.PNG').writeAsBytesSync([1]);
    File('${dir.path}/a.jpg').writeAsBytesSync([1]);
    File('${dir.path}/empty.png').writeAsBytesSync([]);
    File('${dir.path}/notes.txt').writeAsStringSync('x');
    final files = await collectWorkerOutputImages(work, 'asg-1');
    expect(files.map((f) => f.uri.pathSegments.last), ['a.jpg', 'b.PNG']);
    expect(await collectWorkerOutputImages(work, 'asg-2'), isEmpty);
  });

  test('a failed upload skips that image only', () async {
    final dir = await outputs();
    File('${dir.path}/fail.png').writeAsBytesSync([1]);
    File('${dir.path}/ok.png').writeAsBytesSync([1]);
    final errors = <Object>[];
    final cloud = _RecordingCloud();
    final images = await publishWorkerOutputImages(
      cloud: cloud,
      workingDirectory: work,
      assignmentId: 'asg-1',
      onError: errors.add,
    );
    expect(images.map((i) => i['fileId']), ['wrf-ok.png']);
    expect(errors, hasLength(1));
  });
}
