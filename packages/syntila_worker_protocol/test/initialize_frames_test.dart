import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('initialize request and result round-trip as protocol 4.0 frames', () {
    final request = InitializeRequest(
      requestId: 'init-1',
      workerTypeId: 'chatgpt',
      expectedEngineVersion: '1.0.0',
      profileDefinitionId: 'chatgpt-codex',
      profileReleaseVersion: '1.0.0',
      profileDigest: 'a' * 64,
    );
    expect(decodeWorkerFrame(request.encode()).toJson(), request.toJson());

    final result = InitializeResult(
      requestId: request.requestId,
      workerTypeId: 'chatgpt',
      engineVersion: '1.0.0',
      profileDefinitionId: 'chatgpt-codex',
      profileReleaseVersion: '1.0.0',
      profileSchemaVersion: 1,
      capabilities: const ['initialize'],
    );
    expect(decodeWorkerFrame(result.encode()).toJson(), result.toJson());
  });

  test('negotiates the highest common protocol version', () {
    expect(
      negotiateProtocolVersion(
        connectVersions: const ['2.0', '4.0'],
        engineVersions: const ['2.0', '4.0'],
      ),
      '4.0',
    );
    expect(
      negotiateProtocolVersion(
        connectVersions: const ['2.6'],
        engineVersions: const ['2.6'],
      ),
      isNull,
    );
  });

  test('rejects an oversized capability list', () {
    expect(
      () => InitializeResult(
        requestId: 'init-1',
        workerTypeId: 'chatgpt',
        engineVersion: '1.0.0',
        profileDefinitionId: 'chatgpt-codex',
        profileReleaseVersion: '1.0.0',
        profileSchemaVersion: 1,
        capabilities: List.filled(
          WorkerProtocolLimits.maxCapabilities + 1,
          'x',
        ),
      ),
      throwsFormatException,
    );
  });
}
