import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/common/attachment_cards.dart';
import 'package:syntila_app/src/features/common/media_player.dart';
import 'package:video_player/video_player.dart';

const _fileId = 'wrf-11111111-1111-4111-8111-111111111111';

Widget _scope(Map<String, dynamic> file, List<String> requested) => MaterialApp(
      home: Scaffold(
        body: AttachmentDownloadScope(
          load: (_) async => const [1, 2, 3],
          download: (_, __) async {},
          mediaLink: (file) async {
            requested.add(file['fileId'] as String);
            return Uri.parse('https://backend.test/api/media/$_fileId?sig=x');
          },
          child: AttachmentCards(files: [file]),
        ),
      ),
    );

void main() {
  late VideoPlayerController Function(Uri) original;
  setUp(() => original = mediaControllerFactory);
  tearDown(() => mediaControllerFactory = original);

  testWidgets('an audio card plays from a media link and reports a failure',
      (tester) async {
    final opened = <Uri>[];
    mediaControllerFactory = (link) {
      opened.add(link);
      throw StateError('no player in tests');
    };
    final requested = <String>[];
    await tester.pumpWidget(_scope({
      'kind': 'file',
      'fileId': _fileId,
      'name': 'sound.wav',
      'mediaType': 'audio/wav',
    }, requested));

    expect(find.text('sound.wav'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('audio-play')));
    await tester.pumpAndSettle();

    expect(requested, [_fileId]);
    expect(opened.single.path, '/api/media/$_fileId');
    expect(find.byIcon(Icons.music_off_outlined), findsOneWidget);
  });

  testWidgets('a video card opens the player dialog', (tester) async {
    mediaControllerFactory = (_) => throw StateError('no player in tests');
    final requested = <String>[];
    await tester.pumpWidget(_scope({
      'kind': 'file',
      'fileId': _fileId,
      'name': 'clip.mp4',
      'mediaType': 'video/mp4',
    }, requested));

    expect(find.byKey(const ValueKey('video-play-badge')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('attachment-open')));
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey('attachment-video-player')), findsOneWidget);
    expect(find.byKey(const ValueKey('media-failure')), findsOneWidget);
    expect(requested, [_fileId]);
  });

  test('recognizes audio and video files by type or name', () {
    expect(attachmentIsAudio({'name': 'a.MP3'}), isTrue);
    expect(attachmentIsAudio({'mediaType': 'audio/ogg'}), isTrue);
    expect(attachmentIsVideo({'name': 'b.webm'}), isTrue);
    expect(attachmentIsVideo({'name': 'notes.txt'}), isFalse);
    expect(formatMediaTime(const Duration(seconds: 75)), '1:15');
  });
}
