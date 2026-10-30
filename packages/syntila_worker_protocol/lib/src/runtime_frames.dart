import 'discovered_models.dart';
import 'dart:convert';

import 'initialize_frames.dart';
import 'limits.dart';
import 'protocol_version.dart';
import 'worker_issue_codes.dart';

/// Internal WorkerProgress control marker emitted once the Engine has started
/// the provider process. Host supervisors consume it for deterministic tests
/// and do not forward it as user-facing progress.
const workerProviderExecutionStartedMessage =
    'syntila.engine.provider_execution_started.v1';

enum WorkerProbeMode { passive, live }

enum WorkerSessionPolicy { stateless, durableSession }

enum ProbeCheckStatus { passed, failed, warning }

final class ProbeRequest extends WorkerFrame {
  ProbeRequest({
    required super.requestId,
    required this.mode,
    this.timeoutMs = WorkerProtocolLimits.maxProbeTimeoutMs,
    this.protocolVersion = localWorkerProtocolVersion,
  }) {
    _validateProtocol(protocolVersion);
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (timeoutMs < 100 || timeoutMs > WorkerProtocolLimits.maxProbeTimeoutMs) {
      throw const FormatException('probe timeout is outside the allowed range');
    }
  }

  final String protocolVersion;

  /// `passive` guarantees no provider model request; `live` may consume quota.
  final WorkerProbeMode mode;
  final int timeoutMs;

  @override
  String get type => 'probe.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'mode': mode.name,
        'timeoutMs': timeoutMs,
      };

  factory ProbeRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'type', 'protocolVersion', 'requestId', 'mode', 'timeoutMs'},
    );
    _expectType(json, 'probe.request');
    final mode = _requiredString(json, 'mode');
    return ProbeRequest(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      protocolVersion: _requiredString(json, 'protocolVersion'),
      mode: WorkerProbeMode.values.firstWhere(
        (candidate) => candidate.name == mode,
        orElse: () =>
            throw const FormatException('probe mode must be passive or live'),
      ),
      timeoutMs: _probeTimeout(json),
    );
  }
}

int _probeTimeout(Map<String, Object?> json) {
  final value = json['timeoutMs'] ?? WorkerProtocolLimits.maxProbeTimeoutMs;
  if (value is! int ||
      value < 100 ||
      value > WorkerProtocolLimits.maxProbeTimeoutMs) {
    throw const FormatException('probe timeout is outside the allowed range');
  }
  return value;
}

/// Asks the Engine to run the Profile-owned usage command. The Engine only
/// executes the command declared by the admitted Profile; the request carries
/// no arguments.
final class UsageRequest extends WorkerFrame {
  UsageRequest({
    required super.requestId,
    this.timeoutMs = WorkerProtocolLimits.maxUsageTimeoutMs,
    this.protocolVersion = localWorkerProtocolVersion,
  }) {
    _validateProtocol(protocolVersion);
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (timeoutMs < 1000 ||
        timeoutMs > WorkerProtocolLimits.maxUsageTimeoutMs) {
      throw const FormatException('usage timeout is outside the allowed range');
    }
  }

  final String protocolVersion;
  final int timeoutMs;

  @override
  String get type => 'usage.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'timeoutMs': timeoutMs,
      };

  factory UsageRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {'type', 'protocolVersion', 'requestId', 'timeoutMs'},
    );
    _expectType(json, 'usage.request');
    final timeout = json['timeoutMs'];
    if (timeout is! int) {
      throw const FormatException('usage timeout must be an integer');
    }
    return UsageRequest(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      protocolVersion: _requiredString(json, 'protocolVersion'),
      timeoutMs: timeout,
    );
  }
}

/// Raw provider usage report. [output] is exactly what the provider command
/// printed (ANSI escapes removed, bounded in size); it is never interpreted.
final class UsageResult extends WorkerFrame {
  UsageResult({
    required super.requestId,
    required this.output,
    required this.errorOutput,
    required this.exitCode,
    this.truncated = false,
  }) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (output.length > WorkerProtocolLimits.maxUsageOutputChars ||
        errorOutput.length > WorkerProtocolLimits.maxUsageOutputChars) {
      throw const FormatException('usage output exceeds the size limit');
    }
  }

  final String output;
  final String errorOutput;
  final int exitCode;
  final bool truncated;

  @override
  String get type => 'usage.result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'output': output,
        'errorOutput': errorOutput,
        'exitCode': exitCode,
        'truncated': truncated,
      };

  factory UsageResult.fromJson(Map<String, Object?> json) {
    _expectKeys(
      json,
      const {
        'type',
        'requestId',
        'output',
        'errorOutput',
        'exitCode',
        'truncated',
      },
    );
    _expectType(json, 'usage.result');
    final exitCode = json['exitCode'];
    final truncated = json['truncated'];
    if (exitCode is! int || truncated is! bool) {
      throw const FormatException('usage result fields are invalid');
    }
    return UsageResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      output: _requiredStringAllowEmpty(json, 'output'),
      errorOutput: _requiredStringAllowEmpty(json, 'errorOutput'),
      exitCode: exitCode,
      truncated: truncated,
    );
  }
}

final class ProviderToolInfo {
  ProviderToolInfo({required String name, String? version, String? path})
      : name = _boundedText(
          name,
          'tool name',
          WorkerProtocolLimits.maxProviderToolNameLength,
        ),
        version = version == null
            ? null
            : _boundedText(
                version,
                'tool version',
                WorkerProtocolLimits.maxProviderToolVersionLength,
              ),
        path = path;

  final String name;
  final String? version;

