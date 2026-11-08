import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/gestures.dart';
import 'package:syntila_app/src/features/common/markdown_composer.dart';
import 'package:syntila_app/src/features/common/syntila_markdown_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final toolbarSend in [false, true]) {
      testWidgets(
          'composer control colors $brightness toolbarSend=$toolbarSend',
          (tester) async {
        final controller = TextEditingController(text: 'Draft');
        addTearDown(controller.dispose);
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(
              body: MarkdownComposer(
            controller: controller,
            chatStyle: true,
            sendInToolbar: toolbarSend,
            additionalControlsBuilder:
                toolbarSend ? (_) => const Text("Options") : null,
            showMarkdownControlsInSuffix: !toolbarSend,
            onSend: () {},
          )),
        ));
        void expectControls(String toggle) {
          final icon = tester.widget<Icon>(find.descendant(
              of: find.byTooltip(toggle), matching: find.byType(Icon)));
          expect(icon.color, theme.colorScheme.onSurface);
          final send = tester.widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded));
          expect(send.color, theme.colorScheme.onSurface);
          expect(find.byType(Divider), findsNothing);
        }

        expectControls('Show Markdown controls');
        await tester.tap(find.byTooltip('Show Markdown controls'));
        await tester.pump();
        expectControls('Hide Markdown controls');
        expect(
            tester
                .widget<IconButton>(
                    find.widgetWithIcon(IconButton, Icons.format_bold))
                .color,
            theme.colorScheme.onSurface);
        final preview = tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Preview'));
        expect(preview.style?.foregroundColor?.resolve({}),
            theme.colorScheme.onSurface);
        await tester.tap(find.text('Preview'));
        await tester.pump();
        final write =
            tester.widget<TextButton>(find.widgetWithText(TextButton, 'Write'));
        expect(write.style?.foregroundColor?.resolve({}),
            theme.colorScheme.onSurface);
        expect(find.byType(Divider), findsNothing);
      });
    }
  }

  testWidgets(
      'toolbar Send stays visible on narrow screens while typing remains enabled',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      chatStyle: true,
      sendInToolbar: true,
      sendEnabled: false,
      onSend: () {},
      additionalControlsBuilder: (_) => const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child:
              Row(children: [Text('Worker · Model · Effort · extra options')])),
    ))));
    expect(find.byTooltip('Send message'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byTooltip('Send message')),
        findsNothing);
    expect(tester.getRect(find.byTooltip('Send message')).right,
        lessThanOrEqualTo(360));
    expect(
        tester
            .widget<IconButton>(find.ancestor(
                of: find.byIcon(Icons.send_rounded),
                matching: find.byType(IconButton)))
            .onPressed,
        isNull);
    await tester.enterText(find.byType(TextField), 'Draft next request');
    expect(controller.text, 'Draft next request');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Chat restores compact send controls and hides formatting by default',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
                controller: controller,
                chatStyle: true,
                onSend: controller.clear))));
    expect(find.byTooltip('Bold'), findsNothing);
    expect(find.text('Preview'), findsNothing);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.decoration?.hintText, isNull);
    expect(field.minLines, 1);
    expect(
        find.descendant(
            of: find.byType(TextField),
            matching: find.byTooltip('Send message')),
        findsOneWidget);
    await tester.tap(find.byTooltip('Show Markdown controls'));
    await tester.pump();
    expect(find.byTooltip('Bold'), findsOneWidget);
    expect(tester.getTopLeft(find.byTooltip('Bold')).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byType(TextField)).dy));
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Write'), findsNothing);
    expect(tester.getTopLeft(find.text('Preview')).dx,
        greaterThan(tester.getTopLeft(find.byTooltip('Task list')).dx));
    controller.text = 'Ready to send';
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('Preview'), findsNothing);
    expect(find.text('Write'), findsOneWidget);
    expect(tester.getCenter(find.text('Write')).dy,
        closeTo(tester.getCenter(find.byTooltip('Task list')).dy, 1));
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('Send message')).dy,
        closeTo(tester.getCenter(find.text('Write')).dy, 1));
    expect(tester.getTopLeft(find.byTooltip('Send message')).dx,
        greaterThan(tester.getTopLeft(find.text('Write')).dx));
    controller.text = 'Ready to send';
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Write'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.byTooltip('Hide Markdown controls'));
    await tester.pump();
    expect(find.byTooltip('Bold'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two-pane toolbar keeps Send at the right in Write and Preview',
      (tester) async {
    final controller = TextEditingController(text: '**Draft**');
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 460,
                child: MarkdownComposer(
                  controller: controller,
                  chatStyle: true,
                  onSend: () => sends++,
                  showMarkdownControls: false,
                  showMarkdownControlsInSuffix: false,
                  showSendInSuffix: false,
                  sendInFormattingToolbar: true,
                )))));
    expect(find.byTooltip('Show Markdown controls'), findsNothing);
    expect(find.byTooltip('Hide Markdown controls'), findsNothing);
    expect(find.byTooltip('Bold'), findsOneWidget);
    for (final mode in ['Preview', 'Write']) {
      expect(find.byTooltip('Send message'), findsOneWidget);
      expect(tester.getCenter(find.byTooltip('Send message')).dy,
          closeTo(tester.getCenter(find.text(mode)).dy, 1));
      expect(
          tester
              .getRect(find.widgetWithIcon(IconButton, Icons.send_rounded))
              .right,
          closeTo(454, 1));
      await tester.tap(find.text(mode));
      await tester.pump();
    }
    await tester.tap(find.byTooltip('Send message'));
    expect(sends, 1);
    expect(controller.text, '**Draft**');
    expect(tester.takeException(), isNull);
  });

  test('empty selections, multiline prefixes and quote toggle', () {
    for (final format in MarkdownFormat.values) {
      final controller = TextEditingController();
      formatMarkdown(controller, format);
      expect(controller.text, isNotEmpty, reason: format.name);
      expect(controller.selection.isValid, isTrue);
      controller.dispose();
    }
    for (final (format, prefix) in [
      (MarkdownFormat.heading, '## '),
      (MarkdownFormat.bulletList, '- '),
      (MarkdownFormat.taskList, '- [ ] '),
      (MarkdownFormat.quote, '> '),
    ]) {
      final controller = TextEditingController(text: 'one\ntwo')
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      formatMarkdown(controller, format);
      expect(controller.text, '${prefix}one\n${prefix}two');
      if (format == MarkdownFormat.quote) {
        formatMarkdown(controller, format);
        expect(controller.text, 'one\ntwo');
      }
      controller.dispose();
    }
    final controller = TextEditingController(text: 'one\ntwo')
      ..selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    formatMarkdown(controller, MarkdownFormat.codeBlock);
    expect(controller.text, '```\none\ntwo\n```');
    controller.dispose();
  });
  testWidgets(
      'Enter sends, Shift Enter authors a newline, and Cmd/Ctrl Enter sends',
      (tester) async {
    final controller = TextEditingController(text: '**raw**');
    addTearDown(controller.dispose);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
            body: MarkdownComposer(
          controller: controller,
          onSend: () => sends++,
        ))));
    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(sends, 1);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.textInputAction, TextInputAction.newline);
    // The platform text-input service delivers the newline to the controller.
    tester.testTextInput.enterText('**raw**\n');
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
    }
    expect(sends, 3);
    expect(controller.text, '**raw**\n');
    await tester.tap(find.byTooltip('Send message'));
    expect(sends, 4);
  });

  testWidgets('Enter submits edit and Shift Enter keeps a newline',
      (tester) async {
    final controller = TextEditingController(text: 'draft');
    addTearDown(controller.dispose);
    var submits = 0;
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: Scaffold(
            body: MarkdownComposer(
          controller: controller,
          onSubmit: () => submits++,
        ))));

    await tester.tap(find.byType(TextField));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(submits, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(submits, 1);
  });

  test('inline and fenced edits preserve selected content', () {
    for (final (format, expected) in [
      (MarkdownFormat.bold, '**hello**'),
      (MarkdownFormat.italic, '*hello*'),
      (MarkdownFormat.inlineCode, '`hello`'),
      (MarkdownFormat.codeBlock, '```\nhello\n```'),
      (MarkdownFormat.link, '[hello](url)'),
    ]) {
      final controller = TextEditingController(text: 'hello')
        ..selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      formatMarkdown(controller, format);
      expect(controller.text, expected);
      expect(controller.selection.textInside(controller.text),
          format == MarkdownFormat.link ? 'url' : 'hello');
      controller.dispose();
    }
  });

  test('line formatting affects selected lines without touching neighbors', () {
    final controller = TextEditingController(text: 'before\none\ntwo\nafter')
      ..selection = const TextSelection(baseOffset: 8, extentOffset: 15);
    formatMarkdown(controller, MarkdownFormat.numberedList);
    expect(controller.text, 'before\n1. one\n2. two\nafter');
    controller.dispose();
  });

  testWidgets('composer preview keeps source and keyboard formatting works',
      (tester) async {
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MarkdownComposer(controller: controller))));
    await tester.tap(find.byType(TextField));
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, '**hello**');
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(
        tester
            .widget<SyntilaMarkdownBody>(find.byType(SyntilaMarkdownBody))
            .data,
        '**hello**');
    await tester.tap(find.text('Write'));
    await tester.pump();
    expect(controller.text, '**hello**');
  });

  testWidgets('smile button opens an emoji popup that inserts at the cursor',
      (tester) async {
    final controller = TextEditingController(text: 'Hi there');
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      chatStyle: true,
      onSend: () {},
    ))));
    await tester.tap(find.byKey(const ValueKey('emoji-picker-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-picker')), findsOneWidget);
    expect(find.text('😀'), findsOneWidget);

    await tester.tap(find.byTooltip('Hearts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🔥'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Hi🔥 there');
    expect(controller.selection.baseOffset, 2 + '🔥'.length);
    expect(find.byKey(const ValueKey('emoji-picker')), findsNothing);
  });

  testWidgets('two-row layout puts emoji and Markdown popup under the input',
      (tester) async {
    final controller = TextEditingController(text: 'word');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    var sent = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: controller,
      chatStyle: true,
      twoRowLayout: true,
      onSend: () => sent++,
    ))));
    final input = tester.getRect(find.byType(TextField));
    final emoji =
        tester.getRect(find.byKey(const ValueKey('emoji-picker-button')));
    final markdown = tester.getRect(find.byTooltip('Show Markdown controls'));
    final send = tester
        .getRect(find.byKey(const ValueKey('composer-send-Send message')));
    for (final control in [emoji, markdown, send]) {
      expect(control.top, greaterThanOrEqualTo(input.bottom));
    }
    expect(emoji.left, lessThan(markdown.left));
    expect(send.left, greaterThan(markdown.right));
    expect(find.byTooltip('Bold'), findsNothing);

    await tester.tap(find.byTooltip('Show Markdown controls'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('markdown-controls-popup')), findsOneWidget);
    await tester.tap(find.byTooltip('Bold'));
    await tester.pumpAndSettle();
    expect(controller.text, '**word**');
    expect(find.byKey(const ValueKey('markdown-controls-popup')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    expect(sent, 1);
  });

  testWidgets('message and execution rows share composer geometry',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> show(bool execution) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 600,
                  child: MarkdownComposer(
                    controller: controller,
                    chatStyle: true,
                    twoRowLayout: true,
                    maxLines: 6,
                    showEmojiPicker: !execution,
                    showMarkdownControls: !execution,
                    executionControlsBuilder: execution
                        ? (_) =>
                            const SizedBox(height: 32, child: Text('Execution'))
                        : null,
                    onSend: () {},
                  ))),
        ));
    await show(false);
    final message = tester.getRect(find.byType(MarkdownComposer));
    final send = tester
        .getRect(find.byKey(const ValueKey('composer-send-Send message')));
    await show(true);
    expect(tester.getRect(find.byType(MarkdownComposer)), message);
    expect(
        tester
            .getRect(find.byKey(const ValueKey('composer-send-Send message'))),
        send);
    expect(find.text('Execution'), findsOneWidget);
    expect(find.byKey(const ValueKey('emoji-picker-button')), findsNothing);
  });

  testWidgets(
      '32 pixel mode rail stays anchored to the bottom as multiline input grows',
      (tester) async {
    final controller = TextEditingController(text: 'one line');
    addTearDown(controller.dispose);
    const railKey = ValueKey('test-mode-rail');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 600,
      child: MarkdownComposer(
        controller: controller,
        chatStyle: true,
        twoRowLayout: true,
        maxLines: 6,
        leadingControls: const SizedBox(key: railKey, height: 64),
        onSend: () {},
      ),
    ))));
    void expectAnchoredBottom() {
      final slot =
          tester.getRect(find.byKey(const ValueKey('composer-leading-rail')));
      final rail = tester.getRect(find.byKey(railKey));
      final composer = tester.getRect(find.byType(MarkdownComposer));
      expect(slot.width, 32);
      expect(slot.left, composer.left + 4);
      expect(rail.center.dx, closeTo(slot.center.dx, 0.01));
      expect(rail.bottom, composer.bottom - 8);
      final strip = tester.getRect(
          find.byKey(const ValueKey('composer-leading-rail-background')));
      expect(strip.left, composer.left);
      expect(strip.width, 40);
      expect(strip.top, composer.top);
      expect(strip.bottom, composer.bottom);
      expect(slot.center.dx, closeTo(strip.center.dx, 0.01));
      expect(
          tester
              .widget<ColoredBox>(find.descendant(
                  of: find.byKey(
                      const ValueKey('composer-leading-rail-background')),
                  matching: find.byType(ColoredBox)))
              .color,
          SyntilaColors.composerRailLight);
    }

    expectAnchoredBottom();
    final initialHeight = tester.getSize(find.byType(MarkdownComposer)).height;
    await tester.enterText(find.byType(TextField), 'one\ntwo\nthree\nfour');
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MarkdownComposer)).height,
        greaterThan(initialHeight));
    expectAnchoredBottom();
  });

  testWidgets('Thread grip resizes the input and reset restores its height',
      (tester) async {
    final controller = TextEditingController();
    final height = ComposerInputHeight();
    addTearDown(controller.dispose);
    addTearDown(height.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SizedBox(
              width: 600,
              child: StatefulBuilder(
                builder: (context, rebuild) => MarkdownComposer(
                  controller: controller,
                  chatStyle: true,
                  twoRowLayout: true,
                  inputHeight: height,
                  onSend: () => rebuild(() {
                    height.resetManual();
                    controller.clear();
                  }),
                ),
              ))),
    ));
    await tester.pumpAndSettle();
    final initial = tester.getSize(find.byType(TextField)).height;
    await tester.drag(find.byKey(const ValueKey('composer-resize-grip')),
        const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TextField)).height, greaterThan(initial));
    await tester.enterText(find.byType(TextField), 'Hello');
    await tester.tap(find.byKey(const ValueKey('composer-send-Send message')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TextField)).height, initial);
  });

  testWidgets(
      'shared Thread input height survives mode switches without hover hints',
      (tester) async {
    final message = TextEditingController(text: 'one\ntwo\nthree\nfour');
    final request = TextEditingController();
    final height = ComposerInputHeight();
    addTearDown(message.dispose);
    addTearDown(request.dispose);
    addTearDown(height.dispose);
    Future<void> show(TextEditingController controller, String tooltip) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 600,
        child: MarkdownComposer(
          controller: controller,
          chatStyle: true,
          twoRowLayout: true,
          inputHeight: height,
          showControlTooltips: false,
          sendTooltip: tooltip,
          onSend: () {},
        ),
      ))));
      await tester.pumpAndSettle();
    }

    await show(message, 'Send message');
    final expanded = tester.getSize(find.byType(MarkdownComposer)).height;
    await show(request, 'Send request');
    expect(tester.getSize(find.byType(MarkdownComposer)).height, expanded);
    expect(find.byType(TextField), findsOneWidget);
    expect(request.text, isEmpty);
    expect(
        tester
            .widget<TooltipVisibility>(find.descendant(
                of: find.byType(MarkdownComposer),
                matching: find.byType(TooltipVisibility)))
            .visible,
        isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester
        .getCenter(find.byKey(const ValueKey('composer-send-Send request'))));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Send request'), findsNothing);
    await mouse.removePointer();
    await show(message, 'Send message');
    expect(tester.getSize(find.byType(MarkdownComposer)).height, expanded);
    expect(message.text, 'one\ntwo\nthree\nfour');
  });

  testWidgets('two-row controls keep one height at desktop (compact) density',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<double> composerHeight({Widget? leading, Widget? execution}) async {
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Scaffold(
              body: SizedBox(
            width: 600,
            child: MarkdownComposer(
              controller: controller,
              chatStyle: true,
              twoRowLayout: true,
              showEmojiPicker: false,
              showMarkdownControls: false,
              showDictation: false,
              toolbarLeadingControls: leading,
              executionControlsBuilder:
                  execution == null ? null : (_) => execution,
            ),
          ))));
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(MarkdownComposer)).height;
    }

    // Message: IconButton (48 -> 40 compact). Ask AI: selector (40 -> 32).
    final message = await composerHeight(
        leading: IconButton(onPressed: () {}, icon: const Icon(Icons.add)));
    final askAi = await composerHeight(
        execution: const ModelEffortSelector(
            compact: true,
            catalog: ExecutionSelectionCatalog([]),
            value: ExecutionSelection()));
    expect(askAi, message);
  });

  testWidgets(
      'shared input height shrinks when either input is sent or cleared',
      (tester) async {
    final message = TextEditingController();
    final request = TextEditingController();
    final height = ComposerInputHeight();
    addTearDown(message.dispose);
    addTearDown(request.dispose);
    addTearDown(height.dispose);
    Future<double> show(TextEditingController controller) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 600,
        child: MarkdownComposer(
          key: ValueKey(controller),
          controller: controller,
          chatStyle: true,
          twoRowLayout: true,
          maxLines: 6,
          inputHeight: height,
          onSend: () {},
        ),
      ))));
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(MarkdownComposer)).height;
    }

    final single = await show(request);
    await show(message);
    await tester.enterText(find.byType(TextField), 'one\ntwo\nthree\nfour');
    await tester.pumpAndSettle();
    final tall = tester.getSize(find.byType(MarkdownComposer)).height;
    expect(tall, greaterThan(single));

    // Switching keeps the taller Message height for the empty request.
    expect(await show(request), tall);

    // Message is sent (cleared) while hidden: request shrinks to its own size.
    message.clear();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MarkdownComposer)).height, single);

    // A two-line request now drives the height; clearing it shrinks again.
    await tester.enterText(find.byType(TextField), 'a\nb');
    await tester.pumpAndSettle();
    final twoLines = tester.getSize(find.byType(MarkdownComposer)).height;
    expect(twoLines, greaterThan(single));
    expect(await show(message), twoLines);
    await show(request);
    request.clear();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MarkdownComposer)).height, single);
    expect(await show(message), single);
  });

  testWidgets('emoji picker can be hidden', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MarkdownComposer(
      controller: TextEditingController(),
      chatStyle: true,
      showEmojiPicker: false,
      onSend: () {},
    ))));
    expect(find.byKey(const ValueKey('emoji-picker-button')), findsNothing);
  });
}
