import 'ax_execution_phase.dart';
import 'ax_models.dart';

class AxTurnExecutionConfig {
  AxTurnExecutionConfig.fromJson(Map<String, dynamic> json)
      : schemaVersion = json['schemaVersion'] as int,
        workerId = json['workerId'] as String,
        profileId = json['profileId'] as String,
        profileReleaseVersion = json['profileReleaseVersion'] as int,
        modelId = json['modelId'] as String?,
        effort = json['effort'] as String?,
        workflowId = json['workflowId'] as String,
        workflowVersion = json['workflowVersion'] as int;
  final int schemaVersion;
  final String workerId;
  final String profileId;
  final int profileReleaseVersion;
  final String? modelId;
  final String? effort;
  final String workflowId;
  final int workflowVersion;
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'workerId': workerId,
        'profileId': profileId,
        'profileReleaseVersion': profileReleaseVersion,
        'modelId': modelId,
        'effort': effort,
        'workflowId': workflowId,
        'workflowVersion': workflowVersion,
      };
}

class AxWorkflowStepRun {
  final AxTurnExecutionConfig? executionConfig;
  AxWorkflowStepRun.fromJson(Map<String, dynamic> json)
      : schemaVersion = json['schemaVersion'] as int,
        id = json['id'] as String,
        workflowRunId = json['workflowRunId'] as String,
        executionConfig = json['executionConfig'] is Map
            ? AxTurnExecutionConfig.fromJson(
                Map<String, dynamic>.from(json['executionConfig'] as Map))
            : null,
        taskId = json['taskId'] as String,
        stepId = json['stepId'] as String,
        role = json['role'] as String,
        workerId = json['workerId'] as String?,
        modelId = json['modelId'] as String?,
        effort = json['effort'] as String?,
        workerSessionId = json['workerSessionId'] as String?,
        baseContextRevision = json['baseContextRevision'] as int,
        status = json['status'] as String,
        result = json['result'] as String?,
        startedAt = json['startedAt'] as String?,
        completedAt = json['completedAt'] as String?,
        workerTurnIds = List.unmodifiable(
            (json['workerTurnIds'] as List? ?? const []).cast<String>());
  final int schemaVersion, baseContextRevision;
  final String id, workflowRunId, taskId, stepId, role, status;
  final String? workerId,
      modelId,
      effort,
      workerSessionId,
      result,
      startedAt,
      completedAt;
  final List<String> workerTurnIds;
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'workflowRunId': workflowRunId,
        if (executionConfig != null)
          'executionConfig': executionConfig!.toJson(),
        'taskId': taskId,
        'stepId': stepId,
        'role': role,
        'workerId': workerId,
        'modelId': modelId,
        'effort': effort,
        'workerSessionId': workerSessionId,
        'baseContextRevision': baseContextRevision,
        'status': status,
        'result': result,
        'startedAt': startedAt,
        'completedAt': completedAt,
        'workerTurnIds': workerTurnIds
      };
}

class AxWorkflowRun {
  final Map<String, AxTurnExecutionConfig> executionConfigs;
  AxWorkflowRun.fromJson(Map<String, dynamic> json)
      : executionConfigs = Map.unmodifiable(
            (json['executionConfigs'] as Map? ?? const {}).map((key, value) =>
                MapEntry(
                    key.toString(),
                    AxTurnExecutionConfig.fromJson(
                        Map<String, dynamic>.from(value as Map))))),
        schemaVersion = json['schemaVersion'] as int,
        id = json['id'] as String,
        conversationId = json['conversationId'] as String,
        userMessageId = json['userMessageId'] as String,
        triggerMessageId =
            (json['triggerMessageId'] ?? json['userMessageId']) as String,
        startedAt = json['startedAt'] as String?,
        completedAt = json['completedAt'] as String?,
        stepRuns = List.unmodifiable((json['stepRuns'] as List? ?? const [])
            .whereType<Map>()
            .map((item) =>
                AxWorkflowStepRun.fromJson(Map<String, dynamic>.from(item)))),
        workRequestId = json['workRequestId'] as String,
        workflowId = json['workflowId'] as String,
        workflowVersion = json['workflowVersion'] as int,
        status = json['status'] as String,
        runtimeRunIds =
            List.unmodifiable((json['runtimeRunIds'] as List).cast<String>()),
        workerTurnIds =
            List.unmodifiable((json['workerTurnIds'] as List).cast<String>()),
        createdAt = json['createdAt'] as String,
        updatedAt = json['updatedAt'] as String;
  final int schemaVersion;
  final String id,
      conversationId,
      userMessageId,
      workRequestId,
      workflowId,
      status,
      createdAt,
      updatedAt;
  final int workflowVersion;
  final String triggerMessageId;
  final String? startedAt, completedAt;
  final List<AxWorkflowStepRun> stepRuns;
  final List<String> runtimeRunIds, workerTurnIds;
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'conversationId': conversationId,
        'userMessageId': userMessageId,
        'workRequestId': workRequestId,
        'workflowId': workflowId,
        'workflowVersion': workflowVersion,
        'status': status,
        'triggerMessageId': triggerMessageId,
        'startedAt': startedAt,
        'completedAt': completedAt,
        if (executionConfigs.isNotEmpty)
          'executionConfigs': executionConfigs
              .map((key, value) => MapEntry(key, value.toJson())),
        'stepRuns': stepRuns.map((step) => step.toJson()).toList(),
        'runtimeRunIds': runtimeRunIds,
        'workerTurnIds': workerTurnIds,
        'createdAt': createdAt,
        'updatedAt': updatedAt
      };
}