  /// Local diagnostics only. Never include this field in Cloud inventory.
  final String? path;

  Map<String, Object?> toJson() => {
        'name': name,
        if (version != null) 'version': version,
      };

  factory ProviderToolInfo.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'name', 'version'});
    return ProviderToolInfo(
      name: _requiredString(json, 'name'),
      version: _optionalString(json, 'version'),
      path: _optionalString(json, 'path'),
    );
  }
}

final class ProbeCheck {
  ProbeCheck({
    required String code,
    required this.status,
    required String message,
  })  : code = _boundedText(
          code,
          'check code',
          WorkerProtocolLimits.maxCheckCodeLength,
        ),
        message = _safeBoundedText(
          message,
          'check message',
          WorkerProtocolLimits.maxCheckMessageLength,
        ) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(this.code)) {
      throw const FormatException(
        'check code must be a stable lowercase issue identifier',
      );
    }
  }

  final String code;
  final ProbeCheckStatus status;
  final String message;

  Map<String, Object?> toJson() => {
        'code': code,
        'status': status.name,
        'message': message,
      };

  factory ProbeCheck.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {'code', 'status', 'message'});
    final status = _requiredString(json, 'status');
    return ProbeCheck(
      code: _requiredString(json, 'code'),
      status: ProbeCheckStatus.values.firstWhere(
        (candidate) => candidate.name == status,
        orElse: () => throw const FormatException('invalid probe check status'),
      ),
      message: _requiredString(json, 'message'),
    );
  }
}

final class ProbeResult extends WorkerFrame {
  ProbeResult({
    required super.requestId,
    required this.mode,
    required this.ready,
    required Iterable<ProbeCheck> checks,
    this.modelCatalog,
    ProviderToolInfo? tool,
    String? providerToolName,
    String? providerToolVersion,
    String? issueCode,
    String? diagnostics,
  })  : providerToolName = (providerToolName ?? tool?.name) == null
            ? null
            : _safeToolName(providerToolName ?? tool!.name),
        providerToolVersion = (providerToolVersion ?? tool?.version) == null
            ? null
            : _safeToolVersion(providerToolVersion ?? tool!.version!),
        checks = List.unmodifiable(checks),
        issueCode = issueCode == null
            ? null
            : _boundedText(
                issueCode,
                'issueCode',
                WorkerProtocolLimits.maxCheckCodeLength,
              ),
        diagnostics = diagnostics == null
            ? null
            : _safeBoundedText(
                diagnostics,
                'diagnostics',
                WorkerProtocolLimits.maxDiagnosticLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (this.checks.length > WorkerProtocolLimits.maxProbeChecks) {
      throw const FormatException('too many probe checks');
    }
    if (!ready && this.issueCode == null) {
      throw const FormatException(
        'a not-ready probe result requires an issueCode',
      );
    }
    if (this.providerToolName == null && this.providerToolVersion != null) {
      throw const FormatException(
        'providerToolVersion requires providerToolName',
      );
    }
    if (this.issueCode != null && !WorkerIssueCode.isKnown(this.issueCode!)) {
      throw const FormatException('issueCode is not a supported stable code');
    }
  }

  final WorkerProbeMode mode;
  final bool ready;
  final String? providerToolName;
  final String? providerToolVersion;
  @Deprecated('Use providerToolName and providerToolVersion')
  ProviderToolInfo? get tool => providerToolName == null
      ? null
      : ProviderToolInfo(name: providerToolName!, version: providerToolVersion);
  final DiscoveredModelCatalog? modelCatalog;
  final List<ProbeCheck> checks;
  final String? issueCode;
  final String? diagnostics;

  @override
  String get type => 'probe.result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'mode': mode.name,
        'ready': ready,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        if (modelCatalog != null) 'modelCatalog': modelCatalog!.toJson(),
        'checks': checks.map((check) => check.toJson()).toList(growable: false),
        'issueCode': issueCode,
        'diagnostics': diagnostics,
      };

  factory ProbeResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'mode',
      'ready',
      'providerToolName',
      'providerToolVersion',
      'checks',
      'modelCatalog',
      'issueCode',
      'diagnostics',
    });
    _expectType(json, 'probe.result');
    if (json['modelCatalog'] != null && json['modelCatalog'] is! Map)
      throw const FormatException('modelCatalog must be an object');
    final rawMode = _requiredString(json, 'mode');
    final rawReady = json['ready'];
    final rawToolName = json['providerToolName'];
    final rawToolVersion = json['providerToolVersion'];
    final rawChecks = json['checks'];
    if (rawReady is! bool)
      throw const FormatException('ready must be a boolean');
    if (rawToolName != null && rawToolName is! String)
      throw const FormatException('providerToolName must be a string or null');
    if (rawToolVersion != null && rawToolVersion is! String)
      throw const FormatException(
          'providerToolVersion must be a string or null');
    if (rawToolName == null && rawToolVersion != null)
      throw const FormatException(
          'providerToolVersion requires providerToolName');
    if (rawChecks is! List ||
        rawChecks.length > WorkerProtocolLimits.maxProbeChecks) {
      throw const FormatException('checks must be a bounded array');
    }
    return ProbeResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      mode: _parseProbeMode(rawMode),
      ready: rawReady,
      modelCatalog: json['modelCatalog'] == null
          ? null
          : DiscoveredModelCatalog.fromJson(
              Map<String, Object?>.from(json['modelCatalog'] as Map)),
      providerToolName: rawToolName as String?,
      providerToolVersion: rawToolVersion as String?,
      checks: rawChecks.map((check) {
        if (check is! Map)
          throw const FormatException('each check must be an object');
        return ProbeCheck.fromJson(Map<String, Object?>.from(check));
      }).toList(growable: false),
      issueCode: _optionalString(json, 'issueCode'),
      diagnostics: _optionalString(json, 'diagnostics'),
    );
  }
}

