import 'dart:convert';
import 'package:syntila_app/src/features/common/attachment_cards.dart';
import 'package:syntila_app/src/features/common/markdown_composer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_design/syntila_design.dart';

void main() {
  test('text preview is bounded, plain source and tolerates unknown files', () {
    expect(
        attachmentTextPreview({
          'name': 'note.md',
          'contentBase64': base64Encode(utf8.encode('<b>source</b>' * 200))
        })!
            .length,
        1200);
    expect(attachmentTextPreview({'name': 'a.pdf', 'contentBase64': 'AA=='}),
        isNull);
    expect(
        attachmentTextPreview({'name': 'a.txt', 'contentBase64': 'invalid!'}),
        isNull);
  });
  testWidgets('square cards sit above text; close shows only on hover',
      (tester) async {
    var removed = 0;
    final controller = TextEditingController(text: 'Message text');
    final file = {'name': 'note.txt', 'sizeBytes': 5, 'previewText': 'hello'};
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
            body: MarkdownComposer(
                controller: controller,
                chatStyle: true,
                attachments: AttachmentCards(
                    files: [file], onRemove: (_) => removed++)))));
    final card = tester.getRect(find.byType(AttachmentCard));
    expect(card.width, card.height);
    expect(card.top, lessThan(tester.getTopLeft(find.byType(TextField)).dy));
    expect(find.text('hello'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.byTooltip('Remove attachment'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(card.center);
    await tester.pumpAndSettle();
    final overlaySurface = find.descendant(
        of: find.byTooltip('Remove attachment'),
        matching: find.byType(Material));
    expect(tester.widget<Material>(overlaySurface.first).shape,
        SyntilaRadius.buttonShape);
    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(removed, 1);
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove attachment'), findsNothing);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('thumbnail is center-cropped; tap opens original in a popup',
      (tester) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: AttachmentCard(file: {
        'name': 'image.png',
        'mediaType': 'image/png',
        'previewImage': png,
        'contentBase64': png,
      })),
    ));
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byType(AttachmentCard));
    expect(card.width, card.height);
    final thumb = tester.widget<Image>(find.byType(Image));
    expect(thumb.fit, BoxFit.cover);
    expect(thumb.alignment, Alignment.center);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: card.center);
    await tester.pump();
    // Hover rebuilds must reuse the same image so the thumbnail can't flicker.
    expect(tester.widget<Image>(find.byType(Image)).image, thumb.image);
    await mouse.removePointer();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('attachment-open')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('attachment-image-viewer')), findsOneWidget);
    await tester.tap(find.byTooltip('Close preview'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('attachment-image-viewer')), findsNothing);
  });
  testWidgets('history non-image opens externally and can download',
      (tester) async {
    String? opened;
    List<int>? downloaded;
    final file = {
      'name': 'document.pdf',
      'mediaType': 'application/pdf',
      'sizeBytes': 42,
      'fileId': 'file',
      'previewImage': 'invalid!'
    };
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AttachmentDownloadScope(
                load: (_) async => [1, 2, 3],
                download: (_, bytes) async => downloaded = bytes,
                open: (bytes, name, type) => opened = '$name|$type|$bytes',
                child: AttachmentCards(files: [file])))));
    expect(find.byTooltip('Remove attachment'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('attachment-open')));
    await tester.pumpAndSettle();
    expect(opened, 'document.pdf|application/pdf|[1, 2, 3]');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
        location: tester.getCenter(find.byType(AttachmentCard)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Download attachment'));
    await tester.pumpAndSettle();
    expect(downloaded, [1, 2, 3]);
    await mouse.removePointer();
  });
}
