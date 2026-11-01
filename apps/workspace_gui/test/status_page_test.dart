import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_workspace_gui/src/status_page.dart';
import 'package:syntila_workspace_gui/main.dart' show WorkspaceHeader;

class _Runner implements CliRunner {
  _Runner(this.respond);

  final CliResult Function(List<String> args) respond;
  final calls = <List<String>>[];

  @override
  String get executable => 'syntila';

  @override
  Future<GuiManifestModel> loadManifest() => throw UnimplementedError();

  @override
  CliRun start(List<String> args) {
    calls.add(args);
    return CliRun(Future.value(respond(args)), () {});
  }
}

CliResult _result(
  List<String> args,
  int code,
  String stdout, [
  String stderr = '',
]) => CliResult(
  args: args,
  exitCode: code,
  stdout: stdout,
  stderr: stderr,
  duration: Duration.zero,
);

Future<void> _pump(WidgetTester tester, CliRunner runner) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: StatusPage(runner: runner, interval: const Duration(hours: 1)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('header shows the themed logo before the app name', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: WorkspaceHeader()),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byType(Image));
      final asset = image.image as AssetImage;
      expect(
        asset.assetName,
        brightness == Brightness.dark
            ? 'assets/branding/syntila_logo_dark.png'
            : 'assets/branding/syntila_logo.png',
      );
      expect(
        tester.getTopLeft(find.byType(Image)).dx,
        lessThan(tester.getTopLeft(find.text('Syntila Workspace')).dx),
      );
    }
  });

  testWidgets('shows cards and connects', (tester) async {
    var connected = false;
    var accepting = true;
    final runner = _Runner(
      (args) => _result(
        args,
        0,
        args.first == 'status'
            ? jsonEncode({
                'workspace': {'name': 'Mac', 'workRoot': '/w'},
                'cloud': {
                  'connected': connected,
                  'lifecycleState': 'offline',
                  'transport': 'websocket',
                  'acceptingNewWork': accepting,
                },
                'service': {'serviceHealthy': true},
                'assignments': {'activeCount': 2},
                'workers': [
                  {'productWorkerTypeId': 'chatgpt'},
                  {'productWorkerTypeId': 'gemini'},
                  {'productWorkerTypeId': 'chatgpt'},
                ],
                'config': {'state': 'valid'},
              })
            : '{}',
      ),
    );
    await _pump(tester, runner);

    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('chatgpt, gemini'), findsOneWidget);
    expect(find.text('2 running'), findsOneWidget);
    expect(find.text('Config: valid\nWork Root: /w'), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(4));

    final cloudCard = find.ancestor(
      of: find.text('Cloud'),
      matching: find.byType(Card),
    );
    final workCard = find.ancestor(
      of: find.text('Active work'),
      matching: find.byType(Card),
    );
    expect(
      find.descendant(of: cloudCard, matching: find.text('Connect')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: workCard, matching: find.text('Pause new work')),
      findsOneWidget,
    );
    accepting = false;
    await tester.tap(find.text('Pause new work'));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(of: workCard, matching: find.text('Resume new work')),
      findsOneWidget,
    );
    expect(runner.calls, [
      ['status', '--json'],
      ['pause', '--json'],
      ['status', '--json'],
    ]);
    runner.calls.clear();
    connected = true;
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    expect(runner.calls, [
      ['connect', '--json'],
      ['status', '--json'],
    ]);
    expect(find.text('Connected'), findsOneWidget);
    expect(
      find.descendant(of: cloudCard, matching: find.text('Disconnect')),
      findsOneWidget,
    );
    await tester.tap(find.text('Resume new work'));
    await tester.pump();
    await tester.pump();
    expect(runner.calls[2], ['resume', '--json']);
  });

  testWidgets('cards use one or two columns within the content width', (
    tester,
  ) async {
    final runner = _Runner(
      (args) => _result(
        args,
        0,
        jsonEncode({
          'workspace': {'name': 'Mac'},
          'cloud': {},
          'service': {},
          'assignments': {},
          'workers': [],
          'config': {},
        }),
      ),
    );
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final width in [400.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 1200);
      await _pump(tester, runner);
      expect(find.text('No workers configured'), findsOneWidget);
      final cards = find.byType(Card);
      final first = tester.getRect(cards.at(0));
      final second = tester.getRect(cards.at(1));
      if (width == 400) {
        expect(second.top, greaterThan(first.top));
        expect(first.left, closeTo(second.left, 1));
      } else {
        expect(second.top, first.top);
        expect(second.size, first.size);
        expect(tester.getSize(cards.at(2)), first.size);
        expect(tester.getSize(cards.at(3)), first.size);
        expect(second.left, greaterThan(first.left));
        expect(second.right - first.left, lessThanOrEqualTo(800));
      }
    }
  });

  testWidgets('offers to start the service when status fails', (tester) async {
    final runner = _Runner(
      (args) => args.first == 'status'
          ? _result(
              args,
              69,
              '',
              'syntila: the Workspace service is not running',
            )
          : _result(args, 0, '{}'),
    );
    await _pump(tester, runner);

    expect(
      find.text('The Workspace service is not available.'),
      findsOneWidget,
    );
    expect(find.textContaining('not running'), findsOneWidget);
    await tester.tap(find.text('Start service'));
    await tester.pump();
    expect(runner.calls[1], ['service', 'start', '--json']);
  });
}
