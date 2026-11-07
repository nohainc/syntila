import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A provider observation that has already been reduced to safe, bounded
/// Worker Activity fields. Provider payloads and tool output never cross this
/// boundary.
class ProviderActivityObservation {
  const ProviderActivityObservation({
    required this.type,
    required this.status,
    required this.title,
    this.activityId,
    this.details = const <String, Object?>{},
  });

  final String type;
  final String status;
  final String title;
  final String? activityId;
  final Map<String, Object?> details;
}

/// Handles provider event families that cannot be expressed safely by the
/// declarative Profile mapping grammar. This is deliberately kept at the
/// generic Engine boundary; Cloud and Core do not know provider event shapes.
class ProviderActivityAdapter {
  ProviderActivityAdapter._(this.kind);

  final String kind;
  final Set<String> _reportedDiagnostics = <String>{};
  final Map<String, int> _fallbackCounts = <String, int>{};
  final Map<String, List<String>> _pendingFallbackIds =
      <String, List<String>>{};

  static ProviderActivityAdapter? fromProfile(Map<String, Object?> profile) {
    final activity = profile['activity'];
    if (activity is! Map) return null;
    final declared = activity['adapter'];
    if (declared is String &&
        const {
          'codex-jsonl',
          'agy-stream-json',
          'claude-stream-json',
          'grok-streaming-json',
          'copilot-jsonl',
        }.contains(declared)) {
      return ProviderActivityAdapter._(declared);
    }
    final provider = profile['providerTool'];
    final name = provider is Map ? provider['name'] : null;
    final normalizedName = name is String ? name.toLowerCase() : '';
    if (normalizedName.contains('codex')) {
      return ProviderActivityAdapter._('codex-jsonl');
    }
    if (normalizedName == 'agy' || normalizedName.contains('antigravity')) {
      return ProviderActivityAdapter._('agy-stream-json');
    }
    if (normalizedName.contains('claude')) {
      return ProviderActivityAdapter._('claude-stream-json');
    }
    if (normalizedName.contains('copilot')) {
      return ProviderActivityAdapter._('copilot-jsonl');
    }
    return null;
  }

  /// Normalizes one provider line. [declarativeMatched] tells the adapter
  /// that the ordinary Profile mapping already produced the event, so the
  /// adapter only adds a fallback for missing identifiers or unsupported
  /// lifecycle/error variants.
  List<ProviderActivityObservation> normalizeLine(
    String line, {
    required bool declarativeMatched,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return _diagnostic('malformed_json');
    }
    if (decoded is! Map) return _diagnostic('unsupported_event_shape');
    return normalizeEvent(decoded, declarativeMatched: declarativeMatched);
  }

  List<ProviderActivityObservation> normalizeEvent(
    Map event, {
    required bool declarativeMatched,
  }) {
    return switch (kind) {
      'codex-jsonl' => _normalizeCodex(
        event,
        declarativeMatched: declarativeMatched,
      ),
      'agy-stream-json' => _normalizeAgy(
        event,
        declarativeMatched: declarativeMatched,
      ),
      'claude-stream-json' => _normalizeClaude(event),
      'grok-streaming-json' => _normalizeGrok(event),
      'copilot-jsonl' => _normalizeCopilot(
        event,
        declarativeMatched: declarativeMatched,
      ),
      _ => _diagnostic('unsupported_adapter'),
    };
  }

  /// Returns a provider final response when the provider encodes message text
  /// outside the Profile's simple scalar selector. Codex has emitted both
  /// `item.text` and `item.content[].text` forms across CLI releases.
  ///
  /// This is deliberately a response-only extraction. It does not expose the
  /// provider event or tool output to activity consumers.
  String? finalResponseText(Map event) {
    if (kind != 'codex-jsonl') return null;
    final type = event['type'];
    if (type == 'turn.completed' && event['final_response'] is String) {
      final response = (event['final_response'] as String).trimRight();
      return response.isEmpty ? null : response;
    }
    if (type != 'item.completed' && type != 'item.updated') return null;
    final item = event['item'];
    if (item is! Map || item['type'] != 'agent_message') return null;
    final scalar = item['text'];
    if (scalar is String && scalar.trim().isNotEmpty) return scalar;
    final content = item['content'];
    if (content is! List) return null;
    final parts = <String>[];
    for (final entry in content) {
      if (entry is String && entry.trim().isNotEmpty) {
        parts.add(entry);
      } else if (entry is Map && entry['text'] is String) {
        final text = entry['text'] as String;
        if (text.trim().isNotEmpty) parts.add(text);
      }
    }
    if (parts.isEmpty) return null;
    return parts.join();
  }