/// Syntila-owned identity and context target. Native handles are local-only.
final class ConversationBootstrap {
  ConversationBootstrap(
      {required this.conversationId,
      required this.contextRevision,
      required this.throughSequence,
      required this.text,
      this.turnRevision}) {
    if (turnRevision != null &&
        (turnRevision != contextRevision + 1 ||
            turnRevision! > 9007199254740991)) {
      throw const FormatException("Invalid bootstrap turn revision");
    }
    if (conversationId.isEmpty ||
        conversationId.length > 128 ||
        contextRevision < 0 ||
        contextRevision > 9007199254740991 ||
        throughSequence < 0 ||
        throughSequence > 9007199254740991 ||
        text.isEmpty ||
        utf8.encode(text).length > 256 * 1024) {
      throw const FormatException('Invalid canonical Conversation bootstrap');
    }
  }
  String? deltaAfter(int revision, int throughSequenceAlreadyConsumed,
      {String? knownWorkerSessionId}) {
    if (turnRevision == null) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map ||
        decoded['conversationId'] != conversationId ||
        decoded['throughSequence'] != throughSequence ||
        decoded['history'] is! List) {
      throw const FormatException('Invalid canonical history envelope');
    }
    final missing = <Map>[];
    var previousSequence = 0;
    for (final raw in decoded['history'] as List) {
      if (raw is! Map ||
          raw['sequence'] is! int ||
          raw['contextRevision'] is! int ||
          (raw['metadata'] != null && raw['metadata'] is! Map) ||
          (raw['sequence'] as int) <= previousSequence ||
          raw['sequence'] > throughSequence ||
          raw['contextRevision'] < 0 ||
          raw['contextRevision'] > contextRevision) {
        throw const FormatException('Invalid canonical history entry');
      }
      previousSequence = raw['sequence'] as int;
      // Revision bookkeeping adds no provider context and must not defeat the
      // current-session fast path on every accepted request.
      if (raw['eventType'] == 'context.revision_advanced') continue;
      if (raw['contextRevision'] > revision ||
          (raw['sequence'] > throughSequenceAlreadyConsumed &&
              (raw['kind'] == 'context_event' ||
                  raw['kind'] == 'artifact_event' ||
                  raw['contextRevision'] == 0 ||
                  (raw['kind'] == 'worker_response' &&
                      (knownWorkerSessionId == null ||
                          (raw['metadata'] as Map?)?['workerSessionId'] !=
                              knownWorkerSessionId))))) {
        missing.add(raw);
      }
    }
    final rawContext = decoded['context'];
    final contextDelta = <String, Object?>{};
    if (rawContext != null) {
      if (decoded['schemaVersion'] != 1 ||
          !const {'BootstrapContext', 'StatelessContext', 'DeltaContext'}
              .contains(decoded['kind'])) {
        throw const FormatException('Invalid Context Engine schema');
      }
      if (rawContext is! Map)
        throw const FormatException('Invalid structured context');
      for (final entry in rawContext.entries) {
        if (!const {
          'objective',
          'importantDecisions',
          'constraints',
          'currentState',
          'openIssues',
          'artifacts',
          'workflowState',
          'summary'
        }.contains(entry.key)) {
          throw const FormatException('Unknown structured context section');
        }
        final value = entry.value;
        bool fresh(Object? fact) {
          if (fact is! Map ||
              fact['revision'] is! int ||
              fact['sequence'] is! int ||
              fact['revision'] < 0 ||
              fact['revision'] > contextRevision ||
              fact['sequence'] < 0 ||
              fact['sequence'] > throughSequence) {
            throw const FormatException('Invalid structured context fact');
          }
          return fact['revision'] > revision ||
              fact['sequence'] > throughSequenceAlreadyConsumed;
        }

        if (const {
          'importantDecisions',
          'constraints',
          'openIssues',
          'artifacts'
        }.contains(entry.key)) {
          if (value is! Map)
            throw const FormatException('Invalid structured context records');
          final selected =
              Map.fromEntries(value.entries.where((item) => fresh(item.value)));
          if (selected.isNotEmpty) contextDelta[entry.key as String] = selected;
        } else if (value != null && fresh(value)) {
          contextDelta[entry.key as String] = value;
        }
      }
    }
    final workflow = decoded['workflowExecutionContext'];
    if (workflow != null &&
        (workflow is! Map ||
            workflow['schemaVersion'] != 1 ||
            workflow['workRequestId'] is! String ||
            workflow['activeStepId'] is! String ||
            workflow['steps'] is! List ||
            (workflow['steps'] as List).length > 1000 ||
            !(workflow['steps'] as List).any((step) =>
                step is Map && step['id'] == workflow['activeStepId']))) {
      throw const FormatException('Invalid Workflow execution context');
    }
    // Execution state is request/step-scoped, independently of Conversation
    // revision. Work and multi-step handoffs must refresh it on every execution.
    final includeWorkflow = workflow is Map &&
        (workflow['workflowId'] != 'chat' ||
            (workflow['steps'] as List).length > 1 ||
            missing.isNotEmpty ||
            contextDelta.isNotEmpty);
    return missing.isEmpty && contextDelta.isEmpty && !includeWorkflow
        ? null
        : jsonEncode({
            if (rawContext != null) ...{
              'schemaVersion': 1,
              'kind': 'DeltaContext',
              'contextRevision': contextRevision,
              'fromRevision': revision,
              'afterSequence': throughSequenceAlreadyConsumed,
            },
            'conversationId': conversationId,
            'throughSequence': throughSequence,
            'history': missing,
            if (contextDelta.isNotEmpty) 'context': contextDelta,
            if (decoded.containsKey('conversationContext'))
              'conversationContext': Map.fromEntries(contextDelta.entries
                  .where((entry) => entry.key != 'workflowState')),
            if (includeWorkflow) 'workflowExecutionContext': workflow,
          });
  }

  final String conversationId;
  final int? turnRevision;
  final int contextRevision;
  final int throughSequence;
  final String text;
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'conversationId': conversationId,
        'contextRevision': contextRevision,
        'throughSequence': throughSequence,
        'text': text,
        if (turnRevision != null) 'turnRevision': turnRevision,
      };
  factory ConversationBootstrap.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'schemaVersion',
      'conversationId',
      'contextRevision',
      'throughSequence',
      'text',
      'turnRevision',
    });
    if ((json['turnRevision'] != null && json['turnRevision'] is! int) ||
        json['schemaVersion'] != 1 ||
        json['contextRevision'] is! int ||
        json['throughSequence'] is! int) {
      throw const FormatException('Invalid Conversation bootstrap schema');
    }
    return ConversationBootstrap(
        conversationId: _requiredString(json, 'conversationId'),
        contextRevision: json['contextRevision'] as int,
        throughSequence: json['throughSequence'] as int,
        text: _requiredString(json, 'text'),
        turnRevision: json['turnRevision'] as int?);
  }
}

