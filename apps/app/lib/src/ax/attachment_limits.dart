import 'ax_data.dart' show AxAccountPlan;
import 'ax_files.dart';

/// Per-request attachment limits shared by the Ask AI and Message composers.
/// Cloud enforces every bound; these only give earlier, per-file feedback.
const maxAttachmentCount = 10;

/// The signed-in account's upload limits as Cloud last reported them. Until
/// Cloud answers the Free limits apply, the safe side; the server is still the
/// authority, so a stale value can only cost a rejected upload.
class AxAttachmentPolicy {
  AxAttachmentPolicy._();

  static final AxAttachmentPolicy instance = AxAttachmentPolicy._();

  static const freeFileBytes = 25000000;
  static const freeStorageBytes = 1000000000;

  int maxFileBytes = freeFileBytes;
  int storageBytes = freeStorageBytes;

  /// Retained plus in-flight bytes, once My Files or an upload has reported it.
  int? usedBytes;

  /// Room left for new uploads, or null when usage is not known yet.
  int? get availableBytes => usedBytes == null
      ? null
      : (storageBytes - usedBytes!).clamp(0, storageBytes).toInt();

  void updateFromPlan(AxAccountPlan plan) {
    maxFileBytes = plan.attachmentMaxFileBytes ?? maxFileBytes;
    storageBytes = plan.attachmentStorageBytes ?? storageBytes;
  }

  void updateFromUsage(AxStorageUsage usage) {
    if (usage.quotaBytes > 0) storageBytes = usage.quotaBytes;
    if (usage.maxFileBytes > 0) maxFileBytes = usage.maxFileBytes;
    usedBytes = usage.usedBytes + usage.reservedBytes;
  }

  void reset() {
    maxFileBytes = freeFileBytes;
    storageBytes = freeStorageBytes;
    usedBytes = null;
  }

  /// Shown beside "Add files". Upload allowance is separate from what a Worker
  /// can read, and Syntila does not check that before sending.
  String get hint =>
      'Up to $maxAttachmentCount files, each up to ${formatFileSize(maxFileBytes)}. '
      'Whether a Worker can read a file depends on the Worker and the file type.';
}

/// Which of a multi-file selection fit alongside [existing] attachments.
class AttachmentAdmission {
  const AttachmentAdmission(this.accepted, this.skipped);

  /// Indexes into the candidate list, in selection order.
  final List<int> accepted;

  /// Human-readable reasons, one per skipped file.
  final List<String> skipped;

  /// A single notice for the skipped files, or null when all were admitted.
  String? get notice {
    if (skipped.isEmpty) return null;
    const shown = 3;
    final listed = skipped.take(shown).join('; ');
    final more =
        skipped.length > shown ? ' and ${skipped.length - shown} more' : '';
    return 'Skipped ${skipped.length} '
        '${skipped.length == 1 ? 'file' : 'files'}: $listed$more.';
  }
}

/// Admits files in order. A file over the plan's per-file limit ("too large")
/// is told apart from one that no longer fits the remaining storage ("storage
/// full"), and files beyond the remaining slots are skipped without rejecting
/// the rest.
AttachmentAdmission admitAttachments({
  required int existing,
  required List<({String name, int sizeBytes})> candidates,
  int? maxFileBytes,
  int? availableBytes,
}) {
  final limit = maxFileBytes ?? AxAttachmentPolicy.instance.maxFileBytes;
  var remaining = availableBytes ?? AxAttachmentPolicy.instance.availableBytes;
  final accepted = <int>[];
  final skipped = <String>[];
  for (final (index, file) in candidates.indexed) {
    if (file.sizeBytes > limit) {
      skipped.add(
          '"${file.name}" is too large (over ${formatFileSize(limit)} per file)');
    } else if (existing + accepted.length >= maxAttachmentCount) {
      skipped.add('"${file.name}" exceeds the $maxAttachmentCount-file limit');
    } else if (remaining != null && file.sizeBytes > remaining) {
      skipped.add('"${file.name}" does not fit: storage is full');
    } else {
      accepted.add(index);
      if (remaining != null) remaining -= file.sizeBytes;
    }
  }
  return AttachmentAdmission(accepted, skipped);
}
