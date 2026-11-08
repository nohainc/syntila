import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_work_models.dart';
import 'package:syntila_app/src/features/common/attachment_cards.dart';

import 'conversation_turn_fixture.dart';

const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
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
  });
}
