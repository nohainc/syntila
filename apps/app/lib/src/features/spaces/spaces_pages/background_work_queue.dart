part of '../spaces_pages.dart';

/// Sends a Thread's queued Work messages while its page is not open.
///
/// The open Thread page owns its queue and dispatches it as presentation
/// updates arrive. When the page is left with messages still waiting, this
/// sender takes over: it re-reads the Thread's requests on a short interval
/// and submits the next message once nothing is processing. It stops when the
/// queue empties, is paused, or the page for that Thread opens again.
class _BackgroundWorkQueue {
  _BackgroundWorkQueue._(
      this.key, this.threadId, this.cache, this.submit, this.interval);

  static final _senders = <String, _BackgroundWorkQueue>{};

  /// Queue keys whose Thread page is open and dispatching itself.
  static final _owners = <String>{};

  final String key;
  final String threadId;
  final AxWorkHistoryCache cache;
  final Future<void> Function(_QueuedWorkMessage message) submit;
  final Duration interval;
  Timer? _timer;
  bool _sending = false;

  /// Whether a background send for [key] is in flight.
  static bool isSending(String key) => _senders[key]?._sending ?? false;

  static void claim(String key) => _owners.add(key);

  /// Releases [key] from its page and keeps sending its remaining messages.
  static void release(
    String key, {
    required String threadId,
    required AxWorkHistoryCache cache,
    required Future<void> Function(_QueuedWorkMessage message) submit,
    Duration interval = const Duration(seconds: 3),
  }) {
    _owners.remove(key);
    if (_senders.containsKey(key) || !_hasWork(key)) return;
    final sender =
        _BackgroundWorkQueue._(key, threadId, cache, submit, interval);
    _senders[key] = sender;
    sender._timer = Timer.periodic(interval, (_) => sender._tick());
  }

  @visibleForTesting
  static void reset() {
    for (final sender in _senders.values.toList()) {
      sender._stop();
    }
    _owners.clear();
  }

  static bool _hasWork(String key) =>
      (_ThreadPageState._queuedWorkByThread[key]?.isNotEmpty ?? false) &&
      _ThreadPageState._workQueuePauses[key] == null;

  void _stop() {
    _timer?.cancel();
    if (identical(_senders[key], this)) _senders.remove(key);
  }

  Future<void> _tick() async {
    if (_sending) return;
    if (_owners.contains(key) || !_hasWork(key)) {
      _stop();
      return;
    }
    _sending = true;
    try {
      final history = await cache.refresh(threadId);
      final processing = history.requests.any((request) =>
          !request.id.startsWith('local-') &&
          request.isProcessing);
      // The page may have opened, or the queue changed, while reading.
      if (processing || _owners.contains(key) || !_hasWork(key)) return;
      final queue = _ThreadPageState._queuedWorkByThread[key]!;
      final message = queue.removeAt(0);
      try {
        await submit(message);
        if (!_hasWork(key)) _stop();
      } catch (error) {
        if (error is AxMutationSuperseded) return;
        // Keep it first in line; the user resumes from the Thread.
        queue.insert(0, message);
        _ThreadPageState._workQueuePauses[key] = _WorkQueuePause.failure;
        _stop();
      }
    } catch (_) {
      // A failed read retries on the next tick.
    } finally {
      _sending = false;
    }
  }
}
