import 'dart:convert';

const int providerFailureSchemaVersion = 1;

abstract final class ProviderFailureLimits {
  static const int maxNativeErrorCodeBytes = 128;
  static const int maxProviderErrorTextBytes = 4096;
  static const int maxFailedRunResponseBytes = 32768;
  static const int maxTotalBytes = 40960;
}

const Set<String> providerFailureSources = <String>{
  'structured_error',
  'result_message',
  'stderr',
  'stdout',
  'plugin',
};

const Set<String> providerFailureOmittableFields = <String>{
  'nativeErrorCode',
  'providerErrorText',
  'failedRunResponse',
};

final RegExp _ansiEscapePattern = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
final RegExp _singleLineControlPattern = RegExp(r'[\x00-\x1F\x7F-\x9F]');
final RegExp _multilineControlPattern =
    RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]');

final List<RegExp> _credentialPatterns = <RegExp>[
  RegExp(r'\bsk-[A-Za-z0-9_-]{16,}\b'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\bxox[baprs]-[A-Za-z0-9-]{10,}\b'),
  RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b', caseSensitive: false),
  RegExp(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'),
];

int providerFailureUtf8ByteLength(String value) => utf8.encode(value).length;

bool containsDetectedCredential(String value) =>
    _credentialPatterns.any((pattern) => pattern.hasMatch(value));

String stripTerminalControlChars(String value, {required bool multiline}) {
  final withoutAnsi = value.replaceAll(_ansiEscapePattern, '');
  if (multiline) {
    final normalized =
        withoutAnsi.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return normalized.replaceAll(_multilineControlPattern, '');
  }
  return withoutAnsi.replaceAll(_singleLineControlPattern, ' ').trim();
}

({String value, bool truncated}) truncateUtf8ToBytes(
  String value,
  int maxBytes,
) {
  if (maxBytes <= 0) {
    return (value: '', truncated: value.isNotEmpty);
  }
  final encoded = utf8.encode(value);
  if (encoded.length <= maxBytes) {
    return (value: value, truncated: false);
  }
  var safeEnd = maxBytes;
  while (safeEnd > 0 && (encoded[safeEnd - 1] & 0xC0) == 0x80) {
    safeEnd--;
  }
  if (safeEnd > 0) {
    final lead = encoded[safeEnd - 1];
    var seqLen = 1;
    if ((lead & 0xE0) == 0xC0) {
      seqLen = 2;
    } else if ((lead & 0xF0) == 0xE0) {
      seqLen = 3;
    } else if ((lead & 0xF8) == 0xF0) {
      seqLen = 4;
    }
    if (safeEnd - 1 + seqLen > maxBytes) {
      safeEnd--;
    } else {
      safeEnd = maxBytes;
    }
  }
  return (
    value: utf8.decode(encoded.sublist(0, safeEnd), allowMalformed: false),
    truncated: true,
  );
}

final class ProviderFailureDetails {
  const ProviderFailureDetails({
    this.schemaVersion = providerFailureSchemaVersion,
    this.nativeErrorCode,
    this.providerErrorText,
    this.failedRunResponse,
    required this.source,
    this.truncated,
    this.omitted,
    this.omittedFields,
  });

  final int schemaVersion;
  final String? nativeErrorCode;
  final String? providerErrorText;
  final String? failedRunResponse;
  final String source;
  final bool? truncated;
  final bool? omitted;
  final List<String>? omittedFields;

  factory ProviderFailureDetails.fromJson(Map<String, Object?> json) {
    const allowedKeys = <String>{
      'schemaVersion',
      'nativeErrorCode',
      'providerErrorText',
      'failedRunResponse',
      'source',
      'truncated',
      'omitted',
      'omittedFields',
    };
    for (final key in json.keys) {
      if (!allowedKeys.contains(key)) {
        throw FormatException('Unknown providerFailure key: $key');
      }
    }
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != providerFailureSchemaVersion) {
      throw FormatException(
        'Unsupported providerFailure schemaVersion: $schemaVersion',
      );
    }
    final source = json['source'];
    if (source is! String || !providerFailureSources.contains(source)) {
      throw FormatException('Invalid providerFailure source: $source');
    }

    String? readBoundedString(String key, int maxBytes) {
      final raw = json[key];
      if (raw == null) return null;
      if (raw is! String || raw.isEmpty) {
        throw FormatException('$key must be a non-empty string');
      }
      if (providerFailureUtf8ByteLength(raw) > maxBytes) {
        throw FormatException('$key exceeds $maxBytes UTF-8 bytes');
      }
      return raw;
    }

    final nativeErrorCode = readBoundedString(
      'nativeErrorCode',
      ProviderFailureLimits.maxNativeErrorCodeBytes,
    );
    final providerErrorText = readBoundedString(
      'providerErrorText',
      ProviderFailureLimits.maxProviderErrorTextBytes,
    );
    final failedRunResponse = readBoundedString(
      'failedRunResponse',
      ProviderFailureLimits.maxFailedRunResponseBytes,
    );

    final totalBytes =
        (nativeErrorCode == null
            ? 0
            : providerFailureUtf8ByteLength(nativeErrorCode)) +
        (providerErrorText == null
            ? 0
            : providerFailureUtf8ByteLength(providerErrorText)) +
        (failedRunResponse == null
            ? 0
            : providerFailureUtf8ByteLength(failedRunResponse));
    if (totalBytes > ProviderFailureLimits.maxTotalBytes) {
      throw FormatException(
        'providerFailure total UTF-8 bytes ($totalBytes) exceeds ${ProviderFailureLimits.maxTotalBytes}',
      );
    }

    final truncated = json['truncated'];
    if (truncated != null && truncated is! bool) {
      throw const FormatException('truncated must be a boolean');
    }
    final omitted = json['omitted'];
    if (omitted != null && omitted is! bool) {
      throw const FormatException('omitted must be a boolean');
    }
    List<String>? omittedFields;
    final rawOmittedFields = json['omittedFields'];
    if (rawOmittedFields != null) {
      if (rawOmittedFields is! List) {
        throw const FormatException('omittedFields must be a list');
      }
      if (rawOmittedFields.length > providerFailureOmittableFields.length) {
        throw const FormatException('omittedFields exceeds maximum length');
      }
      omittedFields = rawOmittedFields.map((entry) {
        if (entry is! String || !providerFailureOmittableFields.contains(entry)) {
          throw FormatException('Invalid omittedFields entry: $entry');
        }
        return entry;
      }).toList(growable: false);
      if (omittedFields.isNotEmpty && omitted != true) {
        throw const FormatException(
          'omitted must be true when omittedFields is non-empty',
        );
      }
    }

    return ProviderFailureDetails(
      schemaVersion: schemaVersion as int,
      nativeErrorCode: nativeErrorCode,
      providerErrorText: providerErrorText,
      failedRunResponse: failedRunResponse,
      source: source,
      truncated: truncated as bool?,
      omitted: omitted as bool?,
      omittedFields: omittedFields,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        if (nativeErrorCode != null) 'nativeErrorCode': nativeErrorCode,
        if (providerErrorText != null) 'providerErrorText': providerErrorText,
        if (failedRunResponse != null) 'failedRunResponse': failedRunResponse,
        'source': source,
        if (truncated != null) 'truncated': truncated,
        if (omitted != null) 'omitted': omitted,
        if (omittedFields != null) 'omittedFields': omittedFields,
      };
}

ProviderFailureDetails sanitizeProviderFailureDetails({
  String? nativeErrorCode,
  String? providerErrorText,
  String? failedRunResponse,
  required String source,
}) {
  if (!providerFailureSources.contains(source)) {
    throw FormatException('Invalid providerFailure source: $source');
  }
  var truncated = false;
  final omittedFields = <String>[];

  String? processField(
    String? raw,
    String field,
    int maxBytes,
    bool multiline,
  ) {
    if (raw == null) return null;
    final cleaned = stripTerminalControlChars(raw, multiline: multiline);
    if (cleaned.isEmpty) return null;
    if (containsDetectedCredential(cleaned)) {
      omittedFields.add(field);
      return null;
    }
    final bounded = truncateUtf8ToBytes(cleaned, maxBytes);
    if (bounded.truncated) truncated = true;
    return bounded.value.isNotEmpty ? bounded.value : null;
  }

  final cleanCode = processField(
    nativeErrorCode,
    'nativeErrorCode',
    ProviderFailureLimits.maxNativeErrorCodeBytes,
    false,
  );
  final cleanError = processField(
    providerErrorText,
    'providerErrorText',
    ProviderFailureLimits.maxProviderErrorTextBytes,
    true,
  );
  final cleanResponse = processField(
    failedRunResponse,
    'failedRunResponse',
    ProviderFailureLimits.maxFailedRunResponseBytes,
    true,
  );

  return ProviderFailureDetails(
    nativeErrorCode: cleanCode,
    providerErrorText: cleanError,
    failedRunResponse: cleanResponse,
    source: source,
    truncated: truncated ? true : null,
    omitted: omittedFields.isNotEmpty ? true : null,
    omittedFields: omittedFields.isNotEmpty ? omittedFields : null,
  );
}