class AxConversationTurn {
  AxConversationTurn.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        conversationId = json['conversationId'] as String,
        workflowId = json['workflowId'] as String,
        workflowVersion = json['workflowVersion'] as int,
        userMessageId = json['userMessageId'] as String,
        workRequestId = json['workRequestId'] as String,
        workflowRunId = json['workflowRunId'] as String?,
        workflowStepRunId = json['workflowStepRunId'] as String?,
        runtimeRunId = json['runtimeRunId'] as String?,
        assignmentId = json['assignmentId'] as String,
        taskId = json['taskId'] as String,
        stepKind = json['stepKind'] as String,
        workerId = json['workerId'] as String,
        workerTypeId = json['workerTypeId'] as String,
        workerDisplayName = json['workerDisplayName'] as String,
        workerOwnerName = json['workerOwnerName'] as String?,
        profileId = json['profileId'] as String,
        profileVersion = json['profileVersion'] as int,
        modelId = json['modelId'] as String?,
        modelName = json['modelName'] as String?,
        catalogRevision = json['catalogRevision'] as String?,
        effort = json['effort'] as String?,
        workerSessionId = json['workerSessionId'] as String?,
        baseContextRevision = json['baseContextRevision'] as int,
        status = json['status'] as String,
        startedAt = json['startedAt'] as String?,
        completedAt = json['completedAt'] as String?,
        resultText = json['resultText'] as String?,
        createdAt = json['createdAt'] as String;
  final String id;
  final String conversationId;
  final String workflowId;
  final int workflowVersion;
  final String userMessageId;
  final String workRequestId;
  final String? workflowRunId;
  final String? workflowStepRunId;
  final String? runtimeRunId;
  final String assignmentId;
  final String taskId;
  final String stepKind;
  final String workerId;
  final String workerTypeId;
  final String workerDisplayName;

  /// Person whose Workspace ran this turn, when Cloud recorded it.
  final String? workerOwnerName;
  final String profileId;
  final int profileVersion;
  final String? modelId;
  final String? modelName, catalogRevision;
  final String? effort;
  final String? workerSessionId;
  final int baseContextRevision;
  final String status;
  final String? startedAt;
  final String? completedAt;
  final String? resultText;
  final String createdAt;
  Map<String, dynamic> toJson() => {
        'id': id,
        'conversationId': conversationId,
        'workflowId': workflowId,
        'workflowVersion': workflowVersion,
        'userMessageId': userMessageId,
        'workRequestId': workRequestId,
        'workflowRunId': workflowRunId,
        'workflowStepRunId': workflowStepRunId,
        'runtimeRunId': runtimeRunId,
        'assignmentId': assignmentId,
        'taskId': taskId,
        'stepKind': stepKind,
        'workerId': workerId,
        'workerTypeId': workerTypeId,
        'workerDisplayName': workerDisplayName,
        if (workerOwnerName != null) 'workerOwnerName': workerOwnerName,
        'profileId': profileId,
        'profileVersion': profileVersion,
        'modelId': modelId,
        if (modelName != null) 'modelName': modelName,
        if (catalogRevision != null) 'catalogRevision': catalogRevision,
        'effort': effort,
        'workerSessionId': workerSessionId,
        'baseContextRevision': baseContextRevision,
        'status': status,
        'startedAt': startedAt,
        'completedAt': completedAt,
        'resultText': resultText,
        'createdAt': createdAt,
      };
}

