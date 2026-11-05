const conformanceSuiteVersion = '1.1.0';

/// Printed with every result. Conformance is not a safety assessment.
const conformanceDisclaimer =
    'Conformance shows protocol behavior only. It does not show that the '
    'plugin is safe, honest about its declared access, or free of malicious '
    'behavior, and it is not a security rating.';

enum ConformanceStatus { passed, failed, skipped }

class ConformanceCase {
  const ConformanceCase({
    required this.id,
    required this.status,
    required this.milliseconds,
    this.detail,
  });

  final String id;
  final ConformanceStatus status;
  final int milliseconds;
  final String? detail;

  Map<String, Object?> toJson() => {
        'id': id,
        'status': status.name,
        'ms': milliseconds,
        if (detail != null) 'detail': detail,
      };
}

class ConformanceReport {
  const ConformanceReport({required this.protocol, required this.cases});

  final String protocol;
  final List<ConformanceCase> cases;

  bool get passed => cases.every((c) => c.status != ConformanceStatus.failed);

  Map<String, Object?> toJson() => {
        'suiteVersion': conformanceSuiteVersion,
        'protocol': protocol,
        'passed': passed,
        'cases': [for (final c in cases) c.toJson()],
        'disclaimer': conformanceDisclaimer,
      };
}
