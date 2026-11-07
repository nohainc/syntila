import 'package:flutter/foundation.dart';
import 'worker_execution_options.dart';
export 'worker_execution_options.dart';
import 'dart:convert';

enum RunStatus {
  active,
  running,
  waiting,
  paused,
  completed,
  failed,
  cancelled
}

enum TaskStatus {
  completed,
  running,
  ready,
  blocked,
  pending,
  failed,
  cancelled
}

extension TaskStatusHelpers on TaskStatus {
  bool get isCompleted => this == TaskStatus.completed;
  bool get isRunning => this == TaskStatus.running;
  bool get isBlocked => this == TaskStatus.blocked;
  bool get isFailed =>
      this == TaskStatus.failed || this == TaskStatus.cancelled;
  bool get isPending => this == TaskStatus.pending || this == TaskStatus.ready;
  String get label => switch (this) {
        TaskStatus.completed => 'Completed',
        TaskStatus.failed => 'Failed',
        TaskStatus.cancelled => 'Cancelled',
        TaskStatus.running => 'Running',
        TaskStatus.ready => 'Ready',
        TaskStatus.blocked => 'Blocked',
        TaskStatus.pending => 'Pending',
      };
}

extension AxTaskHelpers on AxTask {
  bool get isCompleted => status.isCompleted;
  bool get isRunning => status.isRunning;
  bool get isFailed => status.isFailed || status == TaskStatus.blocked;
  String get stage => phase.isNotEmpty ? phase : 'Execution';
  String? get assignedWorkerId => worker.isNotEmpty ? worker : null;
}

extension AxSpaceHelpers on AxSpace {
  String get title => name;

  /// AI History is a Space-level opt-in. Missing settings stay hidden.
  bool get showAiHistory => settings['showAiHistory'] == true;
}

enum FindingSeverity { blocker, major, minor, note }

enum FindingStatus { open, fixed, verified }

class AxCandidateOutput {
  const AxCandidateOutput({
    required this.worker,
    required this.role,
    required this.status,
    required this.summary,
    required this.artifactCount,
  });

  final String worker;
  final String role;
  final String status;
  final String summary;
  final int artifactCount;

  factory AxCandidateOutput.fromJson(Map<String, dynamic> json) =>
      AxCandidateOutput(
        worker: _string(json, 'worker'),
        role: _string(json, 'role'),
        status: _string(json, 'status'),
        summary: _string(json, 'summary'),
        artifactCount: json['artifactCount'] as int? ?? 0,
      );
}

class AxSynthesisDecision {
  const AxSynthesisDecision({
    required this.status,
    required this.summary,
    required this.worker,
    required this.evidence,
  });

  final String status;
  final String summary;
  final String worker;
  final String evidence;

  factory AxSynthesisDecision.fromJson(Map<String, dynamic> json) =>
      AxSynthesisDecision(
        status: _string(json, 'status'),
        summary: _string(json, 'summary'),
        worker: _string(json, 'worker'),
        evidence: _string(json, 'evidence'),
      );
}

String _string(Map<String, dynamic> json, String key, [String fallback = '—']) {
  final value = json[key];
  return value == null ? fallback : value.toString();
}

class AxWorkflowCapabilities {
  const AxWorkflowCapabilities({
    this.userSelectsWorker = false,
    this.userSelectsModel = false,
    this.userSelectsEffort = false,
    this.multiStep = false,
    this.multiWorker = false,
    this.automaticContinuation = false,
    this.requiresApprovalBetweenSteps = false,
  });

  final bool userSelectsWorker;
  final bool userSelectsModel;
  final bool userSelectsEffort;
  final bool multiStep;
  final bool multiWorker;
  final bool automaticContinuation;
  final bool requiresApprovalBetweenSteps;

  factory AxWorkflowCapabilities.fromJson(Map<String, dynamic> json) =>
      AxWorkflowCapabilities(
        userSelectsWorker: json['userSelectsWorker'] == true,
        userSelectsModel: json['userSelectsModel'] == true,
        userSelectsEffort: json['userSelectsEffort'] == true,
        multiStep: json['multiStep'] == true,
        multiWorker: json['multiWorker'] == true,
        automaticContinuation: json['automaticContinuation'] == true,
        requiresApprovalBetweenSteps:
            json['requiresApprovalBetweenSteps'] == true,
      );
}

/// A multi-step workflow resolves its Worker and model separately per role.
Map<String, dynamic> submissionExecutionSelection(
        AxBuiltinWorkflow? workflow, Map<String, dynamic> selection) =>
    workflow?.executionPolicy.multiStep == true
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(selection);

class AxBuiltinWorkflow {
  const AxBuiltinWorkflow({
    required this.id,
    required this.version,
    required this.name,
    required this.description,
    required this.steps,
    required this.snapshot,
    this.executionPolicy = const AxWorkflowCapabilities(),
    this.composerBindingId,
  });

  final String id;
  final int version;
  final String name;
  final String description;
  final List<AxBuiltinWorkflowStep> steps;
  final Map<String, dynamic> snapshot;
  final AxWorkflowCapabilities executionPolicy;
  final String? composerBindingId;
  String get reference => '$id:v$version';

  factory AxBuiltinWorkflow.fromJson(Map<String, dynamic> json) =>
      AxBuiltinWorkflow(
        id: _string(json, 'id', ''),
        version: json['version'] as int? ?? 1,
        name: _string(json, 'name', ''),
        description: _string(json, 'description', ''),
        steps: (json['steps'] as List? ?? const [])
            .whereType<Map>()
            .map((step) =>
                AxBuiltinWorkflowStep.fromJson(Map<String, dynamic>.from(step)))
            .toList(),
        executionPolicy: AxWorkflowCapabilities.fromJson(
          json['executionPolicy'] is Map
              ? Map<String, dynamic>.from(json['executionPolicy'] as Map)
              : const {},
        ),
        composerBindingId: json['composerBindingId'] as String?,
        snapshot: Map<String, dynamic>.from(json)
          ..remove('executionPolicy')
          ..remove('composerBindingId'),
      );
}

class AxBuiltinWorkflowStep {
  const AxBuiltinWorkflowStep({
    required this.kind,
    required this.order,
    this.id,
  });

  final String kind;
  final int order;

  /// Step-instance ID; present when a definition repeats a kind.
  final String? id;
  String get instanceId => id ?? kind;

  factory AxBuiltinWorkflowStep.fromJson(Map<String, dynamic> json) =>
      AxBuiltinWorkflowStep(
        kind: _string(json, 'kind', ''),
        order: json['order'] as int? ?? 0,
        id: json['id'] is String
            ? json['id'] as String
            : (json['stepId'] is String
                ? json['stepId'] as String
                : (json['step_id'] is String
                    ? json['step_id'] as String
                    : (json['stepInstanceId'] is String
                        ? json['stepInstanceId'] as String
                        : null))),
      );
}

List<String> _strings(Map<String, dynamic> json, String key) =>
    List<String>.from(json[key] as List? ?? const []);

List<String> _runtimeCapabilityLabels(Map<String, dynamic> json, String key) {
  dynamic value = json[key];
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return const [];
    }
  }
  if (value is List) return value.whereType<String>().toList();
  if (value is! Map) return const [];

  final labels = (value['supportedRuntimes'] as List? ?? const [])
      .whereType<String>()
      .toList();
  final maxConcurrentWorkers = value['maxConcurrentWorkers'];
  if (maxConcurrentWorkers is int) {
    labels.add('Up to $maxConcurrentWorkers concurrent Workers');
  }
  return labels;
}

enum AxPhaseStatus { completed, inProgress, pending }

class AxPhaseItem {
  const AxPhaseItem({
    required this.name,
    required this.status,
    this.detail,
  });

  final String name;
  final AxPhaseStatus status;
  final String? detail;

  factory AxPhaseItem.fromJson(Map<String, dynamic> json) => AxPhaseItem(
        name: _string(json, 'name'),
        status: AxPhaseStatus.values.firstWhere(
          (v) => v.name == json['status'],
          orElse: () => AxPhaseStatus.pending,
        ),
        detail: json['detail'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': status.name,
        'detail': detail,
      };
}

/// The three Space member rights shared with Cloud. Using one's own Workers in
/// Chat is not a right of its own: it follows [chat]. A legacy
/// `useOwnWorkers` field from older Cloud responses is ignored.
class AxSpacePermissions {
  const AxSpacePermissions(
      {this.chat = false, this.work = false, this.manageOwnThreads = false});
  final bool chat, work, manageOwnThreads;

  factory AxSpacePermissions.forRole(String role) => AxSpacePermissions(
      chat: role == 'owner' || role == 'collaborator',
      work: role == 'owner' || role == 'collaborator',
      manageOwnThreads: role == 'owner' || role == 'collaborator');
  factory AxSpacePermissions.fromJson(Map json) => AxSpacePermissions(
      chat: json['chat'] == true,
      work: json['work'] == true,
      manageOwnThreads: json['manageOwnThreads'] == true);

  /// Key order is the members table column order.
  Map<String, bool> toJson() =>
      {'chat': chat, 'work': work, 'manageOwnThreads': manageOwnThreads};
}

class AxThread {
  const AxThread({
    required this.id,
    required this.spaceId,
    required this.name,
    required this.lead,
    required this.status,
    required this.brief,
    required this.primaryWorkspace,
    required this.queueStatus,
    this.briefAuthorName = '',
    this.leadDisplayName = '',
    this.workConfig = const {},
    this.metadata = const {},
    this.canConfigureWork = false,
    this.canDestroy = false,
    this.canExecuteWork = false,
    this.archived = false,
    this.creatorEmail = '',
    this.creatorIsOwner = true,
    this.isGeneral = false,
    this.hasActiveWork = false,
    this.hasUnread = false,
    this.pinnedAt = '',
    this.pinPosition = 0,
    this.createdAt = '',
    this.updatedAt = '',
  });

  final String id;
  final String spaceId;
  final String name;
  final String lead;
  final String leadDisplayName;
  final String status;
  final String brief;

  /// Who sent [brief], the latest Thread message; empty when unknown.
  final String briefAuthorName;
  final String primaryWorkspace;
  final String queueStatus;
  final Map<String, dynamic> workConfig;

  /// Cloud-backed Thread presentation state (`viewState`: active tab, selected
  /// workflow, Worker, model, effort). Never used for execution decisions.
  final Map<String, dynamic> metadata;
  final bool canConfigureWork;
  final bool canDestroy;
  final bool canExecuteWork;
  final bool archived;
  final String creatorEmail;
  final bool creatorIsOwner;
  final bool isGeneral;

  Map<String, dynamic> get viewState => metadata['viewState'] is Map
      ? Map<String, dynamic>.from(metadata['viewState'] as Map)
      : const {};

  /// Server-derived for the signed-in user; never persisted in the read cache.
  final bool hasActiveWork;
  final bool hasUnread;

  /// When the signed-in user pinned this item; empty when not pinned.
  final String pinnedAt;
  bool get isPinned => pinnedAt.isNotEmpty;

  /// The user's manual pin order; lower comes first.
  final int pinPosition;
  final String createdAt;
  final String updatedAt;

  String get title => name;

  AxThread copyWith(
          {String? name,
          String? title,
          String? status,
          Map<String, dynamic>? workConfig,
          Map<String, dynamic>? viewState,
          bool? hasUnread,
          String? pinnedAt,
          int? pinPosition}) =>
      AxThread(
          id: id,
          spaceId: spaceId,
          name: name ?? title ?? this.name,
          lead: lead,
          leadDisplayName: leadDisplayName,
          status: status ?? this.status,
          brief: brief,
          briefAuthorName: briefAuthorName,
          primaryWorkspace: primaryWorkspace,
          queueStatus: queueStatus,
          workConfig: workConfig ?? this.workConfig,
          metadata: viewState == null
              ? metadata
              : {
                  ...metadata,
                  'viewState': {...this.viewState, ...viewState}
                    ..removeWhere((_, value) => value == null),
                },
          creatorEmail: creatorEmail,
          creatorIsOwner: creatorIsOwner,
          isGeneral: isGeneral,
          hasActiveWork: hasActiveWork,
          hasUnread: hasUnread ?? this.hasUnread,
          pinnedAt: pinnedAt ?? this.pinnedAt,
          pinPosition: pinPosition ?? this.pinPosition,
          createdAt: createdAt,
          updatedAt: updatedAt,
          canConfigureWork: canConfigureWork,
          canDestroy: canDestroy,
          canExecuteWork: canExecuteWork,
          archived: status == null ? archived : status == 'archived');

