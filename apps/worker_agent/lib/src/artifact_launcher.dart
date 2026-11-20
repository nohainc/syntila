import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import 'engine.dart';
import 'folders.dart';
import 'journal.dart';
import 'server_api.dart';
import 'work_root.dart';

/// The live session of the Agent, kept current by the connection so the
/// artifact calls always use the newest epoch.
class AgentSessionHolder {
  SessionGrant? grant;
  void update(SessionGrant value) => grant = value;
}

/// Wraps an [EngineLauncher] with the file side of a step (ADR-037):
///
/// - before launch, every `contextRefs` artifact is downloaded (grant, session
///   and checksum checked) into this assignment's own `inputs` folder under the
///   Space's folder, and the Engine is told the local paths;
/// - after a completed step, files left in its `outputs` folder are uploaded and
///   the result carries artifact IDs, never paths.
///
/// Every folder is re-checked against the Allowed Folders right before it is
/// used. Local paths exist only in the Engine request; none is sent to Cloud.
class ArtifactLauncher implements EngineLauncher {
  ArtifactLauncher({
    required this.inner,
    required this.folders,
    required this.workRoot,
    required this.client,
    required this.holder,
    required this.workerId,
  });

  final EngineLauncher inner;
  final AllowedFolders folders;
  final WorkRoot workRoot;
  final ArtifactClient client;
  final AgentSessionHolder holder;
  final String workerId;

  @override
  Future<int> recoverOrphans() => inner.recoverOrphans();

  @override
  Future<String?> probe() => inner.probe();

  @override
  Future<EngineRun> launch(EngineRequest request) async {
    final snapshot = request.payload['snapshot'];
    if (snapshot is! Map<String, Object?>) return inner.launch(request);
    final refs = snapshot['contextRefs'];
    final spaceId = snapshot['spaceId'];
    if (spaceId is! String) return inner.launch(request);

    final Directory base;
    try {
      base = await workRoot.spaceDirectory(spaceId);
    } on FolderRejectedException {
      // No approved folder for this Space: nothing can be staged or collected.
      if (refs is List && refs.isNotEmpty) {
        return _Failed('folder_not_approved');
      }
      return inner.launch(request);
    }
    final assignmentDir = Directory(
      p.join(base.path, '.syntila', 'assignments', request.assignmentId),
    );
    final inputs = Directory(p.join(assignmentDir.path, 'inputs'));
    final outputs = Directory(p.join(assignmentDir.path, 'outputs'));
    final staged = <Map<String, Object?>>[];
    try {
      await folders.require(base.path, write: true);
      await outputs.create(recursive: true);
      final session = holder.grant;
      if (refs is List && refs.isNotEmpty) {
        // Every reference must be an artifact ID before anything is fetched.
        final parsed = [for (final raw in refs) ArtifactRef.parse(raw)];
        if (session == null) return _Failed('session_unavailable');
        for (final ref in parsed) {
          // Re-checked right before each write.
          await folders.require(base.path, write: true);
          final file = await client.download(
            session: session,
            workerId: workerId,
            ref: ref,
            directory: inputs,
          );
          staged.add({
            'artifactId': ref.artifactId,
            'name': ref.name,
            'path': file.path,
          });
        }
      }
    } on MissingArtifactException {
      return _Failed('missing_artifact');
    } on FolderRejectedException {
      return _Failed('folder_not_approved');
    } on ServerRefusal {
      return _Failed('missing_artifact');
    }

    final payload = {
      ...request.payload,
      'stagedInputs': staged,
      'outputDirectory': outputs.path,
    };
    final run = await inner.launch(
      EngineRequest(
        assignmentId: request.assignmentId,
        attemptId: request.attemptId,
        payload: payload,
        timeout: request.timeout,
      ),
    );
    return _Collecting(this, run, request.assignmentId, base, outputs);
  }

  /// Uploads every regular file under [outputs] (links are skipped) and
  /// returns the descriptors for the result.
  Future<List<Map<String, Object?>>> collect(
    String assignmentId,
    Directory base,
    Directory outputs,
  ) async {
    final session = holder.grant;
    final results = <Map<String, Object?>>[];
    if (!await outputs.exists()) return results;
    final files = await outputs
        .list(recursive: true, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      if (session == null) throw StateError('no session to upload with');
      await folders.require(base.path);
      final name = p.relative(file.path, from: outputs.path);
      final id = await client.upload(
        session: session,
        workerId: workerId,
        assignmentId: assignmentId,
        file: file,
        name: safeArtifactName(name),
      );
      results.add({
        'artifactId': id,
        'name': safeArtifactName(name),
        'sizeBytes': await file.length(),
      });
    }
    return results;
  }
}

class _Failed implements EngineRun {
  _Failed(String code)
    : outcome = Future.value(
        EngineOutcome(TerminalKind.failed, {
          'errorCode': code,
          'retryable': false,
        }),
      );

  @override
  final Future<EngineOutcome> outcome;

  @override
  Future<void> cancel() async {}
}

class _Collecting implements EngineRun, EngineStartEvidence {
  _Collecting(this.owner, this.run, this.assignmentId, this.base, this.outputs);

  final ArtifactLauncher owner;
  final EngineRun run;
  final String assignmentId;
  final Directory base;
  final Directory outputs;

  @override
  Future<bool> get providerStarted {
    final inner = run;
    return inner is EngineStartEvidence
        ? (inner as EngineStartEvidence).providerStarted
        : Future.value(false);
  }

  /// Cached: the outcome is read more than once and uploads must run once.
  @override
  late final Future<EngineOutcome> outcome = _finish();

  Future<EngineOutcome> _finish() async {
    final result = await run.outcome;
    if (result.kind != TerminalKind.completed) return result;
    try {
      final artifacts = await owner.collect(assignmentId, base, outputs);
      if (artifacts.isEmpty) return result;
      final output = result.payload['output'];
      return EngineOutcome(TerminalKind.completed, {
        ...result.payload,
        'artifactIds': [for (final a in artifacts) a['artifactId']],
        'output': {
          if (output is Map<String, Object?>) ...output,
          'artifacts': artifacts,
        },
      });
    } on Object {
      return const EngineOutcome(TerminalKind.failed, {
        'errorCode': 'artifact_upload_failed',
        'retryable': true,
      });
    }
  }

  @override
  Future<void> cancel() => run.cancel();
}
