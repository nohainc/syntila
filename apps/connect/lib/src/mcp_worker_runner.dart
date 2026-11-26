import 'dart:convert';
import 'dart:io';

import 'package:syntila_mcp_worker_store/syntila_mcp_worker_store.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'mcp_worker_allow_list.dart';

class McpWorkerRunner {
  McpWorkerRunner({
    required this.store,
    required this.allowList,
    required this.pinsFile,
  });
  final ExternalWorkerStore store;
  final McpWorkerAllowList allowList;
  final File pinsFile;

  String _key(String id, String version, String digest) =>
      '$id@$version:$digest';

  Future<Map<String, dynamic>> _read() async {
    if (!await pinsFile.exists()) return {};
    try {
      final value = jsonDecode(await pinsFile.readAsString());
      return value is Map<String, dynamic> ? value : {};
    } on Object {
      return {};
    }
  }

  Future<void> record(
    InstalledExternalWorker installed,
    List<Map<String, Object?>> tools,
  ) async {
    final pins = workerToolPins(tools);
    final values = await _read();
    values[_key(
          installed.pluginId,
          installed.version,
          installed.manifestDigest,
        )] =
        pins;
    await pinsFile.parent.create(recursive: true);
    final temp = File('${pinsFile.path}.tmp');
    await temp.writeAsString(jsonEncode(values), flush: true);
    await temp.rename(pinsFile.path);
  }

  /// The MCP Workers this machine can run now: approved and tool-pinned. Reported
  /// to Cloud so the owner can pin one. It lists, never runs; `prepare` still
  /// verifies the install before every run.
  Future<List<Map<String, String>>> runnable() async {
    final pins = await _read();
    final items = <Map<String, String>>[];
    for (final p in await allowList.list()) {
      if (pins[_key(p.id, p.version, p.digest)] is Map) {
        items.add({
          'id': p.id,
          'version': p.version,
          'manifestDigest': p.digest,
          if (p.deviceId != null) 'deviceId': p.deviceId!,
        });
      }
    }
    return items;
  }

  Future<WorkerExecutor> prepare(Object? pin) async {
    if (pin is! Map ||
        pin['id'] is! String ||
        pin['version'] is! String ||
        pin['manifestDigest'] is! String)
      throw const ExternalWorkerException(
        'mcp_worker_not_approved',
        'Invalid MCP Worker pin.',
      );
    final id = pin['id'] as String,
        version = pin['version'] as String,
        digest = pin['manifestDigest'] as String;
    if (!await allowList.isApproved(id, version, digest)) {
      throw const ExternalWorkerException(
        'mcp_worker_not_approved',
        'MCP Worker is not approved.',
      );
    }
    final value = (await _read())[_key(id, version, digest)];
    if (value is! Map ||
        value.isEmpty ||
        value.values.any(
          (v) => v is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(v),
        ))
      throw const ExternalWorkerException(
        'plugin_conformance_required',
        'MCP Worker tools must be inspected and pinned.',
      );
    final installed = await store.load(id, version, digest);
    if (installed.pluginId != id ||
        installed.version != version ||
        installed.manifestDigest != digest)
      throw const ExternalWorkerException(
        'plugin_digest_mismatch',
        'The installed Worker does not match its pin.',
      );
    return workerExecutorFor(
      installed,
      store.dataDirectory(id),
      toolPins: Map<String, String>.from(value),
    );
  }
}
