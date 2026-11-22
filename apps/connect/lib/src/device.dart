import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Machine-wide identity for this computer (`device.json`).
///
/// The [deviceId] is generated once and never changes; [deviceName] defaults to
/// the OS hostname and can be renamed by the owner without affecting [deviceId].
class DeviceInfo {
  const DeviceInfo({required this.deviceId, required this.deviceName});

  final String deviceId;
  final String deviceName;

  Map<String, String> toJson() => {
    'deviceId': deviceId,
    'deviceName': deviceName,
  };
}

class DeviceStore {
  DeviceStore(this.file, {String? Function()? defaultHostname})
    : _defaultHostname = defaultHostname ?? (() => Platform.localHostname);

  final File file;
  final String? Function() _defaultHostname;

  static final _idPattern = RegExp(r'^dev-[0-9a-f]{16}$');

  static String _newId() {
    final random = Random.secure();
    final bytes = [for (var i = 0; i < 8; i++) random.nextInt(256)];
    return 'dev-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  String _fallbackName() {
    final host = _defaultHostname()?.trim();
    if (host != null && host.isNotEmpty) return host;
    return 'Syntila Device';
  }

  Future<DeviceInfo?> load() async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final id = decoded['deviceId'];
      final name = decoded['deviceName'];
      if (id is! String || !_idPattern.hasMatch(id)) return null;
      final resolvedName = name is String && name.trim().isNotEmpty
          ? name.trim()
          : _fallbackName();
      return DeviceInfo(deviceId: id, deviceName: resolvedName);
    } on FormatException {
      return null;
    }
  }

  Future<void> _write(DeviceInfo info) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(info.toJson()), flush: true);
    await temp.rename(file.path);
  }

  /// Returns the existing device identity, or creates one with an immutable
  /// [DeviceInfo.deviceId] and [defaultName] (falling back to the OS hostname).
  Future<DeviceInfo> ensure({String? defaultName}) async {
    final existing = await load();
    if (existing != null) return existing;
    final trimmed = defaultName?.trim();
    final info = DeviceInfo(
      deviceId: _newId(),
      deviceName: (trimmed != null && trimmed.isNotEmpty)
          ? trimmed
          : _fallbackName(),
    );
    await _write(info);
    return info;
  }

  /// Renames this device while keeping [DeviceInfo.deviceId] immutable.
  Future<DeviceInfo> setName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 128) {
      throw const FormatException('device name must be 1 to 128 characters');
    }
    final current = await ensure();
    final updated = DeviceInfo(deviceId: current.deviceId, deviceName: trimmed);
    await _write(updated);
    return updated;
  }
}