class AxConversationHistoryEntry {
  AxConversationHistoryEntry.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        conversationId = json['conversationId'] as String,
        sequence = json['sequence'] as int,
        kind = json['kind'] as String,
        eventType = json['eventType'] as String,
        text = json['text'] as String?,
        metadata = Map.unmodifiable(
            Map<String, dynamic>.from(json['metadata'] as Map)),
        occurredAt = json['occurredAt'] as String,
        recordedAt = json['recordedAt'] as String;
  final String id;
  final String conversationId;
  final int sequence;
  final String kind;
  final String eventType;
  final String? text;
  final Map<String, dynamic> metadata;
  final String occurredAt;
  final String recordedAt;
}

class AxConversationHistoryPage {
  AxConversationHistoryPage.fromJson(Map<String, dynamic> json)
      : conversationId = json['conversationId'] as String,
        historyRevision = json['historyRevision'] as int,
        throughSequence = json['throughSequence'] as int,
        entries = List.unmodifiable((json['entries'] as List).map((item) =>
            AxConversationHistoryEntry.fromJson(
                Map<String, dynamic>.from(item as Map)))),
        nextCursor = json['nextCursor'] is Map
            ? Map<String, int>.unmodifiable(
                Map<String, int>.from(json['nextCursor'] as Map))
            : null;
  final String conversationId;
  final int historyRevision;
  final int throughSequence;
  final List<AxConversationHistoryEntry> entries;
  final Map<String, int>? nextCursor;
}

class AxWorkRequestCursor {
  const AxWorkRequestCursor({required this.createdAt, required this.id});
  final String createdAt;
  final String id;
  @override
  bool operator ==(Object other) =>
      other is AxWorkRequestCursor &&
      other.createdAt == createdAt &&
      other.id == id;
  @override
  int get hashCode => Object.hash(createdAt, id);
}

class AxWorkRequestPage {
  AxWorkRequestPage(
      {required Iterable<AxWorkRequest> requests,
      this.nextCursor,
      this.aiHistoryClearedAt})
      : requests = List.unmodifiable(requests);
  final List<AxWorkRequest> requests;
  final AxWorkRequestCursor? nextCursor;

  /// Requests created at or before this instant stay in the Conversation but
  /// are hidden from AI History.
  final String? aiHistoryClearedAt;
}

/// Attachment display metadata and opaque ID; original file bytes stay in R2.
class AxWorkAttachment {
  const AxWorkAttachment(
      {required this.name,
      required this.sizeBytes,
      this.previewText,
      this.fileId,
      this.previewImage});
  final String name;
  final int sizeBytes;
  final String? fileId;
  final String? previewText;
  final String? previewImage;
  Map<String, dynamic> toJson() => {
        'kind': 'file',
        'name': name,
        'sizeBytes': sizeBytes,
        if (fileId != null) 'fileId': fileId,
        if (previewText != null) 'previewText': previewText,
        if (previewImage != null) 'previewImage': previewImage
      };
  static List<AxWorkAttachment> fromList(Object? value) =>
      List.unmodifiable((value is List ? value : const [])
          .whereType<Map>()
          .where((item) => item['kind'] == 'file')
          .map((item) => AxWorkAttachment(
              name: item['name'] is String
                  ? item['name'] as String
                  : 'Attachment',
              fileId: item['fileId'] as String?,
              previewText: item['previewText'] as String?,
              previewImage: item['previewImage'] as String?,
              sizeBytes:
                  item['sizeBytes'] is int ? item['sizeBytes'] as int : 0)));
}

class AxWorkRequestStatus {
  const AxWorkRequestStatus({
    this.id,
    this.conversationId,
    this.executionConfig,
    this.attachments = const [],
    this.turns = const [],
    this.workflowRun,
    this.threadId,
    required this.status,
    this.text,
    this.error,
    this.errorCode,
    this.errorMessage,
    this.workflowId,
    this.workflowVersion,
    this.workflowName,
    this.requestedByUserId,
    this.requestedByName,
    this.originalRequest,
    this.createdAt,
    this.steps = const [],
    this.activityHistory = const [],
    this.executionPhase,
  });

  final String? id;
  final String? conversationId;
  final List<AxWorkAttachment> attachments;
  final AxTurnExecutionConfig? executionConfig;
  final List<AxConversationTurn> turns;
  final AxWorkflowRun? workflowRun;
  final String? threadId;
  final String status;
  final String? text;
  final String? error;
  final String? errorCode;
  final String? errorMessage;
  final String? workflowId;
  final int? workflowVersion;
  final String? workflowName;
  final String? requestedByUserId;
  final String? requestedByName;
  final String? originalRequest;
  final String? createdAt;
  final List<AxWorkRequestStep> steps;
  final List<Map<String, dynamic>> activityHistory;
  final String? executionPhase;
}

