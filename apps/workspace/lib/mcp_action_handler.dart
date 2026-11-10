import 'mcp_registry.dart';
import 'mcp_service.dart';

/// Handles Cloud-forwarded `mcp.action.request` payloads by delegating to
/// [McpService]. Never throws: returns a structured outcome with `ok: true` or
/// `error: { code, message }`.
class McpActionHandler {
  McpActionHandler(this._service);

  final McpService _service;

  Future<Map<String, Object?>> handle(Map<String, Object?> payload) async {
    final actionId = payload['actionId'];
    final action = payload['action'];
    final serverId = payload['serverId'];
    if (actionId is! String || action is! String || serverId is! String) {
      return {
        'actionId': actionId is String ? actionId : '',
        'ok': false,
        'action': action is String ? action : 'unknown',
        'serverId': serverId is String ? serverId : '',
        'error': {
          'code': 'invalid_request',
          'message': 'actionId, action and serverId are required strings.',
        },
      };
    }
    try {
      Map<String, Object?>? outcome;
      switch (action) {
        case 'enable':
          outcome = _service.enable(serverId);
        case 'disable':
          outcome = _service.disable(serverId);
        case 'remove':
          outcome = _service.remove(serverId);
        case 'consent':
          final acceptHash = payload['acceptHash'];
          outcome = await _service.consent(
            serverId,
            acceptHash: acceptHash is String ? acceptHash : null,
          );
        case 'test':
          outcome = await _service.test(serverId);
        default:
          throw McpPolicyException(
            'unsupported_action',
            'Unsupported action: $action',
          );
      }
      return {
        'actionId': actionId,
        'ok': true,
        'action': action,
        'serverId': serverId,
        'result': outcome,
      };
    } on McpPolicyException catch (e) {
      return {
        'actionId': actionId,
        'ok': false,
        'action': action,
        'serverId': serverId,
        'error': {'code': e.code, 'message': e.message},
      };
    } on McpRegistryUnreadable {
      return {
        'actionId': actionId,
        'ok': false,
        'action': action,
        'serverId': serverId,
        'error': {
          'code': 'mcp_registry_unreadable',
          'message': 'The MCP server registry could not be read.',
        },
      };
    } catch (e) {
      return {
        'actionId': actionId,
        'ok': false,
        'action': action,
        'serverId': serverId,
        'error': {'code': 'internal_error', 'message': e.toString()},
      };
    }
  }
}
