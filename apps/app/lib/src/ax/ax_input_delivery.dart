import 'dart:async';

import 'package:flutter/foundation.dart';

/// Where one file input of a Work Request is in Input Delivery v1.
enum AxInputState { queued, uploading, uploaded, delivered, failed }

class AxInputProgress {
  const AxInputProgress({
    required this.fileId,
    required this.name,
    this.state = AxInputState.queued,
    this.attempt = 0,
    this.error,
  });

  final String fileId;
  final String name;
  final AxInputState state;

  /// Whole-file upload or download attempt currently counted (1-based).
  final int attempt;
  final String? error;

  AxInputProgress copyWith(
          {AxInputState? state, int? attempt, String? error}) =>
      AxInputProgress(
        fileId: fileId,
        name: name,
        state: state ?? this.state,
        attempt: attempt ?? this.attempt,
        error: error,
      );
}

/// One file to upload after its Work Request was accepted.
class AxPendingInputUpload {
  const AxPendingInputUpload({required this.fileId, required this.name});
  final String fileId;
  final String name;
}

/// Server delivery state for one input (`GET /work-requests/:id` `inputs`).
class AxDeliveredInputState {
  const AxDeliveredInputState(
      {required this.fileId,
      required this.state,
      this.deliveryAttempts = 0,
      this.errorMessage});
  final String fileId;
  final String state;
  final int deliveryAttempts;
  final String? errorMessage;
}

/// Uploads a Work Request's files in parallel after the request is accepted,
/// restarting a failed file from scratch, and follows the Workspace's
/// download of each file until all are delivered. Progress is per request
/// and read by the request card, so the composer stays free while files move.
class AxInputDelivery extends ChangeNotifier {
  AxInputDelivery({
    this.maxConcurrentUploads = 3,
    this.maxUploadAttempts = 3,
    this.pollInterval = const Duration(milliseconds: 1500),
    this.maxTracking = const Duration(minutes: 15),
    this.retryDelay = const Duration(seconds: 1),
  });

  static final instance = AxInputDelivery();

  final int maxConcurrentUploads;
  final int maxUploadAttempts;
  final Duration pollInterval;
  final Duration maxTracking;
  final Duration retryDelay;

  final _requests = <String, List<AxInputProgress>>{};

  /// Progress of [workRequestId], or null when it has no tracked files.
  List<AxInputProgress>? progress(String workRequestId) {
    final value = _requests[workRequestId];
    return value == null ? null : List.unmodifiable(value);
  }

  /// A short, CLI-like status block for the request card; null once every
  /// file is delivered.
  String? summary(String workRequestId) {
    final files = _requests[workRequestId];
    if (files == null || files.isEmpty) return null;
    if (files.every((file) => file.state == AxInputState.delivered)) {
      return null;
    }
    final ready =
        files.where((file) => file.state == AxInputState.delivered).length;
    final failed = files.where((file) => file.state == AxInputState.failed);
    final header = failed.isNotEmpty
        ? 'Files could not be delivered to the Worker.'
        : 'Delivering files to the Worker ($ready/${files.length} ready)…';
    final lines = files.map((file) {
      final retry = file.attempt > 1 ? ' (attempt ${file.attempt})' : '';
      return switch (file.state) {
        AxInputState.queued => '• ${file.name} — waiting to upload',
        AxInputState.uploading => '↑ ${file.name} — uploading$retry',
        AxInputState.uploaded =>
          '↓ ${file.name} — downloading to the Worker$retry',
        AxInputState.delivered => '✓ ${file.name} — ready',
        AxInputState.failed => '✗ ${file.name} — ${file.error ?? 'failed'}',
      };
    });
    return [header, ...lines].join('\n');
  }

  void _set(String workRequestId, String fileId,
      AxInputProgress Function(AxInputProgress) update) {
    final files = _requests[workRequestId];
    if (files == null) return;
    final index = files.indexWhere((file) => file.fileId == fileId);
    if (index < 0) return;
    files[index] = update(files[index]);
    notifyListeners();
  }