  List<ProviderActivityObservation> _normalizeCodex(
    Map event, {
    required bool declarativeMatched,
  }) {
    final type = event['type'];
    if (type is! String) return _diagnostic('missing_event_type');
    final item = event['item'];
    final itemMap = item is Map ? item : const <Object?, Object?>{};
    final itemType = itemMap['type'];
    final isTool = const {
      'command_execution',
      'mcp_tool_call',
      'web_search_call',
      'web_search',
      'collab_tool_call',
      'file_change',
    }.contains(itemType);
    final toolKind = itemType is String ? itemType : 'tool';

    if (type == 'item.updated' && isTool) {
      return <ProviderActivityObservation>[
        ProviderActivityObservation(
          type: 'model.status',
          status: 'updated',
          title: 'Tool status updated',
          activityId: _activityId(
            itemMap['id'],
            family: 'codex-tool',
            toolKind: toolKind,
            terminal: false,
            reusePending: true,
          ),
          details: {
            ..._toolDetails(toolKind),
            if (itemMap['id'] is! String || (itemMap['id'] as String).isEmpty)
              'identifierSource': 'generated',
          },
        ),
      ];
    }
    if (type == 'item.failed' && isTool) {
      return <ProviderActivityObservation>[
        ProviderActivityObservation(
          type: 'tool.failed',
          status: 'failed',
          title: 'Tool failed',
          activityId: _activityId(
            itemMap['id'],
            family: 'codex-tool',
            toolKind: toolKind,
            terminal: true,
          ),
          details: _toolDetails(toolKind),
        ),
      ];
    }
    if (type == 'item.completed' && itemType == 'agent_message') {
      return _codexNarration(itemMap);
    }
    if (type == 'item.started' || type == 'item.completed') {
      if (!isTool) return const [];
      if (itemMap['id'] is! String || (itemMap['id'] as String).isEmpty) {
        if (declarativeMatched) {
          return <ProviderActivityObservation>[
            ProviderActivityObservation(
              type: type == 'item.started' ? 'tool.started' : 'tool.completed',
              status: type == 'item.started' ? 'running' : 'completed',
              title: type == 'item.started' ? 'Running tool' : 'Tool completed',
              activityId: _activityId(
                null,
                family: 'codex-tool',
                toolKind: toolKind,
                terminal: type == 'item.completed',
              ),
              details: {
                ..._toolDetails(toolKind),
                'identifierSource': 'generated',
              },
            ),
          ];
        }
        return const [];
      }
      // The declarative mapping owns normal start/completion events so the
      // adapter does not duplicate them.
      return const [];
    }
    // Codex emits item.updated for non-tool items too (plans, reasoning,
    // messages). Those are expected progress, not an unsupported event.
    if (type == 'item.updated') return const [];
    if (type == 'turn.failed' || type == 'error') {
      return <ProviderActivityObservation>[
        const ProviderActivityObservation(
          type: 'model.status',
          status: 'failed',
          title: 'Provider reported an error',
          details: {'diagnostic': 'provider_error'},
        ),
      ];
    }
    if (const {
      'thread.started',
      'turn.started',
      'turn.completed',
      'item.completed',
    }.contains(type)) {
      return const [];
    }
    return _diagnostic('unsupported_event');
  }

  List<ProviderActivityObservation> _normalizeAgy(
    Map event, {
    required bool declarativeMatched,
  }) {
    final eventName = event['event'];
    if (eventName == 'step_update' && event['step_update'] is Map) {
      final step = event['step_update'] as Map;
      final stepType = step['step_type'];
      // Documented AGY step types: user_input, agent_response, tool and
      // checkpoint. `tool_execution` is still accepted for older captures.
      if (stepType == 'tool' || stepType == 'tool_execution') {
        return _normalizeAgyTool(step, declarativeMatched: declarativeMatched);
      }
      if (stepType == 'agent_response') return _agyNarration(step);
      if (const {'user_input', 'checkpoint'}.contains(stepType)) {
        return const [];
      }
      return _diagnostic('unsupported_step_type');
    }
    if (eventName == 'result') {
      final result = event['result'];
      final resultMap = result is Map ? result : const <Object?, Object?>{};
      final status = resultMap['status'];
      if (const {'ERROR', 'FAILED', 'FAILURE', 'INVALID'}.contains(status)) {
        return <ProviderActivityObservation>[
          const ProviderActivityObservation(
            type: 'model.status',
            status: 'failed',
            title: 'Provider reported an error',
            details: {'diagnostic': 'provider_error'},
          ),
        ];
      }
      // Cancellation and interruption are reported by the Engine's terminal
      // activity, so they are not repeated here.
      if (const {
        'SUCCESS',
        'COMPLETED',
        'CANCELED',
        'INTERRUPTED',
        'WAITING',
        'RUNNING',
      }.contains(status)) {
        return const [];
      }
      return _diagnostic('unsupported_result_status');
    }
    if (eventName == 'init') return const [];
    return _diagnostic('unsupported_event');
  }

  /// Codex reports each narration as a whole `agent_message` item. The text
  /// is bounded and secret-masked; the item id keeps one row per message.
  List<ProviderActivityObservation> _codexNarration(Map item) {
    final raw = item['text'];
    String? text = raw is String ? raw : null;
    if (text == null && item['content'] is List) {
      text = (item['content'] as List).map((entry) {
        if (entry is String) return entry;
        if (entry is Map && entry['text'] is String) {
          return entry['text'] as String;
        }
        return '';
      }).join();
    }
    final narration = _narrationExcerpt(text);
    if (narration == null) return const [];
    final id = _safeText(item['id']);
    return <ProviderActivityObservation>[
      _narrationObservation(
        narration,
        activityId: id == null ? null : 'codex-msg-$id',
      ),
    ];
  }

  /// How often a still-growing agy answer is re-reported. agy streams text in
  /// many tiny `text_delta` pieces; the adapter joins them per step and
  /// reports the whole text so far at most once per interval, plus once more
  /// when the step ends. Unchanged text is never re-sent.
  Duration narrationInterval = const Duration(seconds: 2);

  /// Clock used for [narrationInterval]; replaceable in tests.
  DateTime Function() clock = DateTime.now;

  static const int _maxNarrationBuffer = 20000;
  static const int _maxOpenNarrations = 64;
  final Map<String, _NarrationBuffer> _agyNarrations =
      <String, _NarrationBuffer>{};

  List<ProviderActivityObservation> _agyNarration(Map step) {
    final index = step['step_index'];
    if (index is! int || index < 0) return const [];
    final conversation = _safeText(step['conversation_id']) ?? 'session';
    final key = '$conversation:$index';
    if (_agyNarrations.length >= _maxOpenNarrations &&
        !_agyNarrations.containsKey(key)) {
      _agyNarrations.remove(_agyNarrations.keys.first);
    }
    final buffer = _agyNarrations.putIfAbsent(key, _NarrationBuffer.new);
    final delta = step['text_delta'];
    if (delta is String && buffer.text.length < _maxNarrationBuffer) {
      buffer.text.write(delta);
    }
    final state = step['state'];
    final finished =
        state == 'DONE' ||
        state == 'COMPLETED' ||
        state == 'ERROR' ||
        state == 'FAILED';
    final now = clock();
    final last = buffer.lastEmittedAt;
    final due = last == null || now.difference(last) >= narrationInterval;
    if (!finished && !due) return const [];
    if (finished) _agyNarrations.remove(key);
    final narration = _narrationExcerpt(buffer.text.toString());
    if (narration == null || narration == buffer.lastEmitted) return const [];
    buffer.lastEmittedAt = now;
    buffer.lastEmitted = narration;
    final id = 'agy-msg-$key';
    return <ProviderActivityObservation>[
      _narrationObservation(
        narration,
        activityId: id.length > 128 ? id.substring(0, 128) : id,
      ),
    ];
  }

