import 'package:flutter/foundation.dart';

/// Raw usage report printed by a Worker's provider CLI.
///
/// Each provider calculates usage differently and the command that produces it
/// lives in the Worker's Tool Profile. [output] is kept exactly as received;
/// `parseWorkerUsage` may normalize it for display, and the original text is
/// shown whenever that fails.
@immutable
class AxWorkerUsageReport {
  const AxWorkerUsageReport({
    required this.status,
    this.output = '',
    this.errorOutput = '',
    this.exitCode,
    this.truncated = false,
    this.errorMessage,
    this.fetchedAt,
  });

  /// `ok`, `unavailable` (the Profile defines no usage command) or `error`.
  final String status;
  final String output;
  final String errorOutput;
  final int? exitCode;
  final bool truncated;
  final String? errorMessage;
  final DateTime? fetchedAt;

  bool get isOk => status == 'ok';

  /// Text to show: the provider's standard output, or its error output when
  /// the command printed nothing else.
  String get displayText => output.trim().isNotEmpty ? output : errorOutput;

  factory AxWorkerUsageReport.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    return AxWorkerUsageReport(
      status: status is String && status.isNotEmpty ? status : 'error',
      output: json['output'] is String ? json['output'] as String : '',
      errorOutput:
          json['errorOutput'] is String ? json['errorOutput'] as String : '',
      exitCode: json['exitCode'] is int ? json['exitCode'] as int : null,
      truncated: json['truncated'] == true,
      errorMessage: json['errorMessage'] is String
          ? json['errorMessage'] as String
          : null,
      fetchedAt: json['fetchedAt'] is String
          ? DateTime.tryParse(json['fetchedAt'] as String)
          : null,
    );
  }
}

abstract interface class AxWorkerUsageDataSource {
  /// Runs the Profile-defined usage command for [workerId] on its Workspace.
  Future<AxWorkerUsageReport> readWorkerUsage({
    required String workspaceId,
    required String workerId,
  });
}

/// Holds the usage card shown above the composer. Results are local view
/// state: they are never posted to the Thread or stored.
class AxWorkerUsageController extends ChangeNotifier {
  AxWorkerUsageController(this._source);

  final AxWorkerUsageDataSource? _source;

  bool get supported => _source != null;
  String? workerName;
  AxWorkerUsageReport? report;
  bool loading = false;
  bool visible = false;

  /// Shows the provider's original text even when it could be normalized.
  bool showOriginal = false;

  /// A local notice shown instead of a report (for example, no Worker chosen).
  String? message;
  int _generation = 0;

  Future<void> load({
    required String workspaceId,
    required String workerId,
    required String workerName,
  }) async {
    final source = _source;
    if (source == null) return;
    final generation = ++_generation;
    this.workerName = workerName;
    visible = true;
    loading = true;
    showOriginal = false;
    message = null;
    notifyListeners();
    AxWorkerUsageReport result;
    try {
      result = await source.readWorkerUsage(
          workspaceId: workspaceId, workerId: workerId);
    } on Object {
      result = const AxWorkerUsageReport(
        status: 'error',
        errorMessage: 'Usage could not be read. Check that the Worker is '
            'online, then try again.',
      );
    }
    if (generation != _generation) return;
    report = result;
    loading = false;
    notifyListeners();
  }

  void showMessage(String text) {
    _generation++;
    message = text;
    report = null;
    loading = false;
    visible = true;
    notifyListeners();
  }

  void toggleOriginal() {
    showOriginal = !showOriginal;
    notifyListeners();
  }

  void dismiss() {
    _generation++;
    visible = false;
    loading = false;
    notifyListeners();
  }
}
