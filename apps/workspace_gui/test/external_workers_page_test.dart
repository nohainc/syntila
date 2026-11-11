import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_workspace_gui/src/external_workers_page.dart';

class _Runner implements CliRunner {
  _Runner(this.respond);

  final CliResult Function(List<String> args) respond;
  final calls = <List<String>>[];

  List<String> get lines => [for (final c in calls) c.join(' ')];

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
  Object stdout, [
  String stderr = '',
]) => CliResult(
  args: args,
  exitCode: code,
  stdout: stdout is String ? stdout : jsonEncode(stdout),
  stderr: stderr,
  duration: Duration.zero,
);

Map<String, Object?> _worker({
  bool inspected = false,
  bool registered = false,
  bool enabled = false,
}) => {
  'pluginId': 'ollama-mcp',
  'displayName': 'Ollama (MCP Worker)',
  'versions': [
    {
      'version': '1.0.0',
      'registered': registered,
      if (inspected) 'conformance': {'passed': true},
    },
  ],
  if (enabled) 'workspace': {'effective': 'enabled', 'pinnedVersion': '1.0.0'},
};

const _consent = {
  'schemaVersion': 1,
  'consentRequired': true,
  'documentHash': 'h1',
  'document': {
    'plugin': {
      'id': 'ollama-mcp',
      'version': '1.0.0',
      'displayName': 'Ollama (MCP Worker)',
      'author': 'Syntila',
    },
    'digest': {'manifest': 'm', 'artifact': 'a', 'platform': 'darwin-arm64'},
    'signature': {'status': 'unsigned'},
    'requestedAccess': {'subprocess': false, 'note': 'Not enforced.'},
    'mcp': {
      'tools': [
        {'name': 'syntila.execute', 'description': 'Runs a prompt'},
      ],
    },
    'statement': 'Runs as you.',
  },
};

Future<void> _pump(WidgetTester tester, CliRunner runner) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ExternalWorkersPage(runner: runner)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('imports a package and offers the next step', (tester) async {
    var imported = false;
    final runner = _Runner((args) {
      if (args.first == 'workers' && args[1] == 'import') {
        imported = true;
        return _result(args, 0, {'pluginId': 'ollama-mcp', 'version': '1.0.0'});
      }
      return _result(args, 0, {
        'plugins': [if (imported) _worker()],
      });
    });
    await _pump(tester, runner);
    expect(find.text('No External Workers yet.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('external-worker-path')),
      '/tmp/pkg',
    );
    await tester.tap(find.byKey(const Key('external-worker-import')));
    await tester.pumpAndSettle();

    expect(runner.lines, contains('workers import /tmp/pkg --json'));
    expect(find.textContaining('Imported ollama-mcp 1.0.0'), findsOneWidget);
    expect(find.text('Ollama (MCP Worker)'), findsOneWidget);
    expect(find.textContaining('Imported'), findsWidgets);
    expect(find.text('Inspect'), findsOneWidget);
    expect(find.text('Register'), findsNothing);
  });

  testWidgets('enable shows the consent document and accepts it', (
    tester,
  ) async {
    var enabled = false;
    final runner = _Runner((args) {
      if (args[1] == 'enable') {
        if (!args.contains('--accept')) return _result(args, 3, _consent);
        enabled = true;
        return _result(args, 0, {'enabled': true, 'pluginRef': 'plugin-abc'});
      }
      return _result(args, 0, {
        'plugins': [
          _worker(inspected: true, registered: true, enabled: enabled),
        ],
      });
    });
    await _pump(tester, runner);

    await tester.tap(find.text('Enable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Review before you enable'), findsOneWidget);
    expect(find.text('syntila.execute: Runs a prompt'), findsOneWidget);

    await tester.tap(find.byKey(const Key('external-worker-accept')));
    await tester.pumpAndSettle();

    expect(
      runner.lines,
      contains('workers enable ollama-mcp --accept h1 --json'),
    );
    expect(find.textContaining('Enabled ollama-mcp'), findsOneWidget);
    expect(find.text('Disable'), findsOneWidget);
  });

  testWidgets('cancelling consent changes nothing', (tester) async {
    final runner = _Runner((args) {
      if (args[1] == 'register') return _result(args, 3, _consent);
      return _result(args, 0, {
        'plugins': [_worker(inspected: true)],
      });
    });
    await _pump(tester, runner);

    await tester.tap(find.text('Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(runner.calls.where((c) => c.contains('--accept')), isEmpty);
    expect(find.text('Register'), findsOneWidget);
  });

  testWidgets('shows the CLI error when an action fails', (tester) async {
    final runner = _Runner((args) {
      if (args[1] == 'inspect') {
        return _result(
          args,
          1,
          '',
          'syntila: MCP Workers are not available (plugin_mcp_unavailable)',
        );
      }
      return _result(args, 0, {
        'plugins': [_worker()],
      });
    });
    await _pump(tester, runner);

    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('plugin_mcp_unavailable'), findsOneWidget);
  });
}