final class WorkerSessionContext {
  WorkerSessionContext(
      {required this.id,
      required this.conversationId,
      required this.workerId,
      required this.baseContextRevision,
      this.bootstrap}) {
    for (final value in [id, conversationId, workerId]) {
      if (value.isEmpty ||
          value.length > 128 ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(value)) {
        throw const FormatException('Invalid Worker Session scope');
      }
    }
    if (bootstrap != null &&
        (bootstrap!.conversationId != conversationId ||
            bootstrap!.contextRevision != baseContextRevision)) {
      throw const FormatException('Conversation bootstrap scope mismatch');
    }
    if (baseContextRevision < 0 || baseContextRevision > 9007199254740991) {
      throw const FormatException('Invalid Worker Session context revision');
    }
  }
  final ConversationBootstrap? bootstrap;
  final String id;
  final String conversationId;
  final String workerId;
  final int baseContextRevision;
  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'id': id,
        'conversationId': conversationId,
        'workerId': workerId,
        'baseContextRevision': baseContextRevision,
        if (bootstrap != null) 'bootstrap': bootstrap!.toJson(),
      };
  factory WorkerSessionContext.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'schemaVersion',
      'id',
      'conversationId',
      'workerId',
      'baseContextRevision',
      'bootstrap',
    });
    if (json['bootstrap'] != null && json['bootstrap'] is! Map) {
      throw const FormatException('Invalid Conversation bootstrap object');
    }
    if (json['schemaVersion'] != 1 || json['baseContextRevision'] is! int)
      throw const FormatException('Invalid Worker Session context schema');
    return WorkerSessionContext(
        id: _requiredString(json, 'id'),
        conversationId: _requiredString(json, 'conversationId'),
        workerId: _requiredString(json, 'workerId'),
        baseContextRevision: json['baseContextRevision'] as int,
        bootstrap: json['bootstrap'] == null
            ? null
            : ConversationBootstrap.fromJson(
                (json['bootstrap'] as Map).cast<String, Object?>()));
  }
}

