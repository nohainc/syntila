import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

/// Paid feature name shared with Cloud (`PAID_FEATURES` in account-plan.ts).
const pluginPaidFeature = 'workers.custom_plugins';

/// Longest lease Cloud may issue; also the offline grace ceiling.
const pluginLeaseMaxTtl = Duration(hours: 24);

/// How far the local clock may trail the latest Cloud time already seen.
const pluginLeaseClockSkew = Duration(minutes: 5);

/// After a lapse, already-spawned plugin work may finish for this long.
const pluginLapseDrainMax = Duration(minutes: 30);

/// Trust-key publisher name for entitlement leases.
const pluginEntitlementPublisher = 'entitlement';

enum PluginLeaseRejection {
  malformed,
  signatureInvalid,
  ttlInvalid,
  bindingMismatch,
  entitlementClockInvalid,
  expired,
}

/// Same canonical form Cloud signs: keys sorted, no whitespace.
String canonicalJson(Object? value) {
  if (value is List) return '[${value.map(canonicalJson).join(',')}]';
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${canonicalJson(value[k])}').join(',')}}';
  }
  return jsonEncode(value);
}

class PluginEntitlementLease {
  const PluginEntitlementLease({
    required this.kid,
    required this.ownerUserId,
    required this.workspaceId,
    required this.installationId,
    required this.leaseId,
    required this.issuedAt,
    required this.expiresAt,
    required this.planStatus,
    required this.planPeriodEnd,
    required this.claims,
  });

  final String kid;
  final String ownerUserId;
  final String workspaceId;
  final String installationId;
  final String leaseId;
  final DateTime issuedAt;
  final DateTime expiresAt;
  final String planStatus;
  final DateTime? planPeriodEnd;

  /// The exact signed claims, for re-serialization.
  final Map<String, Object?> claims;
}

class PluginLeaseVerification {
  const PluginLeaseVerification.accepted(PluginEntitlementLease this.lease)
      : rejection = null;
  const PluginLeaseVerification.rejected(PluginLeaseRejection this.rejection)
      : lease = null;

  final PluginEntitlementLease? lease;
  final PluginLeaseRejection? rejection;
  bool get isValid => lease != null;
}

const _leaseKeys = {
  'v',
  'kid',
  'feature',
  'ownerUserId',
  'workspaceId',
  'installationId',
  'leaseId',
  'issuedAt',
  'expiresAt',
  'planStatus',
  'planPeriodEnd',
};

/// Reference-checked against the TypeScript issuer
/// (`apps/cloud/src/plugin-entitlement-lease.ts`): a vector it produced is
/// verified in the tests. Local files can lose or corrupt a lease but cannot
/// forge one; the gate that matters remains Cloud scheduling.
class PluginLeaseVerifier {
  const PluginLeaseVerifier(this.trustKeys);

  /// `{publisher: {keyId: base64 raw Ed25519 public key}}`.
  final Map<String, Map<String, String>> trustKeys;

  Future<PluginLeaseVerification> verify(
    Object? envelope, {
    required String ownerUserId,
    required String workspaceId,
    required String installationId,
    required DateTime now,
    DateTime? highWaterMark,
  }) async {
    PluginLeaseVerification reject(PluginLeaseRejection r) =>
        PluginLeaseVerification.rejected(r);
    if (envelope is! Map ||
        envelope.keys.toSet().difference({'lease', 'signature'}).isNotEmpty ||
        envelope['lease'] is! Map ||
        envelope['signature'] is! String) {
      return reject(PluginLeaseRejection.malformed);
    }
    final claims = Map<String, Object?>.from(envelope['lease'] as Map);
    if (claims.keys.toSet().difference(_leaseKeys).isNotEmpty ||
        _leaseKeys.difference(claims.keys.toSet()).isNotEmpty ||
        claims['v'] != 1 ||
        claims['feature'] != pluginPaidFeature ||
        !const {'active', 'trialing', 'past_due'}.contains(
          claims['planStatus'],
        )) {
      return reject(PluginLeaseRejection.malformed);
    }
    String text(String key) {
      final value = claims[key];
      if (value is! String || value.isEmpty || value.length > 128) {
        throw const FormatException('lease field');
      }
      return value;
    }

    final PluginEntitlementLease lease;
    try {
      final end = claims['planPeriodEnd'];
      lease = PluginEntitlementLease(
        kid: text('kid'),
        ownerUserId: text('ownerUserId'),
        workspaceId: text('workspaceId'),
        installationId: text('installationId'),
        leaseId: text('leaseId'),
        issuedAt: DateTime.parse(text('issuedAt')).toUtc(),
        expiresAt: DateTime.parse(text('expiresAt')).toUtc(),
        planStatus: text('planStatus'),
        planPeriodEnd:
            end == null ? null : DateTime.parse(end as String).toUtc(),
        claims: claims,
      );
    } on Object {
      return reject(PluginLeaseRejection.malformed);
    }

    if (!await _signatureValid(lease, envelope['signature'] as String)) {
      return reject(PluginLeaseRejection.signatureInvalid);
    }
    final ttl = lease.expiresAt.difference(lease.issuedAt);
    if (ttl <= Duration.zero || ttl > pluginLeaseMaxTtl) {
      return reject(PluginLeaseRejection.ttlInvalid);
    }
    if (lease.ownerUserId != ownerUserId ||
        lease.workspaceId != workspaceId ||
        lease.installationId != installationId) {
      return reject(PluginLeaseRejection.bindingMismatch);
    }
    final mark = highWaterMark != null && highWaterMark.isAfter(lease.issuedAt)
        ? highWaterMark
        : lease.issuedAt;
    if (now.isBefore(mark.subtract(pluginLeaseClockSkew))) {
      return reject(PluginLeaseRejection.entitlementClockInvalid);
    }
    if (!now.isBefore(lease.expiresAt) ||
        (lease.planPeriodEnd != null && !now.isBefore(lease.planPeriodEnd!))) {
      return reject(PluginLeaseRejection.expired);
    }
    return PluginLeaseVerification.accepted(lease);
  }

