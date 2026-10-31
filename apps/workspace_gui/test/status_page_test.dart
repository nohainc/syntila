import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_workspace_gui/src/status_page.dart';

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
  testWidgets('shows cards and connects', (tester) async {
    var connected = false;
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
                  'acceptingNewWork': true,
                },
                'service': {'serviceHealthy': true},
                'assignments': {'activeCount': 2},
                'workers': [{}, {}, {}],
                'config': {'state': 'valid'},
              })
            : '{}',
      ),
    );
    await _pump(tester, runner);

    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('3 configured'), findsOneWidget);
    expect(find.text('2 running'), findsOneWidget);
    expect(find.text('Config: valid'), findsOneWidget);

    connected = true;
    await tester.tap(find.text('Connect'));
    await tester.pump();
    await tester.pump();
    expect(runner.calls, [
      ['status', '--json'],
      ['connect', '--json'],
      ['status', '--json'],
    ]);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
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
