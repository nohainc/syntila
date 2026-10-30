import 'dart:convert';

import 'package:syntila_cli_worker_runtime/syntila_cli_worker_runtime.dart'
    show
        CliWorkerEngineProbeException,
        SafeProviderDiagnostics,
        WorkerAssignmentCancelledException;
import 'package:syntila_protocol/syntila_protocol.dart'
    show canonicalExecutionErrorCode, executionErrorMessage;

/// A normalized assignment failure safe to report across the runtime link.
class AssignmentExecutionFailure implements Exception {
  const AssignmentExecutionFailure({
    required this.code,
    required this.message,
    this.retryable = false,
    this.localDiagnostic,
  });

  final String code;
  final String message;
  final bool retryable;

  /// Redacted, bounded detail for private issue-report evidence. It is never
  /// displayed as the Work result or included in the public report response.
  final String? localDiagnostic;

  @override
  String toString() => message;
}

/// Converts generic Engine issue codes into the public Workspace execution
/// error contract. Provider-neutral Engine diagnostics stay local, while
/// Cloud receives only the stable protocol code.
String canonicalWorkerExecutionErrorCode(Object? value) => switch (value) {
      'provider_tool_unavailable' => 'cli_not_found',
      'provider_authentication_required' => 'authentication_required',
      'unsupported_provider_tool_version' => 'unsupported_cli_version',
      'deadline_exceeded' => 'timeout',
      'cancelled' => 'cancelled',
      'model_not_supported' => 'model_not_supported',
      'quota_exhausted' => 'quota_exhausted',
      'provider_unavailable' => 'provider_unavailable',
      'permission_denied' => 'permission_denied',
      'context_limit_exceeded' => 'context_limit_exceeded',
      _ => canonicalExecutionErrorCode(value),
    };

bool isWorkerExecutionErrorRetryable(String code) => switch (code) {
      'cancelled' ||
      'permission_denied' ||
      'authentication_required' ||
      'cli_not_found' ||
      'unsupported_cli_version' ||
      'model_not_supported' ||
      'quota_exhausted' ||
      'context_limit_exceeded' =>
        false,
      _ => true,
    };

AssignmentExecutionFailure normalizeAssignmentExecutionFailure(Object error) {
  if (error is AssignmentExecutionFailure) return error;
  if (error is WorkerAssignmentCancelledException) {
    return const AssignmentExecutionFailure(
      code: 'cancelled',
      message: 'The assignment was cancelled.',
      retryable: false,
    );
  }
  if (error is CliWorkerEngineProbeException) {
    final code = canonicalWorkerExecutionErrorCode(error.issueCode);
    return AssignmentExecutionFailure(
      code: code,
      message: executionErrorMessage(code),
      retryable: isWorkerExecutionErrorRetryable(code),
      localDiagnostic: SafeProviderDiagnostics.safeFailureDetail(
        error.localDiagnostics ?? error.safeMessage,
      ),
    );
  }
  final detail = SafeProviderDiagnostics.safeFailureDetail(error);
  return AssignmentExecutionFailure(
    code: 'execution_failed',
    message: 'The assignment could not be completed.',
    retryable: true,
    localDiagnostic: detail,
  );
}

String? assignmentDiagnosticStage(String? diagnostic) {
  if (diagnostic == null) return null;
  try {
    final decoded = jsonDecode(diagnostic);
    final stage = decoded is Map ? decoded['stage'] : null;
    return stage is String &&
            stage.isNotEmpty &&
            stage.length <= 64 &&
            RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$').hasMatch(stage)
        ? stage
        : null;
  } on Object {
    return null;
  }
}
