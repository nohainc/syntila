import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:json_schema/json_schema.dart';

/// Validate untrusted server schemas off the Engine's main isolate. External
/// references are not fetched; an expensive schema is stopped at the budget.
enum McpSchemaResult { valid, invalid, unsupported }

Future<McpSchemaResult> validateMcpSchema(
  Object? schema,
  Object? value, {
  bool compileOnly = false,
  Duration budget = const Duration(seconds: 2),
}) async {
  if (schema is! Map || budget <= Duration.zero)
    return McpSchemaResult.unsupported;
  try {
    if (utf8.encode(jsonEncode(schema)).length > 65536 ||
        !_localReferencesOnly(schema)) {
      return McpSchemaResult.unsupported;
    }
  } on Object {
    return McpSchemaResult.unsupported;
  }
  final port = ReceivePort();
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(_validate, [
      port.sendPort,
      schema,
      value,
      compileOnly,
    ]);
    final result = await port.first.timeout(budget);
    return result is int &&
            result >= 0 &&
            result < McpSchemaResult.values.length
        ? McpSchemaResult.values[result]
        : McpSchemaResult.unsupported;
  } on Object {
    return McpSchemaResult.unsupported;
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    port.close();
  }
}

bool _localReferencesOnly(Object? value, [int depth = 0]) {
  if (depth > 64) return false;
  if (value is List)
    return value.every((v) => _localReferencesOnly(v, depth + 1));
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) return false;
      if (entry.key == r'$ref' ||
          entry.key == r'$dynamicRef' ||
          entry.key == r'$recursiveRef') {
        if (entry.value is! String || !(entry.value as String).startsWith('#'))
          return false;
      }
      if (!_localReferencesOnly(entry.value, depth + 1)) return false;
    }
  }
  return true;
}

void _validate(List<Object?> args) {
  final port = args[0] as SendPort;
  try {
    final schema = JsonSchema.create(
      args[1]!,
      schemaVersion: SchemaVersion.draft2020_12,
    );
    final valid = args[3] == true || schema.validate(args[2]).isValid;
    port.send((valid ? McpSchemaResult.valid : McpSchemaResult.invalid).index);
  } on Object {
    port.send(McpSchemaResult.unsupported.index);
  }
}