  ProviderActivityObservation _narrationObservation(
    String narration, {
    String? activityId,
  }) => ProviderActivityObservation(
    type: 'message.updated',
    status: 'updated',
    title: _narrationTitle(narration),
    activityId: activityId,
    details: {
      'preview': narration,
      if (narration.endsWith('…')) 'previewTruncated': true,
    },
  );

  /// A tool step runs as ACTIVE and then ends with DONE (or COMPLETED in older
  /// captures). The DONE event carries `tool_info.error` when the tool failed.
  /// Pairing uses `tool_id` when present, otherwise the conversation and
  /// `step_index`, which repeat on the start and end events of one step.
  List<ProviderActivityObservation> _normalizeAgyTool(
    Map step, {
    required bool declarativeMatched,
  }) {
    final rawToolInfo = step['tool_info'];
    final toolInfo = rawToolInfo is Map
        ? rawToolInfo
        : const <Object?, Object?>{};
    final rawId = _safeText(step['tool_id']);
    // A tool line that a declarative mapping already matched is owned by that
    // mapping when it has a provider identifier. If the provider omitted the
    // identifier, the adapter must still emit the paired fallback identity so
    // the activity stream cannot leave an unfinishable tool row behind.
    //
    // The AGY Profile mapping keys tool steps by `step_index` when the CLI
    // sends no `tool_id`, so a matched mapping already owns that identity.
    // Emitting the adapter's own composed id as well would report every tool
    // twice under two identifiers.
    final stepIndex = step['step_index'];
    if (declarativeMatched &&
        (rawId != null || (stepIndex is int && stepIndex >= 0))) {
      return const [];
    }

    final state = step['state'];
    final failed =
        const {'FAILED', 'ERROR', 'ERRORED'}.contains(state) ||
        toolInfo['error'] is Map;
    final completed = state == 'DONE' || state == 'COMPLETED';
    final started = state == 'ACTIVE' && !failed;
    if (!failed && !completed && !started) {
      return declarativeMatched
          ? const []
          : _diagnostic('unsupported_tool_state');
    }

    final toolKind =
        _safeText(step['tool_name']) ?? _safeText(toolInfo['name']) ?? 'tool';
    final index = step['step_index'];
    final terminal = failed || completed;
    final String activityId;
    final String identifierSource;
    if (rawId != null) {
      activityId = rawId;
      identifierSource = 'provider';
    } else if (index is int && index >= 0) {
      final conversation = _safeText(step['conversation_id']) ?? 'session';
      final composed = 'agy-step-$conversation-$index';
      activityId = composed.length > 128
          ? composed.substring(0, 128)
          : composed;
      identifierSource = 'step_index';
    } else {
      activityId = _activityId(
        null,
        family: 'agy-tool',
        toolKind: toolKind,
        terminal: terminal,
      );
      identifierSource = 'generated';
    }
    final details = <String, Object?>{
      ..._toolDetails(toolKind),
      if (rawId == null) 'identifierSource': identifierSource,
    };
    final type = failed
        ? 'tool.failed'
        : completed
        ? 'tool.completed'
        : 'tool.started';
    return <ProviderActivityObservation>[
      ProviderActivityObservation(
        type: type,
        status: failed
            ? 'failed'
            : completed
            ? 'completed'
            : 'running',
        title: failed
            ? 'Tool failed'
            : completed
            ? 'Tool completed'
            : 'Running tool',
        activityId: activityId,
        details: details,
      ),
    ];
  }

