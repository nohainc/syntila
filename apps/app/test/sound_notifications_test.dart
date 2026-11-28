import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/app_shell.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/notifications/sound_notifications.dart';
import 'package:syntila_app/src/platform/platform_services.dart';
import 'package:syntila_app/src/platform/view_preferences.dart';
import 'ax_fixture_data.dart';
import 'ax_fixture_realtime.dart';

class TestSoundNotifications implements AxSoundNotifications {
  final played = <AxSoundKind>[];

  @override
  void play(AxSoundKind kind) {
    played.add(kind);
  }

  @override
  void playMessageReceived() => play(AxSoundKind.messageReceived);

  @override
  void playRequestCompleted() => play(AxSoundKind.requestCompleted);
}

class _SoundNotificationSource extends AxFixtureDataSource {
  /// Messages the realtime ID-only `discussion.created` events point at.
  final messages = <String, AxDiscussionMessage>{};

  @override
  Future<AxDiscussionMessage> loadDiscussionMessage(
          {required String messageId}) async =>
      messages[messageId] ?? (throw StateError('not found'));

  @override
  Future<AxSession> loadSession() async => const AxSession(
        authenticated: true,
        sessionId: 'fixture-session',
        viewer: AxViewer(
          id: 'user-me',
          email: 'me@example.com',
          displayName: 'Me',
        ),
      );
}

void main() {
  test('stub sound notifications executes without crashing', () {
    final stub = createAxSoundNotifications();
    expect(() => stub.playMessageReceived(), returnsNormally);
    expect(() => stub.playRequestCompleted(), returnsNormally);
  });

  testWidgets(
      'plays sound on incoming message from another user, stays quiet for own message',
      (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    store.save(const ViewPreferences(muteSound: false));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/'),
      ),
    ));
    await tester.pumpAndSettle();

    // Own message sent by current user ("user-me") -> no sound
    realtime.emit({
      'type': 'discussion.created',
      'payload': {
        'threadId': 'thread-1',
        'authorUserId': 'user-me',
        'text': 'My own message',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, isEmpty);

    // Incoming message from collaborator ("user-other") -> plays messageReceived
    realtime.emit({
      'type': 'discussion.created',
      'payload': {
        'threadId': 'thread-1',
        'authorUserId': 'user-other',
        'text': 'Hello from collaborator',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, [AxSoundKind.messageReceived]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('stays quiet for incoming messages in the visible open thread',
      (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    store.save(const ViewPreferences(muteSound: false));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/spaces/space-auth/threads/thread-auth'),
      ),
    ));
    await tester.pumpAndSettle();

    realtime.emit({
      'type': 'discussion.created',
      'payload': {
        'threadId': 'thread-auth',
        'authorUserId': 'user-other',
        'text': 'Visible in the open thread',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, isEmpty);

    realtime.emit({
      'type': 'discussion.created',
      'payload': {
        'threadId': 'another-thread',
        'authorUserId': 'user-other',
        'text': 'Not visible in the open thread',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, [AxSoundKind.messageReceived]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('plays sound when a request is completed', (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    store.save(const ViewPreferences(muteSound: false));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/'),
      ),
    ));
    await tester.pumpAndSettle();

    // Request completed event -> plays requestCompleted sound
    realtime.emit({
      'type': 'work_request.completed',
      'payload': {
        'workRequestId': 'req-1',
        'threadId': 'thread-1',
        'requestedByUserId': 'user-me',
        'status': 'completed',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, [AxSoundKind.requestCompleted]);

    // Replayed event, a collaborator's request and an unattributed request
    // stay quiet.
    for (final payload in [
      {'workRequestId': 'req-1', 'requestedByUserId': 'user-me'},
      {'workRequestId': 'req-2', 'requestedByUserId': 'user-other'},
      {'workRequestId': 'req-3'},
    ]) {
      realtime.emit({
        'type': 'work_request.completed',
        'payload': {'threadId': 'thread-1', ...payload},
      });
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }
    expect(sounds.played, [AxSoundKind.requestCompleted]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'ID-only message events chime for people only, once, and never for own or AI entries',
      (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    AxDiscussionMessage message(String id, String author, {String? kind}) =>
        AxDiscussionMessage(
          id: id,
          threadId: 'thread-1',
          authorUserId: author,
          body: 'text',
          createdAt: '2026-01-01T00:00:00Z',
          kind: kind ?? 'message',
        );
    source.messages.addAll({
      'm-own': message('m-own', 'user-me'),
      'm-other': message('m-other', 'user-other'),
      'm-ai': message('m-ai', 'user-other', kind: 'ai_answer'),
    });
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    store.save(const ViewPreferences(muteSound: false));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/'),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> emit(String entityId) async {
      realtime.emit({
        'type': 'discussion.created',
        'payload': {'entityId': entityId, 'threadId': 'thread-1'},
      });
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    await emit('m-own');
    await emit('m-ai');
    await emit('m-missing');
    expect(sounds.played, isEmpty);

    await emit('m-other');
    await emit('m-other');
    expect(sounds.played, [AxSoundKind.messageReceived]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'chimes once for failed requests and notifications, not in the open thread',
      (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    store.save(const ViewPreferences(muteSound: false));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/spaces/space-auth/threads/thread-auth'),
      ),
    ));
    await tester.pumpAndSettle();

    Future<void> emit(Map<String, dynamic> event) async {
      realtime.emit(event);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
    }

    // Open thread: failure is already on screen.
    await emit({
      'type': 'work_request.failed',
      'payload': {'workRequestId': 'r0', 'threadId': 'thread-auth'},
    });
    expect(sounds.played, isEmpty);

    // Another thread, own request, failed: chimes once despite two events.
    final payload = {
      'workRequestId': 'r1',
      'threadId': 'other',
      'requestedByUserId': 'user-me',
      'status': 'failed',
    };
    await emit({'type': 'work_request.failed', 'payload': payload});
    await emit({'type': 'thread.failed', 'payload': payload});
    expect(sounds.played, [AxSoundKind.requestCompleted]);

    // A notification-only event chimes.
    await emit({
      'type': 'thread.needs_input',
      'payload': {'threadId': 'other', 'prompt': 'Need input'},
    });
    expect(sounds.played.length, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
      'mute option in settings silences both messages and completed requests',
      (tester) async {
    final sounds = TestSoundNotifications();
    final realtime = TestRealtime();
    final source = _SoundNotificationSource();
    String? rawPrefs;
    final store = ViewPreferencesStore(
      read: () => rawPrefs,
      write: (v) => rawPrefs = v,
    );
    // Sound is muted
    store.save(const ViewPreferences(muteSound: true));

    await tester.pumpWidget(MaterialApp(
      home: SyntilaAppShell(
        services: const DefaultPlatformServices(),
        dataSource: source,
        realtimeClient: realtime,
        soundNotifications: sounds,
        viewPreferencesStore: store,
        initialUri: Uri.parse('/'),
      ),
    ));
    await tester.pumpAndSettle();

    // Incoming message
    realtime.emit({
      'type': 'discussion.created',
      'payload': {
        'threadId': 'thread-1',
        'authorUserId': 'user-other',
        'text': 'Hello',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Request completed
    realtime.emit({
      'type': 'work_request.completed',
      'payload': {
        'workRequestId': 'req-1',
        'threadId': 'thread-1',
        'status': 'completed',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Both should be muted
    expect(sounds.played, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
