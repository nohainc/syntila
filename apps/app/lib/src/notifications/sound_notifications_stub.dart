import 'package:flutter/services.dart';

import 'sound_notifications.dart';

AxSoundNotifications createAxSoundNotifications() =>
    const StubAxSoundNotifications();

/// System sound fallback for desktop, mobile, and test environments.
class StubAxSoundNotifications implements AxSoundNotifications {
  const StubAxSoundNotifications();

  @override
  void play(AxSoundKind kind) {
    try {
      SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  @override
  void playMessageReceived() => play(AxSoundKind.messageReceived);

  @override
  void playRequestCompleted() => play(AxSoundKind.requestCompleted);
}
