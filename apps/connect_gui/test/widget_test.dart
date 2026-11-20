import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_connect_gui/main.dart';
import 'package:syntila_connect_gui/src/status_page.dart';

class _Runner implements CliRunner {
  _Runner(this.respond);

  final CliResult Function(List<String> args) respond;
  final calls = <List<String>>[];

  @override
  String get executable => 'syntila-connect';

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
        body: ConnectStatusPage(
          runner: runner,
          interval: const Duration(hours: 1),
        ),
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
          home: const Scaffold(body: ConnectHeader()),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byType(Image)).dx,
        lessThan(tester.getTopLeft(find.text('Syntila Connect')).dx),
      );
    }
  });

  testWidgets(
    'lists multiple Workers with names, copy Worker ID, and per-Worker service start/stop/restart',
    (tester) async {
      var runningA = false;
      var serviceA = 'stopped';
      final runner = _Runner((args) {
        if (args.first == 'status') {
          return _result(
            args,
            0,
            jsonEncode({
              'workers': [
                {
                  'workerId': 'wrk-123',
                  'workerName': 'My Gemini',
                  'workerType': 'gemini',
                  'server': 'https://cloud.syntila.io',
                  'registration': 'paired',
                  'running': runningA,
                  'connection': runningA ? 'ready' : 'stopped',
                  'service': serviceA,
                  'autoStart': false,
                  'journal': {'acknowledged': 3},
                },
                {
                  'workerId': 'wrk-456',
                  'workerName': 'claude',
                  'workerType': 'claude',
                  'server': 'https://cloud.syntila.io',
                  'registration': 'paired',
                  'running': true,
                  'connection': 'ready',
                  'service': 'running',
                  'autoStart': true,
                },
              ],
            }),
          );
        }
        return _result(args, 0, 'ok');
      });

      await _pump(tester, runner);

      expect(find.text('My Gemini'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('wrk-123'), findsOneWidget);
      expect(find.text('wrk-456'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('status-copy-id-wrk-123')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('status-copy-id-wrk-456')),
        findsOneWidget,
      );

      // Start wrk-123
      runningA = true;
      serviceA = 'running';
      await tester.tap(
        find.byKey(const ValueKey('status-service-start-wrk-123')),
      );
      await tester.pump();
      await tester.pump();

      expect(runner.calls, [
        ['status', '--json'],
        ['service', 'start', '--worker', 'wrk-123'],
        ['status', '--json'],
      ]);

      // Stop wrk-123
      runningA = false;
      serviceA = 'stopped';
      await tester.tap(
        find.byKey(const ValueKey('status-service-stop-wrk-123')),
      );
      await tester.pump();
      await tester.pump();

      expect(runner.calls[3], ['service', 'stop', '--worker', 'wrk-123']);

      // Copy Worker ID button shows snackbar
      await tester.tap(find.byKey(const ValueKey('status-copy-id-wrk-123')));
      await tester.pump();
      expect(find.text('Copied Worker ID: wrk-123'), findsOneWidget);
    },
  );

  testWidgets('offers Install service when no service is installed', (
    tester,
  ) async {
    var service = 'notInstalled';
    final runner = _Runner((args) {
      if (args.first == 'status') {
        return _result(
          args,
          0,
          jsonEncode({
            'workers': [
              {
                'workerId': 'wrk-123',
                'workerName': 'Gemini',
                'server': 'https://cloud.syntila.io',
                'registration': 'paired',
                'running': false,
                'connection': 'stopped',
                'service': service,
                'autoStart': false,
              },
            ],
          }),
        );
      }
      return _result(args, 0, 'installed');
    });

    await _pump(tester, runner);

    expect(find.text('Install service'), findsOneWidget);
    service = 'stopped';
    await tester.tap(find.text('Install service'));
    await tester.pump();
    await tester.pump();

    expect(runner.calls[1], ['service', 'install', '--worker', 'wrk-123']);
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('shows empty state when no Workers are paired', (tester) async {
    final runner = _Runner(
      (args) => _result(args, 0, jsonEncode({'workers': const <Object>[]})),
    );
    await _pump(tester, runner);
    expect(find.text('No Workers on this computer yet'), findsOneWidget);
  });
}