  /// Uploads [files] (at most [maxConcurrentUploads] at once) and tracks
  /// delivery. [upload] sends one whole file; it is called again from scratch
  /// after a failure. After [maxUploadAttempts], [reportUploadFailure] fails
  /// the input on the server, which fails the request before any Worker
  /// starts. [loadDelivery] reads server states; null ends tracking.
  Future<void> start({
    required String workRequestId,
    required List<AxPendingInputUpload> files,
    required Future<void> Function(String fileId) upload,
    required Future<void> Function(String fileId, String message)
        reportUploadFailure,
    required Future<List<AxDeliveredInputState>?> Function() loadDelivery,
  }) async {
    if (files.isEmpty || _requests.containsKey(workRequestId)) return;
    _requests[workRequestId] = [
      for (final file in files)
        AxInputProgress(fileId: file.fileId, name: file.name)
    ];
    notifyListeners();
    final queue = [...files];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final file = queue.removeAt(0);
        await _uploadWithRetries(
            workRequestId, file, upload, reportUploadFailure);
      }
    }

    final uploads = Future.wait([
      for (var i = 0; i < maxConcurrentUploads && i < files.length; i++)
        worker()
    ]);
    final tracking = _track(workRequestId, loadDelivery);
    await uploads;
    await tracking;
  }

  Future<void> _uploadWithRetries(
    String workRequestId,
    AxPendingInputUpload file,
    Future<void> Function(String fileId) upload,
    Future<void> Function(String fileId, String message) reportUploadFailure,
  ) async {
    for (var attempt = 1; attempt <= maxUploadAttempts; attempt++) {
      _set(
          workRequestId,
          file.fileId,
          (value) =>
              value.copyWith(state: AxInputState.uploading, attempt: attempt));
      try {
        await upload(file.fileId);
        _set(
            workRequestId,
            file.fileId,
            (value) => value.state == AxInputState.delivered
                ? value
                : value.copyWith(state: AxInputState.uploaded, attempt: 1));
        return;
      } on Object catch (error) {
        if (attempt == maxUploadAttempts) {
          final message = _shortError(error);
          _set(
              workRequestId,
              file.fileId,
              (value) =>
                  value.copyWith(state: AxInputState.failed, error: message));
          try {
            await reportUploadFailure(file.fileId, message);
          } on Object {
            // The Workflow's idle deadline still ends the request.
          }
          return;
        }
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }

  Future<void> _track(String workRequestId,
      Future<List<AxDeliveredInputState>?> Function() loadDelivery) async {
    final deadline = DateTime.now().add(maxTracking);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      final files = _requests[workRequestId];
      if (files == null) return;
      List<AxDeliveredInputState>? states;
      try {
        states = await loadDelivery();
      } on Object {
        continue;
      }
      if (states == null) return;
      for (final server in states) {
        _set(workRequestId, server.fileId, (value) {
          if (server.state == 'delivered') {
            return value.copyWith(state: AxInputState.delivered, attempt: 1);
          }
          if (server.state == 'failed') {
            return value.copyWith(
                state: AxInputState.failed,
                error: server.errorMessage ?? 'failed');
          }
          if (server.state == 'uploaded' &&
              value.state != AxInputState.failed) {
            return value.copyWith(
                state: AxInputState.uploaded,
                attempt: server.deliveryAttempts + 1);
          }
          return value;
        });
      }
      // Cleared meanwhile (session change): stop following this request.
      final current = _requests[workRequestId];
      if (current == null) return;
      if (current.every((file) =>
          file.state == AxInputState.delivered ||
          file.state == AxInputState.failed)) {
        return;
      }
    }
  }

  /// Drops tracked progress, e.g. on sign-out.
  void clear() {
    _requests.clear();
    notifyListeners();
  }

  static String _shortError(Object error) {
    final text = error.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}
