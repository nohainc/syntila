import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_app/src/features/common/markdown_composer.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ax_fixture_data.dart';

class _UsageDataSource extends AxFixtureDataSource
    implements AxWorkerUsageDataSource {
  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        AxBuiltinWorkflow.fromJson({
          'id': 'direct',
          'executionPolicy': const {
            'userSelectsWorker': true,
            'userSelectsModel': true,
            'userSelectsEffort': true
          },
          'composerBindingId': 'direct',
          'version': 2,
          'name': 'Work',
          'description': 'Implement the requested work.',
          'steps': [
            {'kind': 'implement', 'order': 0},
          ],
        }),
      ];

  @override
  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async =>
      const AxWorkerUsageReport(status: 'ok', output: 'raw report');
}

class _ReportDataSource extends _UsageDataSource {
  _ReportDataSource(this.output);

  final String output;

  @override
  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  }) async =>
      AxWorkerUsageReport(status: 'ok', output: output);
}

const _copilotUsage = '{"quotaSnapshots": {'
    '"chat": {"entitlementRequests": 200, "usedRequests": 2},'
    '"completions": {"entitlementRequests": 2000, "usedRequests": 0}}}';
const _claudeUsage = 'Current session: 6% used\n'
    'Current week (all models): 21% used\n';

void main() {
  testWidgets('usage label column fits the widest label of each report',
      (tester) async {
    Future<double> labelWidth(String output) async {
      final controller = AxWorkerUsageController(_ReportDataSource(output));
      addTearDown(controller.dispose);
      await controller.load(
          workspaceId: 'workspace-1', workerId: 'worker-1', workerName: 'W');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            child: AxWorkerUsagePanel(controller: controller, onRefresh: () {}),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final labels = find.byKey(const ValueKey('worker-usage-label'));
      expect(labels, findsNWidgets(2));
      final widths = {
        for (var i = 0; i < 2; i++) tester.getSize(labels.at(i)).width,
      };
      expect(widths, hasLength(1), reason: 'rows stay aligned');
      return widths.single;
    }

    final copilot = await labelWidth(_copilotUsage);
    final completions = find.text('Code completions');
    // One line: no wrapped "s" on a second line.
    expect(tester.getSize(completions).height, lessThan(20));
    final claude = await labelWidth(_claudeUsage);
    expect(claude, lessThan(copilot));
    expect(tester.takeException(), isNull);
  });

  test('usage controller shows the provider report unchanged', () async {
    final controller = AxWorkerUsageController(_UsageDataSource());
    await controller.load(
        workspaceId: 'workspace-1', workerId: 'worker-1', workerName: 'Claude');
    expect(controller.visible, isTrue);
    expect(controller.loading, isFalse);
    expect(controller.report!.displayText, 'raw report');
    controller.dismiss();
    expect(controller.visible, isFalse);
  });

  test('API client returns the raw report and maps access failures', () async {
    Future<AxWorkerUsageReport> read(http.Response response) {
      final client = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path,
              '/api/workspaces/workspace-1/workers/worker-1/usage');
          return response;
        }),
      );
      return client.readWorkerUsage(
          workspaceId: 'workspace-1', workerId: 'worker-1');
    }

    final ok = await read(http.Response(
        jsonEncode({
          'status': 'ok',
          'output': 'Current session: 6% used\n',
          'errorOutput': '',
          'exitCode': 0,
          'truncated': false,
          'fetchedAt': '2026-10-16T10:00:00.000Z',
        }),
        200));
    expect(ok.isOk, isTrue);
    expect(ok.output, 'Current session: 6% used\n');

    final unavailable = await read(http.Response(
        jsonEncode(
            {'status': 'unavailable', 'errorCode': 'usage_not_configured'}),
        200));
    expect(unavailable.status, 'unavailable');

    final denied = await read(
        http.Response(jsonEncode({'error': 'Workspace not found'}), 404));
    expect(denied.status, 'error');
    expect(denied.errorMessage, contains('Workspace owner'));
  });

  testWidgets('typing / lists commands and /usage asks for a Worker',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 700,
          child: ThreadPage(
            space: const AxSpace(
              id: 'space-1',
              name: 'Space One',
              branch: '',
              lastActivity: 'today',
              role: 'collaborator',
            ),
            thread: const AxThread(
              id: 'thread-1',
              spaceId: 'space-1',
              name: 'Implementation',
              lead: 'Owner',
              status: 'active',
              brief: 'Implement the requested change.',
              primaryWorkspace: 'Workspace One',
              queueStatus: 'Idle',
              canExecuteWork: true,
            ),
            dataSource: _UsageDataSource(),
            onBackToSpace: () {},
            onArchive: () {},
            initialTab: 1,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('slash-command-palette')), findsNothing);
    await tester.enterText(find.byType(TextField).last, '/');
    await tester.pump();
    expect(find.byKey(const ValueKey('slash-command-usage')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('slash-command-usage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-usage-panel')), findsOneWidget);
    expect(find.text('Choose a Worker to read its usage.'), findsOneWidget);

    for (final width in [900.0, 390.0]) {
      await tester.binding.setSurfaceSize(Size(width, 1200));
      await tester.pumpAndSettle();
      final layer = tester
          .getRect(find.byKey(const ValueKey('worker-usage-layer-background')));
      final input = tester.getRect(find.byType(MarkdownComposer));
      expect(layer.left, input.left);
      expect(layer.right, input.right);
      expect(layer.bottom, input.top + 10);
      expect(find.byTooltip('Refresh usage').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Close usage'), findsNothing);
      expect(tester.takeException(), isNull);
    }

    // Keyboard focus changes alone do not dismiss the report.
    final panel =
        tester.widget<AxWorkerUsagePanel>(find.byType(AxWorkerUsagePanel));
    await tester.showKeyboard(find.byType(TextField).last);
    await tester.pumpAndSettle();
    expect(panel.controller.visible, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('worker-usage-panel')), findsNothing);

    panel.controller.showMessage('Usage reopened');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh usage'));
    await tester.pumpAndSettle();
    expect(panel.controller.visible, isTrue);
    await tester.tap(find.byKey(const ValueKey('work-add-attachments')));
    await tester.pumpAndSettle();
    expect(panel.controller.visible, isFalse);
    expect(find.byKey(const ValueKey('work-menu-usage')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('usage attached variant preserves standalone card $brightness',
        (tester) async {
      final controller = AxWorkerUsageController(_UsageDataSource());
      addTearDown(controller.dispose);
      controller.showMessage(List.filled(80, 'Long usage report').join('\n'));
      Future<void> show(bool attached) => tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: Column(children: [
                AxWorkerUsagePanel(
                  controller: controller,
                  onRefresh: () {},
                  attached: attached,
                ),
              ]),
            ),
          ));
      await show(true);
      await tester.pumpAndSettle();
      final background =
          find.byKey(const ValueKey('worker-usage-layer-background'));
      expect(tester.getSize(background).height, lessThanOrEqualTo(250));
      expect(
          (tester.widget<DecoratedBox>(background).decoration as BoxDecoration)
              .color,
          SyntilaColors.composerBackground(brightness == Brightness.dark));
      expect(find.byTooltip('Close usage'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.dragFrom(
          tester.getTopLeft(background) + const Offset(40, 180),
          const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(controller.visible, isTrue);
      expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          greaterThan(0));

      // The default used by the Workspace dialog retains its card and margin.
      controller.showMessage('Standalone report');
      await show(false);
      await tester.pumpAndSettle();
      expect(background, findsNothing);
      final panel = tester
          .widget<Container>(find.byKey(const ValueKey('worker-usage-panel')));
      final context = tester.element(find.byType(AxWorkerUsagePanel));
      expect((panel.decoration as BoxDecoration).color,
          Theme.of(context).colorScheme.surfaceContainerHighest);
      expect(panel.margin, const EdgeInsets.only(bottom: 8));
      await tester.tap(find.byTooltip('Close usage'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('worker-usage-panel')), findsNothing);
    });
  }
}
