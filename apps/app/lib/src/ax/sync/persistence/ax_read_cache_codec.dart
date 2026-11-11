import '../ax_sync_engine.dart';
import '../ax_discussion_cache.dart';
import '../ax_work_history.dart';
import '../ax_space_details.dart';
import '../ax_space_threads.dart';
import '../ax_session_catalogs.dart';
import '../../ax_data.dart';
import '../../ax_models.dart';
import '../ax_owned_workspaces.dart';

/// Explicit safe DTO allowlist, not a serializer for arbitrary query state.
class AxReadCacheCodec {
  static bool serverId(String id) =>
      id.isNotEmpty && !id.startsWith('local-') && !id.startsWith('temp-');

  // `workstream-*` was used by a retired client-side work model. It is not a
  // valid server thread identifier, so persisted records with that prefix
  // must not be restored into the active sync graph.
  static bool threadId(String id) =>
      serverId(id) && !id.startsWith('workstream-');
  Map<String, dynamic> space(AxSpace value) => {
        'id': value.id,
        'name': value.name,
        'branch': value.branch,
        'lastActivity': value.lastActivity,
        'description': value.description,
        'instructions': value.instructions,
        'archived': value.archived,
        'role': value.role,
        'settings': {
          'instructions': value.instructions,
          'archived': value.archived,
          if (value.settings['threadOrder'] is List)
            'threadOrder': (value.settings['threadOrder'] as List)
                .whereType<String>()
                .toList()
        },
      };
  Map<String, dynamic> thread(AxThread value) => {
        'id': value.id,
        'spaceId': value.spaceId,
        'title': value.title,
        'lead': value.lead,
        'status': value.status,
        'brief': value.brief,
        'briefAuthorName': value.briefAuthorName,
        'primaryWorkspace': value.primaryWorkspace,
        'queueStatus': value.queueStatus,
        'canConfigureWork': value.canConfigureWork,
        'canExecuteWork': value.canExecuteWork,
        'archived': value.archived,
        'workConfig': _workConfig(value.workConfig),
      };
  Map<String, dynamic> worker(AxWorker value) => {
        'id': value.id,
        'workspaceId': value.workspaceId,
        'workspaceName': value.workspaceName,
        'workerTypeId': value.workerTypeId,
        'displayName': value.displayName,
        'description': value.description,
        'catalogLifecycleState': value.catalogLifecycleState,
        'catalogVisibilityState': value.catalogVisibilityState,
        'status': value.status,
        'readinessState': value.readinessState,
        'activationState': value.activationState,
        'attentionReasonCode': value.attentionReasonCode,
        'localConcurrencyLimit': value.localConcurrencyLimit,
        'engineVersion': value.engineVersion,
        'profileDefinitionId': value.profileDefinitionId,
        'profileReleaseVersion': value.profileReleaseVersion,
        'providerToolName': value.providerToolName,
        'providerToolVersion': value.providerToolVersion,
        if (value.shared) 'shared': true,
        if (value.executionOptions != null)
          'executionOptions': value.executionOptions!.toJson(),
      };
  Map<String, dynamic> workspace(AxWorkspace value) => {
        'id': value.id,
        'name': value.name,
        'slug': value.slug,
        'status': value.status,
        'role': value.role,
        'hasRuntimeIdentity': value.hasRuntimeIdentity,
        'platform': value.platform,
        'architecture': value.architecture,
        'hostname': value.hostname,
        'appVersion': value.appVersion,
        'activeTransport': value.activeTransport,
        'connectionMode': value.connectionMode,
        'runtimeCapabilitiesJson': value.runtimeCapabilities,
        'factsUpdatedAt': value.factsUpdatedAt,
        'updateChannel': value.updateChannel,
        'lastSeen': value.lastSeen,
        'workerCount': value.workerCount,
        'activeTaskCount': value.activeTaskCount,
      };
  Map<String, dynamic> message(AxDiscussionMessage value) => {
        'id': value.id,
        'threadId': value.threadId,
        'authorUserId': value.authorUserId,
        'authorName': value.authorName,
        'body': value.body,
        'references': value.references,
        'attachments': value.attachments,
        'editedAt': value.editedAt,
        'createdAt': value.createdAt,
        'kind': value.kind,
        'eventType': value.eventType,
        'workRequestId': value.workRequestId,
        'workerDisplayName': value.workerDisplayName,
        if (value.replyTo != null) 'replyTo': value.replyTo!.toJson(),
      };
  Map<String, dynamic> work(AxWorkRequest value) => {
        'conversationId': value.conversationId,
        'executionConfig': value.executionConfig?.toJson(),
        'workflowRun': value.workflowRun?.toJson(),
        'turns': value.turns.map((turn) => turn.toJson()).toList(),
        'id': value.id,
        'requestedByName': value.requestedByName,
        'requestedByUserId': value.requestedByUserId,
        'prompt': value.prompt,
        'attachments': value.attachments.map((file) => file.toJson()).toList(),
        'workflowId': value.workflowId,
        'workflowVersion': value.workflowVersion,
        'workflowName': value.workflowName,
        'isPhased': value.isPhased,
        'status': value.status,
        'createdAt': value.createdAt,
        'finalText': value.finalText,
        'error': value.error,
        'steps': value.steps.map(step).toList(),
        if (value.replyTo != null) 'replyTo': value.replyTo!.toJson(),
      };
  Map<String, dynamic> step(AxWorkRequestStep value) => {
        'kind': value.kind,
        'status': value.status,
        'workerId': value.workerId,
        'workerTypeId': value.workerTypeId,
        'workerDisplayName': value.workerDisplayName,
        'engineVersion': value.engineVersion,
        'profileDefinitionId': value.profileDefinitionId,
        'profileReleaseVersion': value.profileReleaseVersion,
        'providerToolName': value.providerToolName,
        'providerToolVersion': value.providerToolVersion,
        'model': value.model,
        'reasoningEffort': value.reasoningEffort,
        if (value.modelName != null) 'modelName': value.modelName,
        if (value.catalogRevision != null)
          'catalogRevision': value.catalogRevision,
        'testSummary': value.testSummary,
        'startedAt': value.startedAt,
        'updatedAt': value.updatedAt,
        'elapsedMs': value.elapsedMs,
        'completedAt': value.completedAt,
        'resultText': value.resultText,
        'assignmentId': value.assignmentId,
        'sessionPolicy': value.sessionPolicy,
        'errorCode': value.errorCode,
        'errorMessage': value.errorMessage,
        'retrySessionStrategy': value.retrySessionStrategy,
      };
  Map<String, dynamic> _workConfig(Map<String, dynamic> value) => {
        if (value['defaultWorkflowId'] is String)
          'defaultWorkflowId': value['defaultWorkflowId'],
        if (value['threadInstructions'] is String)
          'threadInstructions': value['threadInstructions'],
        if (value['bindings'] is Map)
          'bindings': {
            for (final item in (value['bindings'] as Map).entries)
              if (item.key is String && item.value is Map)
                item.key as String: {
                  for (final field in ['additionalInstructions'])
                    if (item.value[field] is String) field: item.value[field],
                },
          },
      };
  Map<String, dynamic> workflow(AxBuiltinWorkflow value) => {
        'executionPolicy': {
          'userSelectsWorker': value.executionPolicy.userSelectsWorker,
          'userSelectsModel': value.executionPolicy.userSelectsModel,
          'userSelectsEffort': value.executionPolicy.userSelectsEffort,
          'multiStep': value.executionPolicy.multiStep,
          'multiWorker': value.executionPolicy.multiWorker,
          'automaticContinuation': value.executionPolicy.automaticContinuation,
          'requiresApprovalBetweenSteps':
              value.executionPolicy.requiresApprovalBetweenSteps,
        },
        'composerBindingId': value.composerBindingId,
        'id': value.id,
        'version': value.version,
        'name': value.name,
        'description': value.description,
        'steps': [
          for (final step in value.steps)
            {'kind': step.kind, 'order': step.order}
        ],
      };
  Map<String, dynamic>? encode(AxCacheRecord record) {
    final key = record.key.parts;
    final value = record.data;
    Object? data;
    if (key.length == 1 && (key.first == 'spaces') && value is List<AxSpace>) {
      data = value.where((v) => serverId(v.id)).map(space).toList();
    } else if (key.length == 2 &&
        (key.first == 'space') &&
        value is AxSpace &&
        value.id == key[1] &&
        serverId(value.id)) {
      data = space(value);
    } else if (key.length == 3 &&
        (key.first == 'space') &&
        (key.last == 'threads') &&
        value is List<AxThread>) {
      data = value
          .where((v) => threadId(v.id) && v.spaceId == key[1])
          .map(thread)
          .toList();
    } else if (key.length == 1 &&
        key.first == 'workers' &&
        value is List<AxWorker>) {
      data = value.map(worker).toList();
    } else if (key.length == 1 &&
        key.first == 'workspaces' &&
        value is List<AxWorkspace>) {
      data = value.map(workspace).toList();
    } else if (key.length == 1 &&
        key.first == 'workflow-catalog' &&
        value is List<AxBuiltinWorkflow>) {
      data = value.map(workflow).toList();
    } else if (key.length == 3 &&
        (key.first == 'thread') &&
        key.last == 'discussion' &&
        value is AxDiscussionHistory) {
      final safe = value.messages
          .where((m) =>
              serverId(m.id) &&
              m.threadId == key[1] &&
              !value.deletedMessageIds.contains(m.id))
          .toList();
      final recent =
          safe.skip(safe.length > 50 ? safe.length - 50 : 0).toList();
      data = {
        'messages': recent.map(message).toList(),
        'deletedMessageIds':
            value.deletedMessageIds.where(serverId).toList(growable: false),
        'olderCursor': safe.length > 50 ? null : value.olderCursor,
        'newestCursor': value.newestCursor,
        'initialLoaded': value.initialLoaded && safe.length <= 50
      };
    } else if (key.length == 3 &&
        (key.first == 'thread') &&
        key.last == 'work-requests' &&
        value is AxWorkHistory) {
      if (!threadId(key[1])) return null;
      final safe = value.requests.where((r) => serverId(r.id)).toList();
      final recent =
          safe.skip(safe.length > 50 ? safe.length - 50 : 0).toList();
      final cursor = safe.length > 50
          ? AxWorkRequestCursor(
              createdAt: recent.first.createdAt, id: recent.first.id)
          : value.olderCursor;
      data = {
        'requests': recent.map(work).toList(),
        'olderCursor': cursor == null
            ? null
            : {'createdAt': cursor.createdAt, 'id': cursor.id},
        'initialLoaded': value.initialLoaded,
        'newestPageRequest': value.newestPageRequest == null ||
                !serverId(value.newestPageRequest!.id)
            ? null
            : work(value.newestPageRequest!)
      };
    } else {
      return null;
    }
    return {
      'version': 1,
      'key': key,
      'data': data,
      'fetched': record.fetched?.toUtc().toIso8601String(),
      'accessed': record.accessed?.toUtc().toIso8601String()
    };
  }

