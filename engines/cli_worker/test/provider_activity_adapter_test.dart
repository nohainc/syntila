import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/syntila_cli_worker_engine.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent;

  List<String> fixture(String provider) => File(
    '${root.path}/packages/tool-profile/test/fixtures/$provider-events/adapter-edge-cases.jsonl',
  ).readAsLinesSync();

  test(
    'Codex adapter preserves missing-id tool pairs and reports failures',
    () {
      final adapter = ProviderActivityAdapter.fromProfile({
        'providerTool': {'name': 'codex'},
        'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
      })!;
      final observations = <ProviderActivityObservation>[];
      for (final line in fixture('codex')) {
        observations.addAll(
          adapter.normalizeLine(
            line,
            declarativeMatched: line.contains('item.'),
          ),
        );
      }

      final tools = observations
          .where(
            (event) =>
                event.type == 'tool.started' ||
                event.type == 'tool.completed' ||
                event.type == 'tool.failed',
          )
          .toList();
      expect(tools.map((event) => event.type), [
        'tool.started',
        'tool.completed',
        'tool.failed',
      ]);
      expect(tools[0].activityId, tools[1].activityId);
      expect(tools[0].activityId, isNotEmpty);
      expect(tools[0].details['identifierSource'], 'generated');
      expect(
        observations.map((event) => event.details['diagnostic']),
        containsAll(['provider_error', 'malformed_json']),
      );
    },
  );

  test('agy adapter preserves missing-id tool pairs and failed tools', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;
    final observations = <ProviderActivityObservation>[];
    for (final line in fixture('antigravity')) {
      observations.addAll(
        adapter.normalizeLine(
          line,
          declarativeMatched: line.contains('ACTIVE'),
        ),
      );
    }

    final tools = observations
        .where(
          (event) =>
              event.type == 'tool.started' ||
              event.type == 'tool.completed' ||
              event.type == 'tool.failed',
        )
        .toList();
    expect(tools.map((event) => event.type), [
      'tool.started',
      'tool.completed',
      'tool.failed',
    ]);
    expect(tools[0].activityId, tools[1].activityId);
    expect(tools[0].details['identifierSource'], 'generated');
    expect(
      observations.map((event) => event.details['diagnostic']),
      containsAll(['provider_error', 'malformed_json']),
    );
  });

  test('adapter IDs remain distinct for repeated missing-id invocations', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'codex'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    final starts = <String?>[];
    for (var index = 0; index < 2; index++) {
      final event =
          jsonDecode(
                '{"type":"item.started","item":{"type":"command_execution"}}',
              )
              as Map<String, Object?>;
      starts.add(
        adapter
            .normalizeEvent(event, declarativeMatched: true)
            .single
            .activityId,
      );
    }
    expect(starts[0], isNot(starts[1]));
  });

  test('Codex adapter extracts content-array final responses', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Codex CLI'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    expect(
      adapter.finalResponseText({
        'type': 'item.completed',
        'item': {
          'type': 'agent_message',
          'content': [
            {'type': 'output_text', 'text': 'first'},
            {'type': 'output_text', 'text': ' second'},
          ],
        },
      }),
      'first second',
    );
  });

  test('Codex adapter treats non-tool item updates as expected progress', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Codex CLI'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    for (final itemType in ['todo_list', 'reasoning', 'agent_message']) {
      expect(
        adapter.normalizeEvent({
          'type': 'item.updated',
          'item': {'id': 'item-1', 'type': itemType},
        }, declarativeMatched: true),
        isEmpty,
        reason: '$itemType updates must not raise a diagnostic',
      );
    }
    final searchUpdate = adapter.normalizeEvent({
      'type': 'item.updated',
      'item': {'id': 'search-1', 'type': 'web_search'},
    }, declarativeMatched: true);
    expect(searchUpdate.single.type, 'model.status');
    expect(searchUpdate.single.activityId, 'search-1');
  });

  test('Codex adapter reports agent messages as narration', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Codex CLI'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    final narration = adapter.normalizeEvent({
      'type': 'item.completed',
      'item': {
        'id': 'item_2',
        'type': 'agent_message',
        'text': 'I\u2019ll run `sleep 25 && echo done` and wait.\n',
      },
    }, declarativeMatched: true);
    expect(narration.single.type, 'message.updated');
    expect(narration.single.activityId, 'codex-msg-item_2');
    expect(
      narration.single.details['preview'],
      'I\u2019ll run `sleep 25 && echo done` and wait.',
    );
    expect(
      adapter.normalizeEvent({
        'type': 'item.completed',
        'item': {'id': 'item_3', 'type': 'agent_message', 'text': '  '},
      }, declarativeMatched: true),
      isEmpty,
    );
  });

  test('agy adapter joins text deltas and reports at most every interval', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;
    var now = DateTime.utc(2026, 10, 17, 12);
    adapter.clock = () => now;
    List<ProviderActivityObservation> delta(String text, {String? state}) =>
        adapter.normalizeEvent({
          'event': 'step_update',
          'step_update': {
            'conversation_id': 'c1',
            'step_index': 1,
            'state': state ?? 'ACTIVE',
            'step_type': 'agent_response',
            'text_delta': text,
          },
        }, declarativeMatched: false);

    final first = delta(
      '**Step 1:** Creating [a.txt](file:///var/x/a.txt) and ',
    );
    expect(first.single.type, 'message.updated');
    expect(first.single.activityId, 'agy-msg-c1:1');
    expect(first.single.details['preview'], 'Step 1: Creating a.txt and');

    // Inside the interval nothing is sent.
    now = now.add(const Duration(milliseconds: 500));
    expect(delta('b.txt in the '), isEmpty);
    now = now.add(const Duration(milliseconds: 500));
    expect(delta('current folder'), isEmpty);

    // Past the interval the whole text so far is reported again.
    now = now.add(const Duration(seconds: 2));
    final next = delta(', each with a [partial](file:///va');
    expect(
      next.single.details['preview'],
      'Step 1: Creating a.txt and b.txt in the current folder, each with a',
    );

    // The finished step is reported once more, then forgotten.
    final done = delta('th).\n', state: 'DONE');
    expect(done.single.details['preview'], endsWith('each with a partial.'));
    expect(delta('', state: 'DONE'), isEmpty);
  });

  test('agy adapter pairs documented tool steps by step index', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;
    Map<String, Object?> step(Map<String, Object?> fields) => {
      'event': 'step_update',
      'step_update': {'conversation_id': 'c1', ...fields},
    };

    final started = adapter.normalizeEvent(
      step({
        'step_index': 2,
        'state': 'ACTIVE',
        'step_type': 'tool',
        'tool_name': 'run_command',
      }),
      declarativeMatched: false,
    );
    final completed = adapter.normalizeEvent(
      step({
        'step_index': 2,
        'state': 'DONE',
        'step_type': 'tool',
        'tool_name': 'run_command',
        'tool_info': {'name': 'run_command', 'output': 'ok'},
      }),
      declarativeMatched: false,
    );
    final failed = adapter.normalizeEvent(
      step({
        'step_index': 3,
        'state': 'DONE',
        'step_type': 'tool',
        'tool_name': 'run_command',
        'tool_info': {
          'name': 'run_command',
          'error': {'type': 'permission', 'message': 'denied'},
        },
      }),
      declarativeMatched: false,
    );

    expect(started.single.type, 'tool.started');
    expect(completed.single.type, 'tool.completed');
    expect(completed.single.activityId, started.single.activityId);
    expect(failed.single.type, 'tool.failed');
    expect(failed.single.activityId, isNot(started.single.activityId));
    // Checkpoints and responses are expected steps, not diagnostics.
    expect(
      adapter.normalizeEvent(
        step({'step_index': 4, 'state': 'ACTIVE', 'step_type': 'checkpoint'}),
        declarativeMatched: false,
      ),
      isEmpty,
    );
  });

  group('Claude adapter', () {
    ProviderActivityAdapter adapter() => ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Claude Code'},
      'activity': {'adapter': 'claude-stream-json', 'mappings': <Object?>[]},
    })!;

    List<ProviderActivityObservation> line(
      ProviderActivityAdapter adapter,
      Map<String, Object?> event,
    ) => adapter.normalizeLine(jsonEncode(event), declarativeMatched: false);

    test('is selected from the declared adapter or the provider name', () {
      expect(
        ProviderActivityAdapter.fromProfile({
          'providerTool': {'name': 'Claude Code'},
          'activity': {'mappings': <Object?>[]},
        })?.kind,
        'claude-stream-json',
      );
      expect(adapter().kind, 'claude-stream-json');
    });

    test('pairs tool_use with tool_result and reports failures', () {
      final claude = adapter();
      final started = line(claude, {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'thinking', 'thinking': 'secret reasoning'},
            {'type': 'text', 'text': 'Checking the project files'},
            {
              'type': 'tool_use',
              'id': 'toolu_01',
              'name': 'Bash',
              'input': {'command': 'curl -H token=abcdef123456 example.test'},
            },
          ],
        },
      });
      expect(started.map((e) => e.type), [
        'model.status',
        'message.updated',
        'tool.started',
      ]);
      expect(started.last.activityId, 'toolu_01');
      expect(started.last.title, 'Running a command');
      expect(started.last.details['toolKind'], 'Bash');

      final done = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_01',
              'content': 'secret output',
            },
          ],
        },
      });
      expect(done.single.type, 'tool.completed');
      expect(done.single.activityId, 'toolu_01');
      expect(done.single.title, 'Ran a command');

      final failed = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_02',
              'is_error': true,
              'content': 'secret error',
            },
          ],
        },
      });
      expect(failed.single.title, 'Tool failed');
      expect(failed.single.type, 'tool.failed');

      // MCP tool call lifecycle: start, complete, and fail.
      line(claude, {
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'id': 'toolu_mcp_ok',
              'name': 'mcp__github__create_issue',
              'input': {'title': 'bug'},
            },
            {
              'type': 'tool_use',
              'id': 'toolu_mcp_err',
              'name': 'mcp__github__close_issue',
              'input': {'issue_number': 42},
            },
          ],
        },
      });
      final mcpDone = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_mcp_ok',
              'content': 'created',
            },
          ],
        },
      });
      expect(mcpDone.single.type, 'tool.completed');
      expect(mcpDone.single.title, 'Used a connected tool');

      final mcpFail = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_mcp_err',
              'is_error': true,
              'content': 'forbidden',
            },
          ],
        },
      });
      expect(mcpFail.single.type, 'tool.failed');
      expect(mcpFail.single.title, 'Connected tool failed');
      expect(failed.single.status, 'failed');
      expect(failed.single.activityId, 'toolu_02');

      expect(started[1].title, 'Checking the project files');
      expect(started[1].details['preview'], 'Checking the project files');
      // Bounded command summaries mask credentials; reasoning and tool output
      // never cross the activity boundary.
      final everything = [
        ...started,
        ...done,
        ...failed,
      ].map((e) => '${e.title} ${e.details} ${e.activityId}').join(' ');
      expect(everything, isNot(contains('abcdef123456')));
      expect(everything, contains('[redacted]'));
      expect(everything, isNot(contains('secret reasoning')));
      expect(everything, isNot(contains('secret output')));
      expect(everything, isNot(contains('secret error')));
    });

    test('reports bounded, redacted narration keyed by the message id', () {
      final claude = adapter();
      List<ProviderActivityObservation> narrate(String text, {String? id}) =>
          line(claude, {
            'type': 'assistant',
            'message': {
              if (id != null) 'id': id,
              'content': [
                {'type': 'text', 'text': text},
              ],
            },
          });

      final first = narrate('Step 1:\nCreating files', id: 'msg_01AbC');
      expect(first.single.type, 'message.updated');
      expect(first.single.activityId, 'claude-msg-msg_01AbC');
      expect(first.single.title, 'Step 1: Creating files');
      expect(first.single.details['preview'], 'Step 1: Creating files');
      expect(first.single.details.containsKey('previewTruncated'), isFalse);

      // The same message id replaces the earlier row.
      expect(
        narrate('Step 1: Done', id: 'msg_01AbC').single.activityId,
        first.single.activityId,
      );

      final secrets = narrate(
        'key sk-abcdefghijklmnopqrstuvwx and token=abcdef123456 and '
        'Bearer abcdefghijklmnop1234',
      ).single;
      expect(secrets.details['preview'], isNot(contains('abcdefghijkl')));
      expect(secrets.details['preview'], isNot(contains('abcdef123456')));
      expect(secrets.details['preview'], contains('[redacted]'));
      expect(secrets.activityId, isNull);

      final long = narrate('x' * 5000).single;
      expect((long.details['preview'] as String).length, 1500);
      expect(long.details['previewTruncated'], isTrue);
      expect(long.title.length, 160);

      final blank = narrate('   ').single;
      expect(blank.title, 'Writing the response');
      expect(blank.details, isEmpty);
    });

    test('reports background commands still running when the turn ends', () {
      final claude = adapter();
      expect(
        line(claude, {
          'type': 'system',
          'subtype': 'background_tasks_changed',
          'tasks': [
            {'task_id': 'bmn2h4bpp', 'description': 'Wait then print done'},
          ],
        }),
        isEmpty,
      );
      final ended = line(claude, {'type': 'result', 'is_error': false});
      expect(ended.single.type, 'tool.failed');
      expect(ended.single.activityId, 'claude-bg-bmn2h4bpp');
      expect(
        ended.single.title,
        'Background command stopped when the agent finished',
      );
      // Reported once; a later result or an empty list reports nothing.
      expect(line(claude, {'type': 'result', 'is_error': false}), isEmpty);
      line(claude, {
        'type': 'system',
        'subtype': 'background_tasks_changed',
        'tasks': [
          {'task_id': 'b1'},
        ],
      });
      line(claude, {
        'type': 'system',
        'subtype': 'background_tasks_changed',
        'tasks': <Object?>[],
      });
      expect(line(claude, {'type': 'result', 'is_error': false}), isEmpty);
    });

    test('titles tools by name and ignores unrelated events silently', () {
      final claude = adapter();
      String title(String name) => line(claude, {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'tool_use', 'id': 'toolu_$name', 'name': name},
          ],
        },
      }).single.title;
      expect(title('Edit'), 'Editing files');
      expect(title('Read'), 'Reading files');
      expect(title('WebSearch'), 'Searching the web');
      expect(title('Task'), 'Working with a sub-agent');
      expect(title('mcp__server__tool'), 'Using a connected tool');
      expect(title('SomethingNew'), 'Running a tool');

      final init = line(claude, {'type': 'system', 'subtype': 'init'});
      expect(init.single.type, 'model.started');
      expect(init.single.title, 'Thinking');
      expect(line(claude, {'type': 'system', 'subtype': 'api_retry'}), isEmpty);
      for (final type in ['result', 'stream_event', 'rate_limit_event']) {
        expect(line(claude, {'type': type, 'subtype': 'init'}), isEmpty);
      }
      expect(
        line(claude, {
          'type': 'assistant',
          'message': {'content': 'plain'},
        }),
        isEmpty,
      );
    });
  });

  test(
    'agy adapter defers to a matched mapping that keys tools by step_index',
    () {
      final adapter = ProviderActivityAdapter.fromProfile({
        'providerTool': {'name': 'agy'},
        'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
      })!;
      Map<String, Object?> tool(String state) => {
        'event': 'step_update',
        'step_update': {
          'conversation_id': 'c1',
          'step_index': 1,
          'state': state,
          'step_type': 'tool',
          'tool_name': 'run_command',
        },
      };
      // The Profile mapping already reported these under id "1".
      expect(
        adapter.normalizeEvent(tool('ACTIVE'), declarativeMatched: true),
        isEmpty,
      );
      expect(
        adapter.normalizeEvent(tool('DONE'), declarativeMatched: true),
        isEmpty,
      );
      // Without a matching mapping the adapter still provides the pair.
      expect(
        adapter.normalizeEvent(tool('ACTIVE'), declarativeMatched: false),
        hasLength(1),
      );
    },
  );

  group('agy presentation', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;

    Map<String, Object?> tool(String name, Map<String, Object?> params) => {
      'event': 'step_update',
      'step_update': {
        'conversation_id': 'c1',
        'step_index': 1,
        'state': 'DONE',
        'step_type': 'tool',
        'tool_name': name,
        'tool_info': {'name': name, 'parameters': params},
      },
    };

    test('tool rows say what was done, with a short masked summary', () {
      final file = adapter.agyToolPresentation(
        tool('write_to_file', {'TargetFile': '/tmp/work/a.txt'}),
        'tool.completed',
      )!;
      expect(file.title, 'Wrote a file');
      expect(file.summary, 'a.txt');

      final command = adapter.agyToolPresentation(
        tool('run_command', {'CommandLine': 'curl -H "token=abcdef123456" x'}),
        'tool.completed',
      )!;
      expect(command.title, 'Ran a command');
      expect(command.summary, contains('[redacted]'));
      expect(command.summary, isNot(contains('abcdef123456')));

      expect(
        adapter
            .agyToolPresentation(tool('run_command', {}), 'tool.failed')!
            .title,
        'Command failed',
      );
      expect(
        adapter
            .agyToolPresentation(tool('mystery', {}), 'tool.completed')!
            .title,
        'Tool completed',
      );
    });

    test('streamed answer is the last non-empty assistant step', () {
      Map<String, Object?> step(int index, String text) => {
        'event': 'step_update',
        'step_update': {
          'conversation_id': 'c1',
          'step_index': index,
          'state': 'ACTIVE',
          'step_type': 'agent_response',
          'text_delta': text,
        },
      };
      expect(
        adapter.streamedAnswer([step(1, 'Hi'), step(3, ' there'), step(5, '')]),
        'there',
      );
      expect(adapter.streamedAnswer(<Object?>[]), isNull);
    });

    test('answer drops narration already streamed', () {
      Map<String, Object?> step(int index, String text) => {
        'event': 'step_update',
        'step_update': {
          'conversation_id': 'c1',
          'step_index': index,
          'state': 'ACTIVE',
          'step_type': 'agent_response',
          'text_delta': text,
        },
      };
      final events = <Object?>[
        step(1, 'I am checking runs.'),
        step(3, 'I am fixing format.'),
        step(5, 'Summary: all fixed.'),
      ];
      expect(
        adapter.answerAfterNarration(
          events,
          'I am checking runs.\nI am fixing format.\nSummary: all fixed.',
        ),
        'Summary: all fixed.',
      );
      // Text that does not start with the narration is left alone.
      expect(adapter.answerAfterNarration(events, 'Something else'), isNull);
      // A single step has nothing to remove.
      expect(adapter.answerAfterNarration([step(1, 'Only')], 'Only'), isNull);
    });
  });

  test('Claude tool rows carry a short summary on start and finish', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'claude'},
      'activity': {'adapter': 'claude-stream-json', 'mappings': <Object?>[]},
    })!;
    final started = adapter.normalizeEvent({
      'type': 'assistant',
      'message': {
        'id': 'm1',
        'content': [
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'Bash',
            'input': {'command': 'git status'},
          },
        ],
      },
    }, declarativeMatched: false);
    expect(started.single.details['summary'], 'git status');
    final finished = adapter.normalizeEvent({
      'type': 'user',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': 't1', 'content': 'ok'},
        ],
      },
    }, declarativeMatched: false);
    expect(finished.single.title, 'Ran a command');
    expect(finished.single.details['summary'], 'git status');
  });

  test('Copilot tool rows get a title and summary', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'GitHub Copilot CLI'},
      'activity': {'adapter': 'copilot-jsonl', 'mappings': <Object?>[]},
    })!;
    final start = adapter.normalizeEvent({
      'type': 'tool.execution_start',
      'data': {
        'toolCallId': 'call_1',
        'toolName': 'bash',
        'arguments': {'command': 'curl -H "token=abcdef123456" x'},
      },
    }, declarativeMatched: false);
    expect(start.single.title, 'Running a command');
    expect(start.single.details['summary'], contains('[redacted]'));
    expect(start.single.details['summary'], isNot(contains('abcdef123456')));
    final done = adapter.toolPresentation({
      'type': 'tool.execution_complete',
      'data': {
        'toolCallId': 'call_1',
        'toolName': 'bash',
        'arguments': {'command': 'curl -H "token=abcdef123456" x'},
      },
    }, 'tool.completed')!;
    expect(done.title, 'Ran a command');
    expect(done.summary, contains('[redacted]'));
  });

  test('Codex tool rows get a title and summary', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'codex'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    final done = adapter.toolPresentation({
      'type': 'item.completed',
      'item': {'type': 'command_execution', 'command': 'ls -la'},
    }, 'tool.completed')!;
    expect(done.title, 'Ran a command');
    expect(done.summary, 'ls -la');
    final edit = adapter.toolPresentation({
      'type': 'item.completed',
      'item': {
        'type': 'file_change',
        'changes': [
          {'path': '/repo/lib/a.dart'},
          {'path': '/repo/lib/b.dart'},
        ],
      },
    }, 'tool.completed')!;
    expect(edit.summary, 'a.dart +1 more');
  });
}
