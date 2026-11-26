import 'dart:convert';
import 'dart:io';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

void main() {
  test('the Gemini profile derives models and efforts from agy output', () {
    final profile =
        jsonDecode(
              File(
                '../../apps/profile_lab/assets/profiles/gemini.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(profile['model']['selectionMapping'], isNull);
    final rule = profile['model']['discovery']['effortVariants'];
    final models = parseDiscoveredModels(
      File('test/fixtures/agy-models-1.4.0.tsv').readAsStringSync(),
      '',
    );
    final grouped = normalizeCombinedModels(
      models,
      null,
      '1.4.0',
      effortVariants: rule,
    );
    expect(grouped.map((m) => m.id), [
      'gemini-4-argon',
      'gemini-3.8-flash',
      'claude-opus-5-5',
      'claude-sonnet-5-5',
      'gpt-oss-120b',
    ]);
    expect(grouped.first.name, 'Gemini 4 Argon');
    expect(grouped.first.supportedReasoningEfforts, ['low', 'medium', 'high']);
    expect(grouped.last.supportedReasoningEfforts, ['medium']);
    expect(grouped.every((m) => m.selectionMode == 'combined'), isTrue);
    expect(grouped.every((m) => m.defaultReasoningEffort == null), isTrue);
    for (final model in grouped) {
      for (final effort in model.supportedReasoningEfforts) {
        expect(
          models.map((m) => m.id),
          contains(
            resolveNativeSelection(
              model,
              effort,
              null,
              '1.4.0',
              effortVariants: rule,
            ),
          ),
        );
      }
      expect(
        () => resolveNativeSelection(
          model,
          null,
          null,
          '1.4.0',
          effortVariants: rule,
        ),
        throwsFormatException,
      );
    }
  });
  test('a variant without its effort suffix stays its own model', () {
    // agy lists `gemini-pro-orchestrator` as "Orchestrator (Carbon)" next to
    // `gemini-pro-orchestrator-neon`/`-argon`; it must not fail the list.
    final rule = {'source': 'label_parenthesized_suffix', 'separator': '-'};
    final models = parseDiscoveredModels(
      File('test/fixtures/agy-models-orchestrator.tsv').readAsStringSync(),
      '',
    );
    final grouped = normalizeCombinedModels(
      models,
      null,
      '1.4.0',
      effortVariants: rule,
    );
    final ids = grouped.map((m) => m.id).toList();
    expect(ids.toSet().length, ids.length);
    final family = grouped.singleWhere(
      (m) => m.id == 'gemini-pro-orchestrator',
    );
    expect(family.supportedReasoningEfforts.toSet(), {'neon', 'argon'});
    final carbon = grouped.singleWhere(
      (m) => m.id == 'gemini-pro-orchestrator-carbon',
    );
    expect(carbon.name, 'Orchestrator (Carbon)');
    expect(
      resolveNativeSelection(carbon, null, null, '1.4.0', effortVariants: rule),
      'gemini-pro-orchestrator',
    );
    expect(
      resolveNativeSelection(
        family,
        'neon',
        null,
        '1.4.0',
        effortVariants: rule,
      ),
      'gemini-pro-orchestrator-neon',
    );
    expect(ids, containsAll(['gemini-4-neon', 'gemini-3.8-flash']));
  });
  test('derived efforts leave unlabeled lines as plain models', () {
    final rule = {'source': 'label_parenthesized_suffix', 'separator': '-'};
    final grouped = normalizeCombinedModels(
      parseDiscoveredModels(
        'plain-model\tPlain model\n'
            'odd-high\tOdd (Low)\n'
            'x-low\tX (Low)\n',
        '',
      ),
      null,
      '1.0.0',
      effortVariants: rule,
    );
    expect(grouped.map((m) => m.id), ['x', 'plain-model', 'odd-high']);
    expect(grouped[0].supportedReasoningEfforts, ['low']);
    expect(grouped[1].supportedReasoningEfforts, isEmpty);
    expect(grouped[2].supportedReasoningEfforts, isEmpty);
    expect(
      resolveNativeSelection(
        grouped[2],
        null,
        null,
        '1.0.0',
        effortVariants: rule,
      ),
      'odd-high',
    );
  });
  test(
    'TSV discovery preserves exact Gemini IDs and filters other providers',
    () {
      final models = parseDiscoveredModels(
        'gemini-new-high\tGemini New (High)\tlow,high\thigh\n'
            'claude-x\tClaude\n'
            'gemini-new-low\tGemini New (Low)\n',
        'gemini-',
      );
      expect(models.map((m) => m.id), ['gemini-new-high', 'gemini-new-low']);
      expect(models.first.name, 'Gemini New (High)');
      expect(models.first.supportedReasoningEfforts, ['low', 'high']);
      expect(models.first.defaultReasoningEffort, 'high');
      expect(models.every((m) => m.status == 'listed'), isTrue);
      expect(parseDiscoveredModels('claude-one\tOne', 'gemini-'), isEmpty);
      expect(
        parseDiscoveredModels('gpt-o3\tO3\tlow,high\thigh', ''),
        hasLength(1),
      );
    },
  );

  test('the installed agy catalog groups native model-effort IDs', () {
    const output = '''
gemini-3.8-flash-high\tGemini 3.8 Flash (High)
gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
gemini-3.7-flash-high\tGemini 3.7 Flash (High)
gemini-3.7-flash-medium\tGemini 3.7 Flash (Medium)
gemini-3.7-flash-low\tGemini 3.7 Flash (Low)
gemini-3.6-flash-high\tGemini 3.6 Flash (High)
gemini-3.6-flash-medium\tGemini 3.6 Flash (Medium)
gemini-3.6-flash-low\tGemini 3.6 Flash (Low)
gemini-3.1-pro-high\tGemini 3.1 Pro (High)
gemini-3.1-pro-low\tGemini 3.1 Pro (Low)
claude-opus-5-5-low\tClaude Opus 5.5 (Low)
gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
''';
    final native = parseDiscoveredModels(output, 'gemini-');
    expect(native, hasLength(11));
    final mapping = {
      'schemaVersion': 1,
      'models': [
        for (final family in const {
          'gemini-3.8-flash': ['low', 'medium', 'high'],
          'gemini-3.7-flash': ['low', 'medium', 'high'],
          'gemini-3.6-flash': ['low', 'medium', 'high'],
          'gemini-3.1-pro': ['low', 'high'],
        }.entries)
          {
            'id': family.key,
            'name': family.key,
            'variants': [
              for (final effort in family.value)
                {'nativeId': '${family.key}-$effort', 'effort': effort},
            ],
          },
      ],
    };
    final grouped = normalizeCombinedModels(native, mapping, '1.3.3');
    expect(grouped.map((model) => model.id), [
      'gemini-3.8-flash',
      'gemini-3.7-flash',
      'gemini-3.6-flash',
      'gemini-3.1-pro',
    ]);
    expect(grouped.map((model) => model.supportedReasoningEfforts), [
      ['low', 'medium', 'high'],
      ['low', 'medium', 'high'],
      ['low', 'medium', 'high'],
      ['low', 'high'],
    ]);
    expect(grouped.every((model) => model.selectionMode == 'combined'), isTrue);
    expect(
      resolveNativeSelection(grouped.first, 'high', mapping, '1.3.3'),
      'gemini-3.8-flash-high',
    );
    final olderVersion = normalizeCombinedModels(native, mapping, '1.2.16');
    expect(
      olderVersion.map((model) => model.id),
      grouped.map((model) => model.id),
    );
    expect(
      resolveNativeSelection(olderVersion.first, 'high', mapping, '1.2.16'),
      'gemini-3.8-flash-high',
    );
  });
  test('Codex app-server discovery maps models and per-model efforts', () {
    final models = parseCodexAppServerModels({
      'data': [
        {
          'id': 'gpt-6.1-sol',
          'displayName': 'GPT-6.1-Sol',
          'hidden': false,
          'defaultReasoningEffort': 'low',
          'supportedReasoningEfforts': [
            {'reasoningEffort': 'low', 'description': 'Fast'},
            {'reasoningEffort': 'high', 'description': 'Deep'},
          ],
        },
        {'id': 'gpt-hidden', 'displayName': 'Hidden', 'hidden': true},
        {'id': 'o3', 'displayName': 'o3', 'hidden': false},
      ],
      'nextCursor': null,
    }, 'gpt-');
    expect(models.map((model) => model.id), ['gpt-6.1-sol']);
    expect(models.single.supportedReasoningEfforts, ['low', 'high']);
    expect(models.single.defaultReasoningEffort, 'low');
  });

  test('an unrestricted AGY profile exposes every CLI model', () {
    const output = '''
gemini-3.8-flash-high\tGemini 3.8 Flash (High)
gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)
gemini-3.8-flash-low\tGemini 3.8 Flash (Low)
claude-opus-5-5-low\tClaude Opus 5.5 (Low)
claude-opus-5-5-medium\tClaude Opus 5.5 (Medium)
claude-opus-5-5-high\tClaude Opus 5.5 (High)
gpt-oss-120b-medium\tGPT-OSS 120B (Medium)
''';
    final native = parseDiscoveredModels(output, '');
    final mapping = {
      'schemaVersion': 1,
      'models': [
        {
          'id': 'gemini-3.8-flash',
          'name': 'Gemini 3.8 Flash',
          'variants': [
            {'nativeId': 'gemini-3.8-flash-low', 'effort': 'low'},
            {'nativeId': 'gemini-3.8-flash-medium', 'effort': 'medium'},
            {'nativeId': 'gemini-3.8-flash-high', 'effort': 'high'},
          ],
        },
      ],
    };
    final models = normalizeCombinedModels(native, mapping, '1.3.3');
    expect(models.map((model) => model.id), [
      'gemini-3.8-flash',
      'claude-opus-5-5-low',
      'claude-opus-5-5-medium',
      'claude-opus-5-5-high',
      'gpt-oss-120b-medium',
    ]);
    expect(models.first.supportedReasoningEfforts, ['low', 'medium', 'high']);
    expect(models.skip(1).every((model) => model.nativeId == model.id), isTrue);
  });

  test(
    'Codex discovery preserves logical and native identities independently',
    () {
      final models = parseCodexAppServerModels({
        'data': [
          {'id': 'logical', 'model': 'native', 'displayName': 'Model'},
        ],
      }, '');
      expect(models.single.id, 'logical');
      expect(models.single.nativeId, 'native');
      expect(
        () => parseCodexAppServerModels({
          'data': [
            {'id': 'logical', 'model': 42},
          ],
        }, ''),
        throwsFormatException,
      );
      expect(
        () => parseCodexAppServerModels({
          'data': [
            {
              'id': 'logical',
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'high'},
                {'reasoningEffort': 'high'},
              ],
            },
          ],
        }, ''),
        throwsFormatException,
      );
    },
  );

  test('Codex app-server discovery rejects invalid effort metadata', () {
    expect(
      () => parseCodexAppServerModels({
        'data': [
          {
            'id': 'gpt-one',
            'displayName': 'One',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
            ],
            'defaultReasoningEffort': 'high',
          },
        ],
      }, ''),
      throwsFormatException,
    );
  });

  test('Codex app-server discovery performs the JSON-RPC handshake', () async {
    final root = await Directory.systemTemp.createTemp('codex-app-server-');
    addTearDown(() => root.delete(recursive: true));
    final server = File('${root.path}/fake_app_server.dart');
    await server.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    if (request['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {'ok': true}}));
    } else if (request['method'] == 'model/list') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {
        'data': [
          {'id': 'gpt-fixture', 'displayName': 'Fixture', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}], 'defaultReasoningEffort': 'low'}
        ],
        'nextCursor': null
      }}));
    }
  }

}
''');
    final models = await discoverCodexAppServerModels(
      executable: Platform.resolvedExecutable,
      arguments: ['run', server.path],
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
      workingDirectory: root.path,
      idPrefix: 'gpt-',
    );
    expect(models.single.id, 'gpt-fixture');
    expect(models.single.defaultReasoningEffort, 'low');
  });
  test('malformed, duplicate, empty and oversized results are rejected', () {
    for (final output in [
      'gemini-one',
      'gemini-one\tOne\ngemini-one\tTwo',
      'gemini-one\tOne\tlow\tmedium',
      'gemini-one\tOne\tlow\thigh\textra',
      'gemini-bad\tBad\u001b',
      List.generate(129, (i) => 'gemini-$i\tModel $i').join('\n'),
    ]) {
      expect(
        () => parseDiscoveredModels(output, 'gemini-'),
        throwsFormatException,
      );
    }
  });
  test(
    'cache survives restart, invalidates version/profile, and recovers corruption',
    () async {
      final root = await Directory.systemTemp.createTemp('model-discovery-');
      addTearDown(() => root.delete(recursive: true));
      final digest = 'a' * 64;
      final cache = ModelDiscoveryCache(root.path);
      await cache.save(
        DiscoveredModelCatalog(
          profileDigest: digest,
          providerToolVersion: '1.2.16',
          discoveredAt: '2026-10-11T00:00:00Z',
          models: [
            DiscoveredModel(id: 'gemini-one', name: 'One', status: 'verified'),
          ],
        ),
      );
      expect(
        (await ModelDiscoveryCache(
          root.path,
        ).load(digest, '1.2.16'))!.models.single.status,
        'verified',
      );
      expect(await cache.load(digest, '1.2.17'), isNull);
      expect(await cache.load('b' * 64, '1.2.16'), isNull);
      await cache.file.writeAsString('invalid');
      expect(await cache.load(digest, '1.2.16'), isNull);
    },
  );
  test(
    'signed combined mapping intersects native discovery and resolves all AGY pairs',
    () async {
      final mapping = {
        'schemaVersion': 1,
        'models': [
          for (final family in const {
            'gemini-3.8-flash': ['low', 'medium', 'high'],
            'gemini-3.7-flash': ['low', 'medium', 'high'],
            'gemini-3.6-flash': ['low', 'medium', 'high'],
            'gemini-3.1-pro': ['low', 'high'],
          }.entries)
            {
              'id': family.key,
              'name': family.key,
              'variants': [
                for (final effort in family.value)
                  {'nativeId': '${family.key}-$effort', 'effort': effort},
              ],
            },
        ],
      };
      final native = parseDiscoveredModels(
        await File(
          'test/fixtures/model-effort-audit-agy.tsv',
        ).readAsString(),
        'gemini-',
      );
      final families = normalizeCombinedModels(native, mapping, '1.3.3');
      expect(families.length, 4);
      var count = 0;
      for (final model in families) {
        expect(model.defaultReasoningEffort, isNull);
        expect(
          () => resolveNativeSelection(model, null, mapping, '1.3.3'),
          throwsFormatException,
        );
        for (final effort in model.supportedReasoningEfforts) {
          expect(
            resolveNativeSelection(model, effort, mapping, '1.3.3'),
            '${model.id}-$effort',
          );
          count++;
        }
      }
      expect(count, 11);
      expect(normalizeCombinedModels(native, mapping, '1.3.4').length, 4);
      expect(
        normalizeCombinedModels(
          [...native, DiscoveredModel(id: 'gemini-unknown', name: 'Unknown')],
          mapping,
          '1.3.3',
        ).last.id,
        'gemini-unknown',
      );
    },
  );

  test(
    'versioned renames preserve logical identity and reject ambiguous mappings',
    () {
      Map<String, Object?> mapping(List<Map<String, Object?>> variants) => {
        'schemaVersion': 1,
        'models': [
          {'id': 'family', 'name': 'Family', 'variants': variants},
        ],
      };
      final variants = [
        {
          'nativeId': 'old',
          'effort': 'low',
          'providerVersion': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
        },
        {
          'nativeId': 'new',
          'effort': 'low',
          'providerVersion': {'min': '2.0.0', 'maxExclusive': '3.0.0'},
        },
      ];
      for (final pair in [('1.0.0', 'old'), ('2.0.0', 'new')]) {
        final model = normalizeCombinedModels(
          [DiscoveredModel(id: pair.$2, name: 'Native')],
          mapping(variants),
          pair.$1,
        ).single;
        expect(model.id, 'family');
        expect(
          resolveNativeSelection(model, 'low', mapping(variants), pair.$1),
          pair.$2,
        );
      }
      expect(
        () => normalizeCombinedModels(
          [],
          mapping([variants.first, variants.first]),
          '1.0.0',
        ),
        throwsFormatException,
      );
      expect(
        () => normalizeCombinedModels(
          [
            DiscoveredModel(id: 'old', name: 'Native'),
            DiscoveredModel(id: 'family', name: 'Unclassified'),
          ],
          mapping(variants),
          '1.0.0',
        ),
        throwsFormatException,
      );
    },
  );
  test('missing CLI support does not produce a catalog', () async {
    await expectLater(
      discoverCodexAppServerModels(
        executable: '/definitely/missing/provider',
        arguments: const [],
        environment: const {},
        workingDirectory: Directory.current.path,
        idPrefix: '',
      ),
      throwsA(isA<ProcessException>()),
    );
    final root = await Directory.systemTemp.createTemp(
      'unsupported-model-list-',
    );
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/provider.dart');
    await script.writeAsString(
      "import 'dart:io'; void main() { stderr.writeln('unsupported app-server'); exit(2); }",
    );
    await expectLater(
      discoverCodexAppServerModels(
        executable: Platform.resolvedExecutable,
        arguments: ['run', script.path],
        environment: const {},
        workingDirectory: root.path,
        idPrefix: '',
      ),
      throwsFormatException,
    );
  });
}
