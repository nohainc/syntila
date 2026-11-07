import 'dart:convert';

/// Local-only state for reopening a Thread in the same place.
///
/// This object is deliberately separate from Cloud-backed Thread data. Draft
/// text is never included in a request until the user submits it.
class AxThreadViewState {
  const AxThreadViewState({
    this.tabIndex = 0,
    this.workflowReference,
    this.workerId,
    this.workerTypeId,
    this.model,
    this.reasoningEffort,
    this.catalogRevision,
    this.selectionUpdatedAt,
    this.chatDraft = '',
    this.workDraft = '',
    this.chatSeenId,
    this.workSeenId,
    this.pane,
  });

  final int tabIndex;
  final String? workflowReference;
  final String? workerId;

  /// Stable Worker code; unlike [workerId] it survives a Worker rebuild.
  final String? workerTypeId;
  final String? model;
  final String? reasoningEffort;
  final String? catalogRevision;

  /// When the user last changed the Workflow/Worker/model selection (UTC
  /// ISO-8601). Decides between the local and Cloud copies on restore.
  final String? selectionUpdatedAt;
  final String chatDraft;
  final String workDraft;

  /// Last Chat message / Work item the reader had fully seen. Local only;
  /// opening a tab scrolls to the first item after it.
  final String? chatSeenId;
  final String? workSeenId;

  /// Last open Thread pane: [conversationPane], [aiHistoryPane] or
  /// [notesPane]. Local only, like the drafts.
  final String? pane;

  static const conversationPane = 'conversation';
  static const aiHistoryPane = 'aiHistory';
  static const notesPane = 'notes';
  static const _panes = {conversationPane, aiHistoryPane, notesPane};

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'tabIndex': tabIndex.clamp(0, 1),
        if (workflowReference != null) 'workflowReference': workflowReference,
        if (workerId != null) 'workerId': workerId,
        if (workerTypeId != null) 'workerTypeId': workerTypeId,
        if (model != null) 'model': model,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (catalogRevision != null) 'catalogRevision': catalogRevision,
        if (selectionUpdatedAt != null)
          'selectionUpdatedAt': selectionUpdatedAt,
        if (chatDraft.isNotEmpty) 'chatDraft': _bounded(chatDraft),
        if (workDraft.isNotEmpty) 'workDraft': _bounded(workDraft),
        if (chatSeenId != null) 'chatSeenId': chatSeenId,
        if (workSeenId != null) 'workSeenId': workSeenId,
        if (pane != null) 'pane': pane,
      };

  /// Thread metadata wins over the browser-local copy for the selection
  /// unless the local selection is newer; the drafts and the tab (composer mode)
  /// stay local because they are never shared through Cloud.
  static AxThreadViewState? withRemote(
      AxThreadViewState? local, Map<String, dynamic> remote) {
    if (remote.isEmpty) return local;
    String? string(String key) {
      final value = remote[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    // A local selection newer than the Cloud copy wins: the Cloud write may
    // have failed, or the Thread list may predate it.
    final localAt = DateTime.tryParse(local?.selectionUpdatedAt ?? '');
    final remoteAt = DateTime.tryParse(string('selectionUpdatedAt') ?? '');
    if (local != null &&
        localAt != null &&
        (remoteAt == null || localAt.isAfter(remoteAt))) {
      return local;
    }

    final tab = remote['tabIndex'];
    return AxThreadViewState(
      // The tab is the composer mode, so it stays with the local drafts: a
      // Cloud tab differing from this browser's would restore a draft into
      // the hidden composer.
      tabIndex: local?.tabIndex ?? (tab is int ? tab.clamp(0, 1) : 0),
      workflowReference: string('workflowReference'),
      workerId: string('workerId'),
      workerTypeId: string('workerTypeId') ??
          (local?.workerId == string('workerId') ? local?.workerTypeId : null),
      model: string('model'),
      reasoningEffort: string('reasoningEffort'),
      catalogRevision: string('catalogRevision'),
      selectionUpdatedAt: string('selectionUpdatedAt'),
      chatDraft: local?.chatDraft ?? '',
      workDraft: local?.workDraft ?? '',
      chatSeenId: local?.chatSeenId,
      workSeenId: local?.workSeenId,
      pane: local?.pane,
    );
  }

  factory AxThreadViewState.fromJson(Map<String, dynamic> json) {
    String? string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) return null;
      return value;
    }

    String draft(String key) {
      final value = json[key];
      return value is String ? _bounded(value) : '';
    }

    final tab = json['tabIndex'];
    return AxThreadViewState(
      tabIndex: tab is int ? tab.clamp(0, 1) : 0,
      workflowReference: string('workflowReference'),
      workerId: string('workerId'),
      workerTypeId: string('workerTypeId'),
      model: string('model'),
      reasoningEffort: string('reasoningEffort'),
      catalogRevision: string('catalogRevision'),
      selectionUpdatedAt: string('selectionUpdatedAt'),
      chatDraft: draft('chatDraft'),
      workDraft: draft('workDraft'),
      chatSeenId: string('chatSeenId'),
      workSeenId: string('workSeenId'),
      pane: _panes.contains(json['pane']) ? json['pane'] as String : null,
    );
  }

  static String _bounded(String value) =>
      value.length <= 200000 ? value : value.substring(value.length - 200000);

  String encode() => jsonEncode(toJson());
  static AxThreadViewState? decode(String value) {
    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? AxThreadViewState.fromJson(Map<String, dynamic>.from(decoded))
          : null;
    } catch (_) {
      return null;
    }
  }
}
