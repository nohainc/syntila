import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';
import 'engine.dart';
import 'folders.dart';
import 'git_reference.dart';
import 'journal.dart';
import 'output_images.dart';
import 'server_api.dart';
import 'thread_fence.dart';
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
class ArtifactLauncher
    implements EngineLauncher, ModelCatalogSource, UsageSource {
  ArtifactLauncher({
    required this.inner,
    required this.folders,
    required this.workRoot,
    required this.client,
    required this.holder,
    required this.workerId,
    this.log,
  });

  /// Writes one line to the Agent's log (image upload outcomes).
  final void Function(String line)? log;

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
  Future<Map<String, Object?>> discoverModels(Map<String, Object?> pin) async {
    final source = inner;
    return source is ModelCatalogSource
        ? (source as ModelCatalogSource).discoverModels(pin)
        : {'status': 'engine_unavailable'};
  }

  @override
  Future<Map<String, Object?>> readUsage(Map<String, Object?> pin) async {
    final source = inner;
    return source is UsageSource
        ? (source as UsageSource).readUsage(pin)
        : {
            'status': 'error',
            'errorCode': 'engine_unavailable',
            'errorMessage': 'The Engine is not available on this computer.',
          };
  }

  @override
  Future<EngineRun> launch(EngineRequest request) async =>
      _WithImages(this, await _launch(request), request.assignmentId);

  /// Uploads the images the Engine adapter found and lists them in
  /// `output.images`. An image that fails to upload is skipped so the
  /// answer is never lost; local paths never reach Cloud.
  Future<EngineOutcome> publishImages(
    String assignmentId,
    EngineOutcome result,
  ) async {
    final local = result.payload[localOutputImagesKey];
    if (local == null) return result;
    final payload = {...result.payload}..remove(localOutputImagesKey);
    final session = holder.grant;
    final images = <Map<String, Object?>>[];
    log?.call(
      'output images assignment=$assignmentId found=${local is List ? local.length : 0} '
      'session=${session != null}',
    );
    if (result.kind == TerminalKind.completed &&
        session != null &&
        local is List) {
      for (final path in local.whereType<String>()) {
        try {
          final descriptor = await client.uploadOutputImage(
            session: session,
            workerId: workerId,
            assignmentId: assignmentId,
            file: File(path),
          );
          // A preview for the Thread; the original is opened or downloaded.
          String? preview;
          try {
            if (isOutputImage(path)) {
              preview = await outputImagePreview(File(path));
            } else if (isOutputVideo(path)) {
              preview = await outputVideoPreview(File(path));
            }
          } on Object catch (error) {
            log?.call('output image preview failed: $error');
          }
          images.add({
            ...descriptor,
            if (preview != null) 'previewImage': preview,
          });
        } on Object catch (error) {
          log?.call('output image upload failed: $error');
          continue;
        }
      }
    }
    final output = payload['output'];
    if (images.isNotEmpty) {
      payload['output'] = {
        if (output is Map<String, Object?>) ...output,
        'images': images,
      };
    }
    return EngineOutcome(result.kind, payload);
  }

  Future<EngineRun> _launch(EngineRequest request) async {
    final snapshot = request.payload['snapshot'];
    if (snapshot is! Map<String, Object?>) return inner.launch(request);
    final refs = snapshot['contextRefs'];
    final spaceId = snapshot['spaceId'];
    if (spaceId is! String) return inner.launch(request);
    final token = snapshot['fencingToken'];
    final threadId = snapshot['threadId'];
    if (token != null) {
      // A stateful step: the lease's fencing token must not be stale.
      final fence = ThreadFence(
        File('${workRoot.file.parent.path}/thread-fences.json'),
      );
      bool ok;
      try {
        ok =
            token is int &&
            threadId is String &&
            await fence.admit(threadId, token);
      } on FormatException {
        ok = false;
      }
      if (!ok) return _Failed('stale_fence');
    }
    if (!validGitReferences(snapshot['gitReferences'])) {
      return _Failed('invalid_git_reference');
    }

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
        onActivity: request.onActivity,
      ),
    );
    return _Collecting(
      this,
      run,
      request.assignmentId,
      base,
      outputs,
      declaredOutputs(snapshot['artifactOutputs']),
    );
  }

  /// Uploads the regular files directly in [outputs] whose names match a
  /// declared pattern (links and subfolders are skipped) and returns the
  /// descriptors for the result. A step that declared nothing uploads nothing.
  Future<List<Map<String, Object?>>> collect(
    String assignmentId,
    Directory base,
    Directory outputs,
    List<String> declared,
  ) async {
    final session = holder.grant;
    final results = <Map<String, Object?>>[];
    if (declared.isEmpty || !await outputs.exists()) return results;
    final files = await outputs
        .list(followLinks: false)
        .where(
          (e) =>
              e is File && matchesDeclaredOutput(declared, p.basename(e.path)),
        )
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

class _WithImages implements EngineRun, EngineStartEvidence {
  _WithImages(this.owner, this.run, this.assignmentId);

  final ArtifactLauncher owner;
  final EngineRun run;
  final String assignmentId;

  @override
  Future<bool> get providerStarted {
    final inner = run;
    return inner is EngineStartEvidence
        ? (inner as EngineStartEvidence).providerStarted
        : Future.value(false);
  }

  /// Cached: the outcome is read more than once and uploads must run once.
  @override
  late final Future<EngineOutcome> outcome = run.outcome.then(
    (result) => owner.publishImages(assignmentId, result),
  );

  @override
  Future<void> cancel() => run.cancel();
}

class _Collecting implements EngineRun, EngineStartEvidence {
  _Collecting(
    this.owner,
    this.run,
    this.assignmentId,
    this.base,
    this.outputs,
    this.declared,
  );

  final ArtifactLauncher owner;
  final EngineRun run;
  final String assignmentId;
  final Directory base;
  final Directory outputs;
  final List<String> declared;

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
      final artifacts = await owner.collect(
        assignmentId,
        base,
        outputs,
        declared,
      );
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

final _declaredPattern = RegExp(r'^[A-Za-z0-9._*-]{1,100}$');

bool _validPattern(String pattern) =>
    _declaredPattern.hasMatch(pattern) &&
    '*'.allMatches(pattern).length <= 1 &&
    pattern != '.' &&
    pattern != '..';

/// The valid output patterns of a payload (at most 8). Mirrors
/// packages/core/src/artifact-outputs.ts; the server checks them again.
List<String> declaredOutputs(Object? raw) {
  if (raw is! List) return const [];
  final result = <String>[];
  for (final item in raw) {
    if (item is String && _validPattern(item) && !result.contains(item)) {
      result.add(item);
    }
    if (result.length >= 8) break;
  }
  return result;
}

bool matchesDeclaredOutput(List<String> patterns, String name) {
  for (final pattern in patterns) {
    final star = pattern.indexOf('*');
    if (star < 0) {
      if (pattern == name) return true;
      continue;
    }
    final head = pattern.substring(0, star);
    final tail = pattern.substring(star + 1);
    if (name.length >= head.length + tail.length &&
        name.startsWith(head) &&
        name.endsWith(tail)) {
      return true;
    }
  }
  return false;
}
