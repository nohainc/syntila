/// A file the signed-in user uploaded to a Thread. Files belong to their
/// uploader and count toward [AxStorageUsage.quotaBytes] until deleted.
/// [threadId] is null when the Thread was deleted or the user left its Space.
class AxUserFile {
  const AxUserFile({
    required this.fileId,
    required this.name,
    required this.mediaType,
    required this.sizeBytes,
    required this.createdAt,
    this.threadId,
    this.spaceId,
    this.threadName,
    this.spaceName,
    this.inUse = false,
  });

  factory AxUserFile.fromJson(Map<String, dynamic> json) => AxUserFile(
        fileId: json['fileId']?.toString() ?? '',
        name: json['name']?.toString() ?? 'Attachment',
        mediaType: json['mediaType']?.toString() ?? '',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        createdAt: json['createdAt']?.toString() ?? '',
        threadId: json['threadId']?.toString(),
        spaceId: json['spaceId']?.toString(),
        threadName: json['threadName']?.toString(),
        spaceName: json['spaceName']?.toString(),
        inUse: json['inUse'] == true,
      );

  final String fileId;
  final String name;
  final String mediaType;
  final int sizeBytes;
  final String createdAt;
  final String? threadId;
  final String? spaceId;
  final String? threadName;
  final String? spaceName;

  /// A message or Work Request cites the file; deleting it breaks downloads
  /// there.
  final bool inUse;

  /// `Space > Thread`, or null when the Thread is unavailable.
  String? get path => threadId == null
      ? null
      : [spaceName, threadName]
          .map((name) => name?.trim() ?? '')
          .where((name) => name.isNotEmpty)
          .join(' > ');
}

class AxStorageUsage {
  const AxStorageUsage({
    required this.usedBytes,
    required this.fileCount,
    required this.quotaBytes,
    this.reservedBytes = 0,
    this.maxFileBytes = 0,
  });

  factory AxStorageUsage.fromJson(Map<String, dynamic> json) => AxStorageUsage(
        usedBytes: (json['usedBytes'] as num?)?.toInt() ?? 0,
        fileCount: (json['fileCount'] as num?)?.toInt() ?? 0,
        quotaBytes: (json['quotaBytes'] as num?)?.toInt() ?? 0,
        reservedBytes: (json['reservedBytes'] as num?)?.toInt() ?? 0,
        maxFileBytes: (json['maxFileBytes'] as num?)?.toInt() ?? 0,
      );

  final int usedBytes;
  final int fileCount;
  final int quotaBytes;

  /// Bytes held by uploads still in flight; they count against free room.
  final int reservedBytes;

  /// The signed-in user's individual-file limit on their current plan.
  final int maxFileBytes;

  /// Free room for new uploads (never negative).
  int get availableBytes =>
      (quotaBytes - usedBytes - reservedBytes).clamp(0, quotaBytes).toInt();

  /// True once new uploads cannot be admitted; existing files stay usable.
  bool get isFull => quotaBytes > 0 && usedBytes + reservedBytes >= quotaBytes;

  /// True when usage passed the warning threshold (80%).
  bool get nearLimit => quotaBytes > 0 && fraction >= 0.8;

  double get fraction =>
      quotaBytes <= 0 ? 0 : (usedBytes / quotaBytes).clamp(0, 1).toDouble();
}

class AxUserFilesPage {
  const AxUserFilesPage(
      {required this.files, required this.usage, this.nextCursor});

  final List<AxUserFile> files;
  final AxStorageUsage usage;

  /// Pass to [AxUserFilesDataSource.loadUserFiles] for older files.
  final String? nextCursor;
}

/// Optional capability: the signed-in user's uploaded files and quota.
abstract interface class AxUserFilesDataSource {
  Future<AxUserFilesPage> loadUserFiles({String? before});

  /// Retrieves the original bytes of an uploaded file.
  Future<List<int>> downloadUserFile(String fileId);

  Future<void> syncUserFiles();

  /// Deletes the file's bytes and returns the updated usage.
  Future<AxStorageUsage> deleteUserFile(String fileId);
}

/// `1.5 MB`-style size label in decimal units (1 MB = 1,000,000 bytes), the
/// same units as the upload limits.
String formatFileSize(int bytes) {
  const units = ['B', 'kB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final digits = unit == 0 || value >= 10 ? 0 : 1;
  final text = value.toStringAsFixed(digits).replaceFirst(RegExp(r'\.0$'), '');
  return '$text ${units[unit]}';
}
