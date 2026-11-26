import 'dart:io';

import 'dart:convert';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:syntila_connect/src/output_images.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('imgs'));
  tearDown(() => root.delete(recursive: true));

  test('picks up a linked provider image and removes its links', () async {
    final brain = Directory(p.join(root.path, 'brain', 'conv'))
      ..createSync(recursive: true);
    final image = File(p.join(brain.path, 'lake.jpg'))..writeAsBytesSync([1]);
    final secret = File(p.join(root.path, 'secret.png'))..writeAsBytesSync([1]);
    final reply =
        'Here it is:\n\n![Lake](${Uri.file(image.path)})\n\n'
        'File: [lake.jpg](${Uri.file(image.path)})\n'
        '![Other](${Uri.file(secret.path)})';

    final linked = linkedImages(reply, [p.join(root.path, 'brain')]);
    expect(linked, [image.path]);
    expect(await collectOutputImages(const [], linked), [image.path]);
    final text = withoutImageLinks(reply, linked);
    expect(text, isNot(contains(image.path)));
    expect(text, contains(secret.path));
  });

  test('collects every saved file, skipping empty ones', () async {
    final outputs = Directory(p.join(root.path, 'outputs'))..createSync();
    File(p.join(outputs.path, 'b.png')).writeAsBytesSync([1]);
    File(p.join(outputs.path, 'a.webp')).writeAsBytesSync([1]);
    File(p.join(outputs.path, 'empty.png')).createSync();
    File(p.join(outputs.path, 'notes.txt')).writeAsBytesSync([1]);
    final found = await collectOutputImages([outputs.path], const []);
    expect(found.map(p.basename), ['a.webp', 'b.png', 'notes.txt']);
    expect(outputFileMediaType('sound.WAV'), 'audio/wav');
    expect(outputFileMediaType('notes.txt'), 'text/plain');
    expect(outputFileMediaType('blob'), 'application/octet-stream');
  });

  test('makes a small JPEG preview within the budget', () {
    final large = img.Image(width: 2000, height: 1000, numChannels: 4)
      ..clear(img.ColorRgba8(10, 120, 200, 128));
    final preview = encodeOutputImagePreview(img.encodePng(large));
    expect(preview, isNotNull);
    expect(preview!.startsWith('/9j/'), isTrue);
    expect(preview.length, lessThanOrEqualTo(maxOutputImagePreviewChars));
    final decoded = img.decodeJpg(base64Decode(preview))!;
    expect(decoded.width, outputImagePreviewMaxSide);
    expect(decoded.height, outputImagePreviewMaxSide ~/ 2);
    expect(encodeOutputImagePreview(utf8.encode('not an image')), isNull);
  });

  test('a video poster needs ffmpeg and is skipped without it', () async {
    final bin = Directory(p.join(root.path, 'bin'))..createSync();
    expect(
      findFfmpeg({'PATH': bin.path}),
      anyOf(isNull, isNot(startsWith(bin.path))),
    );
    final ffmpegName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    File(p.join(bin.path, ffmpegName)).writeAsStringSync('');
    expect(findFfmpeg({'PATH': bin.path}), p.join(bin.path, ffmpegName));
    final video = File(p.join(root.path, 'clip.mp4'))..writeAsBytesSync([1]);
    expect(isOutputVideo(video.path), isTrue);
    // A tool that cannot run gives no poster, never an error.
    expect(
      await outputVideoPreview(video, ffmpeg: p.join(bin.path, 'missing')),
      isNull,
    );
  });
}
