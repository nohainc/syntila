part of '../cloud_connection.dart';

extension _WorkspaceAssignmentHandlers on WorkspaceCloudConnection {
  static const _terminalDeliveryTimeout = Duration(seconds: 10);
  static const _cancellationTimeout = Duration(seconds: 5);
  static const _defaultQueueWaitTimeout = Duration(minutes: 2);

  Future<void> _handleAssignmentStart(Map<String, dynamic> message) async {
    final socket = _transport;
    final payload = message['payload'];
    final requiredFields = [
      'executionWorkspaceId',
      'workspaceRuntimeId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'assignmentId',
      'idempotencyKey',
    ];
    if (socket == null) return;
    if (payload is! Map<String, dynamic> ||
        requiredFields.any((field) => message[field] is! String)) {
      if (_hasAssignmentCorrelation(message)) {
        await _sendAssignmentError(
          socket,
          message,
          'execution_failed',
          retryable: false,
          diagnostic: _assignmentDiagnostic(
            stage: 'assignment_envelope_validation',
            detail:
                'Assignment envelope is missing a required correlation field',
          ),
        );
      }
      return;
    }

    if (!authorizedWorkspaceIds.contains(message['executionWorkspaceId']) ||
        message['workspaceRuntimeId'] != workspaceRuntimeId) {
      await _sendAssignmentError(
        socket,
        message,
        'worker_not_ready',
        retryable: false,
        diagnostic: _assignmentDiagnostic(
          stage: 'assignment_admission',
          detail: 'Assignment targeted a Workspace that is not authorized',
        ),
      );
      return;
    }

    final assignmentPayload = _flattenAssignmentPayload(payload);
    final payloadError = _validateAssignmentPayload(assignmentPayload);
    if (payloadError != null) {
      await _sendAssignmentError(
        socket,
        message,
        'execution_failed',
        retryable: false,
        diagnostic: _assignmentDiagnostic(
          stage: 'assignment_payload_validation',
          detail: payloadError,
        ),
      );
      return;
    }

    final context = WorkspaceAssignmentContext(
      workspaceId: message['executionWorkspaceId'] as String,
      workspaceRuntimeId: message['workspaceRuntimeId'] as String,
      workerId: message['workerId'] as String,
      runId: message['runId'] as String,
      taskId: message['taskId'] as String,
      attemptId: message['attemptId'] as String,
      assignmentId: message['assignmentId'] as String,
      idempotencyKey: message['idempotencyKey'] as String,
      payload: Map<String, Object?>.from(assignmentPayload),
    );
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.validated',
      stage: 'validation',
    );
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.received',
      stage: 'transport',
    );
    final correlation = _assignmentCorrelation(message);
    if (!acceptingNewWork) {
      await recordAssignmentDiagnostic(
        context,
        event: 'assignment.rejected',
        stage: 'admission',
        severity: 'warning',
        errorCode: 'worker_not_ready',
        retryable: true,
        contextData: {
          'status': _draining ? 'workspace_draining' : 'workspace_paused',
        },
      );
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {
          'accepted': false,
          'reason': _draining ? 'workspace_draining' : 'workspace_paused'
        },
      )));
      return;
    }
    final previous = await assignmentJournal?.find(context.assignmentId);
    if (previous != null) {
      if (previous.status == AssignmentStatus.completed &&
          previous.result != null) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {'accepted': true, 'estimatedStartMs': 0},
        )));
        await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
          'assignment.result',
          correlation,
          {
            'status': 'completed',
            'summary': previous.result!['summary'] ??
                'Assignment replayed from the local journal',
            'output': previous.result!['output'],
            'artifactIds': previous.result!['artifactIds'] ?? const [],
            if (previous.result!['evidence'] is Map)
              'evidence': previous.result!['evidence'],
          },
        )));
      } else if (previous.status == AssignmentStatus.failed) {
        await _sendRecoveredTerminal(socket, previous, correlation);
      } else if (previous.status == AssignmentStatus.cancelled) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.cancel.ack',
          correlation,
          {'cancelled': true, 'alreadyTerminated': true},
        )));
      } else if (_activeAssignments.contains(context.assignmentId) &&
          const {
            AssignmentStatus.received,
            AssignmentStatus.accepted,
            AssignmentStatus.running,
          }.contains(previous.status)) {
        // A duplicate command for an assignment this process is already
        // running means Cloud missed our earlier acknowledgements. Re-assert
        // them; rejecting would make Cloud fail work that is in progress.
        _reassertLiveAssignment(correlation, previous.status);
      } else {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {
            'accepted': false,
            'reason': 'assignment already exists in local journal',
          },
        )));
      }
      return;
    }
    if (_cancelledBeforeStart.remove(context.assignmentId)) {
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.cancelled,
        context: context,
        result: const {'reason': 'Cancelled before Worker launch'},
      );
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.cancelled',
        correlation,
        {
          'status': 'cancelled',
          'reason': 'Cancelled before Worker launch',
        },
      )));
      return;
    }
    await _recordAssignment(context.assignmentId, AssignmentStatus.received,
        context: context);

    if (assignmentHandler == null) {
      await recordAssignmentDiagnostic(
        context,
        event: 'assignment.rejected',
        stage: 'admission',
        severity: 'error',
        errorCode: 'worker_not_ready',
        retryable: false,
        contextData: const {'status': 'no_assignment_handler'},
      );
      await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {'accepted': false, 'reason': 'no assignment handler configured'},
      )));
      return;
    }

    _activeAssignments.add(context.assignmentId);
    _notifyStateChanged();
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.accepted',
      stage: 'accepted',
    );
    await _recordAssignment(context.assignmentId, AssignmentStatus.accepted,
        context: context);
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.queued',
      stage: 'admission',
    );
    if (_cancelledBeforeStart.remove(context.assignmentId)) {
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.cancelled,
        context: context,
        result: const {'reason': 'Cancelled before Worker launch'},
      );
      _activeAssignments.remove(context.assignmentId);
      traceRecorder.finish(context.assignmentId);
      _notifyStateChanged();
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.cancelled',
        correlation,
        {
          'status': 'cancelled',
          'reason': 'Cancelled before Worker launch',
        },
      )));
      return;
    }
    final serviceTrace = _serviceTracePayload(context.assignmentId);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.ack',
      correlation,
      {
        'accepted': true,
        'estimatedStartMs': 0,
        if (serviceTrace.isNotEmpty) 'serviceTrace': serviceTrace,
      },
    )));
    // T6: admission acknowledgement written to the transport.
    traceAssignmentStage(context, 'service_accepted');
    prefetchStartPermit(context);
    await recordAssignmentDiagnostic(
      context,
      event: 'assignment.launching',
      stage: 'engine_startup',
    );
    WorkspaceAssignmentResult result;
    try {
      final timeoutMs = context.payload['timeoutMs'];
      final queueWaitTimeoutMs = context.payload['queueWaitTimeoutMs'];
      final timeout = Duration(milliseconds: timeoutMs as int);
      final queueWaitTimeout = Duration(
        milliseconds: queueWaitTimeoutMs is int
            ? queueWaitTimeoutMs
            : _defaultQueueWaitTimeout.inMilliseconds,
      );
      // The outer watchdog covers both local queue admission and provider
      // execution. The supervisor receives the two deadlines separately, so
      // queue wait cannot consume the provider execution budget.
      result =
          await assignmentHandler!(context).timeout(timeout + queueWaitTimeout);
    } catch (error) {
      try {
        final normalizedError = normalizeAssignmentExecutionFailure(
          error is TimeoutException ? await _deadlineFailure(context) : error,
        );
        final errorCode =
            canonicalWorkerExecutionErrorCode(normalizedError.code);
        final errorMessage = executionErrorMessage(errorCode);
        final diagnostic = SafeProviderDiagnostics.safeFailureDetail(
          normalizedError.localDiagnostic,
        );
        final processExitCode =
            _processExitCode(normalizedError.localDiagnostic);
        if (errorCode == 'cancelled') {
          final cancelledPayload = <String, Object?>{
            'status': 'cancelled',
            'executionId': context.executionId,
            'reason': 'Assignment cancelled before terminal completion.',
          };
          await _recordAssignment(
            context.assignmentId,
            AssignmentStatus.cancelled,
            context: context,
            result: cancelledPayload,
          );
          await recordAssignmentDiagnostic(
            context,
            event: 'assignment.cancelled',
            stage: 'terminal_recorded',
            contextData: {
              'transport': 'assignment_cancelled',
              if (diagnostic != null) 'diagnostic': diagnostic,
            },
          );
          await _sendTerminal(
            socket,
            context,
            'assignment.cancelled',
            correlation,
            cancelledPayload,
          );
          return;
        }
        final errorPayload = <String, Object?>{
          'status': 'failed',
          'executionId': context.executionId,
          'errorCode': errorCode,
          if (processExitCode != null) 'processExitCode': processExitCode,
          'error': {
            'code': errorCode,
            'message': errorMessage,
            'retryable': normalizedError.retryable,
            if (diagnostic != null)
              'details': {
                'diagnostic': diagnostic,
                if (processExitCode != null) 'processExitCode': processExitCode,
              },
          },
        };
        final details = normalizedError.providerFailure;
        final canEncrypt =
            details != null && assignmentJournal?.providerFailureCipher != null;
        final omittedFields = <String>{
          if (details != null)
            for (final field in [
              'nativeErrorCode',
              'providerErrorText',
              'failedRunResponse'
            ])
              if (details[field] is String) field,
          if (details?['omittedFields'] is List)
            ...(details!['omittedFields'] as List).whereType<String>(),
        };
        final omission = details == null
            ? null
            : <String, Object?>{
                'schemaVersion': 1,
                'source': details['source'],
                'omitted': true,
                'omittedFields': omittedFields.toList(),
              };
        final journalResult = <String, Object?>{
          ...errorPayload,
          'error': errorMessage,
          'errorCode': errorCode,
          if (diagnostic != null) 'localDiagnostic': diagnostic,
          if (canEncrypt) 'providerFailure': details,
          if (details != null && !canEncrypt)
            'providerFailureOmission': omission,
        };
        var detailsStored = false;
        try {
          await _recordAssignment(context.assignmentId, AssignmentStatus.failed,
              context: context, result: journalResult);
          detailsStored = canEncrypt;
        } on Object {
          if (!canEncrypt) rethrow;
          journalResult.remove('providerFailure');
          journalResult['providerFailureOmission'] = omission;
          await _recordAssignment(context.assignmentId, AssignmentStatus.failed,
              context: context, result: journalResult);
        }
        if (detailsStored && _cloudAcceptsProviderFailure) {
          errorPayload['providerFailure'] = details;
        } else if (details != null && _cloudAcceptsProviderFailure) {
          errorPayload['providerFailure'] = omission;
        }
        await recordAssignmentDiagnostic(
          context,
          event: 'assignment.failed',
          stage: assignmentDiagnosticStage(normalizedError.localDiagnostic) ??
              'terminal_recorded',
          severity: 'error',
          errorCode: errorCode,
          retryable: normalizedError.retryable,
          contextData: {
            'transport': 'assignment_error',
            if (diagnostic != null) 'diagnostic': diagnostic,
            if (processExitCode != null) 'processExitCode': processExitCode,
            'exceptionType': error.runtimeType.toString(),
          },
        );
        await _sendTerminal(
          socket,
          context,
          'assignment.error',
          correlation,
          errorPayload,
        );
      } finally {
        _activeAssignments.remove(context.assignmentId);
        traceRecorder.finish(context.assignmentId);
        _notifyStateChanged();
      }
      return;
    }
    final resultPayload = <String, Object?>{
      'status': 'completed',
      'executionId': context.executionId,
      'summary': result.summary,
      'output': result.output,
      'artifactIds': result.artifactIds,
      if (result.evidence != null)
        'evidence': {
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          ...result.evidence!,
        },
    };
    try {
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.completed,
        context: context,
        result: resultPayload,
      );
      await recordAssignmentDiagnostic(
        context,
        event: 'assignment.completed',
        stage: 'terminal_recorded',
      );
      await _sendTerminal(
        socket,
        context,
        'assignment.result',
        correlation,
        resultPayload,
      );
    } finally {
      _activeAssignments.remove(context.assignmentId);
      traceRecorder.finish(context.assignmentId);
      _notifyStateChanged();
    }
  }

  Future<AssignmentExecutionFailure> _deadlineFailure(
    WorkspaceAssignmentContext context,
  ) async {
    // The handler may be waiting in profile resolution or process startup,
    // before the Engine has registered an active process. Request cleanup
    // without waiting indefinitely; the terminal journal record below is
    // authoritative even if cancellation races the deadline.
    final cancel = assignmentCancellationHandler;
    if (cancel != null) {
      try {
        await cancel(context.assignmentId, 'Assignment deadline exceeded')
            .timeout(_cancellationTimeout);
      } on Object {
        // Terminal reconciliation must proceed even when cleanup fails.
      }
    }
    return AssignmentExecutionFailure(
      code: 'deadline_exceeded',
      message: 'Assignment execution exceeded its deadline.',
      retryable: true,
      localDiagnostic: jsonEncode({
        'stage': 'service_execution_deadline',
        'assignmentId': context.assignmentId,
        'executionId': context.executionId,
        'attemptId': context.attemptId,
      }),
    );
  }

  Future<void> _sendTerminal(
    WorkspaceTransport socket,
    WorkspaceAssignmentContext context,
    String type,
    Map<String, Object?> correlation,
    Map<String, Object?> payload,
  ) async {
    try {
      // The handler captured its transport when the assignment started. If the
      // Service reconnected while the Worker ran, that transport is closed and
      // its sends are dropped without an error, so a result "sent" on it never
      // reaches Cloud. Treat a replaced transport as a failed delivery and let
      // the journal-driven redelivery send the recorded outcome on the live
      // session.
      if (!identical(_transport, socket)) {
        throw StateError('Workspace transport was replaced during execution');
      }
      await socket
          .sendAndWait(
              jsonEncode(_assignmentEnvelope(type, correlation, payload)))
          .timeout(_terminalDeliveryTimeout);
    } on Object catch (error) {
      // The terminal record was written before this call. Cloud sync retries
      // it from the journal, so a dead transport cannot keep this assignment
      // in the active set or turn a completed result into an unknown outcome.
      await recordAssignmentDiagnostic(
        context,
        event: 'assignment.terminal_delivery_failed',
        stage: 'terminal_delivery',
        severity: 'warning',
        errorCode: 'terminal_delivery_failed',
        retryable: true,
        contextData: {
          'messageType': type,
          'errorType': error.runtimeType.toString(),
        },
      );
      _scheduleTerminalRedelivery();
    }
  }

  Future<void> _handleAssignmentCancel(Map<String, dynamic> message) async {
    final socket = _transport;
    if (socket == null ||
        message['assignmentId'] is! String ||
        message['executionWorkspaceId'] != workspaceId ||
        message['workspaceRuntimeId'] != workspaceRuntimeId) {
      return;
    }
    final assignmentId = message['assignmentId'] as String;
    final payload = message['payload'];
    final reason = payload is Map && payload['reason'] is String
        ? payload['reason'] as String
        : 'Cloud requested cancellation';
    var cancelled = false;
    if (_activeAssignments.contains(assignmentId) &&
        assignmentCancellationHandler != null) {
      cancelled = await assignmentCancellationHandler!(assignmentId, reason);
    }
    if (!cancelled) {
      final previous = await assignmentJournal?.find(assignmentId);
      final terminal = previous != null &&
          {
            AssignmentStatus.completed,
            AssignmentStatus.failed,
            AssignmentStatus.cancelled,
            AssignmentStatus.reconciled,
          }.contains(previous.status);
      if (!terminal) {
        if (!_activeAssignments.contains(assignmentId)) {
          // Durable cancel tombstone: the command has not been admitted here
          // (it may still be in flight, queued behind a slow transport, or
          // delivered again after a Service restart). Persisting the
          // cancellation guarantees a later `assignment.start` for this
          // assignment replays the cancellation instead of launching, and
          // that the outcome is re-delivered until Cloud acknowledges it.
          await _recordAssignment(
            assignmentId,
            AssignmentStatus.cancelled,
            correlation: _assignmentCorrelation(message),
            result: {'reason': reason},
          );
        }
        if (_cancelledBeforeStart.length >= 1024) {
          _cancelledBeforeStart.remove(_cancelledBeforeStart.first);
        }
        _cancelledBeforeStart.add(assignmentId);
        cancelled = true;
      }
    }
    if (cancelled &&
        _activeAssignments.contains(assignmentId) &&
        assignmentCancellationHandler != null) {
      // Close the narrow interval between adding the assignment to the active
      // set and the Worker executor reserving its process slot.
      if (await assignmentCancellationHandler!(assignmentId, reason)) {
        _cancelledBeforeStart.remove(assignmentId);
      }
    }
    final alreadyTerminated = !_activeAssignments.contains(assignmentId);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.cancel.ack',
      _assignmentCorrelation(message),
      {
        'cancelled': cancelled,
        'alreadyTerminated': alreadyTerminated,
      },
    )));
  }

  String? _validateAssignmentPayload(Object? rawPayload) {
    if (rawPayload is! Map<String, dynamic>) {
      return 'Assignment payload must be an object';
    }
    final sessionPolicy = rawPayload['sessionPolicy'] ?? 'stateless';
    final sessionKey = rawPayload['sessionKey'];
    if (!const {'stateless', 'durable_session'}.contains(sessionPolicy) ||
        (sessionKey != null &&
            (sessionKey is! String ||
                sessionKey.trim().isEmpty ||
                sessionKey.length > 256)) ||
        (sessionPolicy == 'stateless' && sessionKey != null) ||
        (sessionPolicy == 'durable_session' && sessionKey == null)) {
      return 'Assignment session policy is invalid';
    }
    final statelessContext = rawPayload['statelessContext'];
    if (statelessContext != null) {
      if (sessionPolicy != 'stateless' || statelessContext is! Map) {
        return 'Invalid stateless Conversation context';
      }
      try {
        ConversationBootstrap.fromJson(
            Map<String, Object?>.from(statelessContext));
      } on FormatException {
        return 'Invalid stateless Conversation context';
      }
    }
    final sessionContext = rawPayload['workerSession'];
    if (sessionContext != null) {
      try {
        if (sessionContext is! Map || sessionPolicy != 'durable_session') {
          return 'Assignment Worker Session is invalid';
        }
        final context = WorkerSessionContext.fromJson(
          Map<String, Object?>.from(sessionContext),
        );
        if (context.workerId != rawPayload['workerId']) {
          return 'Assignment Worker Session belongs to another Worker';
        }
      } on FormatException {
        return 'Assignment Worker Session is invalid';
      }
    }
    if (rawPayload['snapshot'] == null &&
        rawPayload['objective'] == null &&
        rawPayload['role'] == null) {
      for (final field in [
        'assignmentId',
        'executionWorkspaceId',
        'spaceId',
        'runId',
        'taskId',
        'attemptId',
        'requestedByUserId',
        'workspaceRuntimeId',
        'workerId',
        'engineVersion',
        'profileDefinitionId',
        'profileReleaseVersion',
        'config',
        'permissions',
        'contextRefs',
        'timeoutMs',
        'idempotencyKey',
      ]) {
        if (!rawPayload.containsKey(field)) {
          return 'Assignment field $field is required';
        }
      }
      if (rawPayload['config'] is! Map ||
          rawPayload['permissions'] is! List ||
          rawPayload['contextRefs'] is! List ||
          rawPayload['timeoutMs'] is! int ||
          (rawPayload['timeoutMs'] as int) < 1000 ||
          (rawPayload['timeoutMs'] as int) > 2147483647) {
        return 'Assignment snapshot fields are invalid';
      }
      final queueWaitTimeoutMs = rawPayload['queueWaitTimeoutMs'];
      final maxConcurrentAssignments = rawPayload['maxConcurrentAssignments'];
      if (queueWaitTimeoutMs != null &&
          (queueWaitTimeoutMs is! int ||
              queueWaitTimeoutMs < 1000 ||
              queueWaitTimeoutMs > 2147483647)) {
        return 'Assignment queueWaitTimeoutMs is invalid';
      }
      if (maxConcurrentAssignments != null &&
          (maxConcurrentAssignments is! int ||
              maxConcurrentAssignments < 1 ||
              maxConcurrentAssignments > 1024)) {
        return 'Assignment maxConcurrentAssignments is invalid';
      }
      return null;
    }
    for (final field in [
      'objective',
      'role',
      'workerId',
      'engineVersion',
      'profileDefinitionId',
    ]) {
      if (rawPayload[field] is! String ||
          (rawPayload[field] as String).trim().isEmpty) {
        return 'Assignment field $field is required';
      }
    }
    final profileReleaseVersion = rawPayload['profileReleaseVersion'];
    if (profileReleaseVersion is! int || profileReleaseVersion < 1) {
      return 'Assignment profileReleaseVersion must be a positive integer';
    }
    if (rawPayload['input'] is! Map) {
      return 'Assignment input must be an object';
    }
    final artifactIds = rawPayload['contextArtifactIds'];
    if (artifactIds is! List || artifactIds.any((id) => id is! String)) {
      return 'Assignment contextArtifactIds must be a string array';
    }
    final timeoutMs = rawPayload['timeoutMs'];
    if (timeoutMs is! int || timeoutMs < 1000 || timeoutMs > 2147483647) {
      return 'Assignment timeoutMs must be between 1000 and 2147483647 milliseconds';
    }
    final queueWaitTimeoutMs = rawPayload['queueWaitTimeoutMs'];
    if (queueWaitTimeoutMs != null &&
        (queueWaitTimeoutMs is! int ||
            queueWaitTimeoutMs < 1000 ||
            queueWaitTimeoutMs > 2147483647)) {
      return 'Assignment queueWaitTimeoutMs must be between 1000 and 2147483647 milliseconds';
    }
    final maxConcurrentAssignments = rawPayload['maxConcurrentAssignments'];
    if (maxConcurrentAssignments != null &&
        (maxConcurrentAssignments is! int ||
            maxConcurrentAssignments < 1 ||
            maxConcurrentAssignments > 1024)) {
      return 'Assignment maxConcurrentAssignments must be between 1 and 1024';
    }
    final repository = rawPayload['repository'];
    if (repository != null) {
      if (repository is! Map ||
          repository['repositoryId'] is! String ||
          (repository['repositoryId'] as String).trim().isEmpty ||
          repository['revision'] is! String ||
          (repository['revision'] as String).trim().isEmpty) {
        return 'Assignment repository must contain repositoryId and revision';
      }
    }
    return null;
  }

  bool _hasAssignmentCorrelation(Map<String, dynamic> message) {
    for (final field in const [
      'executionWorkspaceId',
      'workspaceRuntimeId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'assignmentId',
      'idempotencyKey',
    ]) {
      final value = message[field];
      if (value is! String || value.trim().isEmpty) return false;
    }
    return true;
  }

  Future<void> _sendAssignmentError(
    WorkspaceTransport socket,
    Map<String, dynamic> message,
    String code, {
    required bool retryable,
    String? diagnostic,
  }) async {
    final canonicalCode = canonicalExecutionErrorCode(code);
    final safeDiagnostic = diagnostic == null
        ? null
        : SafeProviderDiagnostics.safeFailureDetail(diagnostic);
    final assignmentId = message['assignmentId'];
    if (assignmentId is String) {
      await _recordAssignment(
        assignmentId,
        AssignmentStatus.failed,
        correlation: _assignmentCorrelation(message),
        result: {
          'status': 'failed',
          'error': executionErrorMessage(canonicalCode),
          'errorCode': canonicalCode,
          if (safeDiagnostic != null) 'localDiagnostic': safeDiagnostic,
        },
      );
    }
    await socket.sendAndWait(jsonEncode(_assignmentEnvelope(
      'assignment.error',
      _assignmentCorrelation(message),
      {
        'status': 'failed',
        'error': {
          'code': canonicalCode,
          'message': executionErrorMessage(canonicalCode),
          'retryable': retryable,
          if (safeDiagnostic != null)
            'details': {
              'diagnostic': safeDiagnostic,
            },
        },
      },
    )));
  }

  String _assignmentDiagnostic({
    required String stage,
    required String detail,
  }) =>
      jsonEncode({
        'schemaVersion': 1,
        'component': 'workspace_service',
        'stage': stage,
        'errorCode': 'execution_failed',
        'providerStarted': false,
        'detail': detail,
      });

  Future<void> _recordAssignment(
    String assignmentId,
    AssignmentStatus status, {
    WorkspaceAssignmentContext? context,
    Map<String, Object?>? correlation,
    Map<String, Object?>? result,
  }) async {
    final journal = assignmentJournal;
    if (journal == null) return;
    final current = await journal.find(assignmentId);
    if (current != null) {
      final terminal = const {
        AssignmentStatus.completed,
        AssignmentStatus.failed,
        AssignmentStatus.cancelled,
        AssignmentStatus.interrupted,
        AssignmentStatus.reconciled,
      }.contains(current.status);
      // Terminal state is authoritative and monotonic. Duplicate delivery is
      // harmless, but a late success/error must never overwrite the first
      // terminal outcome.
      if (current.status == AssignmentStatus.reconciled ||
          (terminal &&
              status != current.status &&
              status != AssignmentStatus.reconciled)) {
        return;
      }
      if (current.status == status &&
          const {
            AssignmentStatus.completed,
            AssignmentStatus.failed,
            AssignmentStatus.cancelled,
          }.contains(status)) {
        return;
      }
    }
    await journal.append(AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: DateTime.now().toUtc(),
      workspaceId: context?.workspaceId ??
          correlation?['executionWorkspaceId'] as String? ??
          correlation?['workspaceId'] as String?,
      workspaceRuntimeId: context?.workspaceRuntimeId ??
          correlation?['workspaceRuntimeId'] as String?,
      workerId: context?.workerId ?? correlation?['workerId'] as String?,
      runId: context?.runId ?? correlation?['runId'] as String?,
      taskId: context?.taskId ?? correlation?['taskId'] as String?,
      attemptId: context?.attemptId ?? correlation?['attemptId'] as String?,
      idempotencyKey:
          context?.idempotencyKey ?? correlation?['idempotencyKey'] as String?,
      executionId: context?.executionId ??
          correlation?['executionId'] as String? ??
          context?.assignmentId ??
          assignmentId,
      processExitCode: result?['processExitCode'] is int
          ? result!['processExitCode'] as int
          : null,
      errorCode: result?['errorCode'] is String
          ? result!['errorCode'] as String
          : null,
      result: result,
    ));
  }

  int? _processExitCode(String? diagnostic) {
    if (diagnostic == null) return null;
    try {
      final decoded = jsonDecode(diagnostic);
      if (decoded is Map && decoded['processExitCode'] is int) {
        return decoded['processExitCode'] as int;
      }
    } on Object {
      // Diagnostics are optional evidence and never affect reconciliation.
    }
    return null;
  }
}