final class ExecuteRequest extends WorkerFrame {
  ExecuteRequest({
    required super.requestId,
    required this.assignmentId,
    required this.prompt,
    required this.timeoutMs,
    required this.sessionPolicy,
    this.executionPolicy = WorkerExecutionPolicy.restricted,
    this.model,
    this.reasoningEffort,
    this.catalogRevision,
    this.sessionKey,
    this.workerSession,
    this.statelessContext,
    this.additionalDirectories = const [],
    this.compactContext = false,
    this.protocolVersion = localWorkerProtocolVersion,
  }) {
    _validateProtocol(protocolVersion);
    if (compactContext && sessionPolicy != WorkerSessionPolicy.durableSession) {
      throw const FormatException('compactContext requires a durable session');
    }
    if (additionalDirectories.length >
            WorkerProtocolLimits.maxAdditionalDirectories ||
        additionalDirectories.any((path) =>
            path.isEmpty ||
            path.length > 4096 ||
            path.contains('\x00') ||
            !(path.startsWith('/') ||
                RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path))) ||
        additionalDirectories.toSet().length != additionalDirectories.length) {
      throw const FormatException(
          'additionalDirectories must be distinct absolute paths');
    }
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (prompt.trim().isEmpty) {
      throw const FormatException('prompt must not be empty');
    }
    if (utf8.encode(prompt).length > WorkerProtocolLimits.maxPromptBytes) {
      throw const FormatException('prompt exceeds the byte limit');
    }
    if (timeoutMs < 1 || timeoutMs > WorkerProtocolLimits.maxTimeoutMs) {
      throw const FormatException('timeoutMs is outside the allowed range');
    }
    if (model != null) {
      _validateToken(model!, 'model', WorkerProtocolLimits.maxModelLength);
    }
    if (reasoningEffort != null) {
      _validateToken(
        reasoningEffort!,
        'reasoningEffort',
        WorkerProtocolLimits.maxModelLength,
      );
    }
    if (catalogRevision != null &&
        (protocolVersion == '4.0' ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(catalogRevision!))) {
      throw const FormatException(
          'catalogRevision requires protocol 4.1 and a SHA-256 identity');
    }
    if (statelessContext != null &&
        sessionPolicy != WorkerSessionPolicy.stateless) {
      throw const FormatException(
          'Stateless context requires stateless execution');
    }
    if (workerSession != null &&
        sessionPolicy != WorkerSessionPolicy.durableSession) {
      throw const FormatException(
          'Worker Session metadata requires durable execution');
    }
    if (sessionPolicy == WorkerSessionPolicy.durableSession) {
      if (sessionKey == null)
        throw const FormatException('durable sessions require sessionKey');
      _validateToken(
        sessionKey!,
        'sessionKey',
        WorkerProtocolLimits.maxSessionKeyLength,
      );
      if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionKey!)) {
        throw const FormatException(
          'sessionKey must be an opaque safe identifier',
        );
      }
    } else if (sessionKey != null) {
      throw const FormatException(
        'stateless execution must not include sessionKey',
      );
    }
  }

  final String protocolVersion;
  final String assignmentId;
  final String prompt;
  final String? model;
  final String? reasoningEffort;
  final String? catalogRevision;
  final int timeoutMs;
  final WorkerSessionPolicy sessionPolicy;
  final WorkerExecutionPolicy executionPolicy;
  final String? sessionKey;
  final WorkerSessionContext? workerSession;
  final ConversationBootstrap? statelessContext;

  /// Workspace-verified absolute folders the provider CLI may use besides the
  /// working directory. The Profile decides how they become CLI arguments.
  final List<String> additionalDirectories;

  /// Compact the resumed native session with the Profile's compaction
  /// command before running this prompt (the user's answer to a context
  /// overflow). Only sent when true, so older Engines keep accepting frames.
  final bool compactContext;

  @override
  String get type => 'execute.request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'protocolVersion': protocolVersion,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'prompt': prompt,
        'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (catalogRevision != null) 'catalogRevision': catalogRevision,
        'timeoutMs': timeoutMs,
        'sessionPolicy': sessionPolicy == WorkerSessionPolicy.durableSession
            ? 'durable_session'
            : 'stateless',
        'executionPolicy': executionPolicy.wireValue,
        if (sessionKey != null) 'sessionKey': sessionKey,
        if (workerSession != null) 'workerSession': workerSession!.toJson(),
        if (statelessContext != null)
          'statelessContext': statelessContext!.toJson(),
        if (additionalDirectories.isNotEmpty)
          'additionalDirectories': additionalDirectories,
        if (compactContext) 'compactContext': true,
      };

  factory ExecuteRequest.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'protocolVersion',
      'requestId',
      'assignmentId',
      'prompt',
      'model',
      'reasoningEffort',
      'catalogRevision',
      'timeoutMs',
      'sessionPolicy',
      'executionPolicy',
      'sessionKey',
      'workerSession',
      'statelessContext',
      'additionalDirectories',
      'compactContext',
    });
    _expectType(json, 'execute.request');
    final compactContext = json['compactContext'] ?? false;
    if (compactContext is! bool) {
      throw const FormatException('compactContext must be a boolean');
    }
    final directories = json['additionalDirectories'] ?? const <Object?>[];
    if (directories is! List || directories.any((path) => path is! String)) {
      throw const FormatException(
          'additionalDirectories must be a list of strings');
    }
    final model = json['model'];
    if (model != null && model is! String)
      throw const FormatException('model must be a string or null');
    final reasoningEffort = json['reasoningEffort'];
    if (reasoningEffort != null && reasoningEffort is! String) {
      throw const FormatException('reasoningEffort must be a string or null');
    }
    if (json['statelessContext'] != null && json['statelessContext'] is! Map) {
      throw const FormatException('Invalid stateless context object');
    }
    if (json['workerSession'] != null && json['workerSession'] is! Map) {
      throw const FormatException('workerSession must be an object');
    }
    final timeout = json['timeoutMs'];
    if (timeout is! int)
      throw const FormatException('timeoutMs must be an integer');
    final policy = _requiredString(json, 'sessionPolicy');
    final parsedPolicy = switch (policy) {
      'stateless' => WorkerSessionPolicy.stateless,
      'durable_session' => WorkerSessionPolicy.durableSession,
      _ => throw const FormatException('invalid sessionPolicy'),
    };
    final rawExecutionPolicy = json['executionPolicy'] ?? 'restricted';
    if (rawExecutionPolicy is! String) {
      throw const FormatException('executionPolicy must be a string');
    }
    final parsedExecutionPolicy = WorkerExecutionPolicy.fromWireValue(
      rawExecutionPolicy,
    );
    return ExecuteRequest(
      protocolVersion: _requiredString(json, 'protocolVersion'),
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      prompt: _requiredString(json, 'prompt'),
      model: model as String?,
      reasoningEffort: reasoningEffort as String?,
      catalogRevision: _optionalString(json, 'catalogRevision'),
      timeoutMs: timeout,
      sessionPolicy: parsedPolicy,
      executionPolicy: parsedExecutionPolicy,
      sessionKey: _optionalString(json, 'sessionKey'),
      statelessContext: json['statelessContext'] == null
          ? null
          : ConversationBootstrap.fromJson(
              (json['statelessContext'] as Map).cast<String, Object?>()),
      workerSession: json['workerSession'] == null
          ? null
          : WorkerSessionContext.fromJson(
              Map<String, Object?>.from(json['workerSession'] as Map)),
      additionalDirectories: List<String>.unmodifiable(directories),
      compactContext: compactContext,
    );
  }
}