class AxWorkRequestStep {
  const AxWorkRequestStep({
    required this.kind,
    required this.status,
    required this.workerId,
    this.workerTypeId,
    this.workerDisplayName,
    this.engineVersion,
    this.profileDefinitionId,
    this.profileReleaseVersion,
    this.providerToolName,
    this.providerToolVersion,
    this.model,
    this.modelName,
    this.catalogRevision,
    this.reasoningEffort,
    this.testSummary,
    this.startedAt,
    this.updatedAt,
    this.elapsedMs,
    this.completedAt,
    this.resultText,
    this.assignmentId,
    this.sessionPolicy,
    this.errorCode,
    this.errorMessage,
    this.retrySessionStrategy,
    this.executionPhase,
    this.executionPhaseDetail,
    this.failureCategory,
    this.failureCategoryMessage,
    this.retryAllowed = false,
    this.retryRequiresConfirmation = false,
    this.contextCompactionAvailable = false,
  });

  final String kind;
  final String status;
  final String? workerId;
  final String? workerTypeId;
  final String? workerDisplayName;
  final String? engineVersion;
  final String? profileDefinitionId;
  final int? profileReleaseVersion;
  final String? providerToolName;
  final String? providerToolVersion;
  final String? model;
  final String? modelName, catalogRevision;
  final String? reasoningEffort;
  final String? testSummary;
  final String? startedAt;
  final String? updatedAt;
  final int? elapsedMs;
  final String? completedAt;
  final String? resultText;
  final String? assignmentId;
  final String? sessionPolicy;
  final String? errorCode;
  final String? errorMessage;
  final String? retrySessionStrategy;

  /// Cloud-derived execution state; see [AxExecutionPhase]. Null only for
  /// responses from a Cloud that predates Phase 7.
  final String? executionPhase;
  final String? executionPhaseDetail;

  /// Fixed public failure category and message; never provider text.
  final String? failureCategory;
  final String? failureCategoryMessage;

  /// Cloud's retry advice for a failed step.
  final bool retryAllowed;
  final bool retryRequiresConfirmation;

  /// Over the context limit: the Worker can compact its session instead of
  /// clearing AI History. Only the Work Request detail reports it.
  final bool contextCompactionAvailable;

  /// The phase to render: Cloud's, or a status-derived fallback that never
  /// claims Running.
  String get effectivePhase {
    if (AxExecutionPhase.isTerminal(status)) return status;
    final phase = executionPhase;
    if (AxExecutionPhase.isKnown(phase)) return phase!;
    return switch (status) {
      'running' => AxExecutionPhase.submitted,
      'completed' => AxExecutionPhase.completed,
      'failed' => AxExecutionPhase.failed,
      'cancelled' => AxExecutionPhase.cancelled,
      _ => AxExecutionPhase.queued,
    };
  }

  AxWorkRequestStep withExecutionPhase(String phase) => _copy(
        status: status,
        executionPhase: phase,
        executionPhaseDetail: AxExecutionPhase.detail(phase),
      );

  /// Adopts the first assignment Cloud reports for a step that was read
  /// before its assignment existed, together with that assignment's phase.
  AxWorkRequestStep withAssignedPhase(String assignment, String phase) => _copy(
        status: status,
        executionPhase: phase,
        executionPhaseDetail: AxExecutionPhase.detail(phase),
        assignment: assignment,
      );

  /// A terminal status always carries its terminal phase, so a step moved to
  /// `completed` can never keep rendering a stale `running` phase.
  AxWorkRequestStep withStatus(String value) => _copy(
        status: value,
        executionPhase:
            AxExecutionPhase.isTerminal(value) ? value : executionPhase,
        executionPhaseDetail:
            AxExecutionPhase.isTerminal(value) ? null : executionPhaseDetail,
      );

  AxWorkRequestStep _copy({
    required String status,
    required String? executionPhase,
    required String? executionPhaseDetail,
    String? assignment,
  }) =>
      AxWorkRequestStep(
          kind: kind,
          status: status,
          workerId: workerId,
          workerTypeId: workerTypeId,
          workerDisplayName: workerDisplayName,
          engineVersion: engineVersion,
          profileDefinitionId: profileDefinitionId,
          profileReleaseVersion: profileReleaseVersion,
          providerToolName: providerToolName,
          providerToolVersion: providerToolVersion,
          model: model,
          modelName: modelName,
          catalogRevision: catalogRevision,
          reasoningEffort: reasoningEffort,
          testSummary: testSummary,
          startedAt: startedAt,
          updatedAt: updatedAt,
          elapsedMs: elapsedMs,
          completedAt: completedAt,
          resultText: resultText,
          assignmentId: assignment ?? assignmentId,
          sessionPolicy: sessionPolicy,
          errorCode: errorCode,
          errorMessage: errorMessage,
          retrySessionStrategy: retrySessionStrategy,
          executionPhase: executionPhase,
          executionPhaseDetail: executionPhaseDetail,
          failureCategory: failureCategory,
          failureCategoryMessage: failureCategoryMessage,
          retryAllowed: retryAllowed,
          retryRequiresConfirmation: retryRequiresConfirmation,
          contextCompactionAvailable: contextCompactionAvailable);

