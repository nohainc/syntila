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
        'status': 'completed',
      },
    });
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(sounds.played, [AxSoundKind.requestCompleted]);

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