/// A bounded Workspace-selected execution mode.
///
/// `full_access` is emitted only after the Workspace service has verified its
/// persisted host-owner authorization. It remains explicit so the Engine and
/// Worker Profile applies the same policy end to end.
enum WorkerExecutionPolicy {
  restricted('restricted'),
  providerDefault('provider_default'),
  fullAccess('full_access');

  const WorkerExecutionPolicy(this.wireValue);
  final String wireValue;

  static WorkerExecutionPolicy fromWireValue(String value) => switch (value) {
        'restricted' => WorkerExecutionPolicy.restricted,
        'provider_default' => WorkerExecutionPolicy.providerDefault,
        'full_access' => WorkerExecutionPolicy.fullAccess,
        _ => throw const FormatException('invalid executionPolicy'),
      };
}

final class WorkerProgress extends WorkerFrame {
  WorkerProgress({
    required super.requestId,
    required this.assignmentId,
    required this.percentage,
    String? message,
  }) : message = message == null
            ? null
            : _safeBoundedText(
                message,
                'progress message',
                WorkerProtocolLimits.maxProgressMessageLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (!percentage.isFinite || percentage < 0 || percentage > 100) {
      throw const FormatException(
        'progress percentage must be between 0 and 100',
      );
    }
  }

  final String assignmentId;
  final double percentage;
  final String? message;

  @override
  String get type => 'progress';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'percentage': percentage,
        if (message != null) 'message': message,
      };

  factory WorkerProgress.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'percentage',
      'message',
    });
    _expectType(json, 'progress');
    final percentage = json['percentage'];
    if (percentage is! num)
      throw const FormatException('percentage must be numeric');
    return WorkerProgress(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      percentage: percentage.toDouble(),
      message: _optionalString(json, 'message'),
    );
  }
}

/// A provider-neutral activity emitted for every meaningful provider event.
///
/// Unlike [WorkerProgress], activities are not deduplicated by percentage or
/// message. Repeated tool calls therefore remain visible to downstream
/// consumers. `sequence` is strictly increasing for one execution in the
/// Engine output stream; consumers use it to discard duplicate or stale
/// frames without changing the event identity.
final class WorkerActivity extends WorkerFrame {
  WorkerActivity({
    required super.requestId,
    required this.assignmentId,
    required this.executionId,
    required this.workerId,
    required this.eventId,
    required this.sequence,
    required this.timestamp,
    required this.eventType,
    required this.status,
    required this.title,
    this.activityId,
    this.percentage,
    this.durationMs,
    this.toolId,
    this.toolName,
    Map<String, Object?>? details,
  }) : details = details == null ? null : _validatedActivityDetails(details) {
    _validateToken(
        requestId, 'requestId', WorkerProtocolLimits.maxRequestIdLength);
    _validateToken(
        assignmentId, 'assignmentId', WorkerProtocolLimits.maxRequestIdLength);
    _validateToken(executionId, 'executionId',
        WorkerProtocolLimits.maxActivityExecutionIdLength);
    _validateToken(
        workerId, 'workerId', WorkerProtocolLimits.maxWorkerTypeIdLength);
    _validateToken(
        eventId, 'eventId', WorkerProtocolLimits.maxActivityEventIdLength);
    if (activityId != null) {
      _validateToken(
          activityId!, 'activityId', WorkerProtocolLimits.maxActivityIdLength);
    }
    if (sequence < 1 || sequence > WorkerProtocolLimits.maxActivitySequence) {
      throw const FormatException(
          'activity sequence is outside the allowed range');
    }
    if (timestamp.length > 64 || DateTime.tryParse(timestamp) == null) {
      throw const FormatException(
          'activity timestamp must be an ISO-8601 timestamp');
    }
    if (!_activityTypes.contains(eventType)) {
      throw const FormatException('unsupported activity event type');
    }
    if (!_activityStatuses.contains(status)) {
      throw const FormatException('unsupported activity status');
    }
    _boundedText(eventType, 'activity event type',
        WorkerProtocolLimits.maxActivityTypeLength);
    _safeBoundedText(
        title, 'activity title', WorkerProtocolLimits.maxActivityTitleLength);
    if (percentage != null &&
        (!percentage!.isFinite || percentage! < 0 || percentage! > 100)) {
      throw const FormatException(
          'activity percentage must be between 0 and 100');
    }
  }

  static const _activityTypes = <String>{
    'execution.started',
    'model.started',
    'message.updated',
    'tool.started',
    'tool.completed',
    'tool.failed',
    'model.status',
    'execution.completed',
    'execution.failed',
    'execution.cancelled',
  };
  static const _activityStatuses = <String>{
    'running',
    'updated',
    'completed',
    'failed',
    'cancelled',
  };

  final String assignmentId;
  final String executionId;
  final String workerId;
  final String eventId;
  final int sequence;
  final String timestamp;
  final String eventType;
  final String status;
  final String title;
  final String? activityId;
  final double? percentage;
  final int? durationMs;
  final String? toolId;
  final String? toolName;
  final Map<String, Object?>? details;

  bool get isTerminal => const {
        'execution.completed',
        'execution.failed',
        'execution.cancelled',
      }.contains(eventType);

