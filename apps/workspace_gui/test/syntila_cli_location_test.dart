import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_workspace_gui/src/syntila_cli_location.dart';

const _exe =
    '/Applications/Syntila Workspace.app/Contents/MacOS/Syntila Workspace';
const _bundled =
    '/Applications/Syntila Workspace.app/Contents/Resources/bin/syntila';

String _locate(Map<String, String> env, Set<String> files) => locateSyntilaCli(
  environment: env,
  resolvedExecutable: _exe,
  exists: files.contains,
);

void main() {
  test('SYNTILA_CLI wins', () {
    expect(
      _locate({'SYNTILA_CLI': '/dev/syntila'}, {_bundled}),
      '/dev/syntila',
    );
  });

  test('bundled CLI before installed ones', () {
    expect(
      _locate({'HOME': '/u'}, {_bundled, '/usr/local/bin/syntila'}),
      _bundled,
    );
  });

  test('falls back to well-known locations, then PATH', () {
    expect(
      _locate({'HOME': '/u'}, {'/u/.local/bin/syntila'}),
      '/u/.local/bin/syntila',
    );
    expect(_locate({'HOME': '/u'}, {}), 'syntila');
  });
}
