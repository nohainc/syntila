import 'ax_people.dart';
export 'ax_people.dart';
import 'ax_notes.dart';
export 'ax_notes.dart';
import 'ax_files.dart';
export 'ax_files.dart';
import 'ax_workflow_configuration.dart';
export 'ax_workflow_configuration.dart';
import 'ax_workspace_member_access.dart';
export 'ax_workspace_member_access.dart';
import 'worker_usage.dart';
export 'worker_usage.dart';
import 'ax_thread_queue.dart';
export 'ax_thread_queue.dart';
export 'worker_usage_parser.dart';
import 'dart:async';
import 'dart:convert';
import 'ax_input_delivery.dart';
import 'sync/ax_idempotency.dart';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../platform/http_client_stub.dart'
    if (dart.library.html) '../platform/http_client_web.dart' as platform;
import 'ax_models.dart';
import 'ax_work_models.dart';
import 'ax_work_latency_trace.dart';

export 'ax_work_models.dart';
export 'ax_input_delivery.dart';

part 'ax_data/catalog_api.dart';
part 'ax_data/thread_api.dart';
part 'ax_data/auth_api.dart';
part 'ax_data/workspace_api.dart';
part 'ax_data/space_api.dart';
part 'ax_data/read_model_api.dart';
part 'ax_data/notes_api.dart';
part 'ax_data/files_api.dart';

/// Cloud rejected the action because it needs the paid plan.
const paidPlanRequiredCode = 'paid_plan_required';

class AxApiException implements Exception {
  const AxApiException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// Stable Cloud error code, such as [paidPlanRequiredCode].
  final String? code;
  @override
  String toString() => message;
}

/// Session-bound transport validators for stable read resources only.
abstract interface class AxConditionalReadCache {
  void clearConditionalReads();
}

