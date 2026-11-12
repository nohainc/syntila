import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
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
    expect(
      promptWithOutputImages('Draw a fox', 'asg-1'),
      allOf(
        startsWith('Draw a fox'),
        contains('.syntila/outputs/asg-1/'),
        contains(
            'Do not embed them in Markdown or mention the output file path'),
        isNot(contains('attached to your reply')),
      ),
    );
    expect(
      promptWithOutputImages(
        'Draw a fox',
        'asg-1',
        workingDirectoryPath: '/tmp/space',
      ),
      contains(
        [
          '/tmp/space',
          '.syntila',
          'outputs',
          'asg-1',
          '',
        ].join(Platform.pathSeparator),
      ),
    );
  });

  test('collects non-empty output files, in name order', () async {
    final dir = await outputs();
    File('${dir.path}/b.PNG').writeAsBytesSync([1]);
    File('${dir.path}/a.jpg').writeAsBytesSync([1]);
    File('${dir.path}/empty.png').writeAsBytesSync([]);
    File('${dir.path}/notes.txt').writeAsStringSync('x');
    final files = await collectWorkerOutputImages(work, 'asg-1');
    expect(files.map((f) => f.uri.pathSegments.last),
        ['a.jpg', 'b.PNG', 'notes.txt']);
    expect(await collectWorkerOutputImages(work, 'asg-2'), isEmpty);
  });

  test(
      'collects images saved under additional directories when CLI changes cwd',
      () async {
    final extra = await Directory.systemTemp.createTemp('extra-folder');
    addTearDown(() => extra.delete(recursive: true));
    final extraOutputs = await Directory(
      '${extra.path}/${workerOutputImagesRelativePath('asg-1')}',
    ).create(recursive: true);
    File('${extraOutputs.path}/sunset.png').writeAsBytesSync([1, 2, 3]);

    final files = await collectWorkerOutputImages(
      work,
      'asg-1',
      additionalDirectories: [extra.path],
    );
    expect(files.map((f) => f.uri.pathSegments.last), ['sunset.png']);
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

  test('publishes a bounded JPEG preview next to the original', () async {
    final dir = await outputs();
    final original = img.Image(width: 2048, height: 1024, numChannels: 4);
    for (final pixel in original) {
      pixel
        ..r = pixel.x % 256
        ..g = pixel.y % 256
        ..b = (pixel.x * pixel.y) % 256
        ..a = 200;
    }
    File('${dir.path}/large.png').writeAsBytesSync(img.encodePng(original));
    final images = await publishWorkerOutputImages(
      cloud: _RecordingCloud(),
      workingDirectory: work,
      assignmentId: 'asg-1',
    );
    final preview = images.single['previewImage'] as String;
    expect(preview, startsWith('/9j/'));
    expect(preview.length, lessThanOrEqualTo(maxWorkerOutputImagePreviewChars));
    final decoded = img.decodeJpg(base64Decode(preview))!;
    expect(decoded.width, lessThanOrEqualTo(workerOutputImagePreviewMaxSide));
    expect(decoded.width, greaterThan(decoded.height));
    expect(images.single['fileId'], 'wrf-large.png');
  });
}
