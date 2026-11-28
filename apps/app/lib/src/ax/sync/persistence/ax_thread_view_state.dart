import 'dart:convert';

/// State for reopening a Thread in the same place.
///
/// Two owners, never merged: the Workflow/Worker/model/effort selection
/// ([workflowReference], [workerId], [workerTypeId], [model],
/// [reasoningEffort], [catalogRevision]) belongs to Cloud and is only filled in
/// by [restore]; everything else is device-local and is all that [toJson]
/// writes. Draft text is never included in a request until the user submits
/// it.
class AxThreadViewState {
  const AxThreadViewState({
    this.tabIndex = 0,
    this.workflowReference,
    this.workerId,
    this.workerTypeId,
    this.model,
    this.reasoningEffort,
    this.catalogRevision,
    this.chatDraft = '',
    this.workDraft = '',
    this.chatSeenId,
    this.workSeenId,
    this.chatResumeId,
    this.workResumeId,
    this.pane,
    this.workflowSelections = const {},
    this.stepSelections = const {},
    this.researcherCount,
  });

  final int tabIndex;
  final String? workflowReference;
  final String? workerId;

  /// Stable Worker code; unlike [workerId] it survives a Worker rebuild.
  final String? workerTypeId;
  final String? model;
  final String? reasoningEffort;
  final String? catalogRevision;

  final String chatDraft;
  final String workDraft;

  /// Last Chat message / Work item the reader had fully seen. Local only;
  /// opening a tab scrolls to the first item after it.
  final String? chatSeenId;
  final String? workSeenId;

  /// The item at the top of the viewport when the reader last left a timeline
  /// scrolled away from its end; null when it was at the end. Reopening puts
  /// it back at the top. Separate from the seen markers, which decide what is
  /// unread.
  final String? chatResumeId;
  final String? workResumeId;

  /// Last open Thread pane: [conversationPane], [aiHistoryPane] or
  /// [notesPane]. Local only, like the drafts.
  final String? pane;

  /// Last Worker/model/effort per Workflow code (chat, work, ...). Local
  /// only: it is a per-browser convenience, not Thread data, so the Cloud
  /// copy keeps just the active selection.
  final Map<String, Map<String, String>> workflowSelections;

  /// Per-step Worker/model/effort of the active multi-step Workflow (Research,
  /// Plan & Implement), keyed by step id, and the chosen researcher count.
  /// Local only, like [workflowSelections].
  final Map<String, Map<String, String>> stepSelections;
  final int? researcherCount;

  static const conversationPane = 'conversation';
  static const aiHistoryPane = 'aiHistory';
  static const notesPane = 'notes';
  static const _panes = {conversationPane, aiHistoryPane, notesPane};

  /// What is written to Cloud: the selection only, every key present so a
  /// cleared choice (null) clears it there too.
  Map<String, dynamic> get cloudSelection => {
        'workflowReference': workflowReference,
        'workerId': workerId,
        'workerTypeId': workerTypeId,
        'model': model,
        'reasoningEffort': reasoningEffort,
        'catalogRevision': catalogRevision,
      };

  /// The device-local part only. [workflowReference] is kept as the owner of
  /// [stepSelections] and [researcherCount], not as the Thread's selection.
  Map<String, dynamic> toJson() => {
        'schemaVersion': 2,
        'tabIndex': tabIndex.clamp(0, 1),
        if (workflowReference != null) 'workflowReference': workflowReference,
        if (chatDraft.isNotEmpty) 'chatDraft': _bounded(chatDraft),
        if (workDraft.isNotEmpty) 'workDraft': _bounded(workDraft),
        if (chatSeenId != null) 'chatSeenId': chatSeenId,
        if (workSeenId != null) 'workSeenId': workSeenId,
        if (chatResumeId != null) 'chatResumeId': chatResumeId,
        if (workResumeId != null) 'workResumeId': workResumeId,
        if (pane != null) 'pane': pane,
        if (workflowSelections.isNotEmpty)
          'workflowSelections': workflowSelections,
        if (stepSelections.isNotEmpty) 'stepSelections': stepSelections,
        if (researcherCount != null) 'researcherCount': researcherCount,
      };

  /// The Cloud `viewState` is the only source of the selection. The local copy
  /// supplies everything else (tab, drafts, markers, pane, per-Workflow
  /// choices); the tab is the composer mode and stays with the local drafts.
  /// Step choices belong to one Workflow, so they survive only while Cloud
  /// names the Workflow they were made for.
  static AxThreadViewState? restore(
      AxThreadViewState? local, Map<String, dynamic> remote) {
    String? string(String key) {
      final value = remote[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    final workflowReference = string('workflowReference');
    final sameWorkflow = local?.workflowReference == workflowReference;
    return AxThreadViewState(
      tabIndex: local?.tabIndex ?? 0,
      workflowReference: workflowReference,
      workerId: string('workerId'),
      workerTypeId: string('workerTypeId'),
      model: string('model'),
      reasoningEffort: string('reasoningEffort'),
      catalogRevision: string('catalogRevision'),
      chatDraft: local?.chatDraft ?? '',
      workDraft: local?.workDraft ?? '',
      chatSeenId: local?.chatSeenId,
      workSeenId: local?.workSeenId,
      chatResumeId: local?.chatResumeId,
      workResumeId: local?.workResumeId,
      pane: local?.pane,
      workflowSelections: local?.workflowSelections ?? const {},
      stepSelections:
          sameWorkflow ? local?.stepSelections ?? const {} : const {},
      researcherCount: sameWorkflow ? local?.researcherCount : null,
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
      chatDraft: draft('chatDraft'),
      workDraft: draft('workDraft'),
      chatSeenId: string('chatSeenId'),
      workSeenId: string('workSeenId'),
      chatResumeId: string('chatResumeId'),
      workResumeId: string('workResumeId'),
      pane: _panes.contains(json['pane']) ? json['pane'] as String : null,
      workflowSelections: _selections(json['workflowSelections']),
      stepSelections: _selections(json['stepSelections']),
      researcherCount:
          json['researcherCount'] is int && (json['researcherCount'] as int) > 0
              ? json['researcherCount'] as int
              : null,
    );
  }

  static Map<String, Map<String, String>> _selections(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, Map<String, String>>{};
    raw.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final entry = <String, String>{
        for (final e in value.entries)
          if (e.key is String && e.value is String && e.value != '')
            e.key as String: e.value as String,
      };
      if (entry.isNotEmpty) result[key] = entry;
    });
    return result;
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
