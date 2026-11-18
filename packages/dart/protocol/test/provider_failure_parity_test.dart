import 'dart:convert';
import 'dart:io';

import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:test/test.dart';

// Shared with packages/protocol/test/provider-failure-parity.test.ts. Both
// sanitizers must produce identical output for every case.
void main() {
  final file = File('../../protocol/test/fixtures/'
      'provider-failure-sanitize-cases.json');
  final cases = jsonDecode(file.readAsStringSync()) as List<dynamic>;
  Object? value(Object? v) =>
      v is Map ? (v['repeat'] as String) * (v['count'] as int) : v;
  for (final raw in cases) {
    final c = raw as Map<String, dynamic>;
    test(c['name'] as String, () {
      final input = c['input'] as Map<String, dynamic>;
      final result = sanitizeProviderFailureDetails(
        source: input['source'] as String,
        nativeErrorCode: value(input['nativeErrorCode']) as String?,
        providerErrorText: value(input['providerErrorText']) as String?,
        failedRunResponse: value(input['failedRunResponse']) as String?,
      );
      expect(jsonDecode(jsonEncode(result.toJson())), c['expected']);
    });
  }
}
