import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart';
import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';

import 'utils/profile_lab_security.dart';
import 'utils/profile_activity_mapping_fixtures.dart';

/// A single stage result in the progressive test ladder.
class ProfileLabLadderStageResult {
  const ProfileLabLadderStageResult({
    required this.stageId,
    required this.displayName,
    required this.status, // 'passed', 'failed', 'skipped'
    required this.durationMs,
    required this.diagnostics,
    required this.consumesQuota,
    this.issueCode,
    this.details = const {},
  });

  final String stageId;
  final String displayName;
  final String status;
  final int durationMs;
  final String diagnostics;
  final bool consumesQuota;
  final String? issueCode;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
        'stageId': stageId,
        'displayName': displayName,
        'status': status,
        'durationMs': durationMs,
        'diagnostics': diagnostics,
        'consumesQuota': consumesQuota,
        if (issueCode != null) 'issueCode': issueCode,
        'details': details,
      };
}

/// The complete progressive test ladder result across all 6 ordered stages.
class ProfileLabLadderResult {
  const ProfileLabLadderResult({
    required this.overallResult,
    required this.startedAt,
    required this.endedAt,
    required this.stages,
    required this.acceptanceEvidence,
    required this.logs,
    this.publicationEvidence,
  });

  final String overallResult; // 'pass' or 'fail'
  final DateTime startedAt;
  final DateTime endedAt;
  final List<ProfileLabLadderStageResult> stages;

  /// Exact Cloud acceptance contract, present only when every required
  /// applicable acceptance scenario was observed to pass against this candidate.
  final ToolProfileAcceptanceEvidence? acceptanceEvidence;
  final ToolProfilePublicationEvidence? publicationEvidence;
  final List<String> logs;
}

/// Digest-bound V9 publication evidence. This is deliberately smaller than
/// the local test log and contains no provider output, environment, or secret.
class ToolProfilePublicationEvidence {
  const ToolProfilePublicationEvidence({
    required this.workerTypeId,
    required this.candidateDigest,
    required this.engineVersion,
    required this.providerToolName,
    required this.providerToolVersion,
    required this.testedAt,
    required this.scenarios,
  });

  final String workerTypeId;
  final String candidateDigest;
  final String engineVersion;
  final String providerToolName;
  final String providerToolVersion;
  final String testedAt;
  final Map<String, String> scenarios;

  Map<String, Object?> toJson() => {
        'formatVersion': 1,
        'workerTypeId': workerTypeId,
        'candidateDigest': candidateDigest,
        'engineVersion': engineVersion,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        'testedAt': testedAt,
        'scenarios': scenarios,
      };
}

/// Profile Lab's direct representation of Cloud's qualification and acceptance
/// contract. Its serialized shape intentionally matches
/// ToolProfileAcceptanceEvidence in apps/cloud/src/tool-profile-validation.ts.
class ToolProfileAcceptanceEvidence {
  const ToolProfileAcceptanceEvidence({
    required this.profileDefinitionId,
    required this.releaseVersion,
    required this.profileDigest,
    required this.logicalWorkerTypeId,
    required this.engineVersion,
    required this.providerToolName,
    required this.providerToolVersion,
    required this.acceptedAt,
    required this.scenarios,
  });

  final String profileDefinitionId;
  final int releaseVersion;
  final String profileDigest;
  final String logicalWorkerTypeId;
  final String engineVersion;
  final String providerToolName;
  final String providerToolVersion;
  final String acceptedAt;
  final Map<String, String> scenarios;

  Map<String, Object?> toJson() => {
        'formatVersion': 2,
        'profileDefinitionId': profileDefinitionId,
        'releaseVersion': releaseVersion,
        'profileReleaseVersion': '$releaseVersion',
        'logicalWorkerTypeId': logicalWorkerTypeId,
        'profileDigest': profileDigest,
        'engineVersion': engineVersion,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        'acceptedAt': acceptedAt,
        'scenarios': scenarios,
      };