  Future<bool> _signatureValid(
    PluginEntitlementLease lease,
    String signature,
  ) async {
    try {
      final encodedKey = trustKeys[pluginEntitlementPublisher]?[lease.kid];
      if (encodedKey == null) return false;
      final publicKey = base64Decode(encodedKey);
      final signatureBytes = base64Decode(signature);
      if (publicKey.length != 32 || signatureBytes.length != 64) return false;
      return await Ed25519().verify(
        utf8.encode(canonicalJson(lease.claims)),
        signature: Signature(
          signatureBytes,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } on Object {
      return false;
    }
  }
}

/// What the Service may tell a person about plugin entitlement. A UX hint:
/// Cloud decides what is actually scheduled.
class PluginEntitlementStatus {
  const PluginEntitlementStatus({
    required this.entitled,
    this.expiresAt,
    this.reason,
  });

  final bool entitled;
  final DateTime? expiresAt;

  /// `no_lease`, a [PluginLeaseRejection] name, or null when entitled.
  final String? reason;

  Map<String, Object?> toJson(DateTime now) => {
        'entitled': entitled,
        'source': 'lease',
        if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
        if (entitled && expiresAt != null)
          'offlineRemainingSeconds': expiresAt!.difference(now).inSeconds,
        if (reason != null) 'reason': reason,
      };
}

/// Persists the latest lease and the highest Cloud time observed. Both live in
/// the Service's private state directory; neither is trusted without
/// re-verification on every read.
class PluginEntitlementStore {
  PluginEntitlementStore({
    required this.file,
    required this.verifier,
    required this.ownerUserId,
    required this.workspaceId,
    required this.installationId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final File file;
  final PluginLeaseVerifier verifier;
  final String ownerUserId;
  final String workspaceId;
  final String installationId;
  final DateTime Function() _clock;

  Future<Map<String, Object?>> _read() async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map ? Map<String, Object?>.from(decoded) : {};
    } on Object {
      return {};
    }
  }

  Future<void> _write(Map<String, Object?> state) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(state), flush: true);
    await temp.rename(file.path);
  }

  /// Records Cloud time (from a lease or `hello.ack`); never moves backwards.
  Future<void> observeCloudTime(DateTime cloudTime) async {
    final state = await _read();
    final current = DateTime.tryParse('${state['highWaterMark']}');
    if (current == null || cloudTime.isAfter(current)) {
      state['highWaterMark'] = cloudTime.toUtc().toIso8601String();
      await _write(state);
    }
  }

  /// Verifies and stores a lease received from Cloud.
  Future<PluginLeaseVerification> accept(Object? envelope) async {
    final state = await _read();
    final mark = DateTime.tryParse('${state['highWaterMark']}');
    final result = await verifier.verify(
      envelope,
      ownerUserId: ownerUserId,
      workspaceId: workspaceId,
      installationId: installationId,
      now: _clock().toUtc(),
      highWaterMark: mark,
    );
    if (result.isValid) {
      state['envelope'] = envelope;
      final issued = result.lease!.issuedAt;
      if (mark == null || issued.isAfter(mark)) {
        state['highWaterMark'] = issued.toIso8601String();
      }
      await _write(state);
    }
    return result;
  }

  /// Re-verifies the stored lease against the current clock.
  Future<PluginEntitlementStatus> status() async {
    final state = await _read();
    final envelope = state['envelope'];
    if (envelope == null) {
      return const PluginEntitlementStatus(entitled: false, reason: 'no_lease');
    }
    final result = await verifier.verify(
      envelope,
      ownerUserId: ownerUserId,
      workspaceId: workspaceId,
      installationId: installationId,
      now: _clock().toUtc(),
      highWaterMark: DateTime.tryParse('${state['highWaterMark']}'),
    );
    if (result.isValid) {
      return PluginEntitlementStatus(
        entitled: true,
        expiresAt: result.lease!.expiresAt,
      );
    }
    return PluginEntitlementStatus(
      entitled: false,
      reason: result.rejection!.name,
    );
  }
}
