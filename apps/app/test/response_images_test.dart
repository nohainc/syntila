import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/common/attachment_cards.dart';

import 'conversation_turn_fixture.dart';

const _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

void main() {
  test('turn images round-trip and surface on the request', () {
    final json = turnFixture().toJson()
      ..['images'] = [
        {
          'kind': 'file',
          'fileId': 'wrf-1',
          'name': 'fox.png',
          'mediaType': 'image/png',
          'sizeBytes': 10,
        }
      ];
    final turn = AxConversationTurn.fromJson(json);
    expect(turn.images.single.fileId, 'wrf-1');
    expect(AxConversationTurn.fromJson(turn.toJson()).images.single.mediaType,
        'image/png');
    expect(turnFixture().toJson().containsKey('images'), isFalse);

    final request = AxWorkRequest.fromJson({
      'id': 'R',
      'prompt': 'Draw',
      'status': 'completed',
      'createdAt': '2026-10-07T10:00:00Z',
      'turns': [json],
    });
    expect(request.responseImages.map((i) => i.name), ['fox.png']);
  });

  testWidgets('response image loads through the Thread download scope',
      (tester) async {
    final loaded = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AttachmentDownloadScope(
          load: (file) async {
            loaded.add(file['fileId'] as String);
            return _png;
          },
          download: (_, __) async {},
          child: const ResponseImages(files: [
            {'kind': 'file', 'fileId': 'wrf-test-1', 'name': 'fox.png'}
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(loaded, ['wrf-test-1']);
    expect(find.byKey(const ValueKey('response-image-open')), findsOneWidget);
    tester
        .widget<InkWell>(find.byKey(const ValueKey('response-image-open')))
        .onTap!();
    await tester.pump();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('image-viewer-content'));
    expect(tester.getSize(dialog), const Size(44, 44));
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(tester.getSize(dialog), const Size(44, 44));
  });

  testWidgets('image viewer fits width and height without enlarging',
      (tester) async {
    for (final example in [
      (
        encoded:
            'iVBORw0KGgoAAAANSUhEUgAAAZAAAADICAIAAABJdyC1AAAC2ElEQVR4nO3OQQkAQRAEsfFves9C/4qDQATk3h3AL/QDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgFE/ABj1A4BRPwAY9QOAUT8AGPUDgNEHMitZuk04SKkAAAAASUVORK5CYII=',
        original: const Size(400, 200),
        scaled: const Size(220, 110)
      ),
      (
        encoded:
            'iVBORw0KGgoAAAANSUhEUgAAAMgAAAGQCAIAAABkkLjnAAAEyklEQVR4nO3OAQkAMBDEsPNvejPxUCiFCMjelpzjB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1HiB1H6QURZurJuhNIAAAAASUVORK5CYII=',
        original: const Size(200, 400),
        scaled: const Size(76, 152)
      ),
    ]) {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      final bytes = base64Decode(example.encoded);
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AttachmentDownloadScope(
        load: (_) async => bytes,
        download: (_, __) async {},
        child: ResponseImages(files: [
          {'fileId': example.encoded, 'name': 'sized.png'}
        ]),
      ))));
      await tester.pumpAndSettle();
      tester
          .widget<InkWell>(find.byKey(const ValueKey('response-image-open')))
          .onTap!();
      await tester.pump();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final content = find.byKey(const ValueKey('image-viewer-content'));
      expect(tester.getSize(content), example.original);
      await tester.binding.setSurfaceSize(const Size(300, 200));
      await tester.pumpAndSettle();
      expect(
          tester.getSize(content).width, closeTo(example.scaled.width, 0.01));
      expect(
          tester.getSize(content).height, closeTo(example.scaled.height, 0.01));
      await tester.tap(find.byTooltip('Close preview'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    }
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets(
      'response image shows its preview and loads the original to download',
      (tester) async {
    final loaded = <String>[];
    final downloaded = <List<int>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AttachmentDownloadScope(
          load: (file) async {
            loaded.add(file['fileId'] as String);
            return _png;
          },
          download: (_, bytes) async => downloaded.add(bytes),
          child: const ResponseImages(files: [
            {
              'kind': 'file',
              'fileId': 'wrf-test-2',
              'name': 'fox.png',
              'previewImage': '/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==',
            }
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(loaded, isEmpty, reason: 'the preview is shown inline');
    await tester.tap(find.byTooltip('Download image'));
    await tester.pumpAndSettle();
    expect(loaded, ['wrf-test-2']);
    expect(downloaded, [_png]);
  });
}
