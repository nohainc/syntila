import 'dart:io';

import 'package:gui_manifest/gui_manifest.dart' show validateManifest;
import 'package:nanomarkup/nanomarkup.dart' as nano;
import 'package:syntila_workspace/workspace_cli.dart';
import 'package:test/test.dart';

/// Expected IPC command for each service-backed manifest command.
const _ipc = {
  'status': 'service.getStatus',
  'version': 'service.getVersion',
  'connect': 'connection.connect',
  'disconnect': 'connection.disconnect',
  'pause': 'connection.pause',
  'resume': 'connection.resume',
  'workers.list': 'workers.list',
  'workers.catalog': 'workers.getCatalogSnapshot',
  'workers.add': 'workers.configureWorker',
  'workers.remove': 'workers.removeWorker',
  'workers.check': 'workers.checkReadiness',
  'workers.test': 'workers.testWorker',
  'workers.enable': 'workers.enableWorker',
  'workers.disable': 'workers.disableWorker',
  'folders.list': 'folders.list',
  'slots': 'execution.getSlots',
  'assignments.list': 'execution.listActiveAssignments',
  'assignments.cancel': 'execution.cancelAssignment',
  'logs': 'diagnostics.getLogs',
  'metrics': 'diagnostics.getMetrics',
};

/// Handled locally by the CLI (not routed through IPC); not executed here.
const _local = {
  'setup', 'login', 'logout', 'register', 'unregister', 'folders.add', //
  'folders.remove', 'workDir', 'reset', 'service.status', 'service.install',
  'service.start', 'service.stop', 'service.restart', 'service.uninstall',
  'config.show', 'config.validate', 'config.path', 'config.init',
};

Map<String, Object> _manifest() =>
    WorkspaceCli(out: StringBuffer(), err: StringBuffer()).guiManifestTree();

List<Map<String, Object>> _commands() =>
    (_manifest()['commands'] as List).cast<Map<String, Object>>();

void main() {
  group('--gui-manifest', () {
    Future<(int, String, String)> run(List<String> args) async {
      final out = StringBuffer(), err = StringBuffer();
      final code = await WorkspaceCli(
        out: out,
        err: err,
        request: (_, __) async => throw StateError('must not call service'),
      ).run(args);
      return (code, '$out', '$err');
    }

    test('prints the Nano Markup manifest without the service', () async {
      for (final arg in [
        '--gui-manifest',
        '--gui-manifest=1',
        '--gui-manifest=9'
      ]) {
        final (code, out, err) = await run([arg]);
        expect(code, 0, reason: arg);
        expect(err, isEmpty);
        expect(nano.decode(out), _manifest());
      }
    });

    test('rejects unsupported versions with exit 2', () async {
      for (final arg in ['--gui-manifest=0', '--gui-manifest=x']) {
        final (code, out, err) = await run([arg]);
        expect(code, 2, reason: arg);
        expect(out, isEmpty);
        expect(err, startsWith('syntila: '));
      }
    });

    test('is only recognised as the sole argument', () async {
      for (final args in [
        ['--gui-manifest', 'status'],
        ['--gui-manifestx'],
      ]) {
        final (code, out, _) = await run(args);
        expect(code, 64, reason: args.join(' '));
        expect(out, isEmpty);
      }
    });
  });

  test('the manifest is valid and keeps its order', () {
    expect(validateManifest(_manifest()), isEmpty);
    final ids = _commands().map((c) => c['id']).toList();
    expect(ids.take(3), ['status', 'version', 'setup']);
    final nav = (_manifest()['navigation'] as List).cast<Map>();
    expect(
      nav.map((n) => (n['id'], n['command'])),
      [
        ('status', 'status'),
        ('workers', 'workers.list'),
        ('folders', 'folders.list'),
        ('assignments', 'assignments.list'),
        ('logs', 'logs'),
        ('service', 'service.status'),
      ],
    );
  });

  test('related commands are grouped', () {
    final groups = (_manifest()['groups'] as List).cast<Map>();
    expect(
      groups.map((g) => g['id']),
      ['workers', 'folders', 'assignments', 'service', 'config'],
    );
    final byGroup = <String, List<Object?>>{};
    for (final c in _commands()) {
      final group = c['group'];
      if (group is String) (byGroup[group] ??= []).add(c['id']);
    }
    expect(byGroup['workers'], [
      'workers.list',
      'workers.catalog',
      'workers.add',
      'workers.remove',
      'workers.check',
      'workers.test',
      'workers.enable',
      'workers.disable',
    ]);
    expect(byGroup['service'], [
      'service.status',
      'service.install',
      'service.uninstall',
      'service.start',
      'service.stop',
      'service.restart',
    ]);
    expect(
      _commands().where((c) => c['group'] == null).map((c) => c['id']),
      containsAll(['status', 'version', 'login', 'workDir', 'logs', 'reset']),
    );
  });

  test('every manifest command exists in the real command tree', () async {
    // The manifest and the parser come from one declaration; this guards the
    // wiring by asking each declared command for its own help.
    for (final command in _commands()) {
      final path = [
        for (final word in (command['argv'] as List).cast<String>())
          if (!word.startsWith('--')) word,
      ];
      final out = StringBuffer(), err = StringBuffer();
      final code =
          await WorkspaceCli(out: out, err: err).run([...path, '--help']);
      expect(code, 0, reason: '${command['id']}: $err');
      expect('$out', contains('syntila ${path.join(' ')}'),
          reason: '${command['id']}');
    }
  });

  test('help hides later commands but they still run and stay in the manifest',
      () async {
    final dir = Directory.systemTemp.createTempSync('syntila_gui_manifest');
    addTearDown(() => dir.deleteSync(recursive: true));
    final out = StringBuffer();
    expect(
      await WorkspaceCli(out: out, err: StringBuffer())
          .run(['--data-dir', dir.path, '--help']),
      0,
    );
    expect('$out', isNot(contains('workers')));
    expect(_commands().map((c) => c['id']), contains('workers.list'));
  });

  test('ids are unique and navigation targets exist', () {
    final ids = _commands().map((c) => c['id']).toList();
    expect(ids.toSet().length, ids.length);
    final nav = (_manifest()['navigation'] as List).cast<Map>();
    for (final entry in nav) {
      expect(ids, contains(entry['command']), reason: '${entry['id']}');
    }
  });

  test('every command is classified', () {
    final ids = _commands().map((c) => c['id'] as String).toSet();
    expect(ids, {..._ipc.keys, ..._local});
  });

  test('service-backed commands route to the expected IPC call', () async {
    final dir = Directory.systemTemp.createTempSync('syntila_gui_manifest');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final command in _commands()) {
      final id = command['id'] as String;
      final expected = _ipc[id];
      if (expected == null) continue;
      final params = (command['parameters'] as List? ?? const [])
          .cast<Map<String, Object>>();
      final argv = [
        '--data-dir', dir.path, //
        ...(command['argv'] as List).cast<String>(),
        for (final p in params)
          if (p['kind'] == 'positional') 'sample',
      ];
      final calls = <String>[];
      final err = StringBuffer();
      final code = await WorkspaceCli(
        out: StringBuffer(),
        err: err,
        request: (name, _) async {
          calls.add(name);
          // Worker type lookups resolve "sample" to a configured Worker.
          return name == 'workers.list'
              ? {
                  'workers': [
                    {'workerId': 'w1', 'workerTypeId': 'sample'},
                  ],
                }
              : <String, Object?>{};
        },
      ).run(argv);
      expect(code, 0, reason: '$id: ${argv.join(' ')}\n$err');
      expect(calls.last, expected, reason: id);
    }
  });
}
