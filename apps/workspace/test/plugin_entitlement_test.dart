import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/plugin_entitlement.dart';
import 'package:test/test.dart';

/// Produced by the real TypeScript issuer (`issuePluginEntitlementLease`), so
/// this test proves the Dart verifier accepts exactly what Cloud signs.
const _publicKey = "lkioBdUQgez7WQJ+GDKA2aeV28mrD8IVbOvj9DCEP90=";
final _envelope = jsonDecode(r'''{
  "lease": {
    "v": 1,
    "kid": "ent-1",
    "feature": "workers.custom_plugins",
    "ownerUserId": "user-plus",
    "workspaceId": "ws-1",
    "installationId": "inst-1",
    "leaseId": "lease-interop-1",
    "issuedAt": "2026-11-03T10:00:00.000Z",
    "expiresAt": "2026-11-04T10:00:00.000Z",
    "planStatus": "active",
    "planPeriodEnd": null
  },
  "signature": "XysqTeDvrr4M77Nu77Q0afhPBFL5mKQN6cpW1NX0ukv3QnQAOEd0N+eZd6yvMlnV1g0YVe2SkxKuDuNIigGlCw=="
}''') as Map<String, Object?>;

final _issued = DateTime.utc(2026, 11, 3, 10);
DateTime hours(num n) => _issued.add(Duration(minutes: (n * 60).round()));

PluginLeaseVerifier verifier([String key = _publicKey]) => PluginLeaseVerifier({
      pluginEntitlementPublisher: {'ent-1': key},
    });

Future<PluginLeaseVerification> verify(
  Object? envelope, {
  DateTime? now,
  DateTime? mark,
  PluginLeaseVerifier? using,
  String owner = 'user-plus',
}) =>
    (using ?? verifier()).verify(
      envelope,
      ownerUserId: owner,
      workspaceId: 'ws-1',
      installationId: 'inst-1',
      now: now ?? hours(1),
      highWaterMark: mark,
    );

Map<String, Object?> edited(void Function(Map<String, Object?> lease) edit) {
  final copy = jsonDecode(jsonEncode(_envelope)) as Map<String, Object?>;
  edit(copy['lease'] as Map<String, Object?>);
  return copy;
}

void main() {
  test('accepts a lease signed by the TypeScript issuer', () async {
    final result = await verify(_envelope);
    expect(result.isValid, isTrue);
    expect(result.lease!.leaseId, 'lease-interop-1');
    expect(result.lease!.expiresAt, hours(24));
  });

  test('canonical JSON sorts keys and matches the signed form', () {
    expect(
        canonicalJson({
          'b': 1,
          'a': [null, true, 'x'],
          'c': {'z': 1, 'y': 2}
        }),
        '{"a":[null,true,"x"],"b":1,"c":{"y":2,"z":1}}');
  });

  test('rejects an edited lease, another key and an unconfigured trust root',
      () async {
    expect(
      (await verify(edited((l) => l['expiresAt'] = '2026-12-31T00:00:00.000Z')))
          .rejection,
      PluginLeaseRejection.signatureInvalid,
    );
    final other = base64Encode(List<int>.filled(32, 7));
    expect(
      (await verify(_envelope, using: verifier(other))).rejection,
      PluginLeaseRejection.signatureInvalid,
    );
    expect(
      (await verify(_envelope, using: const PluginLeaseVerifier({}))).rejection,
      PluginLeaseRejection.signatureInvalid,
    );
  });

  test('is bound to owner, Workspace and installation', () async {
    expect((await verify(_envelope, owner: 'someone-else')).rejection,
        PluginLeaseRejection.bindingMismatch);
  });

  test('expires exactly at expiresAt with no extra grace', () async {
    expect((await verify(_envelope, now: hours(23.9))).isValid, isTrue);
    expect((await verify(_envelope, now: hours(24))).rejection,
        PluginLeaseRejection.expired);
  });

  test('detects a rolled-back clock using the high-water mark', () async {
    expect(
      (await verify(_envelope, now: hours(1), mark: hours(10))).rejection,
      PluginLeaseRejection.entitlementClockInvalid,
    );
    expect(
      (await verify(_envelope, now: hours(10), mark: hours(10))).isValid,
      isTrue,
    );
  });

  test('rejects malformed envelopes and unknown or missing claims', () async {
    for (final bad in <Object?>[
      null,
      'x',
      {'lease': {}, 'signature': 'x'},
      {..._envelope, 'extra': 1},
      edited((l) => l['extra'] = 1),
      edited((l) => l.remove('kid')),
      edited((l) => l['feature'] = 'other'),
      edited((l) => l['planStatus'] = 'canceled'),
      edited((l) => l['issuedAt'] = 'not a date'),
    ]) {
      expect((await verify(bad)).rejection, PluginLeaseRejection.malformed,
          reason: '$bad');
    }
  });

  group('store', () {
    late Directory dir;
    late DateTime now;
    PluginEntitlementStore store({PluginLeaseVerifier? using}) =>
        PluginEntitlementStore(
          file: File('${dir.path}/entitlement.json'),
          verifier: using ?? verifier(),
          ownerUserId: 'user-plus',
          workspaceId: 'ws-1',
          installationId: 'inst-1',
          clock: () => now,
        );

    setUp(() {
      dir = Directory.systemTemp.createTempSync('entitlement');
      now = hours(1);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('has no entitlement until a valid lease is accepted', () async {
      expect((await store().status()).reason, 'no_lease');
      expect((await store().accept(edited((l) => l['leaseId'] = 'x'))).isValid,
          isFalse);
      expect((await store().status()).entitled, isFalse);
      expect((await store().accept(_envelope)).isValid, isTrue);
      final status = await store().status();
      expect(status.entitled, isTrue);
      expect(status.toJson(now)['offlineRemainingSeconds'], 23 * 3600);
    });

    test('lapses when the lease expires, offline', () async {
      await store().accept(_envelope);
      now = hours(24);
      final status = await store().status();
      expect(status.entitled, isFalse);
      expect(status.reason, 'expired');
    });

    test('editing the stored file cannot extend or forge a lease', () async {
      await store().accept(_envelope);
      final file = File('${dir.path}/entitlement.json');
      final state = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      ((state['envelope'] as Map)['lease'] as Map)['expiresAt'] =
          '2030-01-01T00:00:00.000Z';
      file.writeAsStringSync(jsonEncode(state));
      expect((await store().status()).reason, 'signatureInvalid');
      file.writeAsStringSync('not json');
      expect((await store().status()).reason, 'no_lease');
    });

    test('rolling the clock back is detected after Cloud time was seen',
        () async {
      await store().accept(_envelope);
      await store().observeCloudTime(hours(10));
      now = hours(2);
      expect((await store().status()).reason, 'entitlementClockInvalid');
      // The mark never moves backwards.
      await store().observeCloudTime(hours(3));
      expect((await store().status()).reason, 'entitlementClockInvalid');
    });
  });
}
