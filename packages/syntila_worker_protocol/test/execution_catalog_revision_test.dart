import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:test/test.dart';

void main() {
  ExecuteRequest request({String? revision, String protocol = '4.1'}) =>
      ExecuteRequest(
          requestId: 'r',
          assignmentId: 'a',
          prompt: 'p',
          timeoutMs: 1000,
          sessionPolicy: WorkerSessionPolicy.stateless,
          catalogRevision: revision,
          protocolVersion: protocol);
  test('4.1 carries catalog identity while 4.0 remains readable', () {
    final frame = request(revision: 'a' * 64);
    expect(ExecuteRequest.fromJson(frame.toJson()).catalogRevision, 'a' * 64);
    expect(
        ExecuteRequest.fromJson(request(protocol: '4.0').toJson())
            .catalogRevision,
        isNull);
    expect(
        negotiateProtocolVersion(
            connectVersions: ['4.0', '4.1'], engineVersions: ['4.0', '4.1']),
        '4.1');
  });
  test('rejects invalid pins, legacy pin injection and native arguments', () {
    expect(() => request(revision: 'bad'), throwsFormatException);
    expect(() => request(protocol: '4.0', revision: 'a' * 64),
        throwsFormatException);
    expect(
        () => ExecuteRequest.fromJson(
            {...request().toJson(), 'resolvedNativeModelId': 'arbitrary'}),
        throwsFormatException);
  });
}
