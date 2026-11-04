import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/desktop_auth.dart';
import 'package:syntila_workspace/plugin_cloud.dart';
import 'package:syntila_workspace/plugin_service.dart';
import 'package:syntila_workspace/secure_credentials.dart';
import 'package:test/test.dart';

class MemoryCredentials implements SecureCredentialStore {
  final values = <String, String>{};
  @override
  String? readSync(String key) => values[key];
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

late HttpServer server;
late MemoryCredentials credentials;
final requests = <({String method, String path, String auth, Object? body})>[];
var respond = (HttpRequest r) async {
  r.response.statusCode = 200;
  r.response.write('{}');
};

HttpPluginCloud cloud({int? port, String? workspaceId = 'ws-1'}) =>
    HttpPluginCloud(
      cloudUrl: 'http://127.0.0.1:${port ?? server.port}',
      credentialStore: credentials,
      workspaceId: workspaceId,
      timeout: const Duration(seconds: 2),
    );

Future<void> signIn({DateTime? expires}) async {
  await credentials.write(
    desktopHumanCredentialKey,
    jsonEncode({
      'credential': 'syntila_dhs_abc',
      'sessionId': 's1',
      'userId': 'u1',
      'displayName': 'U',
      'email': 'u@example.com',
      'expiresAt': (expires ?? DateTime.now().add(const Duration(days: 1)))
          .toUtc()
          .toIso8601String(),
    }),
  );
}

Future<void> expectCloudCode(Future<Object?> future, String code) =>
    expectLater(
      future,
      throwsA(isA<PluginCloudException>().having((e) => e.code, 'code', code)),
    );

void main() {
  setUp(() async {
    credentials = MemoryCredentials();
    requests.clear();
    respond = (r) async {
      r.response.statusCode = 200;
      r.response.write('{}');
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      requests.add((
        method: request.method,
        path: request.uri.toString(),
        auth: request.headers.value(HttpHeaders.authorizationHeader) ?? '',
        body: text.isEmpty ? null : jsonDecode(text),
      ));
      await respond(request);
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('registers with the human session and sends only metadata', () async {
    await signIn();
    respond = (r) async {
      r.response.statusCode = 201;
      r.response.write('{"pluginRef":"plugin-3fa91c04b2d7"}');
    };
    final ref = await cloud().registerVersion(
      manifest: {'pluginId': 'acme', 'version': '1.0.0'},
      manifestDigest: 'a' * 64,
      origin: {
        'kind': 'local_path',
        'locator': 'pkg',
        'importedAt': '2026-11-03T00:00:00Z',
      },
      signer: {'fingerprint': 'f' * 64, 'verified': true, 'keyId': 'k'},
    );
    expect(ref, 'plugin-3fa91c04b2d7');
    final sent = requests.single;
    expect(sent.method, 'POST');
    expect(sent.path, '/api/me/worker-plugins');
    expect(sent.auth, 'Bearer syntila_dhs_abc');
    final body = sent.body as Map;
    expect((body['origin'] as Map).keys, {'kind', 'locator'});
    expect((body['signer'] as Map).keys, {'fingerprint', 'verified'});
    expect(jsonEncode(body), isNot(contains('/Users')));
  });

  test('enablement targets this Workspace and carries the consent hash',
      () async {
    await signIn();
    await cloud().setEnablement(
      pluginRef: 'plugin-3fa91c04b2d7',
      version: '1.0.0',
      manifestDigest: 'a' * 64,
      consentHash: 'c' * 64,
      enabled: true,
      shareable: false,
    );
    expect(requests.single.method, 'PUT');
    expect(
      requests.single.path,
      '/api/workspaces/ws-1/worker-plugins/plugin-3fa91c04b2d7',
    );
    expect((requests.single.body as Map)['consentHash'], 'c' * 64);
  });

  test('requires a live human session for account actions', () async {
    await expectCloudCode(
      cloud().removeFromLibrary('plugin-3fa91c04b2d7'),
      'login_required',
    );
    await signIn(expires: DateTime.now().subtract(const Duration(hours: 1)));
    await expectCloudCode(
      cloud().removeFromLibrary('plugin-3fa91c04b2d7'),
      'login_required',
    );
    expect(requests, isEmpty);
  });

  test('maps Cloud statuses to stable error codes', () async {
    await signIn();
    for (final (status, body, code) in [
      (400, '{"code":"plugin_digest_mismatch"}', 'plugin_digest_mismatch'),
      (401, '{}', 'login_required'),
      (402, '{"code":"paid_plan_required"}', 'paid_plan_required'),
      (404, '{}', 'plugin_not_found'),
      (409, '{"code":"plugin_in_use"}', 'plugin_in_use'),
      (409, '{}', 'plugin_version_conflict'),
      (500, '<html>', 'cloud_unavailable'),
    ]) {
      respond = (r) async {
        r.response.statusCode = status;
        r.response.write(body);
      };
      await expectCloudCode(
        cloud().removeFromLibrary('plugin-3fa91c04b2d7'),
        code,
      );
    }
  });

  test('preserves the safe Cloud message for a bad plugin request', () async {
    await signIn();
    respond = (r) async {
      r.response.statusCode = 400;
      r.response.write(
        '{"code":"plugin_manifest_invalid","message":"Manifest is invalid at access.network"}',
      );
    };
    await expectLater(
      cloud().removeFromLibrary('plugin-3fa91c04b2d7'),
      throwsA(
        isA<PluginCloudException>()
            .having((e) => e.code, 'code', 'plugin_manifest_invalid')
            .having(
              (e) => e.message,
              'message',
              'Manifest is invalid at access.network',
            ),
      ),
    );
  });

  test('an unreachable Cloud is cloud_unavailable', () async {
    await signIn();
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close(force: true);
    await expectCloudCode(
      cloud(port: port).removeFromLibrary('plugin-3fa91c04b2d7'),
      'cloud_unavailable',
    );
  });

  test('rejects an invalid plugin reference from Cloud', () async {
    await signIn();
    respond = (r) async {
      r.response.write('{"pluginRef":"chatgpt"}');
    };
    await expectCloudCode(
      cloud().registerVersion(
        manifest: const {},
        manifestDigest: 'a' * 64,
        origin: const {'kind': 'local_path', 'locator': 'x'},
        signer: null,
      ),
      'cloud_unavailable',
    );
  });
}