abstract class _AxApiClientCore
    implements AxDataSource, AxConditionalReadCache {
  _AxApiClientCore({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ??
            (const String.fromEnvironment('SYNTILA_API_URL').isNotEmpty
                ? const String.fromEnvironment('SYNTILA_API_URL')
                : platform.defaultAxApiBaseUrl()),
        client = client ?? platform.createPlatformHttpClient();

  final String baseUrl;
  final http.Client client;
  // Transport references are separate from immutable authored request inputs.
  final _uploadedWorkFiles = <String, String>{};
  String? _sessionToken;
  String? get sessionToken => _sessionToken;
  set sessionToken(String? value) {
    if (value != _sessionToken) {
      clearConditionalReads();
      _uploadedWorkFiles.clear();
      AxInputDelivery.instance.clear();
    }
    _sessionToken = value;
  }

  String? _readUserId;
  int _readGeneration = 0;
  int _readSequence = 0;
  final _conditionalReads =
      <String, ({String etag, String body, int sequence})>{};
  @override
  void clearConditionalReads() {
    _readGeneration++;
    _conditionalReads.clear();
  }

  void _bindReadUser(String? id) {
    if (_readUserId != id) clearConditionalReads();
    _readUserId = id;
  }

  Map<String, String> _headers({String? contentType}) => {
        'accept': 'application/json',
        if (contentType != null) 'content-type': contentType,
        if (sessionToken != null && sessionToken!.isNotEmpty)
          'authorization': 'Bearer $sessionToken',
      };

  Future<Map<String, dynamic>> _getJson(Uri uri,
      {bool conditional = false}) async {
    final generation = _readGeneration;
    final sequence = ++_readSequence;
    final key = uri.toString();
    final cached = conditional ? _conditionalReads.remove(key) : null;
    if (cached != null) _conditionalReads[key] = cached;
    final response = await client.get(uri, headers: {
      ..._headers(),
      if (cached != null) 'if-none-match': cached.etag,
    });
    if (response.statusCode == 304) {
      if (cached == null || generation != _readGeneration) {
        throw const AxApiException(
            'Conditional read has no current cached representation');
      }
      return Map<String, dynamic>.from(jsonDecode(cached.body) as Map);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final error = jsonDecode(response.body);
        if (error is Map && error['error'] is String) {
          detail = ': ${error['error']}';
        }
      } on FormatException {
        // Non-JSON responses (such as proxy pages) are not diagnostic data.
      }
      throw AxApiException(
        'Read model failed for ${uri.path} (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const AxApiException('Read model response is malformed');
    }
    if (conditional && generation == _readGeneration) {
      final etag = response.headers['etag'];
      if (etag != null &&
          etag.isNotEmpty &&
          response.bodyBytes.length <= 262144 &&
          (_conditionalReads[key]?.sequence ?? -1) <= sequence) {
        _conditionalReads.remove(key);
        _conditionalReads[key] =
            (etag: etag, body: response.body, sequence: sequence);
        while (_conditionalReads.length > 16 ||
            _conditionalReads.values.fold<int>(
                    0, (sum, value) => sum + utf8.encode(value.body).length) >
                1048576) {
          _conditionalReads.remove(_conditionalReads.keys.first);
        }
      } else if ((_conditionalReads[key]?.sequence ?? -1) <= sequence) {
        _conditionalReads.remove(key);
      }
    }
    return Map<String, dynamic>.from(decoded);
  }
}

/// Optional capability: record that the signed-in user has seen a Thread.
abstract interface class AxThreadReadDataSource {
  Future<void> markThreadRead(String threadId);
}

/// When another Space member last read a Thread; drives "Seen by".
class AxThreadReadState {
  const AxThreadReadState(
      {required this.userId, required this.displayName, required this.readAt});

  final String userId;
  final String displayName;
  final DateTime readAt;

  static AxThreadReadState? fromJson(Map<String, dynamic> json) {
    final readAt = DateTime.tryParse(json['readAt']?.toString() ?? '');
    final userId = json['userId']?.toString() ?? '';
    if (readAt == null || userId.isEmpty) return null;
    final name = json['displayName']?.toString().trim() ?? '';
    return AxThreadReadState(
        userId: userId,
        displayName: name.isEmpty ? 'Member' : name,
        readAt: readAt);
  }
}

/// The caller's account tier as reported by Cloud. Cloud enforces paid
/// features; the app only uses this to show, hide or label them.
class AxAccountPlan {
  const AxAccountPlan({
    required this.isPaid,
    this.status,
    this.currentPeriodEnd,
    this.features = const {},
  });

  static const free = AxAccountPlan(isPaid: false);

  factory AxAccountPlan.fromJson(Map<String, dynamic> json) => AxAccountPlan(
        isPaid: json['tier'] == 'paid',
        status: json['status'] as String?,
        currentPeriodEnd:
            DateTime.tryParse(json['currentPeriodEnd']?.toString() ?? ''),
        features: {
          for (final feature in json['features'] as List? ?? const [])
            if (feature is String) feature,
        },
      );

  final bool isPaid;
  final String? status;
  final DateTime? currentPeriodEnd;
  final Set<String> features;

  bool has(String feature) => features.contains(feature);
}

/// Optional capability: the viewer's account plan.
abstract interface class AxAccountPlanDataSource {
  Future<AxAccountPlan> loadAccountPlan();
}

/// Optional capability: the viewer's reciprocal read-receipt setting.
abstract interface class AxReadReceiptPrivacyDataSource {
  Future<bool> loadShareReadReceipts();
  Future<void> setShareReadReceipts(bool share);
}

/// Optional capability: read receipts for a Thread's other members.
abstract interface class AxThreadReadReceiptsDataSource {
  Future<List<AxThreadReadState>> loadThreadReadStates(String threadId);
}

/// Optional capability: the durable notification feed of finished Work and
/// its per-user read markers.
abstract interface class AxNotificationDataSource {
  Future<List<Map<String, dynamic>>> loadNotificationFeed();

  /// Marks [ids] read, or every notification when [ids] is null.
  Future<void> markNotificationsRead({List<String>? ids});
}

/// Optional capability: pin or unpin a Space or Thread for the signed-in user.
abstract interface class AxPinDataSource {
  Future<void> setPinned(
      {required String kind, required String id, required bool pinned});

  /// Stores the manual order of pinned items (first to last). Threads need
  /// their [spaceId].
  Future<void> setPinOrder(
      {required String kind, required List<String> ids, String? spaceId});
}

class AxApiClient extends _AxApiClientCore
    with
        _CatalogApi,
        _ThreadApi,
        _AuthApi,
        _WorkspaceApi,
        _SpaceApi,
        _ReadModelApi,
        _NotesApi,
        _FilesApi
    implements
        AxWorkflowConfigurationDataSource,
        AxSpaceWorkflowConfigurationDataSource,
        AxWorkerUsageDataSource,
        AxWorkflowDefaultDataSource,
        AxWorkflowWorkspaceDataSource,
        AxSpaceAdditionalFolderDataSource,
        AxWorkspaceMemberAccessDataSource,
        AxWorkspacePersonAccessDataSource,
        AxWorkspaceSharingDataSource,
        AxPeopleDataSource,
        AxThreadReadDataSource,
        AxThreadReadReceiptsDataSource,
        AxReadReceiptPrivacyDataSource,
        AxAccountPlanDataSource,
        AxNotificationDataSource,
        AxPinDataSource,
        AxNotesDataSource,
        AxUserFilesDataSource,
        AxThreadQueueDataSource {
  AxApiClient({super.baseUrl, super.client});
}

/// A keyed mutation is safe to resend: the server replays the first result.
/// One resend covers a request whose response was lost on the network.
Future<T> _retryOnceWithKey<T>(
    String? idempotencyKey, Future<T> Function() send) async {
  try {
    return await send();
  } on http.ClientException {
    if (idempotencyKey == null) rethrow;
    return send();
  }
}
