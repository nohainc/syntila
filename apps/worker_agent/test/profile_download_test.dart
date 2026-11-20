import 'dart:convert';
import 'dart:io';

import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

void main() {
  test('downloads a pinned Profile with the current Worker session', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = server.first.then((request) async {
      expect(request.uri.path, '/api/worker-agent/profile');
      expect(request.uri.queryParameters, {
        'revision': '4',
        'digest': 'digest',
      });
      expect(request.headers.value('authorization'), 'Bearer secret');
      expect(request.headers.value('x-worker-id'), 'worker');
      expect(request.headers.value('x-worker-session-id'), 'session');
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'snapshot': {'revision': 4},
          'proof': 'proof',
        }),
      );
      await request.response.close();
    });
    final api = ServerApi('http://127.0.0.1:${server.port}');
    addTearDown(api.close);
    final result = await api.downloadProfile(
      workerId: 'worker',
      session: const SessionGrant(
        sessionId: 'session',
        epoch: 1,
        sessionToken: 'secret',
        leaseSeconds: 30,
      ),
      revision: 4,
      digest: 'digest',
    );
    await received;
    expect(result.snapshot, {'revision': 4});
    expect(result.proof, 'proof');
  });
}