  factory AxThread.fromJson(Map<String, dynamic> json) => AxThread(
        id: _string(json, 'id'),
        spaceId: _string(json, 'spaceId'),
        name: _string(json, 'name', _string(json, 'title')),
        lead: _string(json, 'lead', _string(json, 'leadName', 'Unassigned')),
        leadDisplayName: _string(json, 'leadDisplayName'),
        status: _string(json, 'status', 'active'),
        brief: _string(json, 'brief', ''),
        briefAuthorName: _string(json, 'briefAuthorName'),
        primaryWorkspace: _string(json, 'primaryWorkspace', 'Not selected'),
        queueStatus: _string(json, 'queueStatus', 'Idle'),
        workConfig: json['workConfig'] is Map
            ? Map<String, dynamic>.from(json['workConfig'] as Map)
            : const {},
        metadata: json['metadata'] is Map
            ? Map<String, dynamic>.from(json['metadata'] as Map)
            : const {},
        canConfigureWork: json['canConfigureWork'] == true,
        canDestroy: json['canDestroy'] == true,
        canExecuteWork: json['canExecuteWork'] == true,
        archived: json['archived'] == true,
        creatorEmail: _string(json, 'creatorEmail'),
        creatorIsOwner: json['creatorIsOwner'] != false,
        isGeneral: json['isGeneral'] == true ||
            json['is_general'] == 1 ||
            json['is_general'] == true,
        hasActiveWork: json['hasActiveWork'] == true,
        hasUnread: json['hasUnread'] == true,
        pinnedAt: _string(json, 'pinnedAt', ''),
        pinPosition: (json['pinPosition'] as num?)?.toInt() ?? 0,
        createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
        updatedAt: _string(json, 'updatedAt', _string(json, 'updated_at')),
      );
}

/// Discussion paging contract 1. Messages are in chronological display order.
class AxDiscussionPage {
  AxDiscussionPage(
      {required Iterable<AxDiscussionMessage> messages,
      this.nextCursor,
      this.newestCursor})
      : messages = List.unmodifiable(messages);
  final List<AxDiscussionMessage> messages;
  final String? nextCursor;
  final String? newestCursor;
}

/// Reply v1: the message, request or AI response a message replies to, as
/// the server-built snapshot stored with the reply.
class AxReplyReference {
  const AxReplyReference({
    required this.kind,
    required this.id,
    required this.authorName,
    required this.excerpt,
  });

  /// `message` (Chat entry), `request` (Work prompt) or `response` (AI answer).
  final String kind;
  final String id;
  final String authorName;
  final String excerpt;

  /// What the client sends: the server builds the snapshot itself.
  Map<String, dynamic> get target => {'kind': kind, 'id': id};

  Map<String, dynamic> toJson() =>
      {'kind': kind, 'id': id, 'authorName': authorName, 'excerpt': excerpt};

  static AxReplyReference? fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = value['kind'];
    final id = value['id'];
    if (!const {'message', 'request', 'response'}.contains(kind) ||
        id is! String ||
        id.isEmpty) {
      return null;
    }
    return AxReplyReference(
      kind: kind as String,
      id: id,
      authorName: value['authorName']?.toString() ?? '',
      excerpt: value['excerpt']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AxReplyReference &&
      other.kind == kind &&
      other.id == id &&
      other.authorName == authorName &&
      other.excerpt == excerpt;

  @override
  int get hashCode => Object.hash(kind, id, authorName, excerpt);
}

class AxDiscussionMessage {
  const AxDiscussionMessage({
    required this.id,
    required this.threadId,
    required this.authorUserId,
    this.authorName,
    required this.body,
    this.references = const [],
    this.attachments = const [],
    this.editedAt,
    required this.createdAt,
    this.isMe = false,
    this.kind = 'message',
    this.eventType,
    this.workRequestId,
    this.workerDisplayName,
    this.replyTo,
  });

  final String id;
  final String threadId;
  final String authorUserId;
  final String? authorName;
  final String body;
  final List<String> references;
  final List<Map<String, dynamic>> attachments;
  final String? editedAt;
  final String createdAt;
  final bool isMe;

  /// `message` for people's Chat; `ai_request`/`ai_answer` for AI exchanges
  /// archived into the conversation when Work history is cleared.
  final String kind;
  final String? eventType;
  final String? workRequestId;
  final String? workerDisplayName;

  /// The message this one replies to (Reply v1).
  final AxReplyReference? replyTo;

  bool get isAiAnswer => kind == 'ai_answer';
  bool get isAiEntry => kind != 'message';

  AxDiscussionMessage copyWith({String? id, String? body, String? editedAt}) =>
      AxDiscussionMessage(
          id: id ?? this.id,
          threadId: threadId,
          authorUserId: authorUserId,
          authorName: authorName,
          body: body ?? this.body,
          references: references,
          attachments: attachments,
          editedAt: editedAt ?? this.editedAt,
          createdAt: createdAt,
          isMe: isMe,
          kind: kind,
          eventType: eventType,
          workRequestId: workRequestId,
          workerDisplayName: workerDisplayName,
          replyTo: replyTo);

  factory AxDiscussionMessage.fromJson(
    Map<String, dynamic> json, {
    String? currentUserId,
    Map<String, String>? memberNames,
  }) {
    final authorId =
        _string(json, 'authorUserId', _string(json, 'author_user_id', ''));
    final isMe = currentUserId != null &&
        currentUserId.isNotEmpty &&
        authorId == currentUserId;
    final rawName = (json['authorName'] as String?)?.trim() ??
        (json['author_name'] as String?)?.trim() ??
        (json['authorDisplayName'] as String?)?.trim() ??
        (json['author_display_name'] as String?)?.trim() ??
        (json['displayName'] as String?)?.trim() ??
        (json['display_name'] as String?)?.trim();
    final memberName = memberNames?[authorId]?.trim();

    String resolveAuthorName() {
      if (memberName != null &&
          memberName.isNotEmpty &&
          memberName != authorId &&
          !memberName.startsWith('usr_')) {
        return memberName;
      }
      if (rawName != null &&
          rawName.isNotEmpty &&
          rawName != authorId &&
          !rawName.startsWith('usr_')) {
        return rawName;
      }
      if (isMe) return 'You';
      return 'Member';
    }

    final author = resolveAuthorName();
    final rawRefs = json['references'];
    final refs = rawRefs is List
        ? rawRefs.map((e) => e.toString()).toList()
        : <String>[];
    return AxDiscussionMessage(
      id: _string(json, 'id'),
      threadId: _string(json, 'threadId',
          _string(json, 'threadId', _string(json, 'thread_id'))),
      authorUserId: authorId,
      authorName: author,
      body: _string(json, 'body', _string(json, 'content')),
      references: refs,
      attachments:
          (json['attachments'] is List ? json['attachments'] as List : const [])
              .whereType<Map>()
              .map((file) => Map<String, dynamic>.from(file))
              .toList(),
      editedAt: json['editedAt'] as String? ?? json['edited_at'] as String?,
      createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
      isMe: isMe,
      eventType: json['eventType'] as String?,
      kind: (json['kind'] as String?)?.trim().isNotEmpty == true
          ? json['kind'] as String
          : 'message',
      workRequestId: json['workRequestId'] as String?,
      workerDisplayName: json['workerDisplayName'] as String?,
      replyTo: AxReplyReference.fromJson(json['replyTo']),
    );
  }
}

/// Returns a stable descending comparison for user-facing update timestamps.
///
/// Invalid or missing timestamps are treated as older than valid timestamps.
int compareAxLastUpdatedDesc(String left, String right) {
  final leftDate = DateTime.tryParse(left);
  final rightDate = DateTime.tryParse(right);
  if (leftDate != null && rightDate != null) {
    return rightDate.compareTo(leftDate);
  }
  if (leftDate != null) return -1;
  if (rightDate != null) return 1;
  return 0;
}

List<AxSpace> sortAxSpacesByLastUpdate(Iterable<AxSpace> spaces) {
  final indexed = spaces.toList().asMap().entries.toList();
  indexed.sort((left, right) {
    final comparison = compareAxLastUpdatedDesc(
      left.value.lastActivity,
      right.value.lastActivity,
    );
    return comparison == 0 ? left.key.compareTo(right.key) : comparison;
  });
  return indexed.map((entry) => entry.value).toList(growable: false);
}

List<AxThread> sortAxThreadsByLastUpdate(Iterable<AxThread> threads) {
  final indexed = threads.toList().asMap().entries.toList();
  indexed.sort((left, right) {
    final comparison = compareAxLastUpdatedDesc(
      left.value.updatedAt.isNotEmpty
          ? left.value.updatedAt
          : left.value.createdAt,
      right.value.updatedAt.isNotEmpty
          ? right.value.updatedAt
          : right.value.createdAt,
    );
    return comparison == 0 ? left.key.compareTo(right.key) : comparison;
  });
  return indexed.map((entry) => entry.value).toList(growable: false);
}

/// Applies a Space's stored `threadOrder` to Threads already sorted by
/// activity. Threads missing from the stored order (new ones) stay first, in
/// activity order; listed Threads follow in their stored order.
List<AxThread> applyAxThreadOrder(List<AxThread> sorted, Object? storedOrder) {
  if (storedOrder is! List || storedOrder.isEmpty) return sorted;
  final rank = <String, int>{
    for (final entry
        in storedOrder.whereType<String>().toList().asMap().entries)
      entry.value: entry.key,
  };
  final unlisted = sorted.where((t) => !rank.containsKey(t.id));
  final listed = sorted.where((t) => rank.containsKey(t.id)).toList()
    ..sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));
  return [...unlisted, ...listed];
}

/// Manual pin order, then the most recently pinned first.
int compareAxPins(dynamic a, dynamic b) {
  final byPosition = (a.pinPosition as int).compareTo(b.pinPosition as int);
  return byPosition != 0
      ? byPosition
      : (b.pinnedAt as String).compareTo(a.pinnedAt as String);
}

/// The position that puts a new pin above all current ones.
int nextAxPinPosition(Iterable<int> current) =>
    current.isEmpty ? 0 : current.reduce((a, b) => a < b ? a : b) - 1;

/// Pinned Threads first (most recently pinned on top), everything else in the
/// given order. Archived Threads ignore pins.
List<AxThread> applyAxThreadPins(List<AxThread> ordered) {
  bool pinned(AxThread t) => t.isPinned && t.status.toLowerCase() != 'archived';
  final pins = ordered.where(pinned).toList()..sort(compareAxPins);
  if (pins.isEmpty) return ordered;
  return [...pins, ...ordered.where((t) => !pinned(t))];
}

class AxSpace {
  const AxSpace({
    required this.id,
    required this.name,
    required this.branch,
    required this.lastActivity,
    this.threads = const [],
    this.description = '',
    this.instructions = '',
    this.archived = false,
    this.role = 'owner',
    this.kind = 'group',
    this.isSupport = false,
    this.avatarUrl,
    this.settings = const {},
    this.permissions,
    this.hasActiveWork = false,
    this.hasUnread = false,
    this.pinnedAt = '',
    this.pinPosition = 0,
  });

  final String id;
  final String name;
  final String branch;
  final String lastActivity;
  final List<AxThread> threads;
  final String description;
  final String instructions;
  final bool archived;
  final String role;
  final String kind;

  /// The caller's personal support Space: human messaging only, no AI.
  final bool isSupport;
  final String? avatarUrl;
  final Map<String, dynamic> settings;
  final AxSpacePermissions? permissions;

  bool get isDirect => kind == 'direct';
  bool get isGroup => kind == 'group';

  /// Server-derived for the signed-in user across all of the Space's Threads.
  final bool hasActiveWork;
  final bool hasUnread;

  /// When the signed-in user pinned this item; empty when not pinned.
  final String pinnedAt;
  bool get isPinned => pinnedAt.isNotEmpty;

  /// The user's manual pin order; lower comes first.
  final int pinPosition;
  AxSpacePermissions get effectivePermissions => role == 'owner'
      ? AxSpacePermissions.forRole(role)
      : permissions ?? AxSpacePermissions.forRole(role);

