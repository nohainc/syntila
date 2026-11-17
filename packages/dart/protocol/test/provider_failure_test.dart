import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderFailureDetails contract', () {
    test('round-trips valid providerFailure with error and response', () {
      final details = ProviderFailureDetails.fromJson(<String, Object?>{
        'schemaVersion': 1,
        'nativeErrorCode': 'RATE_LIMIT_EXCEEDED',
        'providerErrorText': 'Too many requests',
        'failedRunResponse': 'Partial output',
        'source': 'structured_error',
      });
      expect(details.nativeErrorCode, 'RATE_LIMIT_EXCEEDED');
      expect(details.toJson()['failedRunResponse'], 'Partial output');
    });

    test('rejects invalid source, unknown keys, and oversized UTF-8 values',
        () {
      expect(
        () => ProviderFailureDetails.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'source': 'invalid',
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderFailureDetails.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'source': 'stderr',
          'unknown': true,
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderFailureDetails.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'source': 'stderr',
          'nativeErrorCode': 'x' * 129,
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderFailureDetails.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'source': 'stderr',
          'omittedFields': <String>['providerErrorText'],
        }),
        throwsFormatException,
      );
    });

    test('truncates multi-byte Unicode text on UTF-8 codepoint boundaries', () {
      final result = truncateUtf8ToBytes('🎉🎉🎉', 10);
      expect(result.truncated, isTrue);
      expect(result.value, '🎉🎉');
      expect(providerFailureUtf8ByteLength(result.value), 8);
    });

    test('strips terminal control chars and omits detected credentials', () {
      final sanitized = sanitizeProviderFailureDetails(
        nativeErrorCode: 'ERR\x1B[31m_KEY\x1B[0m\n',
        providerErrorText: 'Token Bearer abcdefghijklmnop123456 failed',
        failedRunResponse: 'Hello\r\nWorld\x07',
        source: 'stderr',
      );
      expect(sanitized.nativeErrorCode, 'ERR_KEY');
      expect(sanitized.providerErrorText, isNull);
      expect(sanitized.failedRunResponse, 'Hello\nWorld');
      expect(sanitized.omitted, isTrue);
      expect(sanitized.omittedFields, <String>['providerErrorText']);
    });

    test('omits common credential assignments and Google keys', () {
      for (final text in ['password=hunter2', 'key AIza${'A' * 35}']) {
        final result = sanitizeProviderFailureDetails(
            source: 'stderr', providerErrorText: text);
        expect(result.providerErrorText, isNull);
        expect(result.omittedFields, ['providerErrorText']);
      }
    });
  });
}