  factory AxWorkRequestStep.fromJson(Map<String, dynamic> json) =>
      AxWorkRequestStep(
        kind: json['kind']?.toString() ?? 'implement',
        status: json['status']?.toString() ?? 'queued',
        workerId: json['workerId']?.toString(),
        workerTypeId: json['workerTypeId']?.toString(),
        workerDisplayName: json['workerDisplayName']?.toString(),
        engineVersion: json['engineVersion']?.toString(),
        profileDefinitionId: json['profileDefinitionId']?.toString(),
        profileReleaseVersion: json['profileReleaseVersion'] as int?,
        providerToolName: json['providerToolName']?.toString(),
        providerToolVersion: json['providerToolVersion']?.toString(),
        model: json['model']?.toString(),
        modelName: json['modelName']?.toString(),
        catalogRevision: json['catalogRevision']?.toString(),
        reasoningEffort: json['reasoningEffort']?.toString(),
        testSummary: json['testSummary']?.toString(),
        startedAt: json['startedAt']?.toString(),
        updatedAt: json['updatedAt']?.toString(),
        elapsedMs: json['elapsedMs'] as int?,
        completedAt: json['completedAt']?.toString(),
        resultText: json['resultText']?.toString(),
        assignmentId: json['assignmentId']?.toString(),
        sessionPolicy: json['sessionPolicy']?.toString(),
        errorCode: json['errorCode']?.toString(),
        errorMessage: json['errorMessage']?.toString(),
        retrySessionStrategy: json['retrySessionStrategy']?.toString(),
        executionPhase: json['executionPhase']?.toString(),
        executionPhaseDetail: json['executionPhaseDetail']?.toString(),
        failureCategory: json['failureCategory']?.toString(),
        failureCategoryMessage: json['failureCategoryMessage']?.toString(),
        retryAllowed:
            (json['retry'] is Map) && (json['retry'] as Map)['allowed'] == true,
        retryRequiresConfirmation: (json['retry'] is Map) &&
            (json['retry'] as Map)['requiresConfirmation'] == true,
        contextCompactionAvailable: json['contextCompactionAvailable'] == true,
      );
}

class AxWorkRequest {
  const AxWorkRequest({
    required this.id,
    this.conversationId,
    this.executionConfig,
    this.attachments = const [],
    this.turns = const [],
    this.workflowRun,
    required this.requestedByName,
    this.requestedByUserId,
    required this.prompt,
    required this.workflowId,
    required this.workflowVersion,
    this.workflowName,
    required this.status,
    required this.createdAt,
    required this.steps,
    this.finalText,
    this.error,
    this.activityHistory = const [],
    this.executionPhase,
    this.replyTo,
  });

  final String id;
  final String? conversationId;
  final List<AxWorkAttachment> attachments;

  /// The message this request replies to (Reply v1).
  final AxReplyReference? replyTo;
  final AxTurnExecutionConfig? executionConfig;
  final List<AxConversationTurn> turns;
  final AxWorkflowRun? workflowRun;
  final String requestedByName;
  final String? requestedByUserId;
  final String prompt;
  final String workflowId;
  final int workflowVersion;
  final String? workflowName;
  final String status;
  final String createdAt;
  final List<AxWorkRequestStep> steps;
  final String? finalText;
  final String? error;
  final List<Map<String, dynamic>> activityHistory;

  /// Cloud-derived phase of the request as a whole. Null for a Cloud that
  /// predates Phase 7.
  final String? executionPhase;