  @override
  String get type => 'activity';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'executionId': executionId,
        'workerId': workerId,
        'eventId': eventId,
        'sequence': sequence,
        'timestamp': timestamp,
        'eventType': eventType,
        'status': status,
        'title': title,
        if (activityId != null) 'activityId': activityId,
        if (percentage != null) 'percentage': percentage,
        if (durationMs != null) 'durationMs': durationMs,
        if (toolId != null) 'toolId': toolId,
        if (toolName != null) 'toolName': toolName,
        if (details != null) 'details': details,
      };

  factory WorkerActivity.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'executionId',
      'workerId',
      'eventId',
      'sequence',
      'timestamp',
      'eventType',
      'status',
      'title',
      'activityId',
      'percentage',
      'durationMs',
      'toolId',
      'toolName',
      'details',
    });
    _expectType(json, 'activity');
    final sequence = json['sequence'];
    if (sequence is! int) {
      throw const FormatException('activity sequence must be an integer');
    }
    final percentage = json['percentage'];
    if (percentage != null && percentage is! num) {
      throw const FormatException('activity percentage must be numeric');
    }
    final durationMs = json['durationMs'];
    if (durationMs != null && durationMs is! int) {
      throw const FormatException('activity duration must be an integer');
    }
    final details = json['details'];
    if (details != null && details is! Map) {
      throw const FormatException('activity details must be an object');
    }
    return WorkerActivity(
      requestId: _boundedString(
          json, 'requestId', WorkerProtocolLimits.maxRequestIdLength),
      assignmentId: _boundedString(
          json, 'assignmentId', WorkerProtocolLimits.maxRequestIdLength),
      executionId: _boundedString(json, 'executionId',
          WorkerProtocolLimits.maxActivityExecutionIdLength),
      workerId: _boundedString(
          json, 'workerId', WorkerProtocolLimits.maxWorkerTypeIdLength),
      eventId: _boundedString(
          json, 'eventId', WorkerProtocolLimits.maxActivityEventIdLength),
      sequence: sequence,
      timestamp: _boundedString(json, 'timestamp', 64),
      eventType: _boundedString(
          json, 'eventType', WorkerProtocolLimits.maxActivityTypeLength),
      status: _boundedString(json, 'status', 32),
      title: _boundedString(
          json, 'title', WorkerProtocolLimits.maxActivityTitleLength),
      activityId: _optionalString(json, 'activityId'),
      percentage: (percentage as num?)?.toDouble(),
      durationMs: durationMs as int?,
      toolId: _optionalString(json, 'toolId'),
      toolName: _optionalString(json, 'toolName'),
      details:
          details == null ? null : Map<String, Object?>.from(details as Map),
    );
  }
}

Map<String, Object?> _validatedActivityDetails(Map<String, Object?> details) {
  _validateActivityValue(details, 0);
  final encoded = utf8.encode(jsonEncode(details));
  if (encoded.length > WorkerProtocolLimits.maxActivityDetailsBytes) {
    throw const FormatException('activity details exceed the byte limit');
  }
  return Map.unmodifiable(details);
}

void _validateActivityValue(Object? value, int depth) {
  if (depth > WorkerProtocolLimits.maxActivityDetailDepth) {
    throw const FormatException('activity details are too deeply nested');
  }
  if (value == null || value is String || value is bool || value is num) return;
  if (value is List) {
    if (value.length > WorkerProtocolLimits.maxActivityDetailEntries) {
      throw const FormatException('too many activity detail items');
    }
    for (final item in value) {
      _validateActivityValue(item, depth + 1);
    }
    return;
  }
  if (value is Map) {
    if (value.length > WorkerProtocolLimits.maxActivityDetailEntries) {
      throw const FormatException('too many activity detail fields');
    }
    for (final entry in value.entries) {
      if (entry.key is! String ||
          !RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$')
              .hasMatch(entry.key as String)) {
        throw const FormatException('invalid activity detail field name');
      }
      _validateActivityValue(entry.value, depth + 1);
    }
    return;
  }
  throw const FormatException(
      'activity details contain an unsupported value type');
}

final class WorkerResult extends WorkerFrame {
  WorkerResult({
    required super.requestId,
    required this.assignmentId,
    required this.output,
    Iterable<String> artifacts = const [],
  }) : artifacts = List.unmodifiable(artifacts) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    _validateToken(
      assignmentId,
      'assignmentId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (utf8.encode(output).length > WorkerProtocolLimits.maxOutputBytes) {
      throw const FormatException('output exceeds the byte limit');
    }
    if (this.artifacts.length > WorkerProtocolLimits.maxArtifacts) {
      throw const FormatException('too many artifacts');
    }
    for (final artifact in this.artifacts) {
      _validateToken(
        artifact,
        'artifact ID',
        WorkerProtocolLimits.maxArtifactIdLength,
      );
    }
  }

  final String assignmentId;
  final String output;
  final List<String> artifacts;

  @override
  String get type => 'result';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        'assignmentId': assignmentId,
        'output': output,
        'artifacts': artifacts,
      };

  factory WorkerResult.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'output',
      'artifacts',
    });
    _expectType(json, 'result');
    final rawArtifacts = json['artifacts'];
    if (rawArtifacts is! List ||
        rawArtifacts.length > WorkerProtocolLimits.maxArtifacts) {
      throw const FormatException('artifacts must be a bounded array');
    }
    if (rawArtifacts.any((item) => item is! String)) {
      throw const FormatException('artifact IDs must be strings');
    }
    return WorkerResult(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _boundedString(
        json,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      output: _requiredStringAllowEmpty(json, 'output'),
      artifacts: rawArtifacts.cast<String>(),
    );
  }
}

