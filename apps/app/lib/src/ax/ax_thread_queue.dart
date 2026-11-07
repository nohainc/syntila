import 'ax_models.dart';

/// A request waiting in a Thread's shared queue. Cloud sends it as its author
/// when the Thread has nothing processing.
class AxThreadQueueItem {
  const AxThreadQueueItem({
    required this.id,
    required this.authorUserId,
    required this.authorName,
    required this.status,
    required this.request,
  });

  final String id;
  final String authorUserId;
  final String authorName;

  /// `queued`, or `sending` while Cloud turns it into a Work request.
  final String status;

  /// The Work request body Cloud sends, as built by the composer.
  final Map<String, dynamic> request;

  Map<String, dynamic> get _input => request['input'] is Map
      ? Map<String, dynamic>.from(request['input'] as Map)
      : const {};

  String get text => _input['originalRequest']?.toString() ?? '';

  bool get isPhased =>
      request['isPhased'] == true || _input['isPhased'] == true;

  String? get phaseTitle =>
      (request['phaseTitle'] ?? _input['phaseTitle'])?.toString();

  String get workflowId => request['workflowId']?.toString() ?? '';

  int get workflowVersion =>
      request['workflowVersion'] is int ? request['workflowVersion'] as int : 1;

  List<Map<String, dynamic>> get attachments => [
        for (final item in (_input['attachments'] as List? ?? const []))
          if (item is Map) Map<String, dynamic>.from(item)
      ];

  Map<String, dynamic> get executionSelection =>
      request['executionSelection'] is Map
          ? Map<String, dynamic>.from(request['executionSelection'] as Map)
          : const {};

  /// The quoted message, kept with its excerpt for display and editing.
  AxReplyReference? get replyTo =>
      AxReplyReference.fromJson(request['replyReference'] ?? _input['replyTo']);

  factory AxThreadQueueItem.fromJson(Map<String, dynamic> json) =>
      AxThreadQueueItem(
        id: json['id'] as String,
        authorUserId: json['authorUserId']?.toString() ?? '',
        authorName: json['authorName']?.toString() ?? '',
        status: json['status']?.toString() ?? 'queued',
        request: json['request'] is Map
            ? Map<String, dynamic>.from(json['request'] as Map)
            : const {},
      );
}

/// A Thread's shared request queue, the same for every member.
class AxThreadQueue {
  const AxThreadQueue({
    this.paused = false,
    this.pauseReason,
    this.failureMessage,
    this.items = const [],
  });

  static const empty = AxThreadQueue();

  final bool paused;

  /// `user` when a member paused it, `failure` after a failed request or send.
  final String? pauseReason;
  final String? failureMessage;
  final List<AxThreadQueueItem> items;

  factory AxThreadQueue.fromJson(Map<String, dynamic> json) => AxThreadQueue(
        paused: json['paused'] == true,
        pauseReason: json['pauseReason'] as String?,
        failureMessage: json['failureMessage'] as String?,
        items: [
          for (final item in (json['items'] as List? ?? const []))
            if (item is Map)
              AxThreadQueueItem.fromJson(Map<String, dynamic>.from(item))
        ],
      );
}

/// Shared Thread request queue (`/threads/:id/queue`). Every call returns the
/// queue as it is after the change.
abstract interface class AxThreadQueueDataSource {
  Future<AxThreadQueue> loadThreadQueue(String threadId);

  Future<AxThreadQueue> enqueueThreadRequest({
    required String threadId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
  });

  /// Replaces the author's own queued request.
  Future<AxThreadQueue> updateThreadQueueItem({
    required String threadId,
    required String itemId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
  });

  Future<AxThreadQueue> removeThreadQueueItem(String threadId, String itemId);

  /// Moves the author's own request to the front and resumes the queue.
  Future<AxThreadQueue> sendThreadQueueItemNow(String threadId, String itemId);

  Future<AxThreadQueue> setThreadQueuePaused(String threadId, bool paused);
}