  AxWorkRequest copyWith({
    String? status,
    List<AxWorkRequestStep>? steps,
    List<Map<String, dynamic>>? activityHistory,
  }) =>
      AxWorkRequest(
          id: id,
          conversationId: conversationId,
          executionConfig: executionConfig,
          turns: turns,
          workflowRun: workflowRun,
          requestedByName: requestedByName,
          requestedByUserId: requestedByUserId,
          prompt: prompt,
          attachments: attachments,
          workflowId: workflowId,
          workflowVersion: workflowVersion,
          workflowName: workflowName,
          status: status ?? this.status,
          createdAt: createdAt,
          steps: steps ?? this.steps,
          finalText: finalText,
          error: error,
          activityHistory: activityHistory ?? this.activityHistory,
          replyTo: replyTo,
          // A terminal status forces the terminal phase so a request that
          // finished can never render as still executing.
          executionPhase: status != null && AxExecutionPhase.isTerminal(status)
              ? status
              : executionPhase);

  String? get testSummary {
    for (final step in steps) {
      if (step.kind == 'test' && step.testSummary != null) {
        return step.testSummary;
      }
    }
    return null;
  }

  factory AxWorkRequest.fromJson(Map<String, dynamic> json) {
    final snapshot = json['workflowSnapshot'];
    final snapshotName = snapshot is Map &&
            snapshot['id'] == json['workflowId'] &&
            snapshot['version'] == json['workflowVersion']
        ? snapshot['name']
        : null;
    final steps = (json['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkRequestStep.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList();
    final activityHistory = (json['activities'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    final rawRequestedByUserId =
        (json['requestedByUserId'] ?? json['requested_by_user_id'])?.toString();
    final rawRequestedByName =
        (json['requestedByName'] ?? json['requested_by_name'])
            ?.toString()
            .trim();
    final effectiveRequestedByName = (rawRequestedByName == null ||
            rawRequestedByName.isEmpty ||
            rawRequestedByName == rawRequestedByUserId ||
            rawRequestedByName.startsWith('usr_'))
        ? 'Team member'
        : rawRequestedByName;
    return AxWorkRequest(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversationId']?.toString(),
      workflowRun: json['workflowRun'] is Map
          ? AxWorkflowRun.fromJson(
              Map<String, dynamic>.from(json['workflowRun'] as Map))
          : null,
      turns: List.unmodifiable((json['turns'] as List? ?? const [])
          .whereType<Map>()
          .map((item) =>
              AxConversationTurn.fromJson(Map<String, dynamic>.from(item)))),
      executionConfig: json['executionConfig'] is Map
          ? AxTurnExecutionConfig.fromJson(
              Map<String, dynamic>.from(json['executionConfig'] as Map))
          : null,
      requestedByName: effectiveRequestedByName,
      requestedByUserId: rawRequestedByUserId,
      prompt: json['prompt']?.toString() ?? '',
      attachments: AxWorkAttachment.fromList(json['attachments']),
      workflowId: json['workflowId']?.toString() ?? 'direct',
      workflowVersion: json['workflowVersion'] as int? ?? 1,
      workflowName: (snapshotName ?? json['workflowName'])?.toString(),
      status: json['status']?.toString() ?? 'queued',
      createdAt: json['createdAt']?.toString() ?? '',
      steps: steps,
      finalText: json['finalText']?.toString(),
      error: json['error']?.toString(),
      activityHistory: activityHistory,
      executionPhase: json['executionPhase']?.toString(),
      replyTo: AxReplyReference.fromJson(json['replyTo']),
    );
  }
}

/// Safe public state for a user-submitted issue report.
class AxIssueReport {
  const AxIssueReport({
    required this.id,
    required this.publicReference,
    required this.status,
    required this.diagnosticState,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AxIssueReport.fromJson(Map<String, dynamic> json) => AxIssueReport(
        id: json['id']?.toString() ?? '',
        publicReference: json['publicReference']?.toString() ?? '',
        status: json['status']?.toString() ?? 'open',
        diagnosticState: json['diagnosticState']?.toString() ?? 'partial',
        createdAt: json['createdAt']?.toString() ?? '',
        updatedAt: json['updatedAt']?.toString() ?? '',
      );

  final String id;
  final String publicReference;
  final String status;
  final String diagnosticState;
  final String createdAt;
  final String updatedAt;
}

/// Public metadata used to show which desktop client requested browser approval.
class AxDesktopAuthIntentStatus {
  const AxDesktopAuthIntentStatus({
    required this.status,
    required this.clientName,
    required this.audience,
  });

  final String status;
  final String clientName;
  final String audience;

  /// Resolve the application name from the server-controlled audience. The
  /// display label never trusts a caller-provided clientName.
  String? get applicationName => switch (audience) {
        'syntila.desktop.management' => 'Syntila Workspace',
        'syntila.profile-lab.management' => 'Syntila Profile Lab',
        _ => null,
      };

  bool get canApprove => status == 'pending' && applicationName != null;

  @override
  bool operator ==(Object other) =>
      other is AxDesktopAuthIntentStatus &&
      other.status == status &&
      other.clientName == clientName &&
      other.audience == audience;

  @override
  int get hashCode => Object.hash(status, clientName, audience);

  factory AxDesktopAuthIntentStatus.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final clientName = json['clientName'];
    final audience = json['audience'];
    if (status is! String ||
        !const {'pending', 'approved', 'claimed', 'denied', 'expired'}
            .contains(status) ||
        clientName is! String ||
        audience is! String) {
      throw const FormatException('Sign-in request metadata is malformed');
    }
    return AxDesktopAuthIntentStatus(
      status: status,
      clientName: clientName,
      audience: audience,
    );
  }
}

abstract interface class AxDataSource {
  Future<AxSession> loadSession();
  Future<List<int>?> loadAvatar({required String url}) async => null;
  Future<void> updateDisplayName({required String displayName}) async =>
      throw UnimplementedError('Profile updates are not available');

  /// Sends a one-time code to [newEmail] to start an email change.
  Future<AxEmailChangeStep> requestEmailChangeCode(
          {required String newEmail}) async =>
      throw UnimplementedError('Email changes are not available');

  /// Verifies the new-address code; Cloud then sends a code to the current
  /// address.
  Future<AxEmailChangeStep> verifyNewEmailCode({required String code}) async =>
      throw UnimplementedError('Email changes are not available');

  /// Verifies the current-address code and returns the applied email.
  Future<String> confirmEmailChange({required String code}) async =>
      throw UnimplementedError('Email changes are not available');
  Future<String> uploadAvatar({
    required List<int> thumbnailBytes,
    required List<int> bytes,
    required String mediaType,
  }) async =>
      throw UnimplementedError('Avatar uploads are not available');
  Future<void> logout();
  Future<void> signInWithEmail({
    required String email,
    required String password,
  });
  Future<void> requestSignUpVerificationCode({
    required String email,
    String? name,
  }) async {}
  Future<void> signUpWithEmail({
    required String name,
    required String email,
    required String password,
    String? otp,
  });
  Future<void> requestPasswordReset({required String email});
  Future<void> resetPassword({
    required String token,
    required String password,
  });
  Future<AxSpace> createSpace({
    required String name,
    String? description,
    String? instructions,
  });
  Future<AxSpace> updateSpace({
    required String spaceId,
    String? name,
    String? description,
    String? instructions,
    Map<String, dynamic>? settings,
  });
  Future<void> archiveSpace({required String spaceId});
  Future<void> deleteSpace({required String spaceId});
  Future<List<AxSpaceMember>> loadSpaceMembers({
    required String spaceId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<List<AxSpaceInvitation>> loadSpaceInvitations({
    required String spaceId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<List<AxAuditEntry>> loadSpaceAudit({
    required String spaceId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<void> updateSpaceMemberPermissions(
          {required String spaceId,
          required String userId,
          required AxSpacePermissions permissions}) async =>
      throw UnimplementedError('Member permissions are not available');
  Future<void> inviteSpaceMemberWithPermissions(
          {required String spaceId,
          required String email,
          required String role,
          required AxSpacePermissions permissions}) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<void> changeSpaceMemberRole({
    required String spaceId,
    required String userId,
    required String role,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<void> removeSpaceMember({
    required String spaceId,
    required String userId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<void> expireSpaceInvitation({
    required String spaceId,
    required String invitationId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<List<AxSpaceInvitation>> loadCurrentUserInvitations() async =>
      const [];
  Future<void> acceptSpaceInvitation({
    required String invitationId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<void> declineSpaceInvitation({
    required String invitationId,
  }) async =>
      throw UnimplementedError('Space collaboration is not available');
  Future<AxAccountSecurity> loadAccountSecurity();
  Future<void> revokeAccountSession(String token);
  Future<void> deleteAccount({required String confirmEmail}) async =>
      throw UnimplementedError('Account deletion is not available');
  Future<void> unlinkAccount({required String accountId}) async =>
      throw UnimplementedError('Account unlinking is not available');
  Future<Uri> beginAccountLink(String provider, Uri returnTo);
  Future<void> approveDesktopAuthIntent({
    required String intentId,
  });
  Future<AxDesktopAuthIntentStatus> loadDesktopAuthIntentStatus(
      {required String intentId});
  Future<void> denyDesktopAuthIntent({required String intentId});
  Future<List<AxWorkspace>> loadWorkspaces();
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false});
  Future<AxSpace> loadSpace({required String spaceId});
  Future<List<AxThread>> loadSpaceThreads({
    required String spaceId,
  });
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? idempotencyKey,
  });
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  });
  Future<void> deleteThread({required String threadId});
  Future<String?> clearThreadWorkHistory({required String threadId}) async =>
      throw UnimplementedError('Clear work history is not available');
  Future<void> clearThreadChatHistory({required String threadId}) async =>
      throw UnimplementedError('Clear chat history is not available');
  Future<String> createWorkRequest({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
  }) async =>
      throw UnimplementedError('Work Request execution is not available');

  /// Sends a one-request execution override without changing Space settings.
  /// Implementations that do not support overrides retain the normal request.
  Future<String> createWorkRequestWithSelection({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    String? idempotencyKey,

    /// Reply v1 target `{kind, id}`; ignored by sources without replies.
    Map<String, dynamic>? replyTo,
  }) async =>
      createWorkRequest(
          threadId: threadId,
          workflowId: workflowId,
          prompt: prompt,
          attachments: attachments,
          idempotencyKey: idempotencyKey);

  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async =>
      const [];
  Future<List<String>> validateWorkRequestEligibilityWithSelection({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
  }) async =>
      validateWorkRequestEligibility(
          threadId: threadId, workflowId: workflowId, attachments: attachments);
  Future<AxConversationHistoryPage> loadConversationHistory(
          {required String threadId,
          required String conversationId,
          int afterSequence = 0,
          int? throughSequence,
          int limit = 50}) async =>
      throw UnimplementedError('Conversation history is not available');
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request status is not available');
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? sessionStrategy,
    bool clearAiHistory = false,
    bool compactContext = false,
    bool confirmSideEffects = false,
  }) async =>
      throw UnimplementedError('Work Request retry is not available');
  Future<void> cancelWorkRequest({
    required String workRequestId,
  }) async =>
      throw UnimplementedError('Work Request cancellation is not available');
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async =>
      null;
  Future<AxIssueReport> reportIssue({required String requestId}) async =>
      throw UnimplementedError('Issue reporting is not available');
  Future<AxWorkRequestPage> loadThreadWorkRequestPage({
    required String threadId,
    int limit = 50,
    String? beforeCreatedAt,
    String? beforeId,
    bool activeOnly = false,
  });
  Future<AxDiscussionPage> loadDiscussionPage(
      {required String threadId,
      int limit = 50,
      String? before,
      String? after});
  Future<List<int>> downloadThreadFile(String threadId, String fileId) async =>
      throw UnimplementedError('File downloads are not available');
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String threadId,
    required String text,
    List<String> references = const [],
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,

    /// Reply v1 target `{kind, id}`; the server stores the quote snapshot.
    Map<String, dynamic>? replyTo,
  }) async =>
      throw UnimplementedError('Discussion messages are not available');
  Future<AxDiscussionMessage> loadDiscussionMessage(
      {required String messageId});
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async =>
      throw UnimplementedError('Discussion messages are not available');
  Future<void> deleteDiscussionMessage({
    required String messageId,
  }) async =>
      throw UnimplementedError('Discussion messages are not available');
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async => const [];
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async =>
      const [];
  Future<AxWorkspace> updateWorkspace({
    required String workspaceId,
    required String name,
  });

  /// Sets how many requests run at once on an owned Workspace.
  Future<void> setWorkspaceParallelSlots({
    required String workspaceId,
    required int slots,
  }) async =>
      throw UnimplementedError('Parallel slots are not available');
  Future<List<AxWorkspaceMember>> loadWorkspaceMembers(
      {required String workspaceId});
  Future<List<AxWorkspaceInvitation>> loadWorkspaceInvitations(
      {required String workspaceId});
  Future<List<AxAuditEntry>> loadWorkspaceAudit({required String workspaceId});
  Future<void> inviteWorkspaceMember({
    required String workspaceId,
    required String email,
    required String role,
  });
  Future<void> changeWorkspaceMemberRole({
    required String workspaceId,
    required String userId,
    required String role,
  });
  Future<void> setWorkspaceMemberStatus({
    required String workspaceId,
    required String userId,
    required String status,
  });
  Future<void> expireWorkspaceInvitation({
    required String workspaceId,
    required String invitationId,
  });

  /// Application bootstrap/recovery state, never a navigation loader.
  /// Space details and Threads are separate focused resource queries.
  Future<AxSnapshot> loadBootstrapState({String? spaceId, String? workspaceId});
  Future<void> controlRun(String runId, String command);
  Future<void> respondToRunPrompt(String runId, String response);
  Future<void> revokeWorkspace({required String workspaceId});
}
