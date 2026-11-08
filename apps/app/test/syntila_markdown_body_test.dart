import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/features/common/syntila_code_block.dart';
import 'package:syntila_app/src/features/common/syntila_markdown_body.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

const source = '''
# Heading
## Subheading
### Third
#### Fourth
##### Fifth
###### Sixth

**Bold** *italic* ***both*** ~~removed~~ `inline`
First line
Second line

```dart
final status = 'ready';
```

> Quoted context

1. Ordered
2. Next

- Parent
  - Nested
- [x] Done
- [ ] Pending

| Name | State |
| --- | --- |
| Worker | Ready |

[Docs](https://example.com/docs) https://example.com

---

<span>HTML stays literal</span>
''';

void main() {
  testWidgets('table zoom opens, changes scale and closes', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SyntilaMarkdownBody(
              data:
                  'Before paragraph\n\n| Name | State |\n| --- | --- |\n| Worker | Ready |\n\nBetween paragraph\n\n| Item | Value |\n| --- | --- |\n| Second | Other |')),
    ));
    expect(find.byTooltip('Zoom table'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Zoom table').last);
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
    final dialog = find.byType(Dialog);
    final rendered = tester.widget<SyntilaMarkdownBody>(find.descendant(
        of: dialog, matching: find.byType(SyntilaMarkdownBody)));
    expect(rendered.data, contains('Second'));
    expect(rendered.data, isNot(contains('Worker')));
    expect(rendered.data, isNot(contains('Before paragraph')));
    final table = find.descendant(of: dialog, matching: find.byType(Table));
    final beforeZoom = tester.getSize(table).height;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsOneWidget);
    expect(tester.getSize(table).height, greaterThan(beforeZoom));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsNothing);
  });

  testWidgets('table dialog fits content and uses the desktop width',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<Size> openTable(String data) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Center(
                    child: SizedBox(
          width: 400,
          child: SyntilaMarkdownBody(data: data),
        )))),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Zoom table'));
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(const ValueKey('table-zoom-content')));
    }

    final small = await openTable('| A | B |\n| --- | --- |\n| 1 | 2 |');
    expect(small.width, lessThan(500));
    expect(small.height, lessThan(300));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    final header =
        List.generate(24, (i) => 'Long column number $i').join(' | ');
    final separator = List.filled(24, '---').join(' | ');
    final row = List.filled(24, 'Example value').join(' | ');
    final wide = await openTable('| $header |\n| $separator |\n| $row |');
    expect(wide.width, greaterThan(1000));
    expect(wide.width, lessThanOrEqualTo(1552));
    expect(wide.height, lessThan(300));
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    final rows = List.generate(80, (i) => '| Row $i | Value |').join('\n');
    final tall = await openTable('| Name | Value |\n| --- | --- |\n$rows');
    expect(tall.height, lessThanOrEqualTo(852));
    expect(tall.height, greaterThan(700));
    final dialog = find.byType(Dialog);
    await tester.drag(
        find
            .descendant(
                of: dialog, matching: find.byType(SingleChildScrollView))
            .first,
        const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('table-like text in a code fence has no zoom control',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SyntilaMarkdownBody(
        data: '```\n| Name | Value |\n| --- | --- |\n| a | b |\n```',
      )),
    ));
    expect(find.byTooltip('Zoom table'), findsNothing);
  });

  test('note blank lines become display-only spacers outside code', () {
    String show(String s) => visibleBlankLinesMarkdown(s).replaceAll('​', 'Z');
    expect(show('Alpha\n\nBeta'), 'Alpha\n\nBeta');
    expect(show('Alpha\n\n\nBeta'), 'Alpha\n\nZ\n\nBeta');
    // Blank lines inside a fence are code, not spacing.
    expect(show('```\none\n\n\nthree\n```'), '```\none\n\n\nthree\n```');
  });

  testWidgets(
      'note previews preserve blank-line spacing without changing messages',
      (tester) async {
    Future<double> height(String data, bool preserve) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: SyntilaMarkdownBody(data: data, preserveBlankLines: preserve),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getSize(find.byType(SyntilaMarkdownBody)).height;
    }

    final normal = await height('Alpha\n\nBeta', false);
    expect(await height('Alpha\n\n\n\nBeta', false), normal);
    final oneBlank = await height('Alpha\n\nBeta', true);
    final threeBlanks = await height('Alpha\n\n\n\nBeta', true);
    expect(threeBlanks, greaterThan(oneBlank));
    expect(await height('\n\nAlpha\n \n\nBeta\n\n', true),
        greaterThan(threeBlanks));
  });

  testWidgets(
      'Notes preserve empty headings produced by multiline heading formatting',
      (tester) async {
    Future<double> height(String data) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
        body: SyntilaMarkdownBody(data: data, preserveBlankLines: true),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getSize(find.byType(SyntilaMarkdownBody)).height;
    }

    final plainHeading = await height('## Heading');
    final withBlankLines = await height('\n\n## Heading\n\n\n');
    expect(withBlankLines, greaterThan(plainHeading));
    expect(await height('## \n## \n## Heading\n## \n## '),
        closeTo(withBlankLines, 0.01));
    expect(find.text('Heading', findRichText: true), findsOneWidget);
  });

  testWidgets(
      'visible blank lines retain headings, lists and literal code whitespace',
      (tester) async {
    const note = '# Heading\n\n- Item\n\n```text\none\n\nthree\n```\n\nTail';
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
      body: SyntilaMarkdownBody(data: note, preserveBlankLines: true),
    )));
    await tester.pumpAndSettle();
    // gpt_markdown ends a level-1 heading with a line break.
    expect(find.textContaining('Heading', findRichText: true), findsOneWidget);
    expect(find.text('Item', findRichText: true), findsOneWidget);
    expect(find.text('Tail', findRichText: true), findsOneWidget);
    expect(tester.widget<SyntilaCodeBlock>(find.byType(SyntilaCodeBlock)).code,
        contains('one\n\nthree'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection copies the whole response across paragraphs and code',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SyntilaMarkdownBody(
        data:
            'First **paragraph**.\n\nSecond paragraph.\n\n```dart\nfinal value = 1;\n```\n\nLast paragraph.',
      )),
    ));
    await tester.pumpAndSettle();
    final region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    region.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();
    expect(copied, contains('First paragraph.'));
    expect(copied, contains('Second paragraph.'));
    expect(copied, contains('final value = 1;'));
    expect(copied, contains('Last paragraph.'));
    expect(copied, isNot(contains('Copy code')));
    expect(copied, isNot(contains('dart')));
  });

  testWidgets('each message keeps Select All inside its message boundary',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SyntilaMarkdownBody(data: 'First message.'),
            SyntilaMarkdownBody(data: 'Second message.'),
          ],
        ),
      ),
    ));

    await tester.pumpAndSettle();
    final regions = find.byType(SelectableRegion);
    expect(regions, findsNWidgets(2));
    final first = tester.state<SelectableRegionState>(regions.at(0));
    first.selectAll();
    await tester.pump();
    first.contextMenuButtonItems
        .firstWhere((item) => item.type == ContextMenuButtonType.copy)
        .onPressed!();
    await tester.pump();

    expect(copied, 'First message.');
  });

  testWidgets('mouse drag selection spans rich Markdown and code',
      (tester) async {
    SelectedContent? selected;
    const data =
        'First paragraph.\n\n```dart\nfinal value = 1;\n```\n\nLast paragraph.';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyntilaMarkdownBody(
          data: data,
          onSelectionChanged: (value) => selected = value,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      tester.getTopLeft(find.text('First paragraph.')),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getBottomRight(find.text('Last paragraph.')));
    await gesture.up();
    await tester.pump();

    expect(selected?.plainText, contains('First paragraph.'));
    expect(selected?.plainText, contains('final value = 1;'));
    expect(selected?.plainText, contains('Last paragraph.'));
  });

  testWidgets('dragging text after a code block selects that text',
      (tester) async {
    SelectedContent? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SyntilaMarkdownBody(
        data: 'first\n\n```dart\nfinal x = 1;\n```\n\nafter code',
        onSelectionChanged: (value) => selected = value,
      )),
    ));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.textContaining('after code'));
    final gesture = await tester.startGesture(
        Offset(rect.left + 1, rect.top + 8),
        kind: PointerDeviceKind.mouse);
    await gesture.moveTo(Offset(rect.right - 1, rect.top + 8));
    await gesture.up();
    await tester.pump();
    expect(selected?.plainText, 'after code');
  });

  for (final prefix in [
    '```dart\nfinal x = 1;\n```',
    '| Name | State |\n| --- | --- |\n| Worker | Ready |',
    '> ```dart\n> final x = 1;\n> ```',
    '> | Name | State |\n> | --- | --- |\n> | Worker | Ready |',
    '- Item\n\n  ```dart\n  final x = 1;\n  ```',
  ]) {
    testWidgets('drag selects text after an inset block: $prefix',
        (tester) async {
      SelectedContent? selected;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(80, 100, 40, 0),
            child: SingleChildScrollView(
              child: SyntilaMarkdownBody(
                data: '$prefix\n\nafter block',
                onSelectionChanged: (value) => selected = value,
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('after block'));
      final gesture = await tester.startGesture(
        Offset(rect.left + 1, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
      await gesture.up();
      await tester.pump();
      expect(selected?.plainText, 'after block');

      final reverse = await tester.startGesture(
        Offset(rect.right - 1, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(reverse.removePointer);
      await reverse.moveTo(Offset(rect.left + 1, rect.center.dy));
      await reverse.up();
      await tester.pump();
      expect(selected?.plainText, 'after block');
    });
  }

  testWidgets('selection crosses quoted code in both directions',
      (tester) async {
    SelectedContent? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: SyntilaMarkdownBody(
            data: 'Before.\n\n> ```dart\n> final x = 1;\n> ```\n\nAfter.',
            onSelectionChanged: (value) => selected = value,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final start = tester.getTopLeft(find.text('Before.'));
    final end = tester.getBottomRight(find.text('After.'));
    for (final reverse in [false, true]) {
      final gesture = await tester.startGesture(reverse ? end : start,
          kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(reverse ? start : end);
      await gesture.up();
      await tester.pump();
      expect(selected?.plainText, contains('Before.'));
      expect(selected?.plainText, contains('final x = 1;'));
      expect(selected?.plainText, contains('After.'));
    }
  });

  testWidgets('selection is refreshed when a live message is replaced',
      (tester) async {
    String data = 'Old response';
    final selections = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SyntilaMarkdownBody(
              data: data,
              onSelectionChanged: (value) {
                if (value != null) selections.add(value.plainText);
              },
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: () => setState(() => data = 'New response'),
              child: const Icon(Icons.refresh),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final first =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    first.selectAll();
    await tester.pump();
    expect(selections.last, 'Old response');

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    final second =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    second.selectAll();
    await tester.pump();
    expect(selections.last, 'New response');
  });

  testWidgets('long responses retain rich rendering and selection',
      (tester) async {
    final paragraphs = List<String>.generate(
        220, (index) => 'Paragraph $index with **bold** and `inline code`.');
    final data = [
      '# Long response',
      '| Name | State |\n| --- | --- |\n| Worker | Ready |',
      '```json\n{"status":"ready","items":[1,2,3]}\n```',
      ...paragraphs,
    ].join('\n\n');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SyntilaMarkdownBody(data: data),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final region =
        tester.state<SelectableRegionState>(find.byType(SelectableRegion));
    region.selectAll();
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(SyntilaCodeBlock), findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is SingleChildScrollView &&
            widget.scrollDirection == Axis.horizontal),
        findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  for (final content in [
    '<script>alert("unsafe")</script>',
    '<iframe src="https://example.com"></iframe>',
    '[bad](javascript:alert) [file](file:///tmp/private)',
    '![tracking](https://example.com/tracker)',
    '**unfinished [broken](\n```unknown\nunclosed',
  ]) {
    testWidgets('untrusted source renders without executable content: $content',
        (tester) async {
      var launches = 0;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SyntilaMarkdownBody(
        data: content,
        openLink: (_) async {
          launches++;
          return true;
        },
      ))));
      expect(find.byType(Image), findsNothing);
      expect(launches, 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('GFM contract renders in $brightness', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: SyntilaMarkdownBody(data: source),
          ),
        ),
      ));
      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      expect(renderer.html, isFalse);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(renderer.data, source);
      expect(find.byType(Table), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
          .join('\n');
      expect(text, contains('Heading'));
      expect(text, contains('Nested'));
      expect(text, contains("final status = 'ready';"));
      expect(text, contains('<span>HTML stays literal</span>'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('authored links delegate to the caller', (tester) async {
    String? destination;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyntilaMarkdownBody(
          data: '[Docs](https://example.com/docs)',
          openLink: (uri) async {
            destination = uri.toString();
            return true;
          },
        ),
      ),
    ));
    final renderer = tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
    renderer.onLinkTap!('https://example.com/docs', 'Docs');
    expect(destination, 'https://example.com/docs');

    destination = null;
    await tester.tap(find.text('Docs', findRichText: true));
    await tester.pump();
    expect(destination, 'https://example.com/docs');
  });

  test('link validation rejects unsafe and malformed destinations', () {
    for (final value in [
      null,
      '',
      'javascript:alert(1)',
      'file:///tmp/file',
      'syntila://run',
      'mailto:user@example.com',
      '/relative',
      '//example.com',
      'https://user:password@example.com',
      'https://@example.com',
      'https://',
      'https:///path',
      'https://example.com:bad',
      'https://example.com:65536',
      'https://example.com/%zz',
      'https://exa mple.com',
      'https://example.com\\path',
      'https://example.com\n',
    ]) {
      expect(validatedMarkdownLink(value), isNull, reason: '$value');
    }
    for (final value in [
      'https://example.com/path?q=value#section',
      'http://localhost:8787/path',
      'https://example.com/a%20b',
      'https://[::1]:443/',
    ]) {
      expect(validatedMarkdownLink(value), isNotNull, reason: value);
    }
  });

  testWidgets('unsafe links never reach the launcher', (tester) async {
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyntilaMarkdownBody(
          data: '[Unsafe](javascript:alert)',
          openLink: (_) async {
            launches++;
            return true;
          },
        ),
      ),
    ));
    final renderer = tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
    renderer.onLinkTap!('javascript:alert', 'Unsafe');
    await tester.pump();
    expect(launches, 0);
  });

  testWidgets('images show alt text without image loading widgets',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SyntilaMarkdownBody(
          data:
              '![Diagram](https://example.com/tracker.png)\n\n![](file:///tmp/image.png)',
        ),
      ),
    ));
    expect(find.text('Diagram'), findsOneWidget);
    expect(find.text('Image'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
      'SyntilaMarkdownStyleSheet uses accessible brand tokens for light and dark modes',
      () {
    final lightSheet =
        SyntilaMarkdownStyleSheet.fromTheme(SyntilaBrand.lightTheme());
    final darkSheet =
        SyntilaMarkdownStyleSheet.fromTheme(SyntilaBrand.darkTheme());

    expect(lightSheet.p?.fontSize, 14);
    expect(darkSheet.p?.fontSize, 14);
    expect(lightSheet.p?.height, 1.5);
    expect(darkSheet.p?.height, 1.5);
    expect(lightSheet.a?.color, SyntilaColors.primaryForegroundLight);
    expect(darkSheet.a?.color, SyntilaColors.primaryForegroundDark);
    expect(lightSheet.codeblockDecoration, isNotNull);
    expect(darkSheet.codeblockDecoration, isNotNull);
  });

  group('code and file link parsing', () {
    test('parses file: schemes with lines and ranges', () {
      final link1 = parseCodeOrFileLink('file:///path/to/main.dart#L10-L20');
      expect(link1, isNotNull);
      expect(link1!.filePath, '/path/to/main.dart');
      expect(link1.line, 10);
      expect(link1.endLine, 20);
      expect(link1.formattedLocation, '/path/to/main.dart:10-20');
      expect(link1.displayTarget, 'main.dart:10-20');

      final link2 = parseCodeOrFileLink('file:///path/to/file.dart:45');
      expect(link2, isNotNull);
      expect(link2!.filePath, '/path/to/file.dart');
      expect(link2.line, 45);
      expect(link2.displayTarget, 'file.dart:45');

      final link3 =
          parseCodeOrFileLink('file:///Users/dev/My%20App/lib/app.dart');
      expect(link3, isNotNull);
      expect(link3!.filePath, '/Users/dev/My App/lib/app.dart');
      expect(link3.line, isNull);
      expect(link3.displayTarget, 'app.dart');

      final winLink = parseCodeOrFileLink('file:///C:/Users/dev/main.dart#L5');
      expect(winLink, isNotNull);
      expect(winLink!.filePath, 'C:/Users/dev/main.dart');
      expect(winLink.line, 5);
      expect(winLink.displayTarget, 'main.dart:5');
    });

    test('parses editor schemes: vscode and cursor', () {
      final vscode =
          parseCodeOrFileLink('vscode://file/Users/dev/project/main.dart:12');
      expect(vscode, isNotNull);
      expect(vscode!.editorScheme, 'vscode');
      expect(vscode.filePath, '/Users/dev/project/main.dart');
      expect(vscode.line, 12);

      final cursor =
          parseCodeOrFileLink('cursor://file/Users/dev/project/main.dart:99');
      expect(cursor, isNotNull);
      expect(cursor!.editorScheme, 'cursor');
      expect(cursor.filePath, '/Users/dev/project/main.dart');
      expect(cursor.line, 99);
    });

    test('parses relative workspace paths and known project files', () {
      final rel1 = parseCodeOrFileLink('apps/app/lib/main.dart:15');
      expect(rel1, isNotNull);
      expect(rel1!.filePath, 'apps/app/lib/main.dart');
      expect(rel1.line, 15);
      expect(rel1.displayTarget, 'main.dart:15');

      final rel2 = parseCodeOrFileLink('README.md#setup');
      expect(rel2, isNotNull);
      expect(rel2!.filePath, 'README.md');
      expect(rel2.line, isNull);
      expect(rel2.displayTarget, 'README.md');

      final rel3 = parseCodeOrFileLink('./pubspec.yaml');
      expect(rel3, isNotNull);
      expect(rel3!.filePath, './pubspec.yaml');

      final dockerfile = parseCodeOrFileLink('Dockerfile');
      expect(dockerfile, isNotNull);
      expect(dockerfile!.filePath, 'Dockerfile');
    });

    test('rejects anchors, web URLs, unsafe schemes, and non-file paths', () {
      expect(parseCodeOrFileLink('#heading'), isNull);
      expect(parseCodeOrFileLink('https://example.com/file.dart'), isNull);
      expect(parseCodeOrFileLink('http://localhost:8080/main.dart'), isNull);
      expect(parseCodeOrFileLink('javascript:alert(1)'), isNull);
      expect(parseCodeOrFileLink('data:text/html'), isNull);
      expect(parseCodeOrFileLink('mailto:dev@example.com'), isNull);
      expect(parseCodeOrFileLink('/spaces/space-123/thread-456'), isNull);
      expect(parseCodeOrFileLink(''), isNull);
      expect(parseCodeOrFileLink(null), isNull);
    });
  });

  group('multi-scheme link handling in SyntilaMarkdownBody', () {
    testWidgets('intra-document anchor clicks complete without error',
        (tester) async {
      var launches = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyntilaMarkdownBody(
            data: '[Anchor](#section)',
            openLink: (_) async {
              launches++;
              return true;
            },
          ),
        ),
      ));
      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      renderer.onLinkTap!('#section', 'Anchor');
      await tester.pump();
      expect(launches, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'file link triggers editor launcher and copies formatted location to clipboard',
        (tester) async {
      Uri? openedUri;
      String? copiedText;

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copiedText = args['text'] as String?;
            return null;
          }
          return null;
        },
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyntilaMarkdownBody(
            data: '[Source](file:///Users/dev/Syntila/app.dart#L10-L20)',
            openLink: (uri) async {
              openedUri = uri;
              return true;
            },
          ),
        ),
      ));

      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      renderer.onLinkTap!(
          'file:///Users/dev/Syntila/app.dart#L10-L20', 'Source');
      await tester.pump();

      expect(
          openedUri, Uri.parse('vscode://file/Users/dev/Syntila/app.dart:10'));
      expect(copiedText, '/Users/dev/Syntila/app.dart:10-20');
      expect(tester.takeException(), isNull);
    });

    testWidgets('relative code path copies to clipboard when editor fails',
        (tester) async {
      String? copiedText;

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            copiedText = args['text'] as String?;
            return null;
          }
          return null;
        },
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyntilaMarkdownBody(
            data: '[Main](apps/app/lib/main.dart:45)',
            openLink: (_) async => false, // Launcher returns false
          ),
        ),
      ));

      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      renderer.onLinkTap!('apps/app/lib/main.dart:45', 'Main');
      await tester.pump();

      expect(copiedText, 'apps/app/lib/main.dart:45');
      expect(tester.takeException(), isNull);
    });

    testWidgets('onOpenFile callback intercepts code links if provided',
        (tester) async {
      ParsedCodeLink? intercepted;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyntilaMarkdownBody(
            data: '[File](lib/src/foo.dart:25)',
            onOpenFile: (link) async {
              intercepted = link;
              return true;
            },
          ),
        ),
      ));

      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      renderer.onLinkTap!('lib/src/foo.dart:25', 'File');
      await tester.pump();

      expect(intercepted, isNotNull);
      expect(intercepted!.filePath, 'lib/src/foo.dart');
      expect(intercepted!.line, 25);
    });

    testWidgets('onNavigateTo callback intercepts in-app routes',
        (tester) async {
      String? navigatedRoute;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SyntilaMarkdownBody(
            data: '[Space](/spaces/space-123)',
            onNavigateTo: (route) {
              navigatedRoute = route;
            },
          ),
        ),
      ));

      final renderer =
          tester.widget<GptMarkdown>(find.byType(GptMarkdown).first);
      renderer.onLinkTap!('/spaces/space-123', 'Space');
      await tester.pump();

      expect(navigatedRoute, '/spaces/space-123');
    });
  });
}