final class WorkerErrorFrame extends WorkerFrame {
  WorkerErrorFrame({
    required super.requestId,
    required String code,
    required String message,
    this.assignmentId,
    this.retryable = false,
    String? diagnostics,
  })  : code = _boundedText(
          code,
          'error code',
          WorkerProtocolLimits.maxCheckCodeLength,
        ),
        message = _safeBoundedText(
          message,
          'error message',
          WorkerProtocolLimits.maxErrorMessageLength,
        ),
        diagnostics = diagnostics == null
            ? null
            : _safeBoundedText(
                diagnostics,
                'diagnostics',
                WorkerProtocolLimits.maxDiagnosticLength,
              ) {
    _validateToken(
      requestId,
      'requestId',
      WorkerProtocolLimits.maxRequestIdLength,
    );
    if (assignmentId != null) {
      _validateToken(
        assignmentId!,
        'assignmentId',
        WorkerProtocolLimits.maxRequestIdLength,
      );
    }
    if (!WorkerIssueCode.isKnown(this.code)) {
      throw const FormatException('error code is not a supported stable code');
    }
  }

  final String? assignmentId;
  final String code;
  final String message;
  final bool retryable;
  final String? diagnostics;

  @override
  String get type => 'error';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'requestId': requestId,
        if (assignmentId != null) 'assignmentId': assignmentId,
        'code': code,
        'message': message,
        'retryable': retryable,
        if (diagnostics != null) 'diagnostics': diagnostics,
      };

  factory WorkerErrorFrame.fromJson(Map<String, Object?> json) {
    _expectKeys(json, const {
      'type',
      'requestId',
      'assignmentId',
      'code',
      'message',
      'retryable',
      'diagnostics',
    });
    _expectType(json, 'error');
    final retryable = json['retryable'];
    if (retryable is! bool)
      throw const FormatException('retryable must be a boolean');
    return WorkerErrorFrame(
      requestId: _boundedString(
        json,
        'requestId',
        WorkerProtocolLimits.maxRequestIdLength,
      ),
      assignmentId: _optionalString(json, 'assignmentId'),
      code: _requiredString(json, 'code'),
      message: _requiredString(json, 'message'),
      retryable: retryable,
      diagnostics: _optionalString(json, 'diagnostics'),
    );
  }
}

void validateInitializeAdmission(
  InitializeResult result, {
  required String expectedWorkerTypeId,
  required String expectedEngineVersion,
  required String expectedProfileDefinitionId,
  required String expectedProfileReleaseVersion,
  required int expectedProfileSchemaVersion,
  required Set<String> requiredCapabilities,
  String negotiatedProtocolVersion = localWorkerProtocolVersion,
}) {
  if (result.workerTypeId != expectedWorkerTypeId) {
    throw const FormatException(
      'initialized Worker Type does not match manifest',
    );
  }
  if (result.engineVersion != expectedEngineVersion) {
    throw const FormatException(
      'initialized Engine version does not match admission',
    );
  }
  if (result.profileDefinitionId != expectedProfileDefinitionId ||
      result.profileReleaseVersion != expectedProfileReleaseVersion) {
    throw const FormatException(
        'initialized Tool Profile does not match admission');
  }
  if (result.protocolVersion != negotiatedProtocolVersion) {
    throw const FormatException(
      'initialized protocol does not match negotiation',
    );
  }
  if (result.profileSchemaVersion != expectedProfileSchemaVersion) {
    throw const FormatException(
      'Tool Profile schema does not match admission',
    );
  }
  if (!result.capabilities.toSet().containsAll(requiredCapabilities)) {
    throw const FormatException('Worker is missing required capabilities');
  }
}

WorkerProbeMode _parseProbeMode(String value) =>
    WorkerProbeMode.values.firstWhere(
      (candidate) => candidate.name == value,
      orElse: () =>
          throw const FormatException('probe mode must be passive or live'),
    );

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('expected $type frame');
}

void _expectKeys(Map<String, Object?> json, Set<String> allowed) {
  final unknown = json.keys.where((key) => !allowed.contains(key));
  if (unknown.isNotEmpty) {
    throw FormatException('frame contains unsupported field: ${unknown.first}');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String _requiredStringAllowEmpty(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

String _boundedString(Map<String, Object?> json, String key, int maxLength) {
  final value = _requiredString(json, key);
  _validateToken(value, key, maxLength);
  return value;
}

String _boundedText(String value, String name, int maxLength) {
  if (value.trim().isEmpty || value.length > maxLength) {
    throw FormatException('$name is empty or exceeds $maxLength characters');
  }
  return value;
}

String _safeToolName(String value) {
  final safe = _boundedText(
    value,
    'providerToolName',
    WorkerProtocolLimits.maxProviderToolNameLength,
  );
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._+()\-]*$').hasMatch(safe)) {
    throw const FormatException('providerToolName must be safe display text');
  }
  return safe;
}

String _safeToolVersion(String value) {
  final safe = _boundedText(
    value,
    'providerToolVersion',
    WorkerProtocolLimits.maxProviderToolVersionLength,
  );
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9.+_\-]*$').hasMatch(safe)) {
    throw const FormatException(
        'providerToolVersion must be a safe version token');
  }
  return safe;
}

String _safeBoundedText(String value, String name, int maxLength) {
  final redacted = value
      .replaceAll(
        RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
        r'$1[REDACTED]',
      )
      .replaceAll(
        RegExp(
          r'''(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*["'])([^"']*)(["'])|(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|cookie|authorization|secret)["']?\s*[:=]\s*)([^\s,}&]+)''',
          caseSensitive: false,
        ),
        r'$1[REDACTED]$3$4[REDACTED]',
      );
  return _boundedText(redacted, name, maxLength);
}

void _validateToken(String value, String name, int maxLength) =>
    _boundedText(value, name, maxLength);

void _validateProtocol(String version) {
  if (!supportedLocalWorkerProtocolVersions.contains(version)) {
    throw FormatException('unsupported protocol version: $version');
  }
}