  bool restore(Map<String, dynamic> record, AxSyncEngine engine,
      AxDataSource source, String userId) {
    if (record['version'] != 1) return false;
    final key = AxQueryKey((record['key'] as List).cast<String>());
    final parts = key.parts;
    if (parts.length > 1 && !serverId(parts[1])) return false;
    if (parts.length > 1 && parts.first == 'thread' && !threadId(parts[1])) {
      return true;
    }
    final fetched = record['fetched'] == null
        ? null
        : DateTime.parse(record['fetched'] as String);
    final accessed = record['accessed'] == null
        ? null
        : DateTime.parse(record['accessed'] as String);
    Map<String, dynamic> map(dynamic value) =>
        Map<String, dynamic>.from(value as Map);
    List<Map<String, dynamic>> list(dynamic value) =>
        (value as List).map(map).toList();
    bool seed<T>(AxQuery<T> query, T value) =>
        engine.seed(query, value, fetched: fetched, accessed: accessed);
    final data = record['data'];
    if (parts.length == 1 && (parts.first == 'spaces')) {
      final values = list(data)
          .map(AxSpace.fromJson)
          .where((v) => serverId(v.id))
          .map((v) => AxSpace.fromJson(space(v)))
          .toList();
      return seed<List<AxSpace>>(
          AxQuery<List<AxSpace>>(
              key: AxQueryKey(['spaces']),
              load: () async => (await source.loadSpaces())
                  .map((s) => s.copyWith(threads: const []))
                  .toList()),
          List.unmodifiable(values));
    }
    if (parts.length == 2 && (parts.first == 'space')) {
      final value = AxSpace.fromJson(map(data));
      if (value.id != parts[1]) return false;
      return seed<AxSpace>(
          AxSpaceDetails(source, engine: engine).query(parts[1]),
          AxSpace.fromJson(space(value)));
    }
    if (parts.length == 3 &&
        (parts.first == 'space') &&
        (parts.last == 'threads')) {
      final values = list(data)
          .map(AxThread.fromJson)
          .where((v) => threadId(v.id) && v.spaceId == parts[1])
          .map((v) => AxThread.fromJson(thread(v)))
          .toList();
      return seed<List<AxThread>>(
          AxSpaceThreads(source, engine: engine).query(parts[1]),
          List.unmodifiable(values));
    }
    final catalogs = AxSessionCatalogs(source, engine: engine);
    if (parts.length == 1 && parts.first == 'workers') {
      return seed<List<AxWorker>>(catalogs.workers,
          List.unmodifiable(list(data).map(AxWorker.fromJson)));
    }
    if (parts.length == 1 && parts.first == 'workflow-catalog') {
      return seed<List<AxBuiltinWorkflow>>(
          catalogs.workflows,
          List.unmodifiable(list(data).map((v) => AxBuiltinWorkflow.fromJson(
              workflow(AxBuiltinWorkflow.fromJson(v))))));
    }
    if (parts.length == 1 && parts.first == 'workspaces') {
      return seed<List<AxWorkspace>>(ownedWorkspacesQuery(source),
          List.unmodifiable(list(data).map(AxWorkspace.fromJson)));
    }
    if (parts.length == 3 &&
        (parts.first == 'thread') &&
        parts.last == 'discussion') {
      final value = map(data);
      final messages = list(value['messages'])
          .map((m) => AxDiscussionMessage.fromJson(m, currentUserId: userId))
          .where((m) => serverId(m.id) && m.threadId == parts[1]);
      return seed<AxDiscussionHistory>(
          AxDiscussionCache(source, engine: engine, registerRetention: false)
              .query(parts[1]),
          AxDiscussionHistory(
              messages: messages,
              deletedMessageIds:
                  (value['deletedMessageIds'] as List? ?? const [])
                      .whereType<String>()
                      .where(serverId),
              olderCursor: value['olderCursor'] as String?,
              newestCursor: value['newestCursor'] as String?,
              initialLoaded: value['initialLoaded'] == true));
    }
    if (parts.length == 3 &&
        (parts.first == 'thread') &&
        parts.last == 'work-requests') {
      final value = map(data);
      final requests = list(value['requests'])
          .map(AxWorkRequest.fromJson)
          .where((r) => serverId(r.id))
          .toList();
      final cursor =
          value['olderCursor'] == null ? null : map(value['olderCursor']);
      final newest = value['newestPageRequest'] == null
          ? null
          : AxWorkRequest.fromJson(map(value['newestPageRequest']));
      return seed<AxWorkHistory>(
          AxWorkHistoryCache(source, engine: engine, registerRetention: false)
              .query(parts[1]),
          AxWorkHistory(
              requests: requests,
              initialLoaded: value['initialLoaded'] == true,
              olderCursor: cursor == null
                  ? null
                  : AxWorkRequestCursor(
                      createdAt: cursor['createdAt'] as String,
                      id: cursor['id'] as String),
              newestPageRequest: newest,
              confirmedIds: requests.map((r) => r.id)));
    }
    return false;
  }
}
