import 'sound_notifications_stub.dart'
    if (dart.library.js_interop) 'sound_notifications_web.dart' as platform;

/// Kinds of sounds the application plays for events.
enum AxSoundKind {
  /// Incoming message from another user or participant.
  messageReceived,

  /// An AI work request has completed.
  requestCompleted,
}

/// Plays audio chimes for application events like incoming messages and request completions.
abstract interface class AxSoundNotifications {
  void play(AxSoundKind kind);

  void playMessageReceived() => play(AxSoundKind.messageReceived);

  void playRequestCompleted() => play(AxSoundKind.requestCompleted);
}

AxSoundNotifications createAxSoundNotifications() =>
    platform.createAxSoundNotifications();
