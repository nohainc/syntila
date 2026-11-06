import 'package:web/web.dart' as web;

import 'sound_notifications.dart';

AxSoundNotifications createAxSoundNotifications() => WebAxSoundNotifications();

/// Web Audio API synthesized chimes for browser environments.
class WebAxSoundNotifications implements AxSoundNotifications {
  web.AudioContext? _context;

  web.AudioContext? _getOrCreateContext() {
    try {
      return _context ??= web.AudioContext();
    } catch (_) {
      return null;
    }
  }

  @override
  void play(AxSoundKind kind) {
    try {
      final ctx = _getOrCreateContext();
      if (ctx == null) return;
      if (ctx.state == 'suspended') {
        ctx.resume();
      }
      final now = ctx.currentTime;
      switch (kind) {
        case AxSoundKind.messageReceived:
          // Pleasant 2-tone chime: D5 (587.33 Hz) -> A5 (880 Hz)
          _playTone(ctx, 587.33, now, 0.08);
          _playTone(ctx, 880.0, now + 0.08, 0.12);
        case AxSoundKind.requestCompleted:
          // Ascending 3-tone chime: C5 (523.25 Hz) -> E5 (659.25 Hz) -> G5 (783.99 Hz)
          _playTone(ctx, 523.25, now, 0.08);
          _playTone(ctx, 659.25, now + 0.07, 0.08);
          _playTone(ctx, 783.99, now + 0.14, 0.18);
      }
    } catch (_) {}
  }

  void _playTone(web.AudioContext ctx, double freq, num start, num duration) {
    try {
      final osc = ctx.createOscillator();
      final gain = ctx.createGain();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(freq, start);
      gain.gain.setValueAtTime(0.12, start);
      gain.gain.exponentialRampToValueAtTime(0.001, start + duration);
      osc.connect(gain);
      gain.connect(ctx.destination);
      osc.start(start);
      osc.stop(start + duration);
    } catch (_) {}
  }

  @override
  void playMessageReceived() => play(AxSoundKind.messageReceived);

  @override
  void playRequestCompleted() => play(AxSoundKind.requestCompleted);
}
