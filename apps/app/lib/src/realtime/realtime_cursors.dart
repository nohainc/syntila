/// The last durable sequence this client applied for each stream. A cursor says
/// "everything up to here is applied", so the server can replay what was missed
/// instead of making the client reload (syntila.messaging/1, ADR-038).
///
/// A Thread stream is a slice of its Space stream and is numbered by the Space
/// sequence, so its cursor is not gapless; the server decides what can resume.
class RealtimeCursors {
  final _applied = <String, int>{};

  static String key(String kind, String id) => '$kind:$id';

  /// Moves the cursor forward only; an older or repeated sequence changes nothing.
  void record(String kind, String id, int sequence) {
    if (sequence < 0) return;
    final k = key(kind, id);
    if (sequence > (_applied[k] ?? -1)) _applied[k] = sequence;
  }

  int? of(String kind, String id) => _applied[key(kind, id)];
}
