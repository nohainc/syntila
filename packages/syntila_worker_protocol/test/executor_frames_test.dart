import 'dart:convert';

import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

WorkerExecutor executor({List<String> env = const ['ACME_ENDPOINT']}) =>
    WorkerExecutor(
      pluginId: 'acme-reviewer',
      version: '1.4.2',
      manifestDigest: 'a' * 64,
      artifactSha256: 'b' * 64,
      executable: '/state/Plugins/plugin-3fa91c04b2d7/1.4.2/bin/reviewer',
      dataDirectory: '/state/Plugins/plugin-3fa91c04b2d7/data',
      arguments: const ['--syntila'],
      environmentNames: env,
    );

ExecuteRequest request({
  WorkerExecutor? withExecutor,
  String protocolVersion = pluginExecutorProtocolVersion,
}) =>
    ExecuteRequest(
      requestId: 'r1',
      assignmentId: 'a1',
      prompt: 'hi',
      timeoutMs: 1000,
      sessionPolicy: WorkerSessionPolicy.stateless,
      executor: withExecutor,
      protocolVersion: protocolVersion,
    );

void main() {
  test('round-trips a plugin execute request on protocol 4.2', () {
    final frame = request(withExecutor: executor());
    final decoded = decodeWorkerFrame(frame.encode()) as ExecuteRequest;
    expect(decoded.protocolVersion, '4.2');
    expect(decoded.executor?.pluginId, 'acme-reviewer');
    expect(decoded.executor?.arguments, ['--syntila']);
    expect(decoded.executor?.environmentNames, ['ACME_ENDPOINT']);
  });

  test('profile execution is unchanged and carries no executor key', () {
    final frame = request(protocolVersion: '4.1');
    expect(frame.toJson().containsKey('executor'), isFalse);
    expect(
        (decodeWorkerFrame(frame.encode()) as ExecuteRequest).executor, isNull);
  });

  test('an executor requires protocol 4.2', () {
    expect(
      () => request(withExecutor: executor(), protocolVersion: '4.1'),
      throwsFormatException,
    );
  });

  test('rejects unknown executor fields, bad digests and unsafe values', () {
    final json =
        Map<String, Object?>.from(request(withExecutor: executor()).toJson());
    final inner = Map<String, Object?>.from(json['executor'] as Map);
    String line(Map<String, Object?> patch) => jsonEncode({
          ...json,
          'executor': {...inner, ...patch},
        });
    for (final patch in <Map<String, Object?>>[
      {'extra': 1},
      {'kind': 'provider'},
      {'manifestDigest': 'A' * 64},
      {'artifactSha256': 'abc'},
      {'executable': 'relative/path'},
      {'dataDirectory': ''},
      {'pluginId': 'Not Kebab'},
      {'version': '1.4'},
      {
        'environmentNames': ['SYNTILA_TOKEN']
      },
      {
        'environmentNames': ['lowercase']
      },
      {'arguments': List<String>.filled(33, 'x')},
    ]) {
      expect(() => decodeWorkerFrame(line(patch)), throwsFormatException,
          reason: '$patch');
    }
  });

  test('negotiation can select 4.2 when both sides support it', () {
    expect(
      negotiateProtocolVersion(
        workspaceVersions: ['4.1', '4.2'],
        workerVersions: ['4.0', '4.1', '4.2'],
      ),
      '4.2',
    );
    expect(
      negotiateProtocolVersion(
        workspaceVersions: ['4.1', '4.2'],
        workerVersions: ['4.0', '4.1'],
      ),
      '4.1',
    );
  });

  test('initialize carries the plugin identity and pins the manifest digest',
      () {
    InitializeRequest build({String digest = ''}) => InitializeRequest(
          requestId: 'i1',
          workerTypeId: 'plugin-3fa91c04b2d7',
          expectedEngineVersion: '1.4.0',
          profileDefinitionId: 'plugin-acme-reviewer',
          profileReleaseVersion: '1.4.2',
          profileDigest: digest.isEmpty ? 'a' * 64 : digest,
          executor: executor(),
          protocolVersion: pluginExecutorProtocolVersion,
        );
    final decoded = decodeWorkerFrame(build().encode()) as InitializeRequest;
    expect(decoded.executor?.manifestDigest, 'a' * 64);
    expect(() => build(digest: 'c' * 64), throwsFormatException);
    expect(
      () => InitializeRequest(
        requestId: 'i1',
        workerTypeId: 'chatgpt',
        expectedEngineVersion: '1.4.0',
        profileDefinitionId: 'chatgpt-codex',
        profileReleaseVersion: '1',
        profileDigest: 'a' * 64,
        executor: executor(),
      ),
      throwsFormatException,
    );
  });
}