  static bool hasCloudContractShape(
    Map<String, Object?> json, {
    Map<String, Object?>? profile,
  }) {
    const fields = {
      'formatVersion',
      'profileDefinitionId',
      'releaseVersion',
      'profileReleaseVersion',
      'logicalWorkerTypeId',
      'profileDigest',
      'engineVersion',
      'providerToolName',
      'providerToolVersion',
      'acceptedAt',
      'scenarios',
    };
    final scenarios = json['scenarios'];
    return json.keys.toSet().containsAll(fields) &&
        fields.containsAll(json.keys) &&
        json['formatVersion'] == 2 &&
        json['profileDefinitionId'] is String &&
        json['releaseVersion'] is int &&
        json['profileReleaseVersion'] == '${json['releaseVersion']}' &&
        json['logicalWorkerTypeId'] is String &&
        json['profileDigest'] is String &&
        json['engineVersion'] is String &&
        json['providerToolName'] is String &&
        json['providerToolVersion'] is String &&
        json['acceptedAt'] is String &&
        DateTime.tryParse(json['acceptedAt'] as String) != null &&
        scenarios is Map &&
        scenarios.keys.toSet().containsAll(cloudAcceptanceScenarioNames) &&
        cloudAcceptanceScenarioNames.toSet().containsAll(scenarios.keys) &&
        scenarios.values.every(
          (result) => result == 'passed' || result == 'not_applicable',
        ) &&
        (profile == null ||
            _sameScenarioStatuses(
              scenarios.cast<String, Object?>(),
              cloudAcceptanceScenarioStatuses(profile),
            ));
  }

  static bool _sameScenarioStatuses(
    Map<String, Object?> actual,
    Map<String, String>? expected,
  ) =>
      expected != null &&
      expected.length == actual.length &&
      expected.entries.every((entry) => actual[entry.key] == entry.value);
}

Future<void> _deleteSandboxTreeWithoutFollowingLinks(
  Directory directory,
) async {
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await _deleteSandboxTreeWithoutFollowingLinks(Directory(entity.path));
      await Directory(entity.path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(entity.path).delete();
    }
  }
}

const cloudAcceptanceScenarioNames = <String>[
  'activity_mapping',
  'passive_probe',
  'usage_check',
];

/// Derives the Cloud scenario status map from the candidate Tool Profile.
///
/// Every Profile must declare a `usage` command, so the usage check always
/// applies. No scenario calls a model.
Map<String, String> cloudAcceptanceScenarioStatuses(
  Map<String, Object?> profile,
) {
  return {
    'activity_mapping': _activityMappingScenarioStatus(profile),
    'passive_probe': 'passed',
    'usage_check': 'passed',
  };
}

String _activityMappingScenarioStatus(Map<String, Object?> profile) {
  final activity = profile['activity'];
  final execution = profile['execution'];
  final output = execution is Map ? execution['output'] : null;
  final mode = output is Map ? output['mode'] : null;
  final mappings = activity is Map ? activity['mappings'] : null;
  if (mappings is! List || mappings.isEmpty || mode != 'jsonl') {
    return 'not_applicable';
  }
  return 'passed';
}

/// Dedicated isolated test harness for running unsigned Tool Profile candidates
/// through the generic CLI Worker Engine in Profile Lab.
class ProfileLabTestSandbox {
  ProfileLabTestSandbox({
    required this.sandboxRoot,
    required this.engineExecutable,
    PlatformProcessSupervisor? processSupervisor,
    Map<String, String> environmentOverrides = const {},
  })  : environmentOverrides = {
          'PATH': providerSearchPath(Platform.environment),
          ...environmentOverrides,
        },
        _processSupervisor =
            processSupervisor ?? const StandardProcessSupervisor();

  final Directory sandboxRoot;
  final File engineExecutable;
  final PlatformProcessSupervisor _processSupervisor;
  final Map<String, String> environmentOverrides;
  CliWorkerEngineSupervisor? _activeSupervisor;
  String? _activeAssignmentId;

  /// Cancels the active Engine assignment, including the provider CLI process tree.
  Future<bool> cancelCurrentTest() async {
    final supervisor = _activeSupervisor;
    final assignmentId = _activeAssignmentId;
    if (supervisor == null || assignmentId == null) return false;
    return supervisor.cancel(assignmentId);
  }

