import 'dart:io';

import 'external_worker_service.dart';
import 'external_worker_store.dart';
import 'workspace_manager_ipc.dart';

/// Translates `externalWorkers.*` IPC commands into [ExternalWorkerService] calls and
/// service errors into stable IPC error codes.
class WorkspaceExternalWorkerCommands {
  WorkspaceExternalWorkerCommands(this.service, {required this.publish});

  final ExternalWorkerService service;

  /// Emits an event to subscribed IPC clients.
  final void Function(Map<String, Object?> event) publish;

  static final _idPattern = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');
  static final _versionPattern = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  static bool handles(String command) => command.startsWith('externalWorkers.');

  Future<Object?> handle(String command, Map<String, Object?> payload) async {
    try {
      return await _handle(command, payload);
    } on ExternalWorkerException catch (error) {
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
    final value = payload['externalWorkerId'];
    if (value is! String || value.length > 48 || !_idPattern.hasMatch(value)) {
      throw const WorkspaceManagerProtocolException(
        'invalid_request',
        'externalWorkerId must be a lowercase External Worker ID.',
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
      case 'externalWorkers.list':
        return service.list();
      case 'externalWorkers.show':
        return service.show(_id(payload), _version(payload));
      case 'externalWorkers.import':
        return service.import(_absolutePath(payload, 'path'));
      case 'externalWorkers.validate':
        return service.validate(_id(payload), _version(payload));
      case 'externalWorkers.test':
        final id = _id(payload);
        return service.test(
          id,
          version: _version(payload),
          onProgress: (message) => publish({
            'name': 'externalWorker.testProgress',
            'externalWorkerId': id,
            'message': message,
          }),
        );
      case 'externalWorkers.register':
        return service.register(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
        );
      case 'externalWorkers.enable':
        return service.enable(
          _id(payload),
          version: _version(payload),
          acceptHash: _hash(payload),
          shareable: payload['shareable'] == true,
        );
      case 'externalWorkers.disable':
        return service.disable(_id(payload));
      case 'externalWorkers.remove':
        return service.remove(_id(payload));
      default:
        throw WorkspaceManagerProtocolException(
          'unsupported_command',
          'Unsupported Workspace Manager command: $command',
        );
    }
  }
}
