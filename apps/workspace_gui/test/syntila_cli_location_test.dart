import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_workspace_gui/src/syntila_cli_location.dart';

const _macExe =
    '/Applications/syntila/Syntila Workspace.app/Contents/MacOS/Syntila Workspace';
const _macSibling = '/Applications/syntila/syntila';
const _macEmbedded =
    '/Applications/syntila/Syntila Workspace.app/Contents/Resources/syntila/syntila';
const _linuxExe = '/usr/lib/syntila/gui/syntila-workspace-gui';

String _mac(Map<String, String> env, Set<String> files) => locateSyntilaCli(
  environment: env,
  resolvedExecutable: _macExe,
  isMacOS: true,
  exists: files.contains,
);

String _linux(Map<String, String> env, Set<String> files) => locateSyntilaCli(
  environment: env,
  resolvedExecutable: _linuxExe,
  isMacOS: false,
  exists: files.contains,
);

void main() {
  test('SYNTILA_CLI wins', () {
    expect(
      _mac({'SYNTILA_CLI': '/dev/syntila'}, {_macSibling}),
      '/dev/syntila',
    );
  });

  group('macOS', () {
    test('sibling CLI in the shared folder comes first', () {
      expect(_mac({}, {_macSibling, _macEmbedded}), _macSibling);
    });

    test('then the CLI embedded by development builds', () {
      expect(_mac({}, {_macEmbedded, '/usr/local/bin/syntila'}), _macEmbedded);
    });

    test('then well-known locations, then PATH', () {
      expect(
        _mac({'HOME': '/u'}, {'/u/.local/bin/syntila'}),
        '/u/.local/bin/syntila',
      );
      expect(
        _mac({}, {'/opt/homebrew/bin/syntila'}),
        '/opt/homebrew/bin/syntila',
      );
      expect(_mac({'HOME': '/u'}, {}), 'syntila');
    });
  });

  group('Linux', () {
    test('sibling CLI in /usr/lib/syntila comes first', () {
      expect(
        _linux({}, {'/usr/lib/syntila/syntila', '/usr/bin/syntila'}),
        '/usr/lib/syntila/syntila',
      );
    });

    test('falls back to /usr/bin/syntila, then PATH', () {
      expect(_linux({}, {'/usr/bin/syntila'}), '/usr/bin/syntila');
      expect(_linux({}, {}), 'syntila');
    });
  });

  group('Windows', () {
    String windows(Map<String, String> env, Set<String> files) =>
        locateSyntilaCli(
          environment: env,
          resolvedExecutable:
              r'C:\Syntila\Workspace\gui\syntila-workspace-gui.exe',
          isMacOS: false,
          isWindows: true,
          exists: files.contains,
        );

    test('finds the sibling CLI and standard install before PATH', () {
      const sibling = r'C:\Syntila\Workspace\syntila.exe';
      const installed =
          r'C:\Users\V\AppData\Local\Programs\Syntila\Workspace\syntila.exe';
      final env = {'LOCALAPPDATA': r'C:\Users\V\AppData\Local'};
      expect(windows(env, {sibling, installed}), sibling);
      expect(windows(env, {installed}), installed);
      expect(windows(env, {}), 'syntila.exe');
    });
  });
}