  /// Discovers model metadata without invoking a model or bypassing trust admission.
  Future<DiscoveredModelCatalog?> discoverTrustedModels(
    ToolProfileCandidate profile,
  ) async {
    if (!profile.isPublished) {
      throw StateError('Discovery requires a published Profile.');
    }
    if (_activeSupervisor != null) {
      throw StateError('An Engine operation is active.');
    }
    final root = sandboxRoot.absolute;
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Sandbox root is not a real directory',
        root.path,
      );
    }
    final scratch = await Directory(
      await root.resolveSymbolicLinks(),
    ).createTemp('model_discovery_');
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: engineExecutable.path,
      platformRuntime: _processSupervisor,
      environmentOverrides: environmentOverrides,
    );
    _activeSupervisor = supervisor;
    try {
      final profileFile = File('${scratch.path}/profile.json');
      await profileFile.writeAsString(canonicalJson(profile.profile));
      final result = await supervisor.probe(
        profile,
        profileFile: profileFile,
        stateDirectory: Directory('${scratch.path}/state'),
        mode: WorkerProbeMode.passive,
      );
      return result.modelCatalog;
    } finally {
      _activeSupervisor = null;
      await supervisor.shutdown();
      await _deleteSandboxTreeWithoutFollowingLinks(scratch);
      await scratch.delete();
    }
  }

  /// Executes the progressive local test ladder:
  /// 1. Schema Validation (no quota)
  /// 2. Event Mapping Replay (no quota)
  /// 3. Executable Discovery (no quota)
  /// 4. CLI Version Command: the command runs and prints something; the
  ///    version is not compared with the Profile's ranges (no quota)
  /// 5. Passive Probe (no model call)
  /// 6. Provider Usage Check: the Profile's usage command (no model call)
  ///
  /// No stage calls a model.
  ///
  /// Engine and CLI version ranges are enforced by Connect readiness on the
  /// user's machine, not here. Cancellation and timeout are Engine behavior
  /// covered by Engine and supervisor tests.
  Future<ProfileLabLadderResult> executeTestLadder({
    required LocalDraftProfileCandidate candidate,
    void Function(String stageId, String status, String diagnostics)?
        onStageUpdate,
    void Function(String level, String message)? onLog,
    void Function(ProfileLabLadderStageResult stage)? onStageResult,
  }) async {
    final logs = <String>[];
    void log(String level, String message) {
      final redacted = ProfileLabSecurity.redactSecrets(message);
      logs.add('[$level] $redacted');
      onLog?.call(level, redacted);
    }

    final stages = <ProfileLabLadderStageResult>[];
    final startedAt = DateTime.now().toUtc();
    bool haltExecution = false;
    final observedAcceptanceScenarios = <String, String>{};
    var expectedAcceptanceScenarios = const <String, String>{};
    String? detectedProviderToolVersion;

    void addStage({
      required String stageId,
      required String displayName,
      required String status,
      required int durationMs,
      required String diagnostics,
      required bool consumesQuota,
      String? issueCode,
      Map<String, Object?> details = const {},
    }) {
      final redactedDiag = ProfileLabSecurity.redactSecrets(diagnostics);
      final stage = ProfileLabLadderStageResult(
        stageId: stageId,
        displayName: displayName,
        status: status,
        durationMs: durationMs,
        diagnostics: redactedDiag,
        consumesQuota: consumesQuota,
        issueCode: issueCode,
        details: details,
      );
      stages.add(stage);
      onStageResult?.call(stage);
      onStageUpdate?.call(stageId, status, redactedDiag);
      log(
        status == 'failed'
            ? 'error'
            : status == 'skipped'
                ? 'warn'
                : 'info',
        'Stage [$displayName]: $status - $redactedDiag',
      );
    }

    // --- STAGE 1: Schema ---
    final s1Timer = Stopwatch()..start();
    EngineProfile? parsedProfile;
    try {
      parsedProfile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      expectedAcceptanceScenarios = cloudAcceptanceScenarioStatuses(
        candidate.profile,
      );
      s1Timer.stop();
      addStage(
        stageId: 'schema',
        displayName: 'Schema Validation',
        status: 'passed',
        durationMs: s1Timer.elapsedMilliseconds,
        diagnostics:
            'Tool Profile v1 canonical schema clean (workerTypeId: ${parsedProfile.workerTypeId}).',
        consumesQuota: false,
      );
    } catch (e) {
      s1Timer.stop();
      haltExecution = true;
      addStage(
        stageId: 'schema',
        displayName: 'Schema Validation',
        status: 'failed',
        durationMs: s1Timer.elapsedMilliseconds,
        diagnostics: 'Tool Profile v1 schema validation failed: $e',
        consumesQuota: false,
        issueCode: 'schema_validation_failed',
      );
    }

    // --- STAGE 2: Profile Activity Mapping ---
    final s2Timer = Stopwatch()..start();
    if (haltExecution) {
      s2Timer.stop();
      addStage(
        stageId: 'activity_mapping',
        displayName: 'Event Mapping Replay',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped because schema validation failed.',
        consumesQuota: false,
      );
    } else {
      final replay = replayProfileActivityMappings(parsedProfile!.json);
      s2Timer.stop();
      if (replay.status == 'failed') haltExecution = true;
      observedAcceptanceScenarios['activity_mapping'] = replay.status;
      addStage(
        stageId: 'activity_mapping',
        displayName: 'Event Mapping Replay',
        status: replay.status,
        durationMs: s2Timer.elapsedMilliseconds,
        diagnostics: replay.message,
        consumesQuota: false,
        issueCode: replay.status == 'failed' ? 'activity_mapping_failed' : null,
        details: {
          'provider': replay.provider,
          if (replay.fixtureName != null) 'fixture': replay.fixtureName,
          'eventCount': replay.events.length,
          'activityCount': replay.activities.length,
        },
      );
    }

    // --- STAGE 3: Executable Discovery ---
    final s3Timer = Stopwatch()..start();
    String? discoveredExecPath;
    if (haltExecution) {
      s3Timer.stop();
      addStage(
        stageId: 'executable_discovery',
        displayName: 'Executable Discovery',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped due to a prior failure.',
        consumesQuota: false,
      );
    } else {
      const locator = CliExecutableLocator();
      final providerTool =
          candidate.profile['providerTool'] as Map<String, Object?>? ?? {};
      final discovery =
          providerTool['discovery'] as Map<String, Object?>? ?? const {};
      final standardPaths =
          (discovery['standardLocations'] as List?)?.whereType<String>() ??
              const <String>[];
      final toolName =
          providerTool['name'] as String? ?? candidate.providerToolName;
      final candidatesList =
          (providerTool['executableCandidates'] as List?)?.cast<String>() ??
              [toolName];

      for (final c in candidatesList) {
        if (ProfileLabSecurity.isUnsafeExecutable(c)) {
          haltExecution = true;
          s3Timer.stop();
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'failed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'Executable candidate "$c" is unsafe or forbidden by security policy.',
            consumesQuota: false,
            issueCode: 'unsafe_executable_declaration',
          );
          break;
        }
        final found = await locator.locate(
          c,
          environment: {...Platform.environment, ...environmentOverrides},
          standardPaths: standardPaths,
        );
        if (found != null) {
          discoveredExecPath = found;
          break;
        }
      }
      if (!s3Timer.isRunning) {
        // Stage timer already stopped on unsafe executable failure
      } else {
        s3Timer.stop();
        if (discoveredExecPath != null) {
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'passed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'Discovered CLI binary for "$toolName" at: $discoveredExecPath',
            consumesQuota: false,
            details: {'executablePath': discoveredExecPath},
          );
        } else {
          haltExecution = true;
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'failed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'No executable binary found for "$toolName" on PATH or standard locations.',
            consumesQuota: false,
            issueCode: 'provider_tool_unavailable',
          );
        }
      }
    }

    // --- STAGE 4: CLI Version Command ---
    // Only checks that the CLI understands its version command and answers
    // with something. The value is recorded, never compared: Profiles support
    // every CLI version, and Connect runs this same check when it verifies a
    // Worker.
    final s4Timer = Stopwatch()..start();
    if (haltExecution) {
      s4Timer.stop();
      addStage(
        stageId: 'cli_version',
        displayName: 'CLI Version Command',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped because executable discovery failed.',
        consumesQuota: false,
      );
    } else {
      try {
        final profile = parsedProfile!;
        final workingDirectory = Directory.current.path;
        final versionResult = await ProfileVersionProbe.run(
          profile: profile,
          executable: discoveredExecPath!,
          commandRunner: const CliCommandRunner(maxOutputBytes: 64 * 1024),
          environment: {
            ...ProfileLabSecurity.buildIsolatedEnvironment(),
            ...environmentOverrides,
          },
          workingDirectory: workingDirectory,
          context: ProfileVersionProbe.buildContext(
            profile: profile,
            workingDirectory: workingDirectory,
            homeDirectory: environmentOverrides['HOME'] ??
                Platform.environment['HOME'] ??
                workingDirectory,
            workerStateDirectory: sandboxRoot.absolute.path,
          ),
          deadline: const Duration(seconds: 30),
        );
        s4Timer.stop();
        final answered =
            versionResult.exitCode == 0 && versionResult.output.isNotEmpty;
        if (answered) {
          detectedProviderToolVersion = versionResult.version ??
              versionResult.output.split(RegExp(r'\r?\n')).first.trim();
          addStage(
            stageId: 'cli_version',
            displayName: 'CLI Version Command',
            status: 'passed',
            durationMs: s4Timer.elapsedMilliseconds,
            diagnostics:
                'The CLI answered its version command: $detectedProviderToolVersion',
            consumesQuota: false,
            details: {'cliVersion': detectedProviderToolVersion},
          );
        } else {
          haltExecution = true;
          addStage(
            stageId: 'cli_version',
            displayName: 'CLI Version Command',
            status: 'failed',
            durationMs: s4Timer.elapsedMilliseconds,
            diagnostics: versionResult.exitCode != 0
                ? 'The CLI version command failed with exit code ${versionResult.exitCode}.'
                : 'The CLI version command returned no output.',
            consumesQuota: false,
            issueCode: 'version_probe_failed',
          );
        }
      } catch (e) {
        s4Timer.stop();
        haltExecution = true;
        addStage(
          stageId: 'cli_version',
          displayName: 'CLI Version Command',
          status: 'failed',
          durationMs: s4Timer.elapsedMilliseconds,
          diagnostics: 'Version command error: $e',
          consumesQuota: false,
          issueCode: 'version_probe_failed',
        );
      }
    }

    // Prepare temp sandbox scratch directory for supervisor probe calls
    final configuredRoot = sandboxRoot.absolute;
    final rootType = await FileSystemEntity.type(
      configuredRoot.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Sandbox root is not a real directory',
        configuredRoot.path,
      );
    }
    final canonicalRoot = await configuredRoot.resolveSymbolicLinks();
    final canonicalRootDirectory = Directory(canonicalRoot);
    final scratchDir = await canonicalRootDirectory.createTemp('test_ladder_');

    try {
      final profileTempFile = File('${scratchDir.path}/profile.json');
      await profileTempFile.writeAsString(canonicalJson(candidate.profile));

      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: engineExecutable.path,
        platformRuntime: _processSupervisor,
        environmentOverrides: environmentOverrides,
      );
      _activeSupervisor = supervisor;

      // --- STAGE 5: Passive Probe ---
      final s5Timer = Stopwatch()..start();
      if (haltExecution) {
        s5Timer.stop();
        addStage(
          stageId: 'passive_probe',
          displayName: 'Passive Probe',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior failure in earlier stage.',
          consumesQuota: false,
        );
      } else {
        try {
          final probeRes = await supervisor.probe(
            candidate,
            profileFile: profileTempFile,
            stateDirectory: scratchDir,
            mode: WorkerProbeMode.passive,
            timeout: const Duration(seconds: 30),
          );
          s5Timer.stop();
          // The local CLI version is not compared in Profile Lab.
          final versionOnly = !probeRes.ready &&
              probeRes.issueCode ==
                  WorkerIssueCode.unsupportedProviderToolVersion;
          if (probeRes.ready || versionOnly) {
            observedAcceptanceScenarios['passive_probe'] = 'passed';
            addStage(
              stageId: 'passive_probe',
              displayName: 'Passive Probe',
              status: 'passed',
              durationMs: s5Timer.elapsedMilliseconds,
              diagnostics: versionOnly
                  ? 'Passive probe clean apart from the CLI version range, '
                      'which Profile Lab does not compare.'
                  : 'Passive probe clean. Non-model contract checks passed.',
              consumesQuota: false,
            );
          } else {
            observedAcceptanceScenarios['passive_probe'] = 'failed';
            haltExecution = true;
            addStage(
              stageId: 'passive_probe',
              displayName: 'Passive Probe',
              status: 'failed',
              durationMs: s5Timer.elapsedMilliseconds,
              diagnostics:
                  'Passive probe issue: ${probeRes.issueCode ?? "probe_failed"}',
              consumesQuota: false,
              issueCode: probeRes.issueCode ?? 'passive_probe_failed',
            );
          }
        } catch (e) {
          observedAcceptanceScenarios['passive_probe'] = 'failed';
          s5Timer.stop();
          haltExecution = true;
          addStage(
            stageId: 'passive_probe',
            displayName: 'Passive Probe',
            status: 'failed',
            durationMs: s5Timer.elapsedMilliseconds,
            diagnostics: 'Passive probe exception: $e',
            consumesQuota: false,
            issueCode: 'passive_probe_exception',
          );
        }
      }

      // --- STAGE 6: Provider Usage Check ---
      // Runs the Profile's usage command through the Engine's live probe. No
      // model is called, so a limit on one model cannot fail the Worker.
      final s6Timer = Stopwatch()..start();
      if (haltExecution) {
        s6Timer.stop();
        addStage(
          stageId: 'usage_check',
          displayName: 'Provider Usage Check',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to a prior failure.',
          consumesQuota: false,
        );
      } else if (candidate.profile['usage'] is! Map) {
        s6Timer.stop();
        observedAcceptanceScenarios['usage_check'] = 'failed';
        haltExecution = true;
        addStage(
          stageId: 'usage_check',
          displayName: 'Provider Usage Check',
          status: 'failed',
          durationMs: 0,
          diagnostics:
              'The Tool Profile must declare a usage command; it replaces the '
              'live model call when checking the provider.',
          consumesQuota: false,
          issueCode: 'usage_command_missing',
        );
      } else {
        try {
          final probeRes = await supervisor.probe(
            candidate,
            profileFile: profileTempFile,
            stateDirectory: scratchDir,
            mode: WorkerProbeMode.live,
            timeout: const Duration(seconds: 30),
          );
          s6Timer.stop();
          if (probeRes.ready) {
            observedAcceptanceScenarios['usage_check'] = 'passed';
            addStage(
              stageId: 'usage_check',
              displayName: 'Provider Usage Check',
              status: 'passed',
              durationMs: s6Timer.elapsedMilliseconds,
              diagnostics: 'The provider answered the usage command.',
              consumesQuota: false,
            );
          } else {
            observedAcceptanceScenarios['usage_check'] = 'failed';
            haltExecution = true;
            addStage(
              stageId: 'usage_check',
              displayName: 'Provider Usage Check',
              status: 'failed',
              durationMs: s6Timer.elapsedMilliseconds,
              diagnostics:
                  'Usage check issue: ${probeRes.issueCode ?? "usage_check_failed"}'
                  '${probeRes.checks.where((c) => c.status == ProbeCheckStatus.failed).map((c) => '\n${c.code}: ${c.message}').join()}',
              consumesQuota: false,
              issueCode: probeRes.issueCode ?? 'usage_check_failed',
            );
          }
        } catch (e) {
          observedAcceptanceScenarios['usage_check'] = 'failed';
          s6Timer.stop();
          haltExecution = true;
          addStage(
            stageId: 'usage_check',
            displayName: 'Provider Usage Check',
            status: 'failed',
            durationMs: s6Timer.elapsedMilliseconds,
            diagnostics: 'Usage check exception: $e',
            consumesQuota: false,
            issueCode: 'usage_check_exception',
          );
        }
      }

      _activeSupervisor = null;
    } finally {
      final supervisor = _activeSupervisor;
      final assignmentId = _activeAssignmentId;
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      Future<void> attemptCleanup(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          cleanupFailure ??= error;
          cleanupStack ??= stack;
        }
      }

      if (supervisor != null && assignmentId != null) {
        await attemptCleanup(() async {
          await supervisor.cancel(assignmentId);
        });
      }
      if (supervisor != null) {
        await attemptCleanup(supervisor.shutdown);
      }
      _activeSupervisor = null;
      _activeAssignmentId = null;
      await attemptCleanup(() async {
        final parent = await scratchDir.parent.resolveSymbolicLinks();
        if (parent != canonicalRoot) {
          throw FileSystemException(
            'Refusing to remove scratch data outside the sandbox root',
            scratchDir.path,
          );
        }
        final scratchType = await FileSystemEntity.type(
          scratchDir.path,
          followLinks: false,
        );
        if (scratchType == FileSystemEntityType.directory) {
          await _deleteSandboxTreeWithoutFollowingLinks(scratchDir);
          await scratchDir.delete();
        } else if (scratchType == FileSystemEntityType.link) {
          await Link(scratchDir.path).delete();
          throw FileSystemException(
            'Sandbox scratch directory was replaced by a symbolic link',
            scratchDir.path,
          );
        } else if (scratchType != FileSystemEntityType.notFound) {
          await File(scratchDir.path).delete();
          throw FileSystemException(
            'Sandbox scratch directory changed type during execution',
            scratchDir.path,
          );
        }
      });
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(cleanupFailure!, cleanupStack!);
      }
    }

    final endedAt = DateTime.now().toUtc();
    final overallResult =
        stages.any((s) => s.status == 'failed') ? 'fail' : 'pass';

    final allAcceptanceScenariosObserved = cloudAcceptanceScenarioNames.every(
      (scenario) =>
          observedAcceptanceScenarios[scenario] ==
          expectedAcceptanceScenarios[scenario],
    );
    final acceptanceEvidence = overallResult == 'pass' &&
            allAcceptanceScenariosObserved &&
            detectedProviderToolVersion != null
        ? ToolProfileAcceptanceEvidence(
            profileDefinitionId: candidate.profileDefinitionId,
            releaseVersion: candidate.releaseVersion,
            profileDigest: candidate.payloadDigest,
            logicalWorkerTypeId: candidate.logicalWorkerTypeId,
            engineVersion: cliWorkerEngineVersion,
            providerToolName: candidate.providerToolName,
            providerToolVersion: detectedProviderToolVersion,
            acceptedAt: endedAt.toIso8601String(),
            scenarios: observedAcceptanceScenarios,
          )
        : null;
    final publicationEvidence = overallResult == 'pass' &&
            allAcceptanceScenariosObserved &&
            detectedProviderToolVersion != null
        ? ToolProfilePublicationEvidence(
            workerTypeId: candidate.logicalWorkerTypeId,
            candidateDigest: candidate.payloadDigest,
            engineVersion: cliWorkerEngineVersion,
            providerToolName: candidate.providerToolName,
            providerToolVersion: detectedProviderToolVersion,
            testedAt: endedAt.toIso8601String(),
            scenarios: Map<String, String>.from(observedAcceptanceScenarios),
          )
        : null;

    return ProfileLabLadderResult(
      overallResult: overallResult,
      startedAt: startedAt,
      endedAt: endedAt,
      stages: stages,
      acceptanceEvidence: acceptanceEvidence,
      publicationEvidence: publicationEvidence,
      logs: logs,
    );
  }
}

/// The host PATH plus the directories the Connect service launch agent puts
/// on PATH (`com.syntila.workspace.service.plist`). A Finder-launched
/// Profile Lab only gets `/usr/bin:/bin:/usr/sbin:/sbin`, so provider CLIs
/// that call helpers such as `gh` for login (Copilot `--headless`) would
/// otherwise behave differently in Profile Lab than in Connect.
String providerSearchPath(Map<String, String> environment) {
  final separator = Platform.isWindows ? ';' : ':';
  final entries = (environment['PATH'] ?? '')
      .split(separator)
      .where((entry) => entry.isNotEmpty)
      .toList();
  if (Platform.isMacOS) {
    for (final directory in const [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ]) {
      if (!entries.contains(directory)) entries.add(directory);
    }
  }
  return entries.join(separator);
}
