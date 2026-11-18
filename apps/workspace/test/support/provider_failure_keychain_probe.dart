import 'dart:io';

import 'package:syntila_workspace/assignment_journal.dart';
import 'package:syntila_workspace/provider_failure_cipher.dart';
import 'package:syntila_workspace/secure_credentials.dart';

Future<void> main(List<String> arguments) async {
  final action = arguments[0];
  final path = arguments[1];
  final service = arguments[2];
  final installation = arguments[3];
  final store = PlatformSecureCredentialStore(service: service);
  final file = File(path);
  final journal = AssignmentJournal(file,
      providerFailureCipher: ProviderFailureCipher(store, file, installation));
  if (action == 'write') {
    await journal.append(AssignmentRecord(
      assignmentId: 'fixture-assignment',
      status: AssignmentStatus.failed,
      updatedAt: DateTime.utc(2026),
      errorCode: 'execution_failed',
      result: {
        'error': 'fixture failure',
        'providerFailure': {
          'schemaVersion': 1,
          'source': 'stderr',
          'providerErrorText': 'journal keychain recovery fixture',
        },
      },
    ));
  } else if (action == 'read') {
    final record = await journal.find('fixture-assignment');
    final failure = record?.result?['providerFailure'];
    if (failure is! Map ||
        failure['providerErrorText'] != 'journal keychain recovery fixture' ||
        record?.status != AssignmentStatus.failed) {
      throw StateError('Encrypted journal recovery failed');
    }
  } else if (action == 'delete') {
    await store.delete('provider-failure-key-v1:$installation');
  } else {
    throw ArgumentError.value(action, 'action');
  }
}