  List<ProviderActivityObservation> _normalizeCopilot(
    Map event, {
    required bool declarativeMatched,
  }) {
    final type = event['type'];
    if (type is! String) return _diagnostic('missing_event_type');
    switch (type) {
      case 'assistant.turn_start':
        return declarativeMatched
            ? const []
            : const <ProviderActivityObservation>[
                ProviderActivityObservation(
                  type: 'model.started',
                  status: 'running',
                  title: 'Thinking',
                ),
              ];
      case 'assistant.message':
        final data = event['data'];
        if (data is! Map) return const [];
        final content = data['content'];
        if (content is! String && content is! List && content is! Map) {
          return const [];
        }
        final narration = _narrationExcerpt(
          content is String
              ? content
              : content is Map
              ? content['text']
              : _copilotMessageText(content),
        );
        if (narration == null) return const [];
        if (declarativeMatched) return const [];
        final id = _safeText(data['messageId']);
        return <ProviderActivityObservation>[
          _narrationObservation(
            narration,
            activityId: id == null ? null : 'copilot-msg-$id',
          ),
        ];
      case 'tool.execution_start':
        final data = event['data'];
        if (data is! Map) return const [];
        final name = _safeText(data['toolName']) ?? 'tool';
        final id = _safeText(data['toolCallId']);
        if (declarativeMatched && id != null) return const [];
        final summary = _copilotToolSummary(data['arguments']);
        if (id != null) {
          _copilotToolTitles[id] = _copilotToolTitle(name);
          if (summary != null) _copilotToolSummaries[id] = summary;
        }
        return <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: 'tool.started',
            status: 'running',
            title: _copilotToolTitle(name),
            activityId:
                id ??
                _activityId(
                  null,
                  family: 'copilot-tool',
                  toolKind: name,
                  terminal: false,
                ),
            details: {
              ..._toolDetails(name),
              if (summary != null) 'summary': summary,
              if (id == null) 'identifierSource': 'generated',
            },
          ),
        ];
      case 'tool.execution_complete':
        final data = event['data'];
        if (data is! Map) return const [];
        final id = _safeText(data['toolCallId']);
        if (id == null) return const [];
        if (declarativeMatched) return const [];
        final failed = data['success'] == false;
        final runningTitle = _copilotToolTitles.remove(id);
        final summary = _copilotToolSummaries.remove(id);
        return <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: failed ? 'tool.failed' : 'tool.completed',
            status: failed ? 'failed' : 'completed',
            title: _copilotFinishedTitle(runningTitle, failed: failed),
            activityId: id,
            details: {if (summary != null) 'summary': summary},
          ),
        ];
      case 'session.error':
        return const <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: 'model.status',
            status: 'failed',
            title: 'Provider reported an error',
            details: {'diagnostic': 'provider_error'},
          ),
        ];
      case 'assistant.message_delta' ||
          'session.tools_updated' ||
          'assistant.turn_end':
        return const [];
      default:
        return const [];
    }
  }

  /// Claude Code `--output-format stream-json` carries tool calls inside the
  /// `content` array of whole `assistant` and `user` messages, which the
  /// bounded selector grammar cannot index. The adapter reads block types,
  /// tool names and tool identifiers, plus a bounded, secret-masked excerpt of
  /// assistant `text` blocks (the model's own narration). It never reads
  /// thinking, tool input or tool results.
  ///
  /// * `assistant` message: a `tool_use` block starts a tool (keyed by its
  ///   `id`), a `thinking` block reports thinking, a `text` block reports the
  ///   narration (title and `preview` detail), keyed by the message id.
  /// * `user` message: a `tool_result` block finishes the tool named by its
  ///   `tool_use_id`, failed when `is_error` is true.
  ///
  /// The session `init` message reports that the model has started. The final
  /// `result` stays with the Profile's execution events (the adapter only adds
  /// a row for background commands that were still running at that point);
  /// every other event type
  /// (`stream_event`, other `system` notices, rate limits) is progress noise
  /// and is ignored without a diagnostic.
  List<ProviderActivityObservation> _normalizeClaude(Map event) {
    final type = event['type'];
    if (type is! String) return _diagnostic('missing_event_type');
    if (type == 'system' && event['subtype'] == 'init') {
      // A new run: nothing from an earlier one carries over.
      _claudeBackgroundTasks.clear();
      _claudeToolTitles.clear();
      _claudeToolSummaries.clear();
      return const <ProviderActivityObservation>[
        ProviderActivityObservation(
          type: 'model.started',
          status: 'running',
          title: 'Thinking',
        ),
      ];
    }
    if (type == 'system' && event['subtype'] == 'background_tasks_changed') {
      // The authoritative list of commands the agent has running in the
      // background right now (empty when none).
      _claudeBackgroundTasks.clear();
      final tasks = event['tasks'];
      if (tasks is List) {
        for (final task in tasks) {
          final id = task is Map ? _safeText(task['task_id']) : null;
          if (id != null && _claudeBackgroundTasks.length < 16) {
            _claudeBackgroundTasks.add(id);
          }
        }
      }
      return const [];
    }
    if (type == 'result') {
      // The agent ended its turn while background commands were still
      // running; Claude Code stops them right after. Say so, because the
      // work they were doing did not finish. The result itself still stands:
      // a server left running at the end is a normal way to finish.
      final stopped = _claudeBackgroundTasks.take(5).toList(growable: false);
      _claudeBackgroundTasks.clear();
      return <ProviderActivityObservation>[
        for (final id in stopped)
          ProviderActivityObservation(
            type: 'tool.failed',
            status: 'failed',
            title: 'Background command stopped when the agent finished',
            activityId: 'claude-bg-$id',
            details: const {'toolKind': 'background_task'},
          ),
      ];
    }
    if (type != 'assistant' && type != 'user') return const [];
    final message = event['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! List) return const [];
    final messageId = message is Map ? _safeText(message['id']) : null;
    final observations = <ProviderActivityObservation>[];
    for (final block in content) {
      if (block is! Map) continue;
      final blockType = block['type'];
      if (type == 'assistant') {
        switch (blockType) {
          case 'tool_use':
            final id = _safeText(block['id']);
            final name = _safeText(block['name']) ?? 'tool';
            if (id != null) {
              if (_claudeToolTitles.length >= 256) {
                _claudeToolTitles.clear();
                _claudeToolSummaries.clear();
              }
              _claudeToolTitles[id] = _claudeToolTitle(name);
              final summary = _claudeToolSummary(block['input']);
              if (summary != null) {
                _claudeToolSummaries[id] = summary;
              } else {
                _claudeToolSummaries.remove(id);
              }
            }
            final startSummary = _claudeToolSummary(block['input']);
            observations.add(
              ProviderActivityObservation(
                type: 'tool.started',
                status: 'running',
                title: _claudeToolTitle(name),
                activityId:
                    id ??
                    _activityId(
                      null,
                      family: 'claude-tool',
                      toolKind: name,
                      terminal: false,
                    ),
                details: {
                  ..._toolDetails(name),
                  if (startSummary != null) 'summary': startSummary,
                  if (id == null) 'identifierSource': 'generated',
                },
              ),
            );
          case 'thinking' || 'redacted_thinking':
            observations.add(
              const ProviderActivityObservation(
                type: 'model.status',
                status: 'updated',
                title: 'Thinking',
              ),
            );
          case 'text':
            final narration = _narrationExcerpt(block['text']);
            observations.add(
              ProviderActivityObservation(
                type: 'message.updated',
                status: 'updated',
                title: narration == null
                    ? 'Writing the response'
                    : _narrationTitle(narration),
                // One id per Claude message: later updates of the same
                // message replace it instead of adding another row.
                activityId: messageId == null ? null : 'claude-msg-$messageId',
                details: {
                  if (narration != null) 'preview': narration,
                  if (narration != null && narration.endsWith('…'))
                    'previewTruncated': true,
                },
              ),
            );
        }
      } else if (blockType == 'tool_result') {
        final id = _safeText(block['tool_use_id']);
        if (id == null) continue;
        final failed = block['is_error'] == true;
        observations.add(
          ProviderActivityObservation(
            type: failed ? 'tool.failed' : 'tool.completed',
            status: failed ? 'failed' : 'completed',
            title: _claudeFinishedTitle(
              _claudeToolTitles.remove(id),
              failed: failed,
            ),
            activityId: id,
            details: {
              if (_claudeToolSummaries.remove(id) case final summary?)
                'summary': summary,
            },
          ),
        );
      }
    }
    return observations;
  }

  static const int _narrationPreviewLimit = 1500;
  static const int _narrationTitleLimit = 160;

  /// A bounded, single-line, secret-masked excerpt of the model's own
  /// narration. Tool input and tool results are never read; only assistant
  /// `text` blocks reach this method. Returns null for blank text.
  String? _narrationExcerpt(Object? raw) {
    if (raw is! String) return null;
    var text = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
    if (text.isEmpty) return null;
    // Keep the words, drop markdown noise: [name](file:///long/path) -> name.
    text = text
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^)]*\)'),
          (match) => match.group(1)!,
        )
        // A link cut off by a partial stream: "[name](file:///va" or "[na".
        .replaceFirst(RegExp(r'\[[^\]]*(\]\([^)]*)?$'), '')
        .replaceAll('**', '')
        .replaceAll(RegExp(r' {2,}'), ' ')
        .trim();
    if (text.isEmpty) return null;
    text = _redactSecrets(text);
    if (text.length > _narrationPreviewLimit) {
      text = '${text.substring(0, _narrationPreviewLimit - 1).trimRight()}…';
    }
    return text;
  }

  String _narrationTitle(String narration) {
    if (narration.length <= _narrationTitleLimit) return narration;
    return '${narration.substring(0, _narrationTitleLimit - 1).trimRight()}…';
  }

  static final List<RegExp> _secretPatterns = <RegExp>[
    RegExp(r'sk-[A-Za-z0-9_-]{16,}'),
    RegExp(r'gh[pousr]_[A-Za-z0-9]{20,}'),
    RegExp(r'AKIA[0-9A-Z]{16}'),
    RegExp(r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'),
    RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{16,}', caseSensitive: false),
    RegExp(
      r'(api[_-]?key|secret|token|password|passwd)(\s*[:=]\s*)\S{6,}',
      caseSensitive: false,
    ),
  ];

  String _redactSecrets(String text) {
    var out = text;
    for (final pattern in _secretPatterns) {
      out = out.replaceAllMapped(pattern, (match) {
        if (match.groupCount >= 2 && match.group(1) != null) {
          return '${match.group(1)}${match.group(2)}[redacted]';
        }
        return '[redacted]';
      });
    }
    return out;
  }

  /// Title and short `summary` for a tool row the Profile mapping produced.
  /// Dispatches by provider; null when the adapter has nothing better to say.
  ({String title, String? summary})? toolPresentation(
    Map event,
    String mappedType,
  ) {
    if (!mappedType.startsWith('tool.')) return null;
    return switch (kind) {
      'agy-stream-json' => agyToolPresentation(event, mappedType),
      'codex-jsonl' => _codexToolPresentation(event, mappedType),
      'copilot-jsonl' => _copilotToolPresentation(event, mappedType),
      _ => null,
    };
  }

  /// One line, control characters removed, secrets masked, at most 100
  /// characters. Paths keep only their last segment.
  String? _shortSummary(Object? raw, {bool path = false}) {
    if (raw is! String) return null;
    var text = raw.replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ').trim();
    if (text.isEmpty) return null;
    if (path) {
      final parts = text.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
      if (parts.isNotEmpty) text = parts.last;
    }
    text = _redactSecrets(text);
    if (text.length > 100) text = '${text.substring(0, 99).trimRight()}…';
    return text;
  }

  ({String title, String? summary})? _codexToolPresentation(
    Map event,
    String mappedType,
  ) {
    final item = event['item'];
    if (item is! Map) return null;
    final (running, done, failed) = switch (item['type']) {
      'command_execution' => (
        'Running a command',
        'Ran a command',
        'Command failed',
      ),
      'file_change' => (
        'Editing files',
        'Edited files',
        'Editing files failed',
      ),
      'web_search' || 'web_search_call' => (
        'Searching the web',
        'Searched the web',
        'Web search failed',
      ),
      'mcp_tool_call' => (
        'Using a connected tool',
        'Used a connected tool',
        'Connected tool failed',
      ),
      _ => ('Running a tool', 'Tool completed', 'Tool failed'),
    };
    final title = switch (mappedType) {
      'tool.started' => running,
      'tool.failed' => failed,
      _ => done,
    };
    String? summary;
    switch (item['type']) {
      case 'command_execution':
        summary = _shortSummary(item['command']);
      case 'file_change':
        final changes = item['changes'];
        if (changes is List && changes.isNotEmpty) {
          final first = changes.first;
          summary = _shortSummary(
            first is Map ? first['path'] : null,
            path: true,
          );
          if (summary != null && changes.length > 1) {
            summary = '$summary +${changes.length - 1} more';
          }
        }
      case 'web_search' || 'web_search_call':
        summary = _shortSummary(item['query']);
      case 'mcp_tool_call':
        summary = _shortSummary(item['tool']);
    }
    return (title: title, summary: summary);
  }

  ({String title, String? summary})? _copilotToolPresentation(
    Map event,
    String mappedType,
  ) {
    final data = event['data'];
    if (data is! Map) return null;
    final name = _safeText(data['toolName']) ?? 'tool';
    final runningTitle = _copilotToolTitle(name);
    final title = switch (mappedType) {
      'tool.started' => runningTitle,
      'tool.failed' => _copilotFinishedTitle(runningTitle, failed: true),
      _ => _copilotFinishedTitle(runningTitle, failed: false),
    };
    final summary = _copilotToolSummary(data['arguments']);
    return (title: title, summary: summary);
  }

  /// Friendlier title and one short `summary` for an agy tool row that the
  /// Profile mapping produced. Returns null for non-agy adapters and events
  /// that are not tool steps. The summary is one line, secret-masked and
  /// bounded: a file name, a search term or the start of a shell command.
  ({String title, String? summary})? agyToolPresentation(
    Map event,
    String mappedType,
  ) {
    if (kind != 'agy-stream-json' || event['event'] != 'step_update') {
      return null;
    }
    final step = event['step_update'];
    if (step is! Map || !mappedType.startsWith('tool.')) return null;
    final name = _safeText(step['tool_name']) ?? '';
    final (running, done, failed) = switch (name) {
      'run_command' || 'command_status' || 'send_command_input' => (
        'Running a command',
        'Ran a command',
        'Command failed',
      ),
      'view_file' || 'view_file_outline' || 'read_url_content' => (
        'Reading a file',
        'Read a file',
        'Reading a file failed',
      ),
      'write_to_file' => (
        'Writing a file',
        'Wrote a file',
        'Writing a file failed',
      ),
      'replace_file_content' || 'multi_replace_file_content' || 'edit_file' => (
        'Editing a file',
        'Edited a file',
        'Editing a file failed',
      ),
      'grep_search' || 'find_by_name' || 'list_dir' || 'codebase_search' => (
        'Searching files',
        'Searched files',
        'Search failed',
      ),
      'search_web' => (
        'Searching the web',
        'Searched the web',
        'Web search failed',
      ),
      _ => ('Running a tool', 'Tool completed', 'Tool failed'),
    };
    final title = switch (mappedType) {
      'tool.started' => running,
      'tool.failed' => failed,
      _ => done,
    };
    final info = step['tool_info'];
    final params = info is Map && info['parameters'] is Map
        ? info['parameters'] as Map
        : const <Object?, Object?>{};
    String? summary;
    for (final key in const [
      'CommandLine',
      'TargetFile',
      'AbsolutePath',
      'FilePath',
      'Path',
      'SearchPath',
      'DirectoryPath',
      'Query',
      'Pattern',
      'Url',
    ]) {
      final value = params[key];
      if (value is! String || value.trim().isEmpty) continue;
      final isPath = key.endsWith('File') || key.endsWith('Path');
      var text = value
          .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
          .trim();
      if (isPath) {
        final parts = text.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
        if (parts.isNotEmpty) text = parts.last;
      }
      text = _redactSecrets(text);
      if (text.length > 100) text = '${text.substring(0, 99).trimRight()}…';
      summary = text;
      break;
    }
    return (title: title, summary: summary);
  }

  /// The text of the last assistant step, for providers whose final result can
  /// arrive empty although the answer was streamed (agy). Null otherwise.
  String? streamedAnswer(List<Object?> events) {
    if (kind != 'agy-stream-json') return null;
    final order = <String>[];
    final texts = <String, StringBuffer>{};
    for (final event in events) {
      if (event is! Map || event['event'] != 'step_update') continue;
      final step = event['step_update'];
      if (step is! Map || step['step_type'] != 'agent_response') continue;
      final index = step['step_index'];
      if (index is! int || index < 0) continue;
      final key = '${_safeText(step['conversation_id']) ?? ''}:$index';
      final buffer = texts.putIfAbsent(key, () {
        order.add(key);
        return StringBuffer();
      });
      final delta = step['text_delta'];
      if (delta is String) buffer.write(delta);
    }
    for (final key in order.reversed) {
      final text = texts[key].toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  /// agy's final `response` repeats the text of every earlier assistant step
  /// (the narration already shown live). Returns [finalText] without that
  /// leading narration, or null when nothing can be safely removed.
  String? answerAfterNarration(List<Object?> events, String finalText) {
    if (kind != 'agy-stream-json') return null;
    final order = <String>[];
    final texts = <String, StringBuffer>{};
    for (final event in events) {
      if (event is! Map || event['event'] != 'step_update') continue;
      final step = event['step_update'];
      if (step is! Map || step['step_type'] != 'agent_response') continue;
      final index = step['step_index'];
      if (index is! int || index < 0) continue;
      final key = '${_safeText(step['conversation_id']) ?? ''}:$index';
      final buffer = texts.putIfAbsent(key, () {
        order.add(key);
        return StringBuffer();
      });
      final delta = step['text_delta'];
      if (delta is String) buffer.write(delta);
    }
    if (order.length < 2) return null;
    final earlier = order
        .take(order.length - 1)
        .map((key) => texts[key].toString())
        .join();
    // Compare ignoring whitespace: the CLI joins steps with its own spacing.
    var i = 0;
    var j = 0;
    bool space(int unit) =>
        unit == 0x20 || unit == 0x0a || unit == 0x0d || unit == 0x09;
    while (true) {
      while (j < earlier.length && space(earlier.codeUnitAt(j))) {
        j++;
      }
      if (j >= earlier.length) break;
      while (i < finalText.length && space(finalText.codeUnitAt(i))) {
        i++;
      }
      if (i >= finalText.length ||
          finalText.codeUnitAt(i) != earlier.codeUnitAt(j)) {
        return null;
      }
      i++;
      j++;
    }
    final rest = finalText.substring(i).trim();
    return rest.isEmpty ? null : rest;
  }

  // Grok Build `--output-format streaming-json` sends the answer only as
  // `text` chunks; the Profile builds the final text declaratively with
  // `append_final_text` / `clear_final_text`. The adapter reports activity.
  final _NarrationBuffer _grokText = _NarrationBuffer();
  var _grokSegment = 0;
  var _grokThinking = false;
  final Map<String, String> _grokToolTitles = <String, String>{};
  final Map<String, String> _grokToolSummaries = <String, String>{};

  /// Grok streams thoughts and text a few characters at a time. Thinking is
  /// reported once per stretch of thought; text is joined per segment (the
  /// text between tool calls) and re-reported at most once per
  /// [narrationInterval]. Tool rows use the provider `toolCallId`. Only tool
  /// names and a few well-known input keys are read; thought text, tool
  /// output and file contents never are.
  List<ProviderActivityObservation> _normalizeGrok(Map event) {
    final type = event['type'];
    if (type is! String) return _diagnostic('missing_event_type');
    switch (type) {
      case 'thought':
        if (_grokThinking) return const [];
        _grokThinking = true;
        return const <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: 'model.status',
            status: 'updated',
            title: 'Thinking',
          ),
        ];
      case 'text':
        _grokThinking = false;
        final delta = event['data'];
        if (delta is String && _grokText.text.length < _maxNarrationBuffer) {
          _grokText.text.write(delta);
        }
        final last = _grokText.lastEmittedAt;
        final now = clock();
        if (last != null && now.difference(last) < narrationInterval) {
          return const [];
        }
        return _grokNarration(now);
      case 'tool_call':
        _grokThinking = false;
        final flushed = _grokNarration(clock());
        _grokSegment += 1;
        _grokText.text.clear();
        _grokText.lastEmitted = null;
        _grokText.lastEmittedAt = null;
        final name = _safeText(event['toolName']) ?? 'tool';
        final id = _safeText(event['toolCallId']);
        final title = _grokToolTitle(name);
        final summary = _grokToolSummary(event['rawInput']);
        if (id != null) {
          if (_grokToolTitles.length >= 256) {
            _grokToolTitles.clear();
            _grokToolSummaries.clear();
          }
          _grokToolTitles[id] = title;
          if (summary != null) _grokToolSummaries[id] = summary;
        }
        return <ProviderActivityObservation>[
          ...flushed,
          ProviderActivityObservation(
            type: 'tool.started',
            status: 'running',
            title: title,
            activityId:
                id ??
                _activityId(
                  null,
                  family: 'grok-tool',
                  toolKind: name,
                  terminal: false,
                ),
            details: {
              ..._toolDetails(name),
              if (summary != null) 'summary': summary,
              if (id == null) 'identifierSource': 'generated',
            },
          ),
        ];
      case 'tool_call_update':
        final status = event['status'];
        if (status != 'completed' && status != 'failed') return const [];
        final id = _safeText(event['toolCallId']);
        if (id == null) return const [];
        final failed = status == 'failed';
        final title = _grokToolTitles.remove(id);
        final summary = _grokToolSummaries.remove(id);
        return <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: failed ? 'tool.failed' : 'tool.completed',
            status: failed ? 'failed' : 'completed',
            title: _claudeFinishedTitle(title, failed: failed),
            activityId: id,
            details: {if (summary != null) 'summary': summary},
          ),
        ];
      case 'end':
        final flushed = _grokNarration(clock());
        _grokText.text.clear();
        _grokText.lastEmitted = null;
        _grokText.lastEmittedAt = null;
        _grokSegment = 0;
        _grokThinking = false;
        _grokToolTitles.clear();
        _grokToolSummaries.clear();
        return flushed;
      case 'error':
        return const <ProviderActivityObservation>[
          ProviderActivityObservation(
            type: 'model.status',
            status: 'failed',
            title: 'Provider reported an error',
            details: {'diagnostic': 'provider_error'},
          ),
        ];
      case 'usage' || 'available_commands':
        return const [];
    }
    return _diagnostic('unsupported_event');
  }

  List<ProviderActivityObservation> _grokNarration(DateTime now) {
    final narration = _narrationExcerpt(_grokText.text.toString());
    if (narration == null || narration == _grokText.lastEmitted) {
      return const [];
    }
    _grokText.lastEmittedAt = now;
    _grokText.lastEmitted = narration;
    return <ProviderActivityObservation>[
      _narrationObservation(narration, activityId: 'grok-msg-$_grokSegment'),
    ];
  }

  /// A fixed, user-facing title for a Grok Build tool name. The titles match
  /// the Claude ones so finished rows reuse [_claudeFinishedTitle].
  String _grokToolTitle(String name) => switch (name) {
    'run_terminal_command' ||
    'get_command_or_subagent_output' ||
    'kill_command_or_subagent' ||
    'monitor' => 'Running a command',
    'read_file' || 'list_dir' || 'grep' => 'Reading files',
    'search_replace' || 'write' => 'Editing files',
    'web_search' || 'web_fetch' => 'Searching the web',
    'spawn_subagent' => 'Working with a sub-agent',
    'todo_write' => 'Updating the plan',
    'use_tool' || 'search_tool' => 'Using a connected tool',
    _ => 'Running a tool',
  };

  String? _grokToolSummary(Object? input) {
    if (input is! Map) return null;
    for (final key in const ['command', 'pattern', 'query', 'url']) {
      final value = _shortSummary(input[key]);
      if (value != null) return value;
    }
    for (final key in const [
      'target_file',
      'file_path',
      'target_directory',
      'path',
    ]) {
      final value = _shortSummary(input[key], path: true);
      if (value != null) return value;
    }
    return _shortSummary(input['description']);
  }

  /// Ids of Claude background commands that are running right now.
  final Set<String> _claudeBackgroundTasks = <String>{};

  /// Running tool titles by `tool_use` id, so the completion row can say what
  /// finished instead of a generic "Tool finished".
  final Map<String, String> _claudeToolTitles = <String, String>{};

  /// Short descriptions of running Claude tools, for the completion row.
  final Map<String, String> _claudeToolSummaries = <String, String>{};

  /// Titles and summaries for Copilot tools so the completion row can say what
  /// completed instead of a generic "Tool finished".
  final Map<String, String> _copilotToolTitles = <String, String>{};
  final Map<String, String> _copilotToolSummaries = <String, String>{};

  /// A file name, search term or the start of a command from a `tool_use`
  /// input. Only these well-known keys are read; the result is masked.
  String? _claudeToolSummary(Object? input) {
    if (input is! Map) return null;
    for (final key in const ['command', 'pattern', 'query', 'url']) {
      final value = _shortSummary(input[key]);
      if (value != null) return value;
    }
    for (final key in const ['file_path', 'path', 'notebook_path']) {
      final value = _shortSummary(input[key], path: true);
      if (value != null) return value;
    }
    return _shortSummary(input['description']);
  }

  String _copilotToolTitle(String name) => switch (name.toLowerCase()) {
    'bash' || 'shell' || 'command' || 'run' => 'Running a command',
    'view' || 'read' || 'ls' || 'glob' || 'grep' => 'Reading files',
    'create' ||
    'write' ||
    'edit' ||
    'apply_patch' ||
    'patch' => 'Editing files',
    'search' || 'web_search' || 'fetch' || 'lookup' => 'Searching the web',
    _ => 'Running a tool',
  };

  String _copilotFinishedTitle(String? runningTitle, {required bool failed}) {
    final done = switch (runningTitle) {
      'Running a command' => 'Ran a command',
      'Reading files' => 'Read files',
      'Editing files' => 'Edited files',
      'Searching the web' => 'Searched the web',
      null => 'Tool finished',
      _ => 'Tool finished',
    };
    if (!failed) return done;
    return switch (runningTitle) {
      'Running a command' => 'Command failed',
      'Reading files' => 'Reading files failed',
      'Editing files' => 'Editing files failed',
      'Searching the web' => 'Web search failed',
      null => 'Tool failed',
      _ => 'Tool failed',
    };
  }

  String? _copilotToolSummary(Object? raw) {
    if (raw is! Map) return null;
    for (final key in const ['command', 'pattern', 'query', 'url']) {
      final value = _shortSummary(raw[key]);
      if (value != null) return value;
    }
    for (final key in const ['path', 'file_path', 'file', 'target']) {
      final value = _shortSummary(raw[key], path: true);
      if (value != null) return value;
    }
    return _shortSummary(raw['description']);
  }

  String? _copilotMessageText(Object? value) {
    if (value is List) {
      final parts = <String>[];
      for (final entry in value) {
        if (entry is Map && entry['text'] is String) {
          final text = entry['text'] as String;
          if (text.trim().isNotEmpty) parts.add(text);
        }
      }
      return parts.isEmpty ? null : parts.join();
    }
    if (value is Map && value['text'] is String) {
      final text = value['text'] as String;
      return text.trim().isEmpty ? null : text;
    }
    return null;
  }

  String _claudeFinishedTitle(String? runningTitle, {required bool failed}) {
    final done = switch (runningTitle) {
      'Running a command' => 'Ran a command',
      'Reading files' => 'Read files',
      'Editing files' => 'Edited files',
      'Searching the web' => 'Searched the web',
      'Working with a sub-agent' => 'Sub-agent finished',
      'Updating the plan' => 'Updated the plan',
      'Using a connected tool' => 'Used a connected tool',
      _ => 'Tool finished',
    };
    if (!failed) return done;
    return switch (runningTitle) {
      'Running a command' => 'Command failed',
      'Using a connected tool' => 'Connected tool failed',
      null => 'Tool failed',
      _ => '${done == 'Tool finished' ? 'Tool' : done} failed',
    };
  }

  /// A fixed, user-facing title for a Claude Code tool name. Only the tool
  /// name is inspected; unknown tools get a generic title.
  String _claudeToolTitle(String name) {
    if (name.startsWith('mcp__')) return 'Using a connected tool';
    return switch (name) {
      'Bash' || 'BashOutput' || 'KillShell' => 'Running a command',
      'Read' || 'Glob' || 'Grep' || 'LS' => 'Reading files',
      'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => 'Editing files',
      'WebSearch' || 'WebFetch' => 'Searching the web',
      'Task' || 'Agent' => 'Working with a sub-agent',
      'TodoWrite' => 'Updating the plan',
      _ => 'Running a tool',
    };
  }

  Map<String, Object?> _toolDetails(String toolKind) => {
    'toolKind': toolKind.length > 64 ? toolKind.substring(0, 64) : toolKind,
  };

  String _activityId(
    Object? raw, {
    required String family,
    required String toolKind,
    required bool terminal,
    bool reusePending = false,
  }) {
    final id = _safeText(raw);
    if (id != null) {
      return id.length > 128 ? id.substring(0, 128) : id;
    }
    final key = '$family:$toolKind';
    if (!terminal && reusePending) {
      final pending = _pendingFallbackIds[key];
      if (pending != null && pending.isNotEmpty) return pending.first;
    }
    if (terminal) {
      final pending = _pendingFallbackIds[key];
      if (pending != null && pending.isNotEmpty) return pending.removeAt(0);
    }
    final occurrence = (_fallbackCounts[key] ?? 0) + 1;
    _fallbackCounts[key] = occurrence;
    final digest = sha256.convert(utf8.encode('$kind:$key')).toString();
    final generated = '$family-${digest.substring(0, 12)}-$occurrence';
    if (!terminal) {
      _pendingFallbackIds.putIfAbsent(key, () => <String>[]).add(generated);
    }
    return generated;
  }

  List<ProviderActivityObservation> _diagnostic(String reason) {
    if (!_reportedDiagnostics.add(reason)) return const [];
    return <ProviderActivityObservation>[
      ProviderActivityObservation(
        type: 'model.status',
        status: 'updated',
        title: 'Provider activity needs attention',
        details: {'diagnostic': reason},
      ),
    ];
  }

  String? _safeText(Object? value) {
    if (value is! String || value.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) return null;
    return value.length > 128 ? value.substring(0, 128) : value;
  }
}

class _NarrationBuffer {
  final StringBuffer text = StringBuffer();
  DateTime? lastEmittedAt;
  String? lastEmitted;
}
