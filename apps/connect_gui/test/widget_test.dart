import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_connect_gui/main.dart';
import 'package:syntila_connect_gui/src/status_page.dart';

/// Answers every command except `status` only when [release] is called, so a
/// test can look at the page while an action is still running.
class _SlowRunner extends _Runner {
  _SlowRunner(super.respond);

  final _pending = Completer<void>();
  void release() => _pending.complete();

  @override
  CliRun start(List<String> args) {
    if (args.first == 'status') return super.start(args);
    calls.add(args);
    return CliRun(_pending.future.then((_) => respond(args)), () {});
  }
}

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
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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

  testWidgets('full access is off by default and is turned on only after a warning', (
    tester,
  ) async {
    var on = false;
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
                'running': true,
                'connection': 'ready',
                'service': 'running',
                'autoStart': false,
                'fullAccess': on,
              },
            ],
          }),
        );
      }
      if (args.first == 'full-access') on = args[1] == 'on';
      return _result(args, 0, 'ok');
    });
    await _pump(tester, runner);
    await tester.pump();

    final toggle = find.byKey(const ValueKey('status-full-access-wrk-123'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Allow full access?'), findsOneWidget);
    expect(runner.calls.where((c) => c.first == 'full-access'), isEmpty);

    await tester.tap(find.byKey(const Key('worker-full-access-confirm')));
    await tester.pumpAndSettle();
    expect(runner.calls.last, ['status', '--json']);
    expect(
      runner.calls.where((c) => c.first == 'full-access').single,
      ['full-access', 'on', '--worker', 'wrk-123'],
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

    // Turning it off needs no warning.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Allow full access?'), findsNothing);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
  });

  testWidgets('Workers are listed by name', (tester) async {
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, Object?> worker(String id, String name) => {
      'workerId': id,
      'workerName': name,
      'server': 'https://cloud.syntila.io',
      'registration': 'paired',
      'running': false,
      'connection': 'stopped',
      'service': 'stopped',
      'autoStart': false,
    };
    final runner = _Runner(
      (args) => _result(
        args,
        0,
        jsonEncode({
          'workers': [
            worker('wrk-1', 'gemini'),
            worker('wrk-2', 'Codex'),
            worker('wrk-3', 'Claude'),
          ],
        }),
      ),
    );
    await _pump(tester, runner);
    await tester.pump();
    double top(String name) => tester.getTopLeft(find.text(name).first).dy;
    expect(top('Claude'), lessThan(top('Codex')));
    expect(top('Codex'), lessThan(top('gemini')));
  });

  testWidgets('clicking a button does not move the page', (tester) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, Object?> worker(String id, String name) => {
      'workerId': id,
      'workerName': name,
      'server': 'https://cloud.syntila.io',
      'registration': 'paired',
      'running': true,
      'connection': 'ready',
      'service': 'running',
      'autoStart': false,
    };
    final runner = _SlowRunner((args) {
      if (args.first == 'status') {
        return _result(
          args,
          0,
          jsonEncode({
            'workers': [worker('wrk-1', 'A'), worker('wrk-2', 'B'), worker('wrk-3', 'C')],
          }),
        );
      }
      return _result(args, 1, '', 'something went wrong');
    });
    await _pump(tester, runner);
    await tester.pump();

    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    // Scroll down, then press a button that is on screen.
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent / 2);
    await tester.pump();
    final before = scrollable.position.pixels;
    expect(before, greaterThan(0));
    final refreshButtons = find.byKey(const Key('worker-models-refresh'));
    var index = -1;
    for (var i = 0; i < refreshButtons.evaluate().length; i++) {
      final y = tester.getCenter(refreshButtons.at(i)).dy;
      if (y > 80 && y < 520) index = i;
    }
    expect(index, isNonNegative);
    // The same button again after the page rebuilds (found by key and place).
    Finder restartFinder() => find.byKey(const Key('worker-models-refresh')).at(index);
    final restart = restartFinder();
    final yBefore = tester.getCenter(restart).dy;
    await tester.tap(restart);
    await tester.pump();
    // While the action runs, a notice shows and the content has not moved.
    expect(find.textContaining('Reading models'), findsOneWidget);
    expect(tester.getCenter(restartFinder()).dy, yBefore);
    runner.release();
    await tester.pump();
    await tester.pump();
    expect(find.text('something went wrong'), findsOneWidget);
    // The message appears over the page; the content stays where it was.
    expect(tester.getCenter(restartFinder()).dy, yBefore);
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, before);
    expect(tester.getCenter(restartFinder()).dy, yBefore);
  });

  testWidgets('a models error can be copied', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final runner = _Runner((args) {
      return _result(
        args,
        0,
        jsonEncode({
          'workers': [
            {
              'workerId': 'wrk-123',
              'workerName': 'Claude',
              'server': 'https://cloud.syntila.io',
              'registration': 'paired',
              'running': true,
              'connection': 'ready',
              'service': 'running',
              'autoStart': false,
              'models': {
                'status': 'provider_failure',
                'message': 'Claude model list failed: HTTP 429 rate limited',
              },
            },
          ],
        }),
      );
    });
    await _pump(tester, runner);
    await tester.pump();

    final copy = find.byKey(const Key('worker-models-error-copy'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pump();
    // The provider's own message is shown and copied, not just a code.
    expect(
      copied,
      'Could not read models: Claude model list failed: HTTP 429 rate limited',
    );
  });

  testWidgets('shows empty state when no Workers are paired', (tester) async {
    final runner = _Runner(
      (args) => _result(args, 0, jsonEncode({'workers': const <Object>[]})),
    );
    await _pump(tester, runner);
    expect(find.text('No Workers on this computer yet'), findsOneWidget);
  });
}