  factory AxSpace.fromJson(Map<String, dynamic> json) => AxSpace(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        branch: _string(json, 'branch'),
        lastActivity: _string(json, 'lastActivity',
            _string(json, 'updatedAt', _string(json, 'createdAt'))),
        threads: (json['threads'] as List? ?? const [])
            .map((item) =>
                AxThread.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        description: _string(json, 'description', ''),
        instructions: _string(
            json,
            'instructions',
            (json['settings'] is Map &&
                    (json['settings'] as Map)['instructions'] != null)
                ? (json['settings'] as Map)['instructions'].toString()
                : ''),
        archived: json['archived'] == true ||
            (json['settings'] is Map &&
                (json['settings'] as Map)['archived'] == true),
        role: _string(json, 'role', 'owner'),
        kind: _string(json, 'kind', 'group'),
        isSupport: json['isSupport'] == true,
        avatarUrl: json['avatarUrl'] as String?,
        permissions: json['permissions'] is Map
            ? AxSpacePermissions.fromJson(json['permissions'] as Map)
            : null,
        settings: json['settings'] is Map
            ? Map<String, dynamic>.from(json['settings'] as Map)
            : const {},
        hasActiveWork: json['hasActiveWork'] == true,
        hasUnread: json['hasUnread'] == true,
        pinnedAt: _string(json, 'pinnedAt', ''),
        pinPosition: (json['pinPosition'] as num?)?.toInt() ?? 0,
      );

  AxSpace copyWith({
    String? id,
    String? name,
    String? branch,
    String? lastActivity,
    List<AxThread>? threads,
    String? description,
    String? instructions,
    bool? archived,
    String? role,
    String? kind,
    String? avatarUrl,
    Map<String, dynamic>? settings,
    String? pinnedAt,
    bool? hasActiveWork,
    bool? hasUnread,
    int? pinPosition,
  }) =>
      AxSpace(
        id: id ?? this.id,
        name: name ?? this.name,
        branch: branch ?? this.branch,
        lastActivity: lastActivity ?? this.lastActivity,
        threads: threads ?? this.threads,
        description: description ?? this.description,
        instructions: instructions ?? this.instructions,
        archived: archived ?? this.archived,
        role: role ?? this.role,
        kind: kind ?? this.kind,
        isSupport: isSupport,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        settings: settings ?? this.settings,
        permissions: permissions,
        hasActiveWork: hasActiveWork ?? this.hasActiveWork,
        hasUnread: hasUnread ?? this.hasUnread,
        pinnedAt: pinnedAt ?? this.pinnedAt,
        pinPosition: pinPosition ?? this.pinPosition,
      );
}

/// Approved personal connection between two users.
class AxPersonConnection {
  const AxPersonConnection({
    required this.userLowId,
    required this.userHighId,
    required this.status,
    required this.establishedAt,
    this.disconnectedAt,
    this.directSpaceId,
  });

  final String userLowId;
  final String userHighId;
  final String status;
  final String establishedAt;
  final String? disconnectedAt;
  final String? directSpaceId;

  bool get isConnected => status == 'connected';

  factory AxPersonConnection.fromJson(Map<String, dynamic> json) =>
      AxPersonConnection(
        userLowId: _string(json, 'userLowId'),
        userHighId: _string(json, 'userHighId'),
        status: _string(json, 'status', 'connected'),
        establishedAt: _string(json, 'establishedAt'),
        disconnectedAt: json['disconnectedAt'] as String?,
        directSpaceId: json['directSpaceId'] as String?,
      );
}

/// Personal 1:1 connection invitation.
class AxPersonInvitation {
  const AxPersonInvitation({
    required this.id,
    required this.inviterUserId,
    this.inviteeUserId,
    this.email,
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.acceptedByUserId,
    required this.updatedAt,
  });

  final String id;
  final String inviterUserId;
  final String? inviteeUserId;
  final String? email;
  final String status;
  final String createdAt;
  final String expiresAt;
  final String? acceptedByUserId;
  final String updatedAt;

  bool get isPending => status == 'pending';

  factory AxPersonInvitation.fromJson(Map<String, dynamic> json) =>
      AxPersonInvitation(
        id: _string(json, 'id'),
        inviterUserId: _string(json, 'inviterUserId'),
        inviteeUserId: json['inviteeUserId'] as String?,
        email: json['email'] as String?,
        status: _string(json, 'status', 'pending'),
        createdAt: _string(json, 'createdAt'),
        expiresAt: _string(json, 'expiresAt'),
        acceptedByUserId: json['acceptedByUserId'] as String?,
        updatedAt: _string(json, 'updatedAt'),
      );
}

/// Per-user Direct Space UI presentation state.
class AxDirectSpaceUserState {
  const AxDirectSpaceUserState({
    required this.spaceId,
    required this.userId,
    this.hidden = false,
    this.lastOpenedAt,
  });

  final String spaceId;
  final String userId;
  final bool hidden;
  final String? lastOpenedAt;

  factory AxDirectSpaceUserState.fromJson(Map<String, dynamic> json) =>
      AxDirectSpaceUserState(
        spaceId: _string(json, 'spaceId'),
        userId: _string(json, 'userId'),
        hidden: json['hidden'] == true,
        lastOpenedAt: json['lastOpenedAt'] as String?,
      );
}

/// Safe Cloud projection of a locally owned Workspace Worker.
/// It intentionally contains no credential references, secrets, or local paths.
class AxWorker {
  const AxWorker({
    required this.id,
    required this.workspaceId,
    required this.workspaceName,
    required this.workerTypeId,
    required this.displayName,
    this.description,
    this.catalogLifecycleState = 'active',
    this.catalogVisibilityState = 'visible',
    required this.status,
    required this.readinessState,
    this.activationState = 'enabled',
    this.attentionReasonCode,
    required this.localConcurrencyLimit,
    this.engineVersion,
    this.profileDefinitionId,
    this.profileReleaseVersion,
    this.providerToolName,
    this.providerToolVersion,
    this.modelOptions = const {},
    this.executionOptions,
    this.shared = false,
  });

  final String id;
  final String workspaceId;
  final String workspaceName;

  /// Shared with the viewer by another person; not the viewer's own Worker.
  final bool shared;
  final String workerTypeId;
  final String displayName;
  final String? description;
  final String catalogLifecycleState;
  final String catalogVisibilityState;
  final String status;
  final String readinessState;
  final String activationState;
  bool get isReady =>
      activationState == 'enabled' &&
      readinessState == 'ready' &&
      catalogLifecycleState == 'active' &&
      catalogVisibilityState == 'visible';
  final String? attentionReasonCode;
  final int localConcurrencyLimit;
  final String? engineVersion;
  final String? profileDefinitionId;
  final int? profileReleaseVersion;
  final String? providerToolName;
  final String? providerToolVersion;
  final Map<String, dynamic> modelOptions;
  final AxWorkerExecutionOptions? executionOptions;

  factory AxWorker.fromJson(Map<String, dynamic> json) => AxWorker(
        executionOptions: json['executionOptions'] is Map
            ? AxWorkerExecutionOptions.fromJson(
                Map<String, dynamic>.from(json['executionOptions'] as Map))
            : null,
        modelOptions: json['modelOptions'] is Map
            ? Map<String, dynamic>.from(json['modelOptions'] as Map)
            : const {},
        id: _string(json, 'id'),
        workspaceId: _string(json, 'workspaceId'),
        workspaceName: _string(json, 'workspaceName'),
        workerTypeId: _string(json, 'workerTypeId'),
        displayName: _string(json, 'displayName'),
        description: json['description']?.toString(),
        catalogLifecycleState: _string(json, 'catalogLifecycleState', 'active'),
        catalogVisibilityState:
            _string(json, 'catalogVisibilityState', 'visible'),
        status: json['activationState'] == 'disabled'
            ? 'disabled'
            : json['readinessState'] == 'ready'
                ? 'ready'
                : 'needs_attention',
        readinessState: _string(json, 'readinessState', 'test_failed'),
        activationState: _string(json, 'activationState', 'enabled'),
        attentionReasonCode: json['readinessIssueCode']?.toString() ??
            json['attentionReasonCode']?.toString(),
        localConcurrencyLimit: json['localConcurrencyLimit'] as int? ?? 1,
        engineVersion: json['engineVersion']?.toString(),
        profileDefinitionId: json['profileDefinitionId']?.toString(),
        profileReleaseVersion: json['profileReleaseVersion'] as int?,
        providerToolName: json['providerToolName']?.toString(),
        providerToolVersion: json['providerToolVersion']?.toString(),
        shared: json['shared'] == true,
      );

  /// The same Worker shown under another name, for example with its Workspace.
  AxWorker withDisplayName(String value) => AxWorker(
        id: id,
        workspaceId: workspaceId,
        workspaceName: workspaceName,
        workerTypeId: workerTypeId,
        displayName: value,
        description: description,
        catalogLifecycleState: catalogLifecycleState,
        catalogVisibilityState: catalogVisibilityState,
        status: status,
        readinessState: readinessState,
        activationState: activationState,
        attentionReasonCode: attentionReasonCode,
        localConcurrencyLimit: localConcurrencyLimit,
        engineVersion: engineVersion,
        profileDefinitionId: profileDefinitionId,
        profileReleaseVersion: profileReleaseVersion,
        providerToolName: providerToolName,
        providerToolVersion: providerToolVersion,
        modelOptions: modelOptions,
        executionOptions: executionOptions,
        shared: shared,
      );
}

class AxTask {
  const AxTask({
    required this.id,
    required this.title,
    required this.phase,
    required this.status,
    required this.worker,
    required this.detail,
    required this.progress,
    required this.dependencies,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String title;
  final String phase;
  final TaskStatus status;
  final String worker;
  final String detail;
  final double progress;
  final List<String> dependencies;
  final String? errorCode;
  final String? errorMessage;

  factory AxTask.fromJson(Map<String, dynamic> json) => AxTask(
      id: _string(json, 'id'),
      title: _string(json, 'title'),
      phase: _string(json, 'phase'),
      status: TaskStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => TaskStatus.pending),
      worker: _string(json, 'worker'),
      detail: _string(json, 'detail'),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      dependencies: _strings(json, 'dependencies'),
      errorCode:
          json['errorCode'] is String ? json['errorCode'] as String : null,
      errorMessage: json['errorMessage'] is String
          ? json['errorMessage'] as String
          : null);
}

class AxFinding {
  const AxFinding({
    required this.id,
    required this.title,
    required this.description,
    required this.severity,
    required this.status,
    required this.taskId,
    required this.author,
  });

  final String id;
  final String title;
  final String description;
  final FindingSeverity severity;
  final FindingStatus status;
  final String taskId;
  final String author;

  factory AxFinding.fromJson(Map<String, dynamic> json) => AxFinding(
      id: _string(json, 'id'),
      title: _string(json, 'title'),
      description: _string(json, 'description'),
      severity: FindingSeverity.values.firstWhere(
          (value) => value.name == json['severity'],
          orElse: () => FindingSeverity.note),
      status: FindingStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => FindingStatus.open),
      taskId: _string(json, 'taskId'),
      author: _string(json, 'author'));
}

class AxEvent {
  const AxEvent({
    required this.time,
    required this.title,
    required this.detail,
    required this.kind,
    this.eventId,
    this.correlationId,
  });

  final String time;
  final String title;
  final String detail;
  final String kind;
  final String? eventId;
  final String? correlationId;

  factory AxEvent.fromJson(Map<String, dynamic> json) => AxEvent(
      time: _string(json, 'time'),
      title: _string(json, 'title'),
      detail: _string(json, 'detail'),
      kind: _string(json, 'kind'),
      eventId: json['eventId'] as String?,
      correlationId: json['correlationId'] as String?);
}

class AxArtifact {
  const AxArtifact({
    required this.name,
    required this.type,
    required this.size,
    required this.source,
  });

  final String name;
  final String type;
  final String size;
  final String source;

  factory AxArtifact.fromJson(Map<String, dynamic> json) => AxArtifact(
      name: _string(json, 'name'),
      type: _string(json, 'type'),
      size: _string(json, 'size'),
      source: _string(json, 'source'));
}

class AxRun {
  const AxRun({
    required this.id,
    this.spaceId,
    this.spaceName,
    this.threadId,
    this.threadTitle,
    required this.status,
    required this.objective,
    required this.taskCount,
    required this.completedTaskCount,
    required this.openFindingCount,
    required this.verifiedCriterionCount,
    required this.criterionCount,
    this.workerName,
    this.modelName,
    this.effort,
    this.startedAt,
    this.durationDisplay,
  });

