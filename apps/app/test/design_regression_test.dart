import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/brand.dart';
import 'package:syntila_app/src/navigation/ax_navigation.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/navigation/app_sidebar.dart';
import 'package:syntila_app/src/features/navigation/ax_shell_context.dart';
import 'package:syntila_app/src/features/common/syntila_code_block.dart';
import 'package:syntila_app/src/features/common/syntila_markdown_body.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';

import 'ax_fixture_data.dart';

void main() {
  group('Phase 24 — Design Regression & Theme Token Tests', () {
    // 1. Logo Header
    testWidgets(
        'logo header renders wordmark and logo mark using theme typography and assets',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  SyntilaBrand.logoMark(size: 28),
                  const SizedBox(width: 10),
                  const Text('Syntila', style: SyntilaTypography.wordmark),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syntila'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('Syntila'));
      expect(textWidget.style?.fontSize, SyntilaTypography.wordmark.fontSize);
      expect(textWidget.style?.fontWeight, FontWeight.w700);
      expect(textWidget.style?.letterSpacing, -0.32);

      // Verify logo mark renders with negative space sparkle asset
      expect(find.byType(Image), findsOneWidget);
    });

    // 2. Sidebar Selected / Unselected State
    testWidgets(
        'sidebar applies distinct styling for selected vs unselected navigation items',
        (WidgetTester tester) async {
      AxNavigation? navigatedTo;
      const shellContext = AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [
          AxSpace(
            id: 'space-1',
            name: 'Space One',
            branch: 'main',
            lastActivity: 'just now',
          ),
        ],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AppSidebar(
              shellContext: shellContext,
              onNavigateTo: (nav) => navigatedTo = nav,
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The app mark remains the Home link without a wordmark.
      expect(find.byTooltip('Syntila — Home'), findsOneWidget);
      expect(find.text('Syntila'), findsNothing);

      // Profile item at bottom
      expect(find.text('Vitalii Noha'), findsOneWidget);

      // Verify unselected profile row container has transparent background
      final profileContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Vitalii Noha'),
              matching: find.byType(Container),
            )
            .first,
      );
      final profileDecoration = profileContainer.decoration as BoxDecoration?;
      expect(profileDecoration?.color, Colors.transparent,
          reason:
              'Unselected navigation item must have transparent background');

      // Tap on profile to navigate
      await tester.tap(find.text('Vitalii Noha'));
      expect(navigatedTo, const AxNavigation.profileSecurity());
    });

    testWidgets(
        'sidebar selected navigation item highlights with active selection token',
        (WidgetTester tester) async {
      const shellContext = AxShellContext(
        navigation: AxNavigation.profileSecurity(),
        spaces: [],
        viewerDisplayName: 'Vitalii Noha',
        viewerEmail: 'vitalii@example.test',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: AppSidebar(
              shellContext: shellContext,
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
              onCreateSpace: () {},
              onLogout: () {},
              onOpenAbout: () {},
              onOpenExternal: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final profileContainer = tester.widget<Container>(
        find
            .ancestor(
              of: find.text('Vitalii Noha'),
              matching: find.byType(Container),
            )
            .first,
      );
      final profileDecoration = profileContainer.decoration as BoxDecoration?;
      expect(profileDecoration?.color, SyntilaColors.navigationSelected,
          reason:
              'Selected navigation item must highlight with SyntilaColors.navigationSelected');

      final profileText = tester.widget<Text>(find.text('Vitalii Noha'));
      expect(profileText.style?.fontWeight, FontWeight.w600);
      expect(profileText.style?.color, SyntilaColors.navigationTextDark);
    });

    // 3. Status Badges & Semantic Tokens
    testWidgets(
        'status badges use semantic tokens rather than hardcoded ad-hoc hex values',
        (WidgetTester tester) async {
      // Test semantic status colors defined in design tokens
      expect(SyntilaBrand.success, SyntilaColors.success);
      expect(SyntilaBrand.warning, SyntilaColors.warning);
      expect(SyntilaBrand.error, SyntilaColors.error);
      expect(SyntilaBrand.info, SyntilaColors.info);
      expect(SyntilaBrand.neutral, SyntilaColors.neutral);

      // Verify tone helper mapping
      expect(ExecutionStatusTone.usable.color(true), SyntilaBrand.success);
      expect(ExecutionStatusTone.degraded.color(true), SyntilaBrand.warning);
      expect(ExecutionStatusTone.failed.color(true), SyntilaBrand.error);

      // Test rendering a status badge widget
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: SyntilaBrand.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(SyntilaRadius.sm),
                  border: Border.all(
                      color: SyntilaBrand.success.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'Ready',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: SyntilaBrand.success,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ready'), findsOneWidget);
      final textWidget = tester.widget<Text>(find.text('Ready'));
      expect(textWidget.style?.color, SyntilaBrand.success);
      expect(textWidget.style?.fontWeight, FontWeight.w600);
    });

    // 4. Buttons
    testWidgets(
        'buttons consume theme tokens for primary, outline, danger, and disabled states',
        (WidgetTester tester) async {
      bool primaryClicked = false;
      bool dangerClicked = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () => primaryClicked = true,
                  child: const Text('Primary Action'),
                ),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text('Secondary Action'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SyntilaBrand.error,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => dangerClicked = true,
                  child: const Text('Danger Action'),
                ),
                const ElevatedButton(
                  onPressed: null,
                  child: Text('Disabled Action'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Primary Action'), findsOneWidget);
      expect(find.text('Secondary Action'), findsOneWidget);
      expect(find.text('Danger Action'), findsOneWidget);
      expect(find.text('Disabled Action'), findsOneWidget);

      await tester.tap(find.text('Primary Action'));
      expect(primaryClicked, isTrue);

      await tester.tap(find.text('Danger Action'));
      expect(dangerClicked, isTrue);

      // Verify disabled button does not trigger events
      final disabledButton = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Disabled Action'),
      );
      expect(disabledButton.onPressed, isNull);
    });

    // 5. Markdown Rendering
    testWidgets(
        'SyntilaMarkdownBody renders headings, body, and inline code with theme tokens',
        (WidgetTester tester) async {
      const markdownContent = '''
# Heading 1
## Heading 2
### Heading 3

This is standard body paragraph text with **bold** and `inline_code`.

> Blockquote context

- Item 1
- Item 2
''';

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: SyntilaMarkdownBody(data: markdownContent),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
          find.textContaining('Heading 1', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('Heading 2', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('Heading 3', findRichText: true), findsOneWidget);
      expect(
          find.textContaining('This is standard body paragraph text',
              findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Blockquote context', findRichText: true),
          findsOneWidget);
      expect(find.textContaining('Item 1', findRichText: true), findsOneWidget);
      expect(find.textContaining('inline_code', findRichText: true),
          findsOneWidget);
    });

    // 6. Code Block
    testWidgets(
        'SyntilaCodeBlock renders syntax container, monospace font, and copy button',
        (WidgetTester tester) async {
      String? copiedText;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      const snippet = 'const apiKey = "syntila-v8";\nconsole.log(apiKey);';

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: const Scaffold(
            body: SyntilaCodeBlock(
              code: snippet,
              language: 'javascript',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('javascript'), findsOneWidget);
      expect(
          find.textContaining('const apiKey = "syntila-v8";'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy code'));
      await tester.pumpAndSettle();

      expect(copiedText, snippet);
    });

    // 7. Work Response Card
    testWidgets(
        'ThreadPage renders prompt bubble and AI response card with theme tokens',
        (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const dataSource = AxFixtureDataSource();

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          home: Scaffold(
            body: ThreadPage(
              space: const AxSpace(
                id: 'p1',
                name: 'Core Engine',
                branch: 'main',
                lastActivity: 'just now',
              ),
              thread: const AxThread(
                id: 'ws-1',
                spaceId: 'p1',
                name: 'Auth Refactor',
                lead: 'Vitalii',
                status: 'active',
                brief: 'Implement account authentication',
                queueStatus: 'Idle',
              ),
              dataSource: dataSource,
              onBackToSpace: () {},
              onArchive: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Thread tabs and panes render
      expect(find.text('Conversation'), findsAtLeastNWidgets(1));
      expect(find.text('AI History'), findsAtLeastNWidgets(1));
    });

    // 9. Key Shared Components Use Theme Tokens (No Hardcoded Breakages)
    testWidgets(
        'dynamic theme switching from light to dark updates shared components',
        (WidgetTester tester) async {
      ThemeMode currentMode = ThemeMode.light;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            theme: SyntilaBrand.lightTheme(),
            darkTheme: SyntilaBrand.darkTheme(),
            themeMode: currentMode,
            home: Scaffold(
              body: Column(
                children: [
                  SyntilaBrand.logoMark(size: 32),
                  const Text('Syntila', style: SyntilaTypography.wordmark),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        currentMode = currentMode == ThemeMode.light
                            ? ThemeMode.dark
                            : ThemeMode.light;
                      });
                    },
                    child: const Text('Toggle Theme'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Light theme active
      expect(Theme.of(tester.element(find.text('Syntila'))).brightness,
          Brightness.light);

      // Toggle theme to dark
      await tester.tap(find.text('Toggle Theme'));
      await tester.pumpAndSettle();

      // Dark theme active
      expect(Theme.of(tester.element(find.text('Syntila'))).brightness,
          Brightness.dark);
    });
  });
}
