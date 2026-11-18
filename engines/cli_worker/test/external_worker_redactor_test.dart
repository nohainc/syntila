import 'package:syntila_cli_worker_engine/src/external_worker_redactor.dart';
import 'package:test/test.dart';

void main() {
  test('detects launch secrets while preserving paths in failure details', () {
    final redactor = ExternalWorkerRedactor(secrets: ['private-value']);
    const path = 'Could not read /Users/example/project/source.dart';
    expect(redactor.redactSecrets(path), path);
    expect(redactor.redact(path), isNot(path));
    expect(
      redactor.redactSecrets('token private-value'),
      isNot('token private-value'),
    );
  });
}
