/// Result of a readiness probe.
class ExternalWorkerReadiness {
  const ExternalWorkerReadiness._(this.state, this.issueCode, this.checks);

  /// The plugin can do work now.
  const ExternalWorkerReadiness.ready(
      {List<ExternalWorkerCheck> checks = const []})
      : this._('ready', null, checks);

  /// Something must be configured first (a missing tool, a missing setting).
  const ExternalWorkerReadiness.setupRequired(
    String issueCode, {
    List<ExternalWorkerCheck> checks = const [],
  }) : this._('setup_required', issueCode, checks);

  /// The user must sign in to whatever the plugin talks to.
  const ExternalWorkerReadiness.signInRequired(
      {List<ExternalWorkerCheck> checks = const []})
      : this._('sign_in_required', 'sign_in_required', checks);

  /// The plugin cannot run on this machine right now.
  const ExternalWorkerReadiness.unavailable(
    String issueCode, {
    List<ExternalWorkerCheck> checks = const [],
  }) : this._('unavailable', issueCode, checks);

  final String state;
  final String? issueCode;
  final List<ExternalWorkerCheck> checks;
}

/// One line of readiness evidence. Messages are shown to the user and are
/// redacted by the host, but never put a secret in one.
class ExternalWorkerCheck {
  const ExternalWorkerCheck(this.code, {required this.ok, this.message});
  final String code;
  final bool ok;
  final String? message;
}

/// A unit of work from the Space.
class WorkRequest {
  const WorkRequest({
    required this.id,
    required this.prompt,
    required this.workingDirectory,
    required this.readOnly,
    required this.deadline,
    this.model,
    this.sessionKey,
    this.resumeSession = false,
    this.rebuildSession = false,
  });

  final String id;

  /// The assembled prompt: context and request. Treat it as untrusted text.
  final String prompt;

  /// The only directory (besides [WorkContext.dataDirectory]) the plugin is
  /// authorised to use.
  final String workingDirectory;

  /// The host asked for no writes. Syntila sends this but cannot enforce it, so
  /// honor it yourself.
  final bool readOnly;
  final Duration deadline;
  final String? model;

  /// Opaque key for session state, present when sessions are in use.
  final String? sessionKey;

  /// True when [sessionKey] should already exist (resume), false when new.
  final bool resumeSession;

  /// Discard incompatible execution state and rebuild from the supplied context.
  final bool rebuildSession;
}

/// What a request can do while it runs.
abstract interface class WorkContext {
  /// Report progress (at most about 20 per second are forwarded).
  void progress(String message, {int? percent});

  /// True once the host asked to stop. Check it between steps.
  bool get isCancelled;

  /// Completes when the host asks to stop.
  Future<void> get cancelled;

  /// A directory only this plugin may write, kept across runs. Never put
  /// secrets here.
  String get dataDirectory;
}

class WorkResult {
  const WorkResult(
    this.output, {
    this.artifacts = const [],
    this.sessionState,
  });

  /// The answer text (at most about 768 KiB).
  final String output;

  /// Paths relative to the working directory, each of which must exist there.
  final List<String> artifacts;

  /// `created`, `resumed` or `unavailable`, when sessions are in use.
  final String? sessionState;
}

/// Throw from [ExternalWorker.execute] to fail a request with a stable code.
class ExternalWorkerFailure implements Exception {
  const ExternalWorkerFailure(this.code, this.message,
      {this.retryable = false});

  /// `invalid_request`, `not_ready`, `sign_in_required`, `unsupported_policy`,
  /// `session_not_found`, `model_unavailable`, `context_limit_exceeded`,
  /// `rate_limited`, `output_too_large` or `internal`.
  final String code;
  final String message;
  final bool retryable;
}

/// Subclass this and pass an instance to `runMcpWorker`.
abstract class ExternalWorker {
  /// Must equal `pluginId` in `plugin.json`.
  String get id;

  /// Must equal `version` in `plugin.json`.
  String get version;

  String get name => id;

  /// Declared capabilities; keep a subset of those in `plugin.json`.
  Map<String, Object?> get capabilities => const {'progress': true};

  /// Passive probes must have no cost or side effects; live probes may call
  /// the service the plugin wraps.
  Future<ExternalWorkerReadiness> probe({required bool live}) async =>
      const ExternalWorkerReadiness.ready();

  /// Metadata-only discovery: must not download models or run inference.
  /// Declare `modelDiscovery: true` to expose this operation over protocol 1.1.
  Future<List<ExternalWorkerModel>> discoverModels() async => const [];

  Future<WorkResult> execute(WorkRequest request, WorkContext context);
}

/// Public model selection metadata; IDs are stable and provider-neutral.
class ExternalWorkerModel {
  const ExternalWorkerModel(
      {required this.id, required this.name, this.status = 'listed'});
  final String id;
  final String name;

  /// Discovery alone is `listed`; use `verified` only after execution evidence.
  final String status;
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'status': status};
}