  final String id;
  final String? spaceId;
  final String? spaceName;
  final String? threadId;
  final String? threadTitle;
  final RunStatus status;
  final String objective;
  final int taskCount;
  final int completedTaskCount;
  final int openFindingCount;
  final int verifiedCriterionCount;
  final int criterionCount;
  final String? workerName;
  final String? modelName;
  final String? effort;
  final DateTime? startedAt;
  final String? durationDisplay;

  bool get isRunning =>
      status == RunStatus.running || status == RunStatus.active;

  AxRun copyWith({
    String? id,
    String? spaceId,
    String? spaceName,
    String? threadId,
    String? threadTitle,
    RunStatus? status,
    String? objective,
    int? taskCount,
    int? completedTaskCount,
    int? openFindingCount,
    int? verifiedCriterionCount,
    int? criterionCount,
    String? workerName,
    String? modelName,
    String? effort,
    DateTime? startedAt,
    String? durationDisplay,
  }) {
    return AxRun(
      id: id ?? this.id,
      spaceId: spaceId ?? this.spaceId,
      spaceName: spaceName ?? this.spaceName,
      threadId: threadId ?? this.threadId,
      threadTitle: threadTitle ?? this.threadTitle,
      status: status ?? this.status,
      objective: objective ?? this.objective,
      taskCount: taskCount ?? this.taskCount,
      completedTaskCount: completedTaskCount ?? this.completedTaskCount,
      openFindingCount: openFindingCount ?? this.openFindingCount,
      verifiedCriterionCount:
          verifiedCriterionCount ?? this.verifiedCriterionCount,
      criterionCount: criterionCount ?? this.criterionCount,
      workerName: workerName ?? this.workerName,
      modelName: modelName ?? this.modelName,
      effort: effort ?? this.effort,
      startedAt: startedAt ?? this.startedAt,
      durationDisplay: durationDisplay ?? this.durationDisplay,
    );
  }

  factory AxRun.fromJson(Map<String, dynamic> json) => AxRun(
        id: _string(json, 'id'),
        spaceId: (json['spaceId']) as String?,
        spaceName: (json['spaceName']) as String?,
        threadId: (json['threadId']) as String?,
        threadTitle: (json['threadTitle']) as String?,
        status: RunStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => RunStatus.running,
        ),
        objective: _string(json, 'objective'),
        taskCount: json['taskCount'] as int? ?? 0,
        completedTaskCount: json['completedTaskCount'] as int? ?? 0,
        openFindingCount: json['openFindingCount'] as int? ?? 0,
        verifiedCriterionCount: json['verifiedCriterionCount'] as int? ?? 0,
        criterionCount: json['criterionCount'] as int? ?? 0,
        workerName: json['workerName'] as String?,
        modelName: json['modelName'] as String?,
        effort: json['effort'] as String?,
        startedAt: json['startedAt'] != null
            ? DateTime.tryParse(json['startedAt'] as String)
            : null,
        durationDisplay: json['durationDisplay'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (spaceId != null) 'spaceId': spaceId,
        if (spaceName != null) 'spaceName': spaceName,
        if (threadId != null) 'threadId': threadId,
        if (threadTitle != null) 'threadTitle': threadTitle,
        'status': status.name,
        'objective': objective,
        'taskCount': taskCount,
        'completedTaskCount': completedTaskCount,
        'openFindingCount': openFindingCount,
        'verifiedCriterionCount': verifiedCriterionCount,
        'criterionCount': criterionCount,
        if (workerName != null) 'workerName': workerName,
        if (modelName != null) 'modelName': modelName,
        if (effort != null) 'effort': effort,
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
        if (durationDisplay != null) 'durationDisplay': durationDisplay,
      };
}

class AxViewer {
  const AxViewer({
    required this.id,
    required this.displayName,
    required this.email,
    this.avatarUrl,
  });

  final String id;
  final String displayName;
  final String email;
  final String? avatarUrl;

  AxViewer copyWith({
    String? displayName,
    String? email,
    String? avatarUrl,
  }) =>
      AxViewer(
        id: id,
        displayName: displayName ?? this.displayName,
        email: email ?? this.email,
        avatarUrl: avatarUrl ?? this.avatarUrl,
      );

  factory AxViewer.fromJson(Map<String, dynamic> json) => AxViewer(
        id: _string(json, 'id'),
        displayName: _string(json, 'displayName'),
        email: _string(json, 'email'),
        avatarUrl:
            json['avatarUrl'] as String? ?? json['avatar_url'] as String?,
      );
}

/// Pending email change step: a one-time code was sent to [email].
class AxEmailChangeStep {
  const AxEmailChangeStep({required this.email, required this.stage});

  /// Address that received the code.
  final String email;

  /// `new` while proving the new address, `current` for the existing one.
  final String stage;

  factory AxEmailChangeStep.fromJson(Map<String, dynamic> json) =>
      AxEmailChangeStep(
        email: _string(json, 'email'),
        stage: _string(json, 'stage'),
      );
}

class AxSession {
  const AxSession({
    required this.authenticated,
    this.viewer,
    this.sessionId,
  });

  final bool authenticated;
  final AxViewer? viewer;
  final String? sessionId;
  factory AxSession.fromJson(Map<String, dynamic> json) => AxSession(
        authenticated: json['authenticated'] == true,
        sessionId: json['sessionId'] as String?,
        viewer: json['user'] is Map
            ? AxViewer.fromJson(Map<String, dynamic>.from(json['user'] as Map))
            : null,
      );
}

class AxAuthAccount {
  const AxAuthAccount({
    required this.id,
    required this.providerId,
    required this.accountId,
  });

  final String id;
  final String providerId;
  final String accountId;

  factory AxAuthAccount.fromJson(Map<String, dynamic> json) => AxAuthAccount(
        id: _string(json, 'id'),
        providerId: _string(json, 'providerId', _string(json, 'provider_id')),
        accountId: _string(json, 'accountId', _string(json, 'account_id')),
      );
}

class AxAuthSession {
  const AxAuthSession({
    required this.token,
    required this.createdAt,
    required this.expiresAt,
    this.id,
    this.userAgent,
    this.ipAddress,
  });

  final String token;
  final String createdAt;
  final String expiresAt;
  final String? id;
  final String? userAgent;
  final String? ipAddress;

  factory AxAuthSession.fromJson(Map<String, dynamic> json) => AxAuthSession(
        token: _string(json, 'token'),
        createdAt: _string(json, 'createdAt', _string(json, 'created_at')),
        expiresAt: _string(json, 'expiresAt', _string(json, 'expires_at')),
        id: json['id'] as String? ?? json['sessionId'] as String?,
        userAgent:
            json['userAgent'] as String? ?? json['user_agent'] as String?,
        ipAddress:
            json['ipAddress'] as String? ?? json['ip_address'] as String?,
      );
}

class AxAccountSecurity {
  const AxAccountSecurity({
    required this.accounts,
    required this.sessions,
  });

  final List<AxAuthAccount> accounts;
  final List<AxAuthSession> sessions;

  AxAccountSecurity copyWith({
    List<AxAuthAccount>? accounts,
    List<AxAuthSession>? sessions,
  }) =>
      AxAccountSecurity(
        accounts: accounts ?? this.accounts,
        sessions: sessions ?? this.sessions,
      );

  factory AxAccountSecurity.fromJson(List<Map<String, dynamic>> accounts,
          List<Map<String, dynamic>> sessions) =>
      AxAccountSecurity(
        accounts: accounts.map(AxAuthAccount.fromJson).toList(growable: false),
        sessions: sessions.map(AxAuthSession.fromJson).toList(growable: false),
      );
}

class AxWorkspace {
  const AxWorkspace({
    required this.id,
    required this.name,
    this.slug = '',
    this.status = 'offline',
    this.role = 'owner',
    this.hasRuntimeIdentity = false,
    this.platform = '—',
    this.architecture = '—',
    this.hostname = '—',
    this.appVersion = '—',
    this.activeTransport,
    this.connectionMode,
    this.runtimeCapabilities = const [],
    this.factsUpdatedAt,
    this.updateChannel = 'stable',
    this.lastSeen = '—',
    this.workerCount = 0,
    this.activeTaskCount = 0,
    this.shared = false,
    this.parallelSlots,
  });

  final String id;
  final String name;
  final String slug;
  final String status;
  final String role;

  /// Lent to the viewer by its owner; the viewer may not manage access.
  final bool shared;
  final bool hasRuntimeIdentity;
  final String platform;
  final String architecture;
  final String hostname;
  final String appVersion;
  final String? activeTransport;
  final String? connectionMode;
  final List<String> runtimeCapabilities;
  final String? factsUpdatedAt;
  final String updateChannel;
  final String lastSeen;
  final int workerCount;
  final int activeTaskCount;

  /// How many requests run at once on this Workspace. Owner-only (null for a
  /// lent Workspace); set on the Workspaces page and enforced by Cloud.
  final int? parallelSlots;

  factory AxWorkspace.fromJson(Map<String, dynamic> json) => AxWorkspace(
        id: _string(json, 'id'),
        name: _string(json, 'name'),
        slug: _string(json, 'slug'),
        status: _string(json, 'status', 'offline'),
        role: _string(json, 'role', 'viewer'),
        hasRuntimeIdentity: json['hasRuntimeIdentity'] == true ||
            json['hasRuntimeIdentity'] == 1,
        platform: _string(json, 'platform'),
        architecture: _string(json, 'architecture'),
        hostname: _string(json, 'hostname'),
        appVersion: _string(json, 'appVersion'),
        activeTransport: json['activeTransport']?.toString(),
        connectionMode: json['connectionMode']?.toString(),
        runtimeCapabilities:
            _runtimeCapabilityLabels(json, 'runtimeCapabilitiesJson'),
        factsUpdatedAt: json['factsUpdatedAt']?.toString(),
        updateChannel: _string(json, 'updateChannel', 'stable'),
        lastSeen: _string(
            json, 'lastSeen', json['factsUpdatedAt']?.toString() ?? '—'),
        workerCount: json['workerCount'] as int? ?? 0,
        activeTaskCount: json['activeTaskCount'] as int? ?? 0,
        shared: json['shared'] == true || json['shared'] == 1,
        parallelSlots: json['parallelSlots'] as int?,
      );

  AxWorkspace copyWith({
    int? workerCount,
    int? activeTaskCount,
    String? lastSeen,
    int? parallelSlots,
  }) =>
      AxWorkspace(
        id: id,
        name: name,
        slug: slug,
        status: status,
        role: role,
        hasRuntimeIdentity: hasRuntimeIdentity,
        platform: platform,
        architecture: architecture,
        hostname: hostname,
        appVersion: appVersion,
        activeTransport: activeTransport,
        connectionMode: connectionMode,
        runtimeCapabilities: runtimeCapabilities,
        factsUpdatedAt: factsUpdatedAt,
        updateChannel: updateChannel,
        lastSeen: lastSeen ?? this.lastSeen,
        workerCount: workerCount ?? this.workerCount,
        activeTaskCount: activeTaskCount ?? this.activeTaskCount,
        shared: shared,
        parallelSlots: parallelSlots ?? this.parallelSlots,
      );
}

class AxWorkspaceMember {
  const AxWorkspaceMember({
    required this.userId,
    required this.displayName,
    required this.email,
    required this.role,
    required this.status,
    required this.createdAt,
  });

  final String userId;
  final String displayName;
  final String email;
  final String role;
  final String status;
  final String createdAt;

