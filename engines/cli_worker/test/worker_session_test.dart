import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
import 'package:syntila_cli_worker_engine/src/engine_session_store.dart';

void main() {
  test(
    'changed references are recoverable only for the same Conversation and Worker',
    () async {
      final root = await Directory.systemTemp.createTemp('session-reference-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'worker',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        profileReleaseVersion: 1,
        sessionFormatId: 'format',
        sessionId: 'native',
        workerSession: WorkerSessionContext(
          id: 'old-reference',
          conversationId: 'conversation',
          workerId: 'worker',
          baseContextRevision: 0,
        ),
        synchronizedContextRevision: 0,
      );
      Future<String?> read(String conversationId, String workerId) =>
          store.read(
            sessionKey: 'scope',
            workerTypeId: 'worker',
            profileDefinitionId: 'profile',
            providerToolIdentity: 'tool',
            compatibleFormatIds: ['format'],
            workerSession: WorkerSessionContext(
              id: 'new-reference',
              conversationId: conversationId,
              workerId: workerId,
              baseContextRevision: 0,
            ),
          );
      for (final owner in [
        ('other-conversation', 'worker'),
        ('conversation', 'other-worker'),
      ]) {
        await expectLater(
          read(owner.$1, owner.$2),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'owner mismatch',
              'Worker Session belongs to another Conversation or Worker',
            ),
          ),
        );
      }
      await expectLater(
        read('conversation', 'worker'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reference drift',
            staleSessionReferenceMessage,
          ),
        ),
      );
      expect(
        await store.quarantine(
          sessionKey: 'scope',
          workerTypeId: 'worker',
          profileDefinitionId: 'profile',
          providerToolIdentity: 'tool',
        ),
        isTrue,
      );
      expect(await read('conversation', 'worker'), isNull);
    },
  );
  test(
    'session revision and history watermarks reflect consumed context and never regress',
    () async {
      final root = await Directory.systemTemp.createTemp('session-revisions-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      WorkerSessionContext scope(
        int base, {
        ConversationBootstrap? bootstrap,
      }) => WorkerSessionContext(
        id: 'session',
        conversationId: 'conversation',
        workerId: 'worker',
        baseContextRevision: base,
        bootstrap: bootstrap,
      );
      Future<void> write(
        WorkerSessionContext context,
        int revision,
        int sequence,
      ) => store.write(
        sessionKey: 'scope',
        workerTypeId: 'fixture',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        profileReleaseVersion: 1,
        sessionFormatId: 'format',
        sessionId: 'native',
        workerSession: context,
        synchronizedContextRevision: revision,
        synchronizedHistorySequence: sequence,
      );
      final bootstrap = ConversationBootstrap(
        conversationId: 'conversation',
        contextRevision: 103,
        turnRevision: 104,
        throughSequence: 20,
        text: '{}',
      );
      await write(scope(103, bootstrap: bootstrap), 104, 20);
      final file = root.listSync().whereType<File>().single;
      final evidence = file.readAsStringSync();
      for (final candidate in [
        (scope(103), 103, 20),
        (scope(104), 104, 19),
        (scope(104), 105, 20),
        (scope(104), 104, -1),
        (scope(104), 104, 9007199254740992),
        (scope(103, bootstrap: bootstrap), 103, 20),
        (scope(103, bootstrap: bootstrap), 104, 21),
      ]) {
        await expectLater(
          write(candidate.$1, candidate.$2, candidate.$3),
          throwsFormatException,
        );
        expect(file.readAsStringSync(), evidence);
      }
      await write(scope(104), 104, 20);
      final state =
          (jsonDecode(file.readAsStringSync()) as Map)['workerSession'] as Map;
      expect(state['synchronizedContextRevision'], 104);
      expect(state['synchronizedHistorySequence'], 20);
      state['synchronizedContextRevision'] = 9007199254740992;
      final decoded = jsonDecode(file.readAsStringSync()) as Map;
      decoded['workerSession'] = state;
      file.writeAsStringSync(jsonEncode(decoded));
      await expectLater(
        store.read(
          sessionKey: 'scope',
          workerTypeId: 'fixture',
          profileDefinitionId: 'profile',
          providerToolIdentity: 'tool',
          compatibleFormatIds: ['format'],
          workerSession: scope(104),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'invalidated native session cannot resume after restart and replacement retains scope',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'session-invalidation-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      final scope = WorkerSessionContext(
        id: 'logical-session',
        conversationId: 'conversation',
        workerId: 'worker',
        baseContextRevision: 0,
      );
      Future<void> write(String native) => store.write(
        sessionKey: 'scope',
        workerTypeId: 'fixture',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        profileReleaseVersion: 1,
        sessionFormatId: 'format',
        sessionId: native,
        workerSession: scope,
      );
      Future<bool> invalidate(String expected) => store.invalidate(
        sessionKey: 'scope',
        workerTypeId: 'fixture',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        expectedNativeSessionId: expected,
      );
      Future<String?> read() => EngineSessionStore(root).read(
        sessionKey: 'scope',
        workerTypeId: 'fixture',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        compatibleFormatIds: ['format'],
        workerSession: scope,
      );
      await write('old-native');
      final file = root.listSync().whereType<File>().single;
      final createdAt =
          (jsonDecode(file.readAsStringSync())
              as Map)['workerSession']['createdAt'];
      expect(await invalidate('another-native'), isFalse);
      expect(await read(), 'old-native');
      expect(await invalidate('old-native'), isTrue);
      expect(await read(), isNull);
      await write('replacement-native');
      expect(await read(), 'replacement-native');
      final metadata =
          (jsonDecode(file.readAsStringSync()) as Map)['workerSession'] as Map;
      expect(metadata['id'], 'logical-session');
      expect(metadata['conversationId'], 'conversation');
      expect(metadata['createdAt'], createdAt);
      expect(metadata['status'], 'active');
      expect(await invalidate('old-native'), isFalse);
      expect(await read(), 'replacement-native');
    },
  );

  test(
    'corrupt local session state can be quarantined before canonical reconstruction',
    () async {
      final root = await Directory.systemTemp.createTemp('session-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      final context = WorkerSessionContext(
        id: 'session-A',
        conversationId: 'conversation-A',
        workerId: 'worker-A',
        baseContextRevision: 1,
      );
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'worker',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        profileReleaseVersion: 1,
        sessionFormatId: 'format',
        sessionId: 'native',
        workerSession: context,
      );
      final stateFile = root.listSync().whereType<File>().single;
      await stateFile.writeAsString('{not-json');

      expect(
        await store.quarantine(
          sessionKey: 'scope',
          workerTypeId: 'worker',
          profileDefinitionId: 'profile',
          providerToolIdentity: 'tool',
        ),
        isTrue,
      );
      expect(await stateFile.exists(), isFalse);
      expect(
        root.listSync().whereType<File>().map((file) => file.path).single,
        contains('.recovery-'),
      );
      expect(
        await store.read(
          sessionKey: 'scope',
          workerTypeId: 'worker',
          profileDefinitionId: 'profile',
          providerToolIdentity: 'tool',
          compatibleFormatIds: ['format'],
          workerSession: context,
        ),
        isNull,
      );
    },
  );

  test(
    'a local session ahead of Cloud is rejected with the recoverable message and can be quarantined',
    () async {
      final root = await Directory.systemTemp.createTemp('session-ahead-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      Future<String?> read(WorkerSessionContext context) => store.read(
        sessionKey: 'scope',
        workerTypeId: 'worker',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        compatibleFormatIds: ['format'],
        workerSession: context,
      );
      final ahead = WorkerSessionContext(
        id: 'session',
        conversationId: 'conversation',
        workerId: 'worker',
        baseContextRevision: 3,
      );
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'worker',
        profileDefinitionId: 'profile',
        providerToolIdentity: 'tool',
        profileReleaseVersion: 1,
        sessionFormatId: 'format',
        sessionId: 'native',
        workerSession: ahead,
        synchronizedContextRevision: 3,
      );
      // Cloud was reset and now sends revision 0 for the same Worker Session.
      final reset = WorkerSessionContext(
        id: 'session',
        conversationId: 'conversation',
        workerId: 'worker',
        baseContextRevision: 0,
      );
      await expectLater(
        read(reset),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            staleSessionAheadOfCloudMessage,
          ),
        ),
      );
      expect(
        await store.quarantine(
          sessionKey: 'scope',
          workerTypeId: 'worker',
          profileDefinitionId: 'profile',
          providerToolIdentity: 'tool',
        ),
        isTrue,
      );
      expect(await read(reset), isNull);
    },
  );

  test(
    'fast path requires exact synchronized context and active native state',
    () async {
      final root = await Directory.systemTemp.createTemp('session-fast-path-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      final scope = WorkerSessionContext(
        id: 'session',
        conversationId: 'conversation',
        workerId: 'worker',
        baseContextRevision: 0,
      );
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-codex',
        providerToolIdentity: 'Codex CLI',
        profileReleaseVersion: 1,
        sessionFormatId: 'format-v1',
        sessionId: 'native-handle',
        workerSession: scope,
        modelId: 'model-A',
        effort: 'medium',
      );
      final file = root.listSync().whereType<File>().single;
      final state =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final metadata = state['workerSession'] as Map;
      // Simulate context already ingested by the future synchronization executor.
      metadata['synchronizedContextRevision'] = 2;
      Future<String?> read(int revision) => store.read(
        sessionKey: 'scope',
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-codex',
        providerToolIdentity: 'Codex CLI',
        compatibleFormatIds: ['format-v1'],
        modelSwitchSupported: false,
        requestedModelId: 'model-A',
        workerSession: WorkerSessionContext(
          id: 'session',
          conversationId: 'conversation',
          workerId: 'worker',
          baseContextRevision: revision,
        ),
      );
      await file.writeAsString(jsonEncode(state));
      expect(await read(2), 'native-handle');
      await expectLater(read(1), throwsFormatException);
      await expectLater(read(3), throwsFormatException);
      metadata['status'] = 'requires_synchronization';
      await file.writeAsString(jsonEncode(state));
      await expectLater(read(2), throwsFormatException);
    },
  );

  test(
    'Conversation WorkerSession survives model/effort changes and compatible Profile releases',
    () async {
      final root = await Directory.systemTemp.createTemp('worker-session-');
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      final context = WorkerSessionContext(
        id: 'session-A',
        conversationId: 'conversation-A',
        workerId: 'worker-A',
        baseContextRevision: 0,
      );
      Future<void> write({
        String? model = 'model-A',
        String? effort = 'medium',
        int version = 1,
      }) => store.write(
        sessionKey: 'scope-A',
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-codex',
        providerToolIdentity: 'Codex CLI',
        profileReleaseVersion: version,
        sessionFormatId: 'format-v1',
        sessionId: 'native-private-handle',
        workerSession: context,
        modelId: model,
        effort: effort,
      );
      // A new store instance models Workspace/Engine restart: no in-memory
      // continuity state may be required to restore this native handle.
      Future<String?> read({WorkerSessionContext? scope}) =>
          EngineSessionStore(root).read(
            sessionKey: 'scope-A',
            workerTypeId: 'chatgpt',
            profileDefinitionId: 'chatgpt-codex',
            providerToolIdentity: 'Codex CLI',
            compatibleFormatIds: ['format-v1'],
            workerSession: scope ?? context,
          );
      await write();
      final file = root.listSync().whereType<File>().single;
      final initial = jsonDecode(await file.readAsString()) as Map;
      final created = (initial['workerSession'] as Map)['createdAt'];
      expect(await read(), 'native-private-handle');
      await write(model: 'model-B', effort: 'high', version: 2);
      expect(root.listSync().whereType<File>(), hasLength(1));
      expect(await read(), 'native-private-handle');
      await expectLater(
        store.read(
          sessionKey: 'scope-A',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
          modelSwitchSupported: false,
          requestedModelId: 'model-A',
        ),
        throwsFormatException,
      );
      expect(
        await store.read(
          sessionKey: 'scope-A',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
          modelSwitchSupported: false,
          requestedModelId: 'model-B',
        ),
        'native-private-handle',
      );
      for (final reconstruct in [false, true]) {
        final selection = store.read(
          sessionKey: 'scope-A',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
          modelSwitchSupported: false,
          requestedModelId: 'model-B',
          requestedEffort: 'low',
          effortChangesNativeModel: true,
          allowModelReconstruction: reconstruct,
        );
        if (reconstruct) {
          expect(await selection, isNull);
        } else {
          await expectLater(selection, throwsFormatException);
        }
      }
      final after = jsonDecode(await file.readAsString()) as Map;
      expect(after['workerSession'], containsPair('id', 'session-A'));
      expect(after['workerSession'], containsPair('profileVersion', 2));
      expect(after['workerSession'], containsPair('lastModelId', 'model-B'));
      expect(after['workerSession'], containsPair('lastEffort', 'high'));
      expect(after['workerSession'], containsPair('createdAt', created));
      expect(
        after['workerSession'],
        containsPair('synchronizedContextRevision', 0),
      );
      await write(model: null, effort: null);
      final defaults =
          (jsonDecode(await file.readAsString()) as Map)['workerSession']
              as Map;
      expect(defaults['lastModelId'], isNull);
      expect(defaults['lastEffort'], isNull);
      expect(
        await EngineSessionStore(root).read(
          sessionKey: 'scope-A',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
        ),
        'native-private-handle',
      );
      await expectLater(
        read(
          scope: WorkerSessionContext(
            id: 'session-B',
            conversationId: 'conversation-B',
            workerId: 'worker-A',
            baseContextRevision: 0,
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        read(
          scope: WorkerSessionContext(
            id: 'session-A',
            conversationId: 'conversation-A',
            workerId: 'worker-B',
            baseContextRevision: 0,
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        read(
          scope: WorkerSessionContext(
            id: 'session-A',
            conversationId: 'conversation-A',
            workerId: 'worker-A',
            baseContextRevision: 1,
          ),
        ),
        throwsFormatException,
      );
      expect(
        await store.read(
          sessionKey: 'scope-A',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'other-profile',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
        ),
        isNull,
      );
    },
  );

  test(
    'existing local session mapping gains explicit ownership after successful use',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'worker-session-upgrade-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = EngineSessionStore(root);
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-codex',
        providerToolIdentity: 'Codex CLI',
        profileReleaseVersion: 1,
        sessionFormatId: 'format-v1',
        sessionId: 'native-existing',
      );
      final context = WorkerSessionContext(
        id: 'session-A',
        conversationId: 'conversation-A',
        workerId: 'worker-A',
        baseContextRevision: 0,
      );
      expect(
        await store.read(
          sessionKey: 'scope',
          workerTypeId: 'chatgpt',
          profileDefinitionId: 'chatgpt-codex',
          providerToolIdentity: 'Codex CLI',
          compatibleFormatIds: ['format-v1'],
          workerSession: context,
        ),
        'native-existing',
      );
      await store.write(
        sessionKey: 'scope',
        workerTypeId: 'chatgpt',
        profileDefinitionId: 'chatgpt-codex',
        providerToolIdentity: 'Codex CLI',
        profileReleaseVersion: 1,
        sessionFormatId: 'format-v1',
        sessionId: 'native-existing',
        workerSession: context,
        modelId: 'model-A',
      );
      final data =
          jsonDecode(
                await root.listSync().whereType<File>().single.readAsString(),
              )
              as Map;
      expect(data['version'], 2);
      expect(
        data['workerSession'],
        containsPair('nativeSessionId', 'native-existing'),
      );
    },
  );
}
