import 'dart:convert';

import 'initialize_frames.dart';
import 'limits.dart';
import 'runtime_frames.dart';

/// Parses one complete NDJSON line into a validated Local Worker Protocol frame.
WorkerFrame decodeWorkerFrame(String line) {
  if (utf8.encode(line).length > WorkerProtocolLimits.maxFrameBytes) {
    throw const FormatException('Worker frame exceeds the byte limit');
  }
  final decoded = jsonDecode(line);
  if (decoded is! Map)
    throw const FormatException('Worker frame must be an object');
  final json = Map<String, Object?>.from(decoded);
  return switch (json['type']) {
    'initialize.request' => InitializeRequest.fromJson(json),
    'initialize.result' => InitializeResult.fromJson(json),
    'probe.request' => ProbeRequest.fromJson(json),
    'probe.result' => ProbeResult.fromJson(json),
    'usage.request' => UsageRequest.fromJson(json),
    'usage.result' => UsageResult.fromJson(json),
    'execute.request' => ExecuteRequest.fromJson(json),
    'conformance.request' => ConformanceRequest.fromJson(json),
    'conformance.result' => ConformanceResult.fromJson(json),
    'progress' => WorkerProgress.fromJson(json),
    'activity' => WorkerActivity.fromJson(json),
    'result' => WorkerResult.fromJson(json),
    'error' => WorkerErrorFrame.fromJson(json),
    _ => throw FormatException(
        'unsupported Worker frame type: ${json['type']}',
      ),
  };
}
