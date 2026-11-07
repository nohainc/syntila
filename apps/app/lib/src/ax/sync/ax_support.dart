/// The caller's personal support Space and its account-level sidebar setting.
class AxSupportSpace {
  const AxSupportSpace({required this.spaceId, required this.hidden});
  final String? spaceId;
  final bool hidden;
}

abstract interface class AxSupportDataSource {
  /// Read the support Space without provisioning it.
  Future<AxSupportSpace> loadSupportSpace();

  /// Get or create the support Space; safe to retry.
  Future<AxSupportSpace> ensureSupportSpace();

  /// Persist the caller's sidebar visibility for the support Space.
  Future<void> setSpaceHidden({required String spaceId, required bool hidden});
}

/// Opens the support Space on demand and makes it visible in the sidebar.
class AxSupportEntry {
  AxSupportEntry(this.source);
  final AxSupportDataSource source;

  /// Current account-level visibility, without provisioning the Space.
  Future<AxSupportSpace> load() => source.loadSupportSpace();

  Future<String> open() async {
    final space = await source.ensureSupportSpace();
    final id = space.spaceId;
    if (id == null) throw StateError('Support Space is unavailable');
    await source.setSpaceHidden(spaceId: id, hidden: false);
    return id;
  }

  /// Show or hide support in the sidebar, provisioning it first if needed.
  Future<AxSupportSpace> setSidebarVisible(bool visible) async {
    final space = await source.ensureSupportSpace();
    final id = space.spaceId;
    if (id == null) throw StateError('Support Space is unavailable');
    await source.setSpaceHidden(spaceId: id, hidden: !visible);
    return AxSupportSpace(spaceId: id, hidden: !visible);
  }
}
