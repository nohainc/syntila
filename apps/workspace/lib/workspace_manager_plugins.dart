import 'dart:io';

import 'plugin_service.dart';
import 'plugin_store.dart';
import 'plugin_signer_trust.dart';
import 'workspace_manager_ipc.dart';

/// Translates `plugins.*` IPC commands into [WorkspacePluginService] calls and
/// service errors into stable IPC error codes.
class WorkspacePluginCommands {
  WorkspacePluginCommands(this.service, {required this.publish});

  final WorkspacePluginService service;

  /// Emits an event to subscribed IPC clients.
  final void Function(Map<String, Object?> event) publish;

  static final _idPattern = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
  static final _versionPattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  static bool handles(String command) => command.startsWith('plugins.');

  Future<Object?> handle(String command, Map<String, Object?> payload) async {
    try {
      return await _handle(command, payload);
    } on PluginServiceException catch (error) {
      final details = error.details;
      final suffix = details is List && details.isNotEmpty
          ? ' ${details.take(5).join('; ')}'
          : '';
      throw WorkspaceManagerProtocolException(
        error.code,
        '${error.message}$suffix',
      );
    }
  }

  String _id(Map<String, Object?> payload) {
    final value = payload['pluginId'];
    if (value is! String || value.length > 48 || !_idPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'pluginId must be a lowercase plugin ID.',
      );
    }
    return value;
  }

  String? _version(Map<String, Object?> payload) {
    final value = payload['version'];
    if (value == null) return null;
    if (value is! String || !_versionPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'version must be MAJOR.MINOR.PATCH.',
      );
    }
    return value;
  }

  String? _hash(Map<String, Object?> payload) {
    final value = payload['acceptHash'];
    if (value == null) return null;
    if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'acceptHash must be a SHA-256 hex digest.',
      );
    }
    return value;
  }

  String _absolutePath(Map<String, Object?> payload, String key) {
    final value = payload[key];
    if (value is! String ||
        value.isEmpty ||
        value.length > 4096 ||
        value.contains('\u0000') ||
        !File(value).isAbsolute) {
      throw WorkspaceManagerProtocolException(
        'invalid_request',
        '$key must be an absolute path.',
      );
    }
    return value;
  }

  Future<Object?> _handle(String command, Map<String, Object?> payload) {
    switch (command) {
      case 'plugins.list':
        return service.list();
      case 'plugins.show':
        return service.show(_id(payload), _version(payload));
      case 'plugins.migrateCheck':
        return service.migrateCheck(_id(payload), version: _version(payload));
      case 'plugins.import':
        return service.import(_absolutePath(payload, 'path'));
      case 'plugins.validate':
        return service.validate(_id(payload), _version(payload));
      case 'plugins.test':
        final id = _id(payload);
        return service.test(
          id,
          version: _version(payload),
          onProgress: (message) => publish({
            'name': 'plugin.testProgress',
            'pluginId': id,
            'message': message,
          }),
        );
      case 'plugins.register':
        return service.register(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
        );
      case 'plugins.enable':
        return service.enable(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
          shareable: payload['shareable'] == true,
        );
      case 'plugins.disable':
        return service.disable(_id(payload));
      case 'plugins.remove':
        return service.remove(_id(payload));
      case 'plugins.export':
        return service.export(
          _id(payload),
          _absolutePath(payload, 'outputPath'),
          version: _version(payload),
        );
      case 'plugins.signers':
        return service.signers();
      case 'plugins.trustSigner':
        return service.trustSigner(_id(payload),
            version: _version(payload), acceptHash: _hash(payload));
      case 'plugins.untrustSigner':
        final fingerprint = payload['fingerprint'];
        if (!PluginSignerTrust.validFingerprint(fingerprint)) {
          throw const WorkspaceManagerProtocolException(
              'invalid_request', 'fingerprint must be a SHA-256 hex digest.');
        }
        return service.untrustSigner(fingerprint as String);
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }
}