  factory AxWorkspaceMember.fromJson(Map<String, dynamic> json) =>
      AxWorkspaceMember(
        userId: _string(json, 'userId'),
        displayName: _string(json, 'displayName', _string(json, 'email')),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'member'),
        status: _string(json, 'status', 'active'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxWorkspaceInvitation {
  const AxWorkspaceInvitation({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
  });

  final String id;
  final String email;
  final String role;
  final String status;
  final String expiresAt;
  final String createdAt;

  factory AxWorkspaceInvitation.fromJson(Map<String, dynamic> json) =>
      AxWorkspaceInvitation(
        id: _string(json, 'id'),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'member'),
        status: _string(json, 'status', 'pending'),
        expiresAt: _string(json, 'expiresAt'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxSpaceMember {
  const AxSpaceMember({
    required this.userId,
    required this.displayName,
    required this.email,
    required this.role,
    required this.createdAt,
    this.permissions,
  });

  final String userId;
  final String displayName;
  final String email;
  final String role;
  final String createdAt;
  final AxSpacePermissions? permissions;
  AxSpacePermissions get effectivePermissions => role == 'owner'
      ? AxSpacePermissions.forRole(role)
      : permissions ?? AxSpacePermissions.forRole(role);

  factory AxSpaceMember.fromJson(Map<String, dynamic> json) => AxSpaceMember(
        userId: _string(json, 'userId'),
        displayName: _string(json, 'displayName', _string(json, 'email')),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'viewer'),
        createdAt: _string(json, 'createdAt'),
        permissions: json['permissions'] is Map
            ? AxSpacePermissions.fromJson(json['permissions'] as Map)
            : null,
      );
}

class AxSpaceInvitation {
  const AxSpaceInvitation({
    required this.id,
    this.spaceId = '',
    this.inviteeUserId,
    this.permissions,
    this.spaceName = '',
    required this.email,
    required this.role,
    required this.status,
    this.invitedByUserId = '',
    this.invitedByUserName = '',
    this.invitedByUserEmail = '',
    this.expiresAt = '',
    required this.createdAt,
  });

  final String id;
  final String? inviteeUserId;
  final AxSpacePermissions? permissions;
  final String spaceId;
  final String spaceName;
  final String email;
  final String role;
  final String status;
  final String invitedByUserId;
  final String invitedByUserName;
  final String invitedByUserEmail;
  final String expiresAt;
  final String createdAt;

  String get invitedByDisplay {
    if (invitedByUserName.isNotEmpty) return invitedByUserName;
    if (invitedByUserEmail.isNotEmpty) return invitedByUserEmail;
    if (invitedByUserId.isNotEmpty) return invitedByUserId;
    return 'Unknown';
  }

  factory AxSpaceInvitation.fromJson(Map<String, dynamic> json) =>
      AxSpaceInvitation(
        id: _string(json, 'id'),
        inviteeUserId: json['inviteeUserId'] as String?,
        permissions: json['permissions'] is Map
            ? AxSpacePermissions.fromJson(json['permissions'] as Map)
            : null,
        spaceId: _string(json, 'spaceId'),
        spaceName: _string(json, 'spaceName'),
        email: _string(json, 'email'),
        role: _string(json, 'role', 'viewer'),
        status: _string(json, 'status', 'pending'),
        invitedByUserId: _string(json, 'invitedByUserId'),
        invitedByUserName: _string(json, 'invitedByUserName'),
        invitedByUserEmail: _string(json, 'invitedByUserEmail'),
        expiresAt: _string(json, 'expiresAt'),
        createdAt: _string(json, 'createdAt'),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'inviteeUserId': inviteeUserId,
        if (permissions != null) 'permissions': permissions!.toJson(),
        'spaceId': spaceId,
        'spaceName': spaceName,
        'email': email,
        'role': role,
        'status': status,
        'invitedByUserId': invitedByUserId,
        'invitedByUserName': invitedByUserName,
        'invitedByUserEmail': invitedByUserEmail,
        'expiresAt': expiresAt,
        'createdAt': createdAt,
      };
}

class AxAuditEntry {
  const AxAuditEntry({
    required this.id,
    required this.action,
    required this.targetType,
    required this.targetId,
    required this.createdAt,
  });

  final String id;
  final String action;
  final String targetType;
  final String targetId;
  final String createdAt;

  factory AxAuditEntry.fromJson(Map<String, dynamic> json) => AxAuditEntry(
        id: _string(json, 'id'),
        action: _string(json, 'action'),
        targetType: _string(json, 'targetType'),
        targetId: _string(json, 'targetId'),
        createdAt: _string(json, 'createdAt'),
      );
}

class AxSnapshot {
  const AxSnapshot({
    this.workspaceId,
    this.viewer,
    this.activeRunId,
    this.run,
    required this.spaces,
    this.workspaces = const [],
    required this.tasks,
    required this.findings,
    required this.events,
    required this.artifacts,
    this.candidateOutputs = const [],
    this.synthesisDecision,
  });

  final String? workspaceId;
  final String? activeRunId;
  final AxViewer? viewer;
  final AxRun? run;
  final List<AxSpace> spaces;
  final List<AxWorkspace> workspaces;
  final List<AxTask> tasks;
  final List<AxFinding> findings;
  final List<AxEvent> events;
  final List<AxArtifact> artifacts;
  final List<AxCandidateOutput> candidateOutputs;
  final AxSynthesisDecision? synthesisDecision;

  AxSnapshot copyWith({
    List<AxSpace>? spaces,
    List<AxWorkspace>? workspaces,
  }) =>
      AxSnapshot(
        workspaceId: workspaceId,
        viewer: viewer,
        activeRunId: activeRunId,
        run: run,
        spaces: spaces ?? this.spaces,
        workspaces: workspaces ?? this.workspaces,
        tasks: tasks,
        findings: findings,
        events: events,
        artifacts: artifacts,
        candidateOutputs: candidateOutputs,
        synthesisDecision: synthesisDecision,
      );

  static AxSnapshot empty() => const AxSnapshot(
      spaces: [],
      workspaces: [],
      tasks: [],
      findings: [],
      events: [],
      artifacts: []);

  factory AxSnapshot.fromJson(Map<String, dynamic> json) => AxSnapshot(
        workspaceId: json['workspaceId'] as String?,
        viewer: json['viewer'] == null
            ? null
            : AxViewer.fromJson(
                Map<String, dynamic>.from(json['viewer'] as Map)),
        activeRunId: json['activeRunId'] as String?,
        run: json['run'] == null
            ? null
            : AxRun.fromJson(Map<String, dynamic>.from(json['run'] as Map)),
        spaces: (json['spaces'] as List? ?? const [])
            .map((item) =>
                AxSpace.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        workspaces: (json['workspaces'] as List? ?? const [])
            .map((item) =>
                AxWorkspace.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        tasks: (json['tasks'] as List? ?? const [])
            .map((item) =>
                AxTask.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        findings: (json['findings'] as List? ?? const [])
            .map((item) =>
                AxFinding.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        events: (json['events'] as List? ?? const [])
            .map((item) =>
                AxEvent.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        artifacts: (json['artifacts'] as List? ?? const [])
            .map((item) =>
                AxArtifact.fromJson(Map<String, dynamic>.from(item as Map)))
            .toList(),
        candidateOutputs: (json['candidateOutputs'] as List? ?? const [])
            .map((item) => AxCandidateOutput.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        synthesisDecision: json['synthesisDecision'] == null
            ? null
            : AxSynthesisDecision.fromJson(
                Map<String, dynamic>.from(json['synthesisDecision'] as Map)),
      );
}

enum AxHomeAttentionType {
  spaceInvitation,
  needsInput,
  approvalRequired,
  executionFailed,
  executionCompleted,
  workerProblem,
  workspaceProblem;

  // Backward-compatible aliases
  static const AxHomeAttentionType invitation = spaceInvitation;
  static const AxHomeAttentionType failedExecution = executionFailed;
  static const AxHomeAttentionType completed = executionCompleted;
  static const AxHomeAttentionType general = executionCompleted;
}

typedef AxAttentionKind = AxHomeAttentionType;

class AxHomeAttentionAction {
  const AxHomeAttentionAction({
    required this.label,
    required this.onPerform,
    this.isDestructive = false,
  });

  final String label;
  final VoidCallback onPerform;
  final bool isDestructive;
}

class AxHomeAttentionItem {
  const AxHomeAttentionItem({
    required this.id,
    this.type = AxHomeAttentionType.needsInput,
    this.priority,
    required this.title,
    String? description,
    String? subtitle,
    this.spaceId,
    this.threadId,
    this.workerId,
    this.workspaceId,
    this.timestamp,
    this.timestampDisplay,
    this.primaryAction,
    this.secondaryAction,
    this.read = false,
    this.categoryLabel,
    this.invitation,
    this.actionLabel,
    this.kind,
    this.severity = 'info',
    bool? isUnread,
    bool? isActionable,
    DateTime? createdAt,
  })  : description = description ?? subtitle ?? '',
        _subtitle = subtitle,
        _isUnread = isUnread,
        _isActionable = isActionable,
        _createdAt = createdAt;

  final String id;
  final AxHomeAttentionType type;
  final int? priority;
  final String title;
  final String description;
  final String? spaceId;
  final String? threadId;
  final String? workerId;
  final String? workspaceId;
  final DateTime? timestamp;
  final String? timestampDisplay;
  final AxHomeAttentionAction? primaryAction;
  final AxHomeAttentionAction? secondaryAction;
  final bool read;
  final String? categoryLabel;
  final AxSpaceInvitation? invitation;
  final String? actionLabel;
  final AxHomeAttentionType? kind;
  final String severity;

  final String? _subtitle;
  final bool? _isUnread;
  final bool? _isActionable;
  final DateTime? _createdAt;

  String get subtitle => _subtitle ?? description;
  bool get isUnread => _isUnread ?? !read;
  bool get isActionable =>
      _isActionable ??
      (primaryAction != null || secondaryAction != null || actionLabel != null);
  DateTime? get createdAt => _createdAt ?? timestamp;

  AxHomeAttentionType get effectiveType => kind ?? type;

  int get priorityOrder {
    if (priority != null) return priority!;
    return switch (effectiveType) {
      AxHomeAttentionType.spaceInvitation => 1,
      AxHomeAttentionType.needsInput => 2,
      AxHomeAttentionType.approvalRequired => 2,
      AxHomeAttentionType.executionFailed => 3,
      AxHomeAttentionType.workerProblem => 4,
      AxHomeAttentionType.workspaceProblem => 5,
      AxHomeAttentionType.executionCompleted => 6,
    };
  }

  factory AxHomeAttentionItem.fromJson(Map<String, dynamic> json) =>
      AxHomeAttentionItem(
        id: _string(json, 'id'),
        type: AxHomeAttentionType.values.firstWhere(
          (t) =>
              t.name == json['type'] ||
              (json['type'] == 'spaceInvitation' &&
                  t == AxHomeAttentionType.spaceInvitation),
          orElse: () => AxHomeAttentionType.needsInput,
        ),
        priority:
            json['priority'] is num ? (json['priority'] as num).toInt() : null,
        title: _string(json, 'title'),
        description: json['description']?.toString(),
        subtitle: json['subtitle']?.toString(),
        spaceId: (json['spaceId'])?.toString(),
        threadId: (json['threadId'])?.toString(),
        workerId: json['workerId']?.toString(),
        workspaceId: json['workspaceId']?.toString(),
        timestamp: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'].toString())
            : (json['timestamp'] != null
                ? DateTime.tryParse(json['timestamp'].toString())
                : null),
        timestampDisplay: json['timestampDisplay']?.toString(),
        categoryLabel: json['categoryLabel']?.toString(),
        actionLabel: json['actionLabel']?.toString(),
        invitation: json['invitation'] is Map
            ? AxSpaceInvitation.fromJson(
                Map<String, dynamic>.from(json['invitation'] as Map))
            : null,
        read: json['read'] == true,
        isUnread: json['unread'] == true || json['isUnread'] == true,
        isActionable:
            json['actionable'] == true || json['isActionable'] == true,
        createdAt: json['createdAt'] != null
            ? DateTime.tryParse(json['createdAt'].toString())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        if (priority != null) 'priority': priority,
        'title': title,
        'description': description,
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        if (spaceId != null) 'spaceId': spaceId,
        if (threadId != null) 'threadId': threadId,
        if (workerId != null) 'workerId': workerId,
        if (workspaceId != null) 'workspaceId': workspaceId,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (timestampDisplay != null) 'timestampDisplay': timestampDisplay,
        if (categoryLabel != null) 'categoryLabel': categoryLabel,
        if (actionLabel != null) 'actionLabel': actionLabel,
        if (invitation != null) 'invitation': invitation!.toJson(),
        'read': read,
        'unread': isUnread,
        'actionable': isActionable,
      };
}

class AxContinueWorkItem {
  const AxContinueWorkItem({
    String? spaceId,
    String? spaceName,
    String? threadId,
    String? threadTitle,
    required this.collaboratorsDisplay,
    required this.lastMessageSnippet,
    this.lastMessageAuthor = '',
    required this.lastActivityDisplay,
    this.lastMeaningfulActivityAt,
    this.hasUserParticipation = false,
    this.hasRecentWorkerResponse = false,
    this.hasUnresolvedState = false,
    this.isDirectMember = true,
    this.archived = false,
  })  : spaceId = spaceId ?? '',
        spaceName = spaceName ?? '',
        threadId = threadId ?? '',
        threadTitle = threadTitle ?? '';

  final String spaceId;
  final String spaceName;
  final String threadId;
  final String threadTitle;
  final String collaboratorsDisplay;
  final String lastMessageSnippet;

  /// Who sent [lastMessageSnippet]; empty when unknown.
  final String lastMessageAuthor;
  final String lastActivityDisplay;
  final DateTime? lastMeaningfulActivityAt;
  final bool hasUserParticipation;
  final bool hasRecentWorkerResponse;
  final bool hasUnresolvedState;
  final bool isDirectMember;
  final bool archived;

  factory AxContinueWorkItem.fromJson(Map<String, dynamic> json) =>
      AxContinueWorkItem(
        spaceId: _string(json, 'spaceId'),
        spaceName: _string(json, 'spaceName'),
        threadId: _string(json, 'threadId'),
        threadTitle: _string(json, 'threadTitle'),
        collaboratorsDisplay: _string(json, 'collaboratorsDisplay'),
        lastMessageSnippet: _string(json, 'lastMessageSnippet'),
        lastMessageAuthor: _string(json, 'lastMessageAuthor'),
        lastActivityDisplay: _string(json, 'lastActivityDisplay'),
        lastMeaningfulActivityAt: json['lastMeaningfulActivityAt'] != null
            ? DateTime.tryParse(json['lastMeaningfulActivityAt'].toString())
            : (json['updatedAt'] != null
                ? DateTime.tryParse(json['updatedAt'].toString())
                : null),
        hasUserParticipation: json['hasUserParticipation'] == true,
        hasRecentWorkerResponse: json['hasRecentWorkerResponse'] == true,
        hasUnresolvedState: json['hasUnresolvedState'] == true,
        isDirectMember: json['isDirectMember'] != false,
        archived: json['archived'] == true,
      );

  Map<String, dynamic> toJson() => {
        'spaceId': spaceId,
        'spaceName': spaceName,
        'threadId': threadId,
        'threadTitle': threadTitle,
        'collaboratorsDisplay': collaboratorsDisplay,
        'lastMessageSnippet': lastMessageSnippet,
        if (lastMessageAuthor.isNotEmpty)
          'lastMessageAuthor': lastMessageAuthor,
        'lastActivityDisplay': lastActivityDisplay,
        if (lastMeaningfulActivityAt != null)
          'lastMeaningfulActivityAt':
              lastMeaningfulActivityAt!.toIso8601String(),
        'hasUserParticipation': hasUserParticipation,
        'hasRecentWorkerResponse': hasRecentWorkerResponse,
        'hasUnresolvedState': hasUnresolvedState,
        'isDirectMember': isDirectMember,
        'archived': archived,
      };

  AxContinueWorkItem copyWith({
    String? spaceId,
    String? spaceName,
    String? threadId,
    String? threadTitle,
    String? collaboratorsDisplay,
    String? lastMessageSnippet,
    String? lastMessageAuthor,
    String? lastActivityDisplay,
    DateTime? lastMeaningfulActivityAt,
    bool? hasUserParticipation,
    bool? hasRecentWorkerResponse,
    bool? hasUnresolvedState,
    bool? isDirectMember,
    bool? archived,
  }) =>
      AxContinueWorkItem(
        spaceId: spaceId ?? this.spaceId,
        spaceName: spaceName ?? this.spaceName,
        threadId: threadId ?? this.threadId,
        threadTitle: threadTitle ?? this.threadTitle,
        collaboratorsDisplay: collaboratorsDisplay ?? this.collaboratorsDisplay,
        lastMessageSnippet: lastMessageSnippet ?? this.lastMessageSnippet,
        lastMessageAuthor: lastMessageAuthor ?? this.lastMessageAuthor,
        lastActivityDisplay: lastActivityDisplay ?? this.lastActivityDisplay,
        lastMeaningfulActivityAt:
            lastMeaningfulActivityAt ?? this.lastMeaningfulActivityAt,
        hasUserParticipation: hasUserParticipation ?? this.hasUserParticipation,
        hasRecentWorkerResponse:
            hasRecentWorkerResponse ?? this.hasRecentWorkerResponse,
        hasUnresolvedState: hasUnresolvedState ?? this.hasUnresolvedState,
        isDirectMember: isDirectMember ?? this.isDirectMember,
        archived: archived ?? this.archived,
      );
}

class AxRecentWorkRanker {
  /// Computes a composite ranking score for a Thread item based on meaningful conversation activity.
  ///
  /// Factors:
  /// - Unresolved state (+1000 pts)
  /// - Recent user participation (+500 pts)
  /// - Recent worker response (+250 pts)
  /// - Direct membership (+100 pts)
  /// - Time recency decay on meaningful conversation activity (up to +500 pts)
  ///
  /// Background metadata / sync updates do NOT inflate the score.
  static double computeScore(AxContinueWorkItem item, {DateTime? now}) {
    if (item.archived || !item.isDirectMember) return -1.0;

    final referenceTime = now ?? DateTime.now();
    double score = 0.0;

    // 1. Unresolved state (pending attention / active run)
    if (item.hasUnresolvedState) {
      score += 1000.0;
    }

    // 2. Direct user participation in discussion
    if (item.hasUserParticipation) {
      score += 500.0;
    }

    // 3. Worker response in discussion
    if (item.hasRecentWorkerResponse) {
      score += 250.0;
    }

    // 4. Direct membership
    if (item.isDirectMember) {
      score += 100.0;
    }

    // 5. Meaningful conversation recency decay
    if (item.lastMeaningfulActivityAt != null) {
      final hoursAgo =
          referenceTime.difference(item.lastMeaningfulActivityAt!).inMinutes /
              60.0;
      if (hoursAgo >= 0) {
        // Continuous decay half-life ~ 12 hours
        final recencyBoost = 500.0 / (1.0 + (hoursAgo / 12.0));
        score += recencyBoost;
      }
    }

    return score;
  }

  /// Filters out archived, deleted, and inaccessible threads,
  /// ranks remaining items using meaningful activity scores,
  /// and returns up to [limit] (default: 5).
  static List<AxContinueWorkItem> rank(
    List<AxContinueWorkItem> items, {
    int limit = 5,
    DateTime? now,
  }) {
    final indexed = <(int index, AxContinueWorkItem item)>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (!item.archived && item.isDirectMember) {
        indexed.add((i, item));
      }
    }

    indexed.sort((a, b) {
      final scoreA = computeScore(a.$2, now: now);
      final scoreB = computeScore(b.$2, now: now);
      if (scoreA != scoreB) {
        return scoreB.compareTo(scoreA); // Highest score first
      }

      // Tie-breaker: recency of meaningful activity
      final timeA = a.$2.lastMeaningfulActivityAt;
      final timeB = b.$2.lastMeaningfulActivityAt;
      if (timeA != null && timeB != null) {
        final cmp = timeB.compareTo(timeA);
        if (cmp != 0) return cmp;
      } else if (timeA != null) {
        return -1;
      } else if (timeB != null) {
        return 1;
      }

      // Final stable tie-breaker: preserve original list order
      return a.$1.compareTo(b.$1);
    });

    return indexed.map((e) => e.$2).take(limit).toList();
  }
}

enum AxProductUpdateCategory {
  feature,
  improvement,
  security,
  workflow,
  collaboration,
  workspace,
  worker;

  String get label => switch (this) {
        AxProductUpdateCategory.feature => 'Feature',
        AxProductUpdateCategory.improvement => 'Improvement',
        AxProductUpdateCategory.security => 'Security',
        AxProductUpdateCategory.workflow => 'Workflow',
        AxProductUpdateCategory.collaboration => 'Collaboration',
        AxProductUpdateCategory.workspace => 'Workspace',
        AxProductUpdateCategory.worker => 'Worker',
      };

  static AxProductUpdateCategory fromString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AxProductUpdateCategory.feature;
    }
    final normalized = value.trim().toLowerCase();
    for (final cat in AxProductUpdateCategory.values) {
      if (cat.name.toLowerCase() == normalized) return cat;
    }
    return AxProductUpdateCategory.feature;
  }
}

enum AxProductUpdateStatus {
  draft,
  published,
  archived;

  static AxProductUpdateStatus fromString(String? value) {
    if (value == null || value.trim().isEmpty) {
      return AxProductUpdateStatus.published;
    }
    final normalized = value.trim().toLowerCase();
    for (final s in AxProductUpdateStatus.values) {
      if (s.name.toLowerCase() == normalized) return s;
    }
    return AxProductUpdateStatus.published;
  }
}

class AxProductUpdate {
  const AxProductUpdate({
    required this.id,
    this.slug = '',
    required this.title,
    required this.summary,
    this.details,
    this.category = AxProductUpdateCategory.feature,
    required this.publishedAt,
    this.minimumAppVersion,
    this.maximumAppVersion,
    this.actionType,
    this.actionTarget,
    this.imageUrl,
    this.audience = 'all',
    this.status = AxProductUpdateStatus.published,
    this.actionUrl,
    this.learnMoreUrl,
    String? dateDisplay,
  }) : _customDateDisplay = dateDisplay;

  final String id;
  final String slug;
  final String title;
  final String summary;
  final String? details;
  final AxProductUpdateCategory category;
  final dynamic publishedAt;
  final String? minimumAppVersion;
  final String? maximumAppVersion;
  final String? actionType;
  final String? actionTarget;
  final String? imageUrl;
  final String audience;
  final AxProductUpdateStatus status;
  final String? actionUrl;
  final String? learnMoreUrl;
  final String? _customDateDisplay;

  DateTime get publishedDateTime {
    if (publishedAt is DateTime) {
      return publishedAt as DateTime;
    }
    if (publishedAt is String) {
      return DateTime.tryParse(publishedAt as String) ?? DateTime(2026, 1, 1);
    }
    return DateTime(2026, 1, 1);
  }

  String get dateDisplay {
    if (_customDateDisplay != null && _customDateDisplay.isNotEmpty) {
      return _customDateDisplay;
    }
    final dt = publishedDateTime;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    final monthIndex = (dt.month >= 1 && dt.month <= 12) ? dt.month - 1 : 0;
    return '${months[monthIndex]} ${dt.day}';
  }

  String get monthYearGroup {
    final dt = publishedDateTime;
    const fullMonths = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    final monthIndex = (dt.month >= 1 && dt.month <= 12) ? dt.month - 1 : 0;
    return '${fullMonths[monthIndex]} ${dt.year}';
  }

  bool isCompatibleWithVersion(String? appVersion) {
    if (appVersion == null || appVersion.isEmpty) return true;
    if (minimumAppVersion != null && minimumAppVersion!.isNotEmpty) {
      if (appVersion.compareTo(minimumAppVersion!) < 0) return false;
    }
    if (maximumAppVersion != null && maximumAppVersion!.isNotEmpty) {
      if (appVersion.compareTo(maximumAppVersion!) > 0) return false;
    }
    return true;
  }

  AxProductUpdate copyWith({
    String? id,
    String? slug,
    String? title,
    String? summary,
    String? details,
    AxProductUpdateCategory? category,
    dynamic publishedAt,
    String? minimumAppVersion,
    String? maximumAppVersion,
    String? actionType,
    String? actionTarget,
    String? imageUrl,
    String? audience,
    AxProductUpdateStatus? status,
    String? actionUrl,
    String? learnMoreUrl,
    String? dateDisplay,
  }) =>
      AxProductUpdate(
        id: id ?? this.id,
        slug: slug ?? this.slug,
        title: title ?? this.title,
        summary: summary ?? this.summary,
        details: details ?? this.details,
        category: category ?? this.category,
        publishedAt: publishedAt ?? this.publishedAt,
        minimumAppVersion: minimumAppVersion ?? this.minimumAppVersion,
        maximumAppVersion: maximumAppVersion ?? this.maximumAppVersion,
        actionType: actionType ?? this.actionType,
        actionTarget: actionTarget ?? this.actionTarget,
        imageUrl: imageUrl ?? this.imageUrl,
        audience: audience ?? this.audience,
        status: status ?? this.status,
        actionUrl: actionUrl ?? this.actionUrl,
        learnMoreUrl: learnMoreUrl ?? this.learnMoreUrl,
        dateDisplay: dateDisplay ?? _customDateDisplay,
      );

  factory AxProductUpdate.fromJson(Map<String, dynamic> json) =>
      AxProductUpdate(
        id: json['id']?.toString() ?? '',
        slug: json['slug']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        summary: json['summary']?.toString() ?? '',
        details: json['details']?.toString(),
        category:
            AxProductUpdateCategory.fromString(json['category']?.toString()),
        publishedAt: json['publishedAt']?.toString() ?? '',
        minimumAppVersion: json['minimumAppVersion']?.toString(),
        maximumAppVersion: json['maximumAppVersion']?.toString(),
        actionType: json['actionType']?.toString(),
        actionTarget: json['actionTarget']?.toString(),
        imageUrl: json['imageUrl']?.toString(),
        audience: json['audience']?.toString() ?? 'all',
        status: AxProductUpdateStatus.fromString(json['status']?.toString()),
        actionUrl: json['actionUrl']?.toString(),
        learnMoreUrl: json['learnMoreUrl']?.toString(),
        dateDisplay: json['dateDisplay']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'slug': slug,
        'title': title,
        'summary': summary,
        'details': details,
        'category': category.name,
        'publishedAt': publishedAt is DateTime
            ? (publishedAt as DateTime).toIso8601String()
            : publishedAt.toString(),
        'minimumAppVersion': minimumAppVersion,
        'maximumAppVersion': maximumAppVersion,
        'actionType': actionType,
        'actionTarget': actionTarget,
        'imageUrl': imageUrl,
        'audience': audience,
        'status': status.name,
        'actionUrl': actionUrl,
        'learnMoreUrl': learnMoreUrl,
        'dateDisplay': dateDisplay,
      };
}

class AxUserProductUpdateState {
  const AxUserProductUpdateState({
    required this.userId,
    required this.updateId,
    this.seenAt,
    this.openedAt,
    this.dismissedAt,
  });

  final String userId;
  final String updateId;
  final DateTime? seenAt;
  final DateTime? openedAt;
  final DateTime? dismissedAt;

  bool get isSeen => seenAt != null;
  bool get isOpened => openedAt != null;
  bool get isDismissed => dismissedAt != null;

  AxUserProductUpdateState copyWith({
    String? userId,
    String? updateId,
    DateTime? seenAt,
    DateTime? openedAt,
    DateTime? dismissedAt,
  }) =>
      AxUserProductUpdateState(
        userId: userId ?? this.userId,
        updateId: updateId ?? this.updateId,
        seenAt: seenAt ?? this.seenAt,
        openedAt: openedAt ?? this.openedAt,
        dismissedAt: dismissedAt ?? this.dismissedAt,
      );

  factory AxUserProductUpdateState.fromJson(Map<String, dynamic> json) =>
      AxUserProductUpdateState(
        userId: json['userId']?.toString() ?? '',
        updateId: json['updateId']?.toString() ?? '',
        seenAt: json['seenAt'] != null
            ? DateTime.tryParse(json['seenAt'].toString())
            : null,
        openedAt: json['openedAt'] != null
            ? DateTime.tryParse(json['openedAt'].toString())
            : null,
        dismissedAt: json['dismissedAt'] != null
            ? DateTime.tryParse(json['dismissedAt'].toString())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'updateId': updateId,
        'seenAt': seenAt?.toIso8601String(),
        'openedAt': openedAt?.toIso8601String(),
        'dismissedAt': dismissedAt?.toIso8601String(),
      };
}

class AxProductUpdateService {
  /// Filters updates for established user Home presentation:
  /// - Status is published (omits draft and archived)
  /// - Not dismissed by the user
  /// - Compatible with the app version
  /// - Sorted by publishedAt DESC
  /// - Limited to 2–3 items (default limit: 3)
  static List<AxProductUpdate> getHomeUpdates(
    List<AxProductUpdate> updates, {
    Map<String, AxUserProductUpdateState> readStates = const {},
    String? appVersion,
    int limit = 3,
  }) {
    final filtered = updates.where((u) {
      if (u.status != AxProductUpdateStatus.published) return false;
      final state = readStates[u.id];
      if (state != null && state.isDismissed) return false;
      if (!u.isCompatibleWithVersion(appVersion)) return false;
      return true;
    }).toList();

    filtered.sort((a, b) => b.publishedDateTime.compareTo(a.publishedDateTime));
    return filtered.take(limit).toList();
  }

  /// Calculates number of unread/unseen product updates:
  /// Published updates that are neither seen nor dismissed.
  static int computeUnreadCount(
    List<AxProductUpdate> updates, {
    Map<String, AxUserProductUpdateState> readStates = const {},
    String? appVersion,
  }) {
    return updates.where((u) {
      if (u.status != AxProductUpdateStatus.published) return false;
      if (!u.isCompatibleWithVersion(appVersion)) return false;
      final state = readStates[u.id];
      if (state != null && (state.isSeen || state.isDismissed)) return false;
      return true;
    }).length;
  }

  /// Groups updates for the full What's New changelog surface by Month Year (e.g. October 2026).
  static Map<String, List<AxProductUpdate>> groupUpdatesByMonthYear(
    List<AxProductUpdate> updates, {
    bool includeDrafts = false,
  }) {
    final list = updates.where((u) {
      if (!includeDrafts && u.status != AxProductUpdateStatus.published) {
        return false;
      }
      return true;
    }).toList();

    list.sort((a, b) => b.publishedDateTime.compareTo(a.publishedDateTime));

    final grouped = <String, List<AxProductUpdate>>{};
    for (final update in list) {
      final key = update.monthYearGroup;
      grouped.putIfAbsent(key, () => []).add(update);
    }
    return grouped;
  }
}

enum AxAiCapabilityUpdateType {
  modelAdded('model_added', 'Model Added'),
  modelRemoved('model_removed', 'Model Removed'),
  modelDeprecated('model_deprecated', 'Model Deprecated'),
  capabilityAdded('capability_added', 'Capability Added'),
  capabilityChanged('capability_changed', 'Capability Changed'),
  profileUpdated('profile_updated', 'Profile Updated'),
  authenticationChanged('authentication_changed', 'Authentication Changed');

  const AxAiCapabilityUpdateType(this.wireName, this.label);

  final String wireName;
  final String label;

  static AxAiCapabilityUpdateType fromString(String? value) {
    if (value == null) return AxAiCapabilityUpdateType.capabilityAdded;
    return AxAiCapabilityUpdateType.values.firstWhere(
      (e) => e.wireName == value || e.name == value,
      orElse: () => AxAiCapabilityUpdateType.capabilityAdded,
    );
  }

  bool get isModelUpdate =>
      this == modelAdded || this == modelRemoved || this == modelDeprecated;

  bool get isCapabilityUpdate =>
      this == capabilityAdded || this == capabilityChanged;
}

enum AxAiCapabilityUpdateSource {
  editorial('editorial', 'Editorial'),
  systemGenerated('system_generated', 'System');

  const AxAiCapabilityUpdateSource(this.wireName, this.label);

  final String wireName;
  final String label;

  static AxAiCapabilityUpdateSource fromString(String? value) {
    if (value == null) return AxAiCapabilityUpdateSource.editorial;
    return AxAiCapabilityUpdateSource.values.firstWhere(
      (e) => e.wireName == value || e.name == value,
      orElse: () => AxAiCapabilityUpdateSource.editorial,
    );
  }

  bool get isEditorial => this == editorial;
  bool get isSystemGenerated => this == systemGenerated;
}

class AxAiCapabilityUpdate {
  const AxAiCapabilityUpdate({
    required this.id,
    required this.workerProfileId,
    this.provider,
    this.type = AxAiCapabilityUpdateType.capabilityAdded,
    this.source = AxAiCapabilityUpdateSource.editorial,
    this.modelId,
    this.modelDisplayName,
    required this.title,
    required this.summary,
    this.publishedAt,
    this.actionTarget,
    this.minimumProfileVersion,
    String? workerDisplayName,
    String? dateDisplay,
    this.actionLabel,
  })  : _workerDisplayName = workerDisplayName,
        _customDateDisplay = dateDisplay;

  final String id;
  final String workerProfileId;
  final String? provider;
  final AxAiCapabilityUpdateType type;
  final AxAiCapabilityUpdateSource source;
  final String? modelId;
  final String? modelDisplayName;
  final String title;
  final String summary;
  final dynamic publishedAt;
  final String? actionTarget;
  final String? minimumProfileVersion;
  final String? _workerDisplayName;
  final String? _customDateDisplay;
  final String? actionLabel;

  bool get isSystemGenerated => source.isSystemGenerated;
  bool get isEditorial => source.isEditorial;

  /// Worker type identifier alias for compatibility.
  String get workerTypeId => workerProfileId;

  /// Worker display name helper.
  String get workerDisplayName {
    if (_workerDisplayName != null && _workerDisplayName.isNotEmpty) {
      return _workerDisplayName;
    }
    return switch (workerProfileId.toLowerCase()) {
      'chatgpt' => 'ChatGPT Worker',
      'gemini' => 'Gemini Worker',
      'claude' => 'Claude Worker',
      'ollama' => 'Ollama Worker',
      _ =>
        '${workerProfileId.isEmpty ? "AI" : "${workerProfileId[0].toUpperCase()}${workerProfileId.substring(1)}"} Worker',
    };
  }

  /// Detail alias for compatibility with legacy UI properties.
  String get detail => summary;

  DateTime get publishedDateTime {
    if (publishedAt is DateTime) {
      return publishedAt as DateTime;
    }
    if (publishedAt is String) {
      return DateTime.tryParse(publishedAt as String) ?? DateTime(2026, 1, 1);
    }
    return DateTime(2026, 1, 1);
  }

  String get dateDisplay {
    if (_customDateDisplay != null && _customDateDisplay.isNotEmpty) {
      return _customDateDisplay;
    }
    final dt = publishedDateTime;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  bool isCompatibleWithProfileVersion(String? profileVersion) {
    if (minimumProfileVersion == null || profileVersion == null) return true;
    return profileVersion.compareTo(minimumProfileVersion!) >= 0;
  }

  AxAiCapabilityUpdate copyWith({
    String? id,
    String? workerProfileId,
    String? provider,
    AxAiCapabilityUpdateType? type,
    AxAiCapabilityUpdateSource? source,
    String? modelId,
    String? modelDisplayName,
    String? title,
    String? summary,
    dynamic publishedAt,
    String? actionTarget,
    String? minimumProfileVersion,
    String? workerDisplayName,
    String? dateDisplay,
    String? actionLabel,
  }) =>
      AxAiCapabilityUpdate(
        id: id ?? this.id,
        workerProfileId: workerProfileId ?? this.workerProfileId,
        provider: provider ?? this.provider,
        type: type ?? this.type,
        source: source ?? this.source,
        modelId: modelId ?? this.modelId,
        modelDisplayName: modelDisplayName ?? this.modelDisplayName,
        title: title ?? this.title,
        summary: summary ?? this.summary,
        publishedAt: publishedAt ?? this.publishedAt,
        actionTarget: actionTarget ?? this.actionTarget,
        minimumProfileVersion:
            minimumProfileVersion ?? this.minimumProfileVersion,
        workerDisplayName: workerDisplayName ?? _workerDisplayName,
        dateDisplay: dateDisplay ?? _customDateDisplay,
        actionLabel: actionLabel ?? this.actionLabel,
      );

  factory AxAiCapabilityUpdate.fromJson(Map<String, dynamic> json) =>
      AxAiCapabilityUpdate(
        id: json['id'] as String? ?? '',
        workerProfileId: json['workerProfileId'] as String? ??
            json['workerTypeId'] as String? ??
            '',
        provider: json['provider'] as String?,
        type: AxAiCapabilityUpdateType.fromString(json['type'] as String?),
        source: AxAiCapabilityUpdateSource.fromString(
            json['source'] as String? ?? json['origin'] as String?),
        modelId: json['modelId'] as String?,
        modelDisplayName: json['modelDisplayName'] as String?,
        title: json['title'] as String? ?? '',
        summary: json['summary'] as String? ?? json['detail'] as String? ?? '',
        publishedAt: json['publishedAt'],
        actionTarget: json['actionTarget'] as String?,
        minimumProfileVersion: json['minimumProfileVersion'] as String?,
        workerDisplayName: json['workerDisplayName'] as String?,
        dateDisplay: json['dateDisplay'] as String?,
        actionLabel: json['actionLabel'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'workerProfileId': workerProfileId,
        if (provider != null) 'provider': provider,
        'type': type.wireName,
        'source': source.wireName,
        if (modelId != null) 'modelId': modelId,
        if (modelDisplayName != null) 'modelDisplayName': modelDisplayName,
        'title': title,
        'summary': summary,
        'publishedAt': publishedAt is DateTime
            ? (publishedAt as DateTime).toIso8601String()
            : publishedAt?.toString(),
        if (actionTarget != null) 'actionTarget': actionTarget,
        if (minimumProfileVersion != null)
          'minimumProfileVersion': minimumProfileVersion,
        if (_workerDisplayName != null) 'workerDisplayName': _workerDisplayName,
        if (_customDateDisplay != null) 'dateDisplay': _customDateDisplay,
        if (actionLabel != null) 'actionLabel': actionLabel,
      };
}

typedef AxAiUpdate = AxAiCapabilityUpdate;

class AxAiCapabilityUpdateService {
  /// Resolves the set of worker profile and provider identifiers accessible to the user:
  /// 1. Directly owned/connected workspace workers (`workerTypeId`, `profileDefinitionId`, `providerToolName`)
  /// 2. Shared space workers in thread configurations (`workConfig['worker']`, `workConfig['workerTypeId']`, `ws.lead`)
  /// 3. Shared space worker grants and settings (`space.settings['sharedWorkers']`, `space.settings['workerGrants']`)
  static Set<String> resolveAccessibleWorkerProfileIds({
    required List<AxWorker> workers,
    List<AxSpace> spaces = const [],
  }) {
    final accessible = <String>{};

    for (final w in workers) {
      if (w.workerTypeId.isNotEmpty) {
        accessible.add(w.workerTypeId.toLowerCase());
      }
      if (w.profileDefinitionId != null && w.profileDefinitionId!.isNotEmpty) {
        accessible.add(w.profileDefinitionId!.toLowerCase());
      }
      if (w.providerToolName != null && w.providerToolName!.isNotEmpty) {
        accessible.add(w.providerToolName!.toLowerCase());
      }
    }

    for (final s in spaces) {
      if (s.archived) continue;
      // Space settings / worker grants
      final settings = s.settings;
      if (settings['sharedWorkers'] is List) {
        for (final item in (settings['sharedWorkers'] as List)) {
          final id = item is Map
              ? (item['workerTypeId'] ??
                      item['workerProfileId'] ??
                      item['id'] ??
                      item['worker'])
                  ?.toString()
              : item?.toString();
          if (id != null && id.isNotEmpty) accessible.add(id.toLowerCase());
        }
      }
      if (settings['workerGrants'] is List) {
        for (final item in (settings['workerGrants'] as List)) {
          final id = item is Map
              ? (item['workerTypeId'] ??
                      item['workerProfileId'] ??
                      item['id'] ??
                      item['worker'])
                  ?.toString()
              : item?.toString();
          if (id != null && id.isNotEmpty) accessible.add(id.toLowerCase());
        }
      }

      for (final th in s.threads) {
        if (th.archived) continue;
        final cfg = th.workConfig;
        final workerInConfig = (cfg['workerTypeId'] ??
                cfg['workerProfileId'] ??
                cfg['worker'] ??
                cfg['workerType'])
            ?.toString();
        if (workerInConfig != null && workerInConfig.isNotEmpty) {
          accessible.add(workerInConfig.toLowerCase());
        }
        // Check standard worker designations in lead (e.g. 'ChatGPT', 'Gemini', 'Claude', 'Ollama')
        final lead = th.lead.toLowerCase();
        if (lead.contains('chatgpt') || lead.contains('openai')) {
          accessible.add('chatgpt');
          accessible.add('openai');
        }
        if (lead.contains('gemini') || lead.contains('google')) {
          accessible.add('gemini');
          accessible.add('google');
        }
        if (lead.contains('claude') || lead.contains('anthropic')) {
          accessible.add('claude');
          accessible.add('anthropic');
        }
        if (lead.contains('ollama')) {
          accessible.add('ollama');
        }
      }
    }

    return accessible;
  }

  /// Filters AI capability updates to only those applicable to the user's accessible workers/profiles.
  /// If the user has zero accessible workers or spaces, returns an empty list (cleanly omitted).
  /// Irrelevant updates for ungranted/unaccessible models or providers are strictly excluded.
  static List<AxAiCapabilityUpdate> getRelevantUpdates({
    required List<AxAiCapabilityUpdate> updates,
    required List<AxWorker> workers,
    List<AxSpace> spaces = const [],
    int? limit,
  }) {
    final accessibleProfileIds = resolveAccessibleWorkerProfileIds(
      workers: workers,
      spaces: spaces,
    );

    if (accessibleProfileIds.isEmpty) {
      return const [];
    }

    final filtered = updates.where((update) {
      final profileId = update.workerProfileId.toLowerCase();
      final provider = update.provider?.toLowerCase();
      final workerTypeId = update.workerTypeId.toLowerCase();

      return accessibleProfileIds.contains(profileId) ||
          accessibleProfileIds.contains(workerTypeId) ||
          (provider != null && accessibleProfileIds.contains(provider));
    }).toList();

    filtered.sort((a, b) => b.publishedDateTime.compareTo(a.publishedDateTime));

    if (limit != null && limit > 0 && filtered.length > limit) {
      return filtered.sublist(0, limit);
    }
    return filtered;
  }

  /// Automatically synthesizes system-generated AI capability discovery updates
  /// when local or catalog model discovery detects newly available or retired models.
  /// (e.g. Profile discovery detects [A, B] -> [A, B, C]).
  static List<AxAiCapabilityUpdate> synthesizeDiscoveredModelUpdates({
    required String workerProfileId,
    String? provider,
    String? workerDisplayName,
    required List<String> previousModelIds,
    required List<String> currentModelIds,
    DateTime? timestamp,
  }) {
    final updates = <AxAiCapabilityUpdate>[];
    final prevSet = previousModelIds.toSet();
    final currentSet = currentModelIds.toSet();

    final addedModels = currentSet.difference(prevSet);
    final removedModels = prevSet.difference(currentSet);

    final resolvedWorkerDisplayName = workerDisplayName ??
        switch (workerProfileId.toLowerCase()) {
          'chatgpt' => 'ChatGPT Worker',
          'gemini' => 'Gemini Worker',
          'claude' => 'Claude Worker',
          'ollama' => 'Ollama Worker',
          _ =>
            '${workerProfileId.isEmpty ? "AI" : "${workerProfileId[0].toUpperCase()}${workerProfileId.substring(1)}"} Worker',
        };

    for (final modelId in addedModels) {
      updates.add(
        AxAiCapabilityUpdate(
          id: 'discovery-$workerProfileId-added-$modelId',
          workerProfileId: workerProfileId,
          provider: provider,
          type: AxAiCapabilityUpdateType.modelAdded,
          source: AxAiCapabilityUpdateSource.systemGenerated,
          modelId: modelId,
          modelDisplayName: modelId,
          title: 'New model available',
          summary:
              'Model $modelId is now available for your $resolvedWorkerDisplayName.',
          publishedAt: timestamp ?? DateTime.now(),
          workerDisplayName: resolvedWorkerDisplayName,
        ),
      );
    }

    for (final modelId in removedModels) {
      updates.add(
        AxAiCapabilityUpdate(
          id: 'discovery-$workerProfileId-removed-$modelId',
          workerProfileId: workerProfileId,
          provider: provider,
          type: AxAiCapabilityUpdateType.modelRemoved,
          source: AxAiCapabilityUpdateSource.systemGenerated,
          modelId: modelId,
          modelDisplayName: modelId,
          title: 'Model retired',
          summary:
              'Model $modelId was removed or retired from $resolvedWorkerDisplayName.',
          publishedAt: timestamp ?? DateTime.now(),
          workerDisplayName: resolvedWorkerDisplayName,
        ),
      );
    }

    return updates;
  }

  /// Merges curated editorial updates with automated system discovery updates.
  /// If an editorial update already covers a specific modelId for a workerProfileId,
  /// the curated editorial item takes precedence over the automated discovery item.
  static List<AxAiCapabilityUpdate> mergeUpdates({
    required List<AxAiCapabilityUpdate> editorialUpdates,
    List<AxAiCapabilityUpdate> discoveryUpdates = const [],
  }) {
    final editorialModelKeys = <String>{};
    for (final u in editorialUpdates) {
      if (u.modelId != null && u.modelId!.isNotEmpty) {
        editorialModelKeys.add(
            '${u.workerProfileId.toLowerCase()}:${u.modelId!.toLowerCase()}');
      }
    }

    final merged = <AxAiCapabilityUpdate>[...editorialUpdates];
    for (final disc in discoveryUpdates) {
      final key =
          '${disc.workerProfileId.toLowerCase()}:${disc.modelId?.toLowerCase()}';
      if (disc.modelId != null && editorialModelKeys.contains(key)) {
        // Suppress redundant system discovery item when curated editorial update exists
        continue;
      }
      merged.add(disc);
    }

    merged.sort((a, b) => b.publishedDateTime.compareTo(a.publishedDateTime));
    return merged;
  }
}

/// Server read projection of Home aggregation:
/// GET /api/home -> { attention, running, recentWork, productUpdates, aiUpdates }
class AxHomeReadModel {
  const AxHomeReadModel({
    this.attention = const [],
    this.running = const [],
    this.recentWork = const [],
    this.productUpdates = const [],
    this.aiUpdates = const [],
  });

  final List<AxHomeAttentionItem> attention;
  final List<AxRun> running;
  final List<AxContinueWorkItem> recentWork;
  final List<AxProductUpdate> productUpdates;
  final List<AxAiCapabilityUpdate> aiUpdates;

  factory AxHomeReadModel.fromJson(Map<String, dynamic> json) {
    final rawAttention = json['attention'];
    final attentionList = <AxHomeAttentionItem>[];
    if (rawAttention is List) {
      for (final it in rawAttention) {
        if (it is Map<String, dynamic>) {
          attentionList.add(AxHomeAttentionItem.fromJson(it));
        } else if (it is Map) {
          attentionList
              .add(AxHomeAttentionItem.fromJson(Map<String, dynamic>.from(it)));
        }
      }
    }

    final rawRunning = json['running'];
    final runningList = <AxRun>[];
    if (rawRunning is List) {
      for (final it in rawRunning) {
        if (it is Map<String, dynamic>) {
          runningList.add(AxRun.fromJson(it));
        } else if (it is Map) {
          runningList.add(AxRun.fromJson(Map<String, dynamic>.from(it)));
        }
      }
    }

    final rawRecentWork = json['recentWork'];
    final recentWorkList = <AxContinueWorkItem>[];
    if (rawRecentWork is List) {
      for (final it in rawRecentWork) {
        if (it is Map<String, dynamic>) {
          recentWorkList.add(AxContinueWorkItem.fromJson(it));
        } else if (it is Map) {
          recentWorkList
              .add(AxContinueWorkItem.fromJson(Map<String, dynamic>.from(it)));
        }
      }
    }

    final rawProductUpdates = json['productUpdates'];
    final productUpdatesList = <AxProductUpdate>[];
    if (rawProductUpdates is List) {
      for (final it in rawProductUpdates) {
        if (it is Map<String, dynamic>) {
          productUpdatesList.add(AxProductUpdate.fromJson(it));
        } else if (it is Map) {
          productUpdatesList
              .add(AxProductUpdate.fromJson(Map<String, dynamic>.from(it)));
        }
      }
    }

    final rawAiUpdates = json['aiUpdates'];
    final aiUpdatesList = <AxAiCapabilityUpdate>[];
    if (rawAiUpdates is List) {
      for (final it in rawAiUpdates) {
        if (it is Map<String, dynamic>) {
          aiUpdatesList.add(AxAiCapabilityUpdate.fromJson(it));
        } else if (it is Map) {
          aiUpdatesList.add(
              AxAiCapabilityUpdate.fromJson(Map<String, dynamic>.from(it)));
        }
      }
    }

    return AxHomeReadModel(
      attention: attentionList,
      running: runningList,
      recentWork: recentWorkList,
      productUpdates: productUpdatesList,
      aiUpdates: aiUpdatesList,
    );
  }

  Map<String, dynamic> toJson() => {
        'attention': attention.map((it) => it.toJson()).toList(),
        'running': running.map((it) => it.toJson()).toList(),
        'recentWork': recentWork.map((it) => it.toJson()).toList(),
        'productUpdates': productUpdates.map((it) => it.toJson()).toList(),
        'aiUpdates': aiUpdates.map((it) => it.toJson()).toList(),
      };
}
