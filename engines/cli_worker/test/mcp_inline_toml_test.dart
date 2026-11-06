import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_config.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

McpServerLaunch server(
  String name, {
  List<String> arguments = const [],
  Map<String, String> environment = const {},
  String command = '/usr/bin/files',
}) => McpServerLaunch(
  name: name,
  command: command,
  arguments: arguments,
  environment: environment,
);

void main() {
  sweepTests();
  test('an empty selection is an empty table', () {
    final toml = McpInlineToml.build(const []);
    expect(toml.servers, '{}');
    expect(toml.environment, isEmpty);
  });

  test('renders servers with commands and arguments', () {
    final toml = McpInlineToml.build([
      server('files', arguments: ['--root', '/tmp/a b']),
      server('git'),
    ]);
    expect(
      toml.servers,
      '{"files"={command="/usr/bin/files",'
      'default_tools_approval_mode="approve",args=["--root","/tmp/a b"]},'
      '"git"={command="/usr/bin/files",default_tools_approval_mode="approve"}}',
    );
  });

  test('escapes quotes, backslashes and control characters', () {
    final toml = McpInlineToml.build([
      server('files', arguments: ['a"b', r'c\d', 'e\nf', '\u0001']),
    ]);
    expect(toml.servers, contains(r'"a\"b"'));
    expect(toml.servers, contains(r'"c\\d"'));
    expect(toml.servers, contains(r'"e\nf"'));
    expect(toml.servers, contains(r'"\u0001"'));
    expect(toml.servers.contains('\n'), isFalse);
  });

  test('secrets stay out of the command line: only variable names appear', () {
    final toml = McpInlineToml.build([
      server('files', environment: {'API_TOKEN': 'super-secret', 'B': 'x'}),
    ]);
    expect(toml.servers, contains('env_vars=["API_TOKEN","B"]'));
    expect(toml.servers, isNot(contains('super-secret')));
    expect(toml.environment, {'API_TOKEN': 'super-secret', 'B': 'x'});
  });

  test('the same variable with the same value is shared', () {
    final toml = McpInlineToml.build([
      server('a', environment: {'TOKEN': 'v'}),
      server('b', environment: {'TOKEN': 'v'}),
    ]);
    expect(toml.environment, {'TOKEN': 'v'});
  });

  test('conflicting values for one variable are refused, not resolved', () {
    expect(
      () => McpInlineToml.build([
        server('a', environment: {'TOKEN': 'one'}),
        server('b', environment: {'TOKEN': 'two'}),
      ]),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          isNot(anyOf(contains('one'), contains('two'))),
        ),
      ),
    );
  });
}

void sweepTests() {
  test(
    'stale private config directories are swept, live ones are not',
    () async {
      final root = await Directory.systemTemp.createTemp('sweep-root-');
      addTearDown(() => root.delete(recursive: true));
      final stale = await Directory('${root.path}/syntila-mcp-old').create();
      final fresh = await Directory('${root.path}/syntila-mcp-new').create();
      final other = await Directory('${root.path}/unrelated-old').create();
      for (final dir in [stale, other]) {
        final result = await Process.run('touch', [
          '-t',
          '202001010000',
          dir.path,
        ]);
        expect(result.exitCode, 0);
      }
      final removed = await McpConfigFile.sweepStale(root: root);
      expect(removed, 1);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(other.existsSync(), isTrue);
    },
    skip: Platform.isWindows ? 'uses touch' : false,
  );
}
