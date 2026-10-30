part of '../spaces_pages.dart';

String _modelDisplayName(String? modelId, {AxWorker? worker}) {
  if (modelId == null || modelId.trim().isEmpty) return '';
  return worker?.executionOptions?.models
          .where((m) => m.id == modelId)
          .firstOrNull
          ?.name ??
      modelId;
}

// Execution diagnostics remain in Workspace/Engine logs, not conversation text.
String _executionFailureMessage(String? code, {String? validationMessage}) =>
    switch (code) {
      'context_limit_exceeded' =>
        'This conversation no longer fits the AI model’s context window. Retry to compact the Worker session or to clear AI History.',
      'session_resume_failed' =>
        'The worker could not continue the previous conversation. Please retry your request.',
      'worker_not_ready' =>
        'The selected worker is not ready on its workspace.',
      'space_folder_exists' => 'Retry to choose whether to use it.',
      'cli_not_found' ||
      'provider_tool_unavailable' =>
        'The worker needs to be set up on its workspace before it can respond.',
      'authentication_required' ||
      'provider_authentication_required' =>
        'Sign in to the worker on its workspace, then retry your request.',
      'unsupported_cli_version' ||
      'unsupported_provider_tool_version' =>
        'Update the worker on its workspace, then retry your request.',
      'model_not_supported' =>
        'The selected model is not available for this worker. Choose another model and retry.',
      'permission_denied' =>
        'The worker does not have the access needed to complete your request.',
      'quota_exhausted' =>
        'The provider’s usage limit has been reached. Wait for the limit to reset or choose another worker, then retry.',
      'provider_unavailable' =>
        'The worker is temporarily unavailable. Please try again later.',
      'timeout' ||
      'deadline_exceeded' =>
        'The worker took too long to respond. Please retry your request.',
      'cancelled' => 'Request cancelled.',
      null => validationMessage ??
          'Your request could not be completed. Please retry.',
      _ => 'Your request could not be completed. Please retry.',
    };

/// Cloud's fixed public failure category, with the code-specific guidance
/// appended only when the code says more than the category already does.
String _publicFailureMessage(AxWorkRequestStep? step, String guidance) {
  if (step?.errorCode == 'context_limit_exceeded' ||
      step?.errorCode == 'quota_exhausted') {
    return guidance;
  }
  final headline = step?.failureCategoryMessage?.trim();
  if (headline == null || headline.isEmpty) return guidance;
  final code = step?.errorCode;
  if (code == null ||
      code == 'execution_failed' ||
      code == 'timeout' ||
      code == 'context_limit_exceeded') {
    return headline;
  }
  return '$headline. $guidance';
}

Future<T?> _showAnchoredMenu<T>({
  required BuildContext buttonContext,
  required List<PopupMenuEntry<T>> items,
  required double itemHeight,
  int dividerCount = 0,
}) async {
  final isDark = Theme.of(buttonContext).brightness == Brightness.dark;
  final box = buttonContext.findRenderObject()! as RenderBox;
  // showMenu positions against the Navigator's overlay, so measure there.
  final overlay = Navigator.of(buttonContext)
      .overlay!
      .context
      .findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final anchorBottom = rect.top - 8;
  final availableHeight = (anchorBottom - 8).clamp(0.0, overlay.size.height);
  // Measure the real rows offstage; fixed per-row estimates drift with
  // density and icon sizes.
  final measureKey = GlobalKey();
  final entry = OverlayEntry(
    builder: (_) => Offstage(
      child: Align(
        alignment: Alignment.topLeft,
        child: Material(
          child: Theme(
            data: Theme.of(buttonContext),
            child: Padding(
              key: measureKey,
              padding: SyntilaMenuStyle.padding,
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in items)
                      item is SyntilaMenuEntry<T>
                          ? item.child
                          : SizedBox(height: item.height),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Overlay.of(buttonContext).insert(entry);
  await WidgetsBinding.instance.endOfFrame;
  final measured = (measureKey.currentContext?.findRenderObject() as RenderBox?)
          ?.size
          .height ??
      (items.length - dividerCount) * itemHeight + 12.0;
  entry.remove();
  entry.dispose();
  if (!buttonContext.mounted) return null;
  final menuHeight = measured.clamp(0.0, availableHeight);
  return showMenu<T>(
    context: buttonContext,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    color: SyntilaColors.composerBackground(isDark),
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: SyntilaMenuStyle.shadow(isDark),
    shape: SyntilaMenuStyle.shape(isDark),
    menuPadding: SyntilaMenuStyle.padding,
    constraints: BoxConstraints(minHeight: menuHeight, maxHeight: menuHeight),
    position: RelativeRect.fromRect(
      Rect.fromLTWH(rect.left, anchorBottom - menuHeight, rect.width, 0),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

class _WorkComposer extends StatelessWidget {
  const _WorkComposer({
    required this.requestController,
    required this.historyController,
    required this.incomingAnchor,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflow,
    required this.workflowCatalog,
    this.workConfig = const <String, dynamic>{},
    this.spaceWorkers = const <AxWorker>[],
    this.eligibleWorkers = const <AxWorker>[],
    required this.loadingWorkflows,
    required this.workflowCatalogError,
    required this.canExecute,
    required this.workTimeline,
    this.historyResponseOverrides = const {},
    this.onToggleHistoryResponse,
    required this.activityStore,
    required this.realtimeStatus,
    required this.localWorkProgress,
    required this.loadingTimeline,
    required this.timelineError,
    required this.submitError,
    required this.submitting,
    required this.attachments,
    required this.onAddFiles,
    required this.executionSelection,
    required this.onExecutionSelectionChanged,
    required this.onRemoveAttachment,
    required this.hasOlder,
    required this.loadingOlder,
    required this.onLoadOlder,
    required this.onReportIssue,
    required this.reportedIssues,
    required this.reportingIssueIds,
    required this.issueReportErrors,
    required this.onRetryStep,
    required this.onCancelRun,
    required this.onWorkflowChanged,
    required this.onRun,
    this.selectionMissing = false,
    this.onSelectionMissing,
    this.onHistoryNavigate,
    this.historyPrompts,
    this.historyOpenDirection = 1,
    this.onHistorySelected,
    this.onHistoryClosed,
    this.queuedMessages = const [],
    this.queuePause,
    this.onQueuePauseChanged,
    this.onQueuedEdit,
    this.onQueuedRemove,
    this.onQueuedSendNow,
    this.usageController,
    this.leadingControls,
    this.inputHeight,
    this.replyTarget,
    this.onReply,
    this.onClearReply,
  });

  /// The message being replied to, and the actions that set or clear it.
  final AxReplyReference? replyTarget;
  final ValueChanged<AxReplyReference>? onReply;
  final VoidCallback? onClearReply;

  final Widget? leadingControls;
  final ComposerInputHeight? inputHeight;
  final TextEditingController requestController;
  final ScrollController historyController;
  final AxTimelineFollowAnchor incomingAnchor;
  final String? currentUserId;
  final String? currentUserName;
  final String workflow;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final Map<String, dynamic> workConfig;
  final List<AxWorker> spaceWorkers;
  final List<AxWorker> eligibleWorkers;
  final bool loadingWorkflows;
  final String? workflowCatalogError;
  final bool canExecute;
  final List<AxWorkRequest> workTimeline;

  /// AI History: responses the reader opened (true) or closed (false). Others
  /// follow [aiHistoryResponseOpenByDefault].
  final Map<String, bool> historyResponseOverrides;
  final void Function(String requestId, bool open)? onToggleHistoryResponse;
  final AxWorkActivityStore activityStore;
  final AxWorkRealtimeStatus realtimeStatus;
  final Map<String, String> localWorkProgress;
  final bool loadingTimeline;
  final String? timelineError;
  final String? submitError;
  final bool submitting;
  final List<Map<String, dynamic>> attachments;
  final Future<void> Function() onAddFiles;
  final Map<String, dynamic> executionSelection;
  final ValueChanged<Map<String, dynamic>> onExecutionSelectionChanged;
  final ValueChanged<int> onRemoveAttachment;
  final bool hasOlder;
  final bool loadingOlder;
  final Future<void> Function() onLoadOlder;
  final Future<void> Function(String)? onReportIssue;
  final Map<String, AxIssueReport> reportedIssues;
  final Set<String> reportingIssueIds;
  final Map<String, String> issueReportErrors;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;
  final ValueChanged<String> onWorkflowChanged;

  final Future<void> Function() onRun;

  /// A send was blocked because the Worker, model or effort is not chosen;
  /// the selector is outlined in red until the choice is complete.
  final bool selectionMissing;
  final ValueChanged<String>? onSelectionMissing;
  final bool Function(int direction)? onHistoryNavigate;

  /// Newest-first prompts shown in the history panel; null when closed.
  final List<String>? historyPrompts;

  /// Key that opened the panel: -1 (Up) starts on the last item, 1 (Down) on
  /// the first.
  final int historyOpenDirection;
  final ValueChanged<String>? onHistorySelected;
  final VoidCallback? onHistoryClosed;

  /// Messages waiting for the processing request to finish, oldest first.
  final List<_QueuedWorkMessage> queuedMessages;

  /// True after a queued message failed to send; the queue waits for the user.
  final _WorkQueuePause? queuePause;
  final ValueChanged<bool>? onQueuePauseChanged;
  final ValueChanged<_QueuedWorkMessage>? onQueuedEdit;
  final ValueChanged<_QueuedWorkMessage>? onQueuedRemove;
  final ValueChanged<_QueuedWorkMessage>? onQueuedSendNow;

  /// Local view state for the Worker usage card; null when the data source
  /// cannot read usage.
  final AxWorkerUsageController? usageController;

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(child: history(context)),
        const SizedBox(height: 16),
        controls(context)
      ]);

  Widget history(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final empty = workTimeline.isEmpty &&
            !loadingTimeline &&
            timelineError == null
        ? Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 42,
                  color: SyntilaColors.neutral,
                ),
                const SizedBox(height: 12),
                Text(
                  'No work requests yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: SyntilaColors.textSecondary(isDark),
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ask AI to do something for the team. Nothing runs until you send the request.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SyntilaColors.neutral,
                  ),
                ),
              ],
            ),
          )
        : null;
    return AxTimelineContainer(
      scrollKey: const ValueKey('work-history-scroll'),
      controller: historyController,
      headerSlivers: [
        if (hasOlder)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: loadingOlder ? null : onLoadOlder,
              child: Text(loadingOlder
                  ? 'Loading older Work history…'
                  : 'Load older Work history'),
            ),
          ),
        if (loadingTimeline && workTimeline.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: LinearProgressIndicator(),
            ),
          )
        else if (timelineError != null && workTimeline.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Could not load Work history: $timelineError',
                style: TextStyle(color: colors.error),
              ),
            ),
          ),
      ],
      itemCount: workTimeline.length,
      // Read top-down: opening a response grows the list below the tapped
      // request instead of moving it.
      empty: empty,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      findChildIndexCallback: (key) {
        if (key is! ValueKey<String>) return null;
        final index = workTimeline.indexWhere((r) => r.id == key.value);
        return index < 0 ? null : index;
      },
      itemBuilder: (context, index) {
        final request = workTimeline[index];
        return KeyedSubtree(
          key: ValueKey(request.id),
          child: KeyedSubtree(
            key: incomingAnchor.keyFor((request.id, 'request')),
            child: MessageDayBoundary(
              date: DateTime.tryParse(request.createdAt)?.toLocal(),
              previousDate: index == 0
                  ? null
                  : DateTime.tryParse(workTimeline[index - 1].createdAt)
                      ?.toLocal(),
              // The Conversation's request card (request bubble, status and
              // response); AI History only leaves out people's Chat messages.
              // Requests read as a list; tapping one shows or hides its
              // response.
              child: Builder(builder: (context) {
                final open = historyResponseOverrides[request.id] ??
                    aiHistoryResponseOpenByDefault(request);
                // A response seen open while it was processing stays open
                // after it finishes, instead of disappearing.
                if (open &&
                    onToggleHistoryResponse != null &&
                    !historyResponseOverrides.containsKey(request.id)) {
                  historyResponseOverrides[request.id] = true;
                }
                return requestCard(context, request,
                    responseAnchorKey:
                        incomingAnchor.keyFor((request.id, 'response')),
                    showResponse: open,
                    onPromptTap: onToggleHistoryResponse == null
                        ? null
                        : () => onToggleHistoryResponse!(request.id, !open));
              }),
            ),
          ),
        );
      },
    );
  }

  /// The live Work Request card (prompt, Worker status, activity, answer) used
  /// by both the Conversation and AI History.
  Widget requestCard(BuildContext context, AxWorkRequest request,
          {GlobalKey? responseAnchorKey,
          bool showPromptBubble = true,
          bool showResponse = true,
          VoidCallback? onPromptTap}) =>
      ListenableBuilder(
        listenable: Listenable.merge([
          activityStore.listenableForRequest(request),
          AxInputDelivery.instance,
        ]),
        builder: (context, _) => _WorkTimelineCard(
          responseAnchorKey: responseAnchorKey,
          showPromptBubble: showPromptBubble,
          showResponse: showResponse,
          onPromptTap: onPromptTap,
          request: request,
          activities: activityStore.forRequest(request),
          clockOffset: activityStore.clockOffsetForRequest(request),
          realtimeStatus: realtimeStatus,
          // File delivery (Input Delivery v1) precedes the Worker's output.
          progressText: AxInputDelivery.instance.summary(request.id) ??
              localWorkProgress[request.id],
          currentUserId: currentUserId,
          currentUserName: currentUserName,
          workflowCatalog: workflowCatalog,
          onReportIssue:
              localWorkProgress.containsKey(request.id) ? null : onReportIssue,
          reportedIssue: reportedIssues[request.id],
          reportingIssue: reportingIssueIds.contains(request.id),
          issueReportError: issueReportErrors[request.id],
          onRetryStep:
              localWorkProgress.containsKey(request.id) ? null : onRetryStep,
          // Members cancel only their own requests.
          onCancelRun: localWorkProgress.containsKey(request.id) ||
                  (currentUserId != null &&
                      request.requestedByUserId != null &&
                      request.requestedByUserId!.isNotEmpty &&
                      request.requestedByUserId != currentUserId)
              ? null
              : onCancelRun,
          onReply: localWorkProgress.containsKey(request.id) ||
                  request.id.startsWith('local-')
              ? null
              : onReply,
        ),
      );

  Widget controls(BuildContext context) => _buildComposerInput(
      context,
      Theme.of(context).brightness == Brightness.dark,
      Theme.of(context).colorScheme);

  AxBuiltinWorkflow? _selectedWorkflow() =>
      workflowCatalog.where((item) => item.reference == workflow).firstOrNull ??
      workflowCatalog
          .where((item) => item.id == workflow.split(':').first)
          .firstOrNull;

  Map<String, dynamic> _stepBinding() {
    final bindings = workConfig['bindings'] is Map
        ? Map<String, dynamic>.from(workConfig['bindings'] as Map)
        : <String, dynamic>{};
    final stepKind = _selectedWorkflow()?.composerBindingId;
    final rawBinding = stepKind == null ? null : bindings[stepKind];
    return rawBinding is Map
        ? Map<String, dynamic>.from(rawBinding)
        : <String, dynamic>{};
  }

  String? _selectedWorkerId() => (executionSelection.containsKey('workerId')
          ? executionSelection['workerId']
          : _stepBinding()['workerId'])
      ?.toString()
      .trim();

  /// What still has to be chosen before a message can be sent: the Worker,
  /// then a model when the Worker offers models, then an effort when the
  /// chosen model offers efforts. Empty when the selection is complete.
  List<String> _missingSelection() {
    final workerId = _selectedWorkerId() ?? '';
    // With no Worker to choose from, sending reports the Space setup problem
    // from Cloud instead of asking for an impossible choice.
    if (workerId.isEmpty) {
      return eligibleWorkers.isEmpty && spaceWorkers.isEmpty
          ? const []
          : const ['Worker', 'model', 'effort'];
    }
    final binding = _stepBinding();
    String chosen(String key) =>
        (executionSelection.containsKey(key)
                ? executionSelection[key]
                : binding[key])
            ?.toString()
            .trim() ??
        '';
    final model = chosen('model');
    final effort = chosen('reasoningEffort');
    final options = [...eligibleWorkers, ...spaceWorkers]
        .where((worker) => worker.id == workerId)
        .firstOrNull
        ?.executionOptions;
    if (options == null) return const [];
    final missing = <String>[];
    if (options.models.isNotEmpty && model.isEmpty) missing.add('model');
    final efforts = options.models
            .where((option) => option.id == model)
            .firstOrNull
            ?.effort ??
        options.effort;
    if (efforts.supported && efforts.values.isNotEmpty && effort.isEmpty) {
      missing.add('effort');
    }
    return missing;
  }

  static String _missingSelectionMessage(List<String> missing) {
    final names = missing.length == 1
        ? missing.single
        : '${missing.sublist(0, missing.length - 1).join(', ')} and ${missing.last}';
    return 'Select a $names before sending.';
  }

  // Below this width (the space left for the controls beside the + and send
  // buttons, not the whole input) the Chat / Work / More rail plus the Worker
  // selector no longer fit on one line, so the rail becomes one list.
  static const _singleWorkflowListWidth = 300.0;

  Widget _additionalControls(BuildContext context) => LayoutBuilder(
      builder: (context, constraints) => _workflowControls(
          context, constraints.maxWidth < _singleWorkflowListWidth));

  Widget _workflowControls(BuildContext context, bool singleList) {
    final workflows = _currentWorkflowVersions(workflowCatalog);
    final selectedWorkflow = _selectedWorkflow();
    final binding = _stepBinding();
    final policy =
        selectedWorkflow?.executionPolicy ?? const AxWorkflowCapabilities();
    final selectedWorkerId = _selectedWorkerId();
    final selectedModel = (executionSelection.containsKey('model')
                ? executionSelection['model']
                : binding['model'])
            ?.toString()
            .trim() ??
        '';
    final selectedReasoningEffort =
        (executionSelection.containsKey('reasoningEffort')
                    ? executionSelection['reasoningEffort']
                    : binding['reasoningEffort'])
                ?.toString()
                .trim() ??
            '';
    final controlBg = Colors.transparent;
    final colors = Theme.of(context).colorScheme;
    final otherWorkflows = workflows
        .where((item) => !_primaryWorkflowIds.contains(item.id))
        .toList();
    final otherSelected = selectedWorkflow != null &&
        !_primaryWorkflowIds.contains(selectedWorkflow.id);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // All workflow items use normal text; the active item is marked by the
    // page content background (canvas).
    final selectedForeground = colors.onSurface;
    final inactiveForeground = colors.onSurface;
    final activeBackground = SyntilaColors.canvas(isDark);
    final canSelect = canExecute && !submitting;
    final menuWorkflows = singleList ? workflows : otherWorkflows;
    final menuSelected =
        selectedWorkflow != null && (singleList || otherSelected);

    const controlBorderRadius = BorderRadius.all(Radius.circular(6));

    Widget primaryWorkflow(String id, String label, String tooltip) {
      final item = workflows.where((item) => item.id == id).firstOrNull;
      final selected = selectedWorkflow?.id == id;
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: Semantics(
          key: ValueKey('work-toggle-$id'),
          label: '$label workflow',
          selected: selected,
          button: true,
          enabled: canSelect && item != null,
          child: Material(
            animationDuration: Duration.zero,
            color: selected ? activeBackground : controlBg,
            borderRadius: controlBorderRadius,
            child: InkWell(
              borderRadius: controlBorderRadius,
              hoverColor: Colors.transparent,
              splashFactory: NoSplash.splashFactory,
              onTap: canSelect && item != null
                  ? () => onWorkflowChanged(item.reference)
                  : null,
              child: Container(
                alignment: Alignment.center,
                height: composerButtonSize,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: item == null
                            ? colors.onSurface.withValues(alpha: 0.38)
                            : selected
                                ? selectedForeground
                                : inactiveForeground)),
              ),
            ),
          ),
        ),
      );
    }

    PopupMenuEntry<String> workflowEntry(
            AxBuiltinWorkflow item, BuildContext menuContext) =>
        SyntilaMenuEntry<String>(
          value: item.reference,
          child: MenuItemButton(
            style: SyntilaMenuStyle.item(
                Theme.of(context).brightness == Brightness.dark),
            leadingIcon: Icon(
              item.reference == selectedWorkflow?.reference
                  ? Icons.check_circle_rounded
                  : Icons.circle_outlined,
              size: 15,
              color: item.reference == selectedWorkflow?.reference
                  ? selectedForeground
                  : inactiveForeground,
            ),
            onPressed: () => Navigator.pop(menuContext, item.reference),
            child: Text(item.name,
                style: SyntilaMenuStyle.textStyle.copyWith(
                    color: item.reference == selectedWorkflow?.reference
                        ? selectedForeground
                        : inactiveForeground)),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (buttonContext) => Semantics(
              key: const ValueKey('work-add-attachments'),
              label: 'Add attachments or recall a request',
              child: Material(
                color: controlBg,
                borderRadius: controlBorderRadius,
                child: InkWell(
                  borderRadius: controlBorderRadius,
                  onTap: () async {
                    final value = await _showAnchoredMenu<String>(
                      buttonContext: buttonContext,
                      itemHeight: 36.0,
                      items: [
                        SyntilaMenuEntry<String>(
                          value: 'files',
                          child: MenuItemButton(
                            style: SyntilaMenuStyle.item(
                                Theme.of(context).brightness ==
                                    Brightness.dark),
                            leadingIcon:
                                const Icon(Icons.attach_file, size: 16),
                            onPressed: canExecute && !submitting
                                ? () => Navigator.pop(buttonContext, 'files')
                                : null,
                            child: const Text('Add files',
                                style: SyntilaMenuStyle.textStyle),
                          ),
                        ),
                        if (onHistoryNavigate != null)
                          SyntilaMenuEntry<String>(
                            value: 'history',
                            child: MenuItemButton(
                              style: SyntilaMenuStyle.item(
                                  Theme.of(context).brightness ==
                                      Brightness.dark),
                              leadingIcon: const Icon(Icons.history, size: 16),
                              onPressed: () =>
                                  Navigator.pop(buttonContext, 'history'),
                              child: const Text('Request history',
                                  style: SyntilaMenuStyle.textStyle),
                            ),
                          ),
                      ],
                    );
                    if (!buttonContext.mounted || value == null) return;
                    if (value == 'files') onAddFiles();
                    if (value == 'history') onHistoryNavigate?.call(-1);
                  },
                  child: const SizedBox(
                    width: composerButtonSize,
                    height: composerButtonSize,
                    child: Icon(Icons.add, size: composerIconSize),
                  ),
                ),
              ),
            ),
          ),
          DecoratedBox(
            key: const ValueKey('work-workflow-track'),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(1),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (!singleList) ...[
                  primaryWorkflow(
                      'chat', 'Chat', 'Chat — talk with the Worker'),
                  primaryWorkflow(
                      'direct', 'Work', 'Work — run a tracked Work Request'),
                ],
                // Hide the menu when it has nothing to list.
                if (menuWorkflows.isNotEmpty)
                  Builder(
                    builder: (workflowBtnContext) => Semantics(
                      key: const ValueKey('work-choose-workflow'),
                      label: menuSelected
                          ? 'Choose workflow, ${selectedWorkflow.name} selected'
                          : 'More workflows',
                      selected: menuSelected,
                      button: true,
                      enabled: canSelect && menuWorkflows.isNotEmpty,
                      child: Material(
                        animationDuration: Duration.zero,
                        color: menuSelected ? activeBackground : controlBg,
                        borderRadius: controlBorderRadius,
                        child: InkWell(
                          borderRadius: controlBorderRadius,
                          hoverColor: Colors.transparent,
                          splashFactory: NoSplash.splashFactory,
                          onTap: canSelect && menuWorkflows.isNotEmpty
                              ? () async {
                                  final value = await _showAnchoredMenu<String>(
                                    buttonContext: workflowBtnContext,
                                    itemHeight: 36.0,
                                    items: [
                                      for (final item in menuWorkflows)
                                        workflowEntry(item, workflowBtnContext),
                                    ],
                                  );
                                  if (!workflowBtnContext.mounted ||
                                      value == null) {
                                    return;
                                  }
                                  onWorkflowChanged(value);
                                }
                              : null,
                          child: Container(
                            alignment: Alignment.center,
                            height: composerButtonSize,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 130),
                                  child: Text(
                                    menuSelected
                                        ? selectedWorkflow.name
                                        : (singleList ? 'Workflow' : 'More'),
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: menuSelected
                                              ? selectedForeground
                                              : inactiveForeground,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 2),
                                const Icon(Icons.keyboard_arrow_down, size: 14),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          DecoratedBox(
            key: const ValueKey('work-composer-selection'),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(6)),
              border: Border.all(
                  color: selectionMissing && _missingSelection().isNotEmpty
                      ? colors.error
                      : Colors.transparent),
            ),
            child: ModelEffortSelector(
              scope: 'work-composer',
              immediatePopup: true,
              workerIconBuilder: (capability) {
                final worker = eligibleWorkers
                    .where((w) => w.id == capability.id)
                    .firstOrNull;
                final asset = WorkerPresentation.resolve(
                        worker?.workerTypeId, capability.name)
                    .iconAssetForBrightness(Theme.of(context).brightness);
                return asset == null
                    ? const Icon(Icons.smart_toy_outlined, size: 22)
                    : Image.asset(asset, width: 22, height: 22);
              },
              modelIconBuilder: (capability, modelId, modelName) {
                final worker = eligibleWorkers
                    .where((w) => w.id == capability?.id)
                    .firstOrNull;
                final presentation = ModelPresentation.resolve(
                  modelId: modelId,
                  modelDisplayName: modelName,
                  fallbackWorkerTypeId: worker?.workerTypeId,
                  fallbackWorkerDisplayName: capability?.name,
                );
                final asset = presentation
                    .iconAssetForBrightness(Theme.of(context).brightness);
                return asset == null
                    ? const Icon(Icons.smart_toy_outlined, size: 22)
                    : Image.asset(asset, width: 22, height: 22);
              },
              compactModelLabelBuilder: (modelId, modelName) {
                return ModelPresentation.stripIdentity(modelName ?? modelId);
              },
              helperMessage: eligibleWorkers
                          .where((worker) => worker.id == selectedWorkerId)
                          .firstOrNull
                          ?.executionOptions
                          ?.modelSwitchSupported ==
                      false
                  ? 'Changing the model starts a new session with the conversation context. Effort changes that select another model follow the same rule.'
                  : null,
              onShowUsage: usageController?.supported ?? false
                  ? () => _runComposerCommand(_usageCommand)
                  : null,
              compact: true,
              compactHeight: composerButtonSize,
              compactIconSize: composerIconSize,
              showWorkerInCompactSummary: false,
              showWorker: true,
              showModel: true,
              showEffort: true,
              showCatalog: false,
              allowWorkerChange: policy.userSelectsWorker,
              allowModelChange: policy.userSelectsModel,
              allowEffortChange: policy.userSelectsEffort,
              catalog:
                  AxWorkflowSelectionOptions(eligibleWorkers).sharedCatalog,
              value: ExecutionSelection(
                  worker: selectedWorkerId,
                  catalogRevision: (executionSelection['catalogRevision'] ??
                      binding['catalogRevision']) as String?,
                  model: selectedModel.isEmpty ? null : selectedModel,
                  effort: selectedReasoningEffort.isEmpty
                      ? null
                      : selectedReasoningEffort),
              readOnly: !canExecute ||
                  submitting ||
                  !(policy.userSelectsWorker ||
                      policy.userSelectsModel ||
                      policy.userSelectsEffort),
              onChanged: (value) => onExecutionSelectionChanged({
                'workerId': value.worker,
                'model': value.model,
                'reasoningEffort': value.effort,
                if (value.catalogRevision != null)
                  'catalogRevision': value.catalogRevision,
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// Runs a composer command against the Worker selected for the current Step.
  void _runComposerCommand(_ComposerCommand command) {
    final controller = usageController;
    if (controller == null || command.id != _usageCommand.id) return;
    final selectedId = _selectedWorkerId();
    final worker = [...spaceWorkers, ...eligibleWorkers]
        .where((item) => item.id == selectedId)
        .firstOrNull;
    if (worker == null) {
      controller.showMessage('Choose a Worker to read its usage.');
      return;
    }
    controller.load(
      workspaceId: worker.workspaceId,
      workerId: worker.id,
      workerName: worker.displayName,
    );
  }

  /// A message that is exactly one known `/command` runs it instead of being
  /// sent as a request. Any other text, including paths such as `/etc/hosts`,
  /// is sent normally.
  bool _tryRunSlashCommand() {
    if (!(usageController?.supported ?? false)) return false;
    final text = requestController.text.trim();
    if (!RegExp(r'^/[a-z]+$').hasMatch(text)) return false;
    final matches = _composerCommands
        .where((command) => command.id.startsWith(text.substring(1)))
        .toList();
    if (matches.length != 1) return false;
    requestController.clear();
    _runComposerCommand(matches.single);
    return true;
  }

  Widget _buildComposerInput(
    BuildContext context,
    bool isDark,
    ColorScheme colors,
  ) {
    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            (usageController?.visible ?? false)) {
          usageController!.dismiss();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (usageController?.supported ?? false)
            _SlashCommandPalette(
              textController: requestController,
              commands: _composerCommands,
              onSelected: (command) {
                requestController.clear();
                _runComposerCommand(command);
              },
            ),
          if (usageController != null)
            AxWorkerUsagePanel(
              controller: usageController!,
              onRefresh: () => _runComposerCommand(_usageCommand),
              attached: true,
              joinsInput: historyPrompts == null && queuedMessages.isEmpty,
            ),
          if (historyPrompts != null)
            _RequestHistoryPanel(
              prompts: historyPrompts!,
              joinsInput: queuedMessages.isEmpty,
              openDirection: historyOpenDirection,
              onSelected: onHistorySelected ?? (_) {},
              onClosed: onHistoryClosed ?? () {},
            ),
          if (queuedMessages.isNotEmpty)
            ListenableBuilder(
              listenable: Listenable.merge([usageController]),
              builder: (context, _) => _QueuedMessagesPanel(
                messages: queuedMessages,
                pause: queuePause,
                hasPanelAbove: historyPrompts != null ||
                    (usageController?.visible ?? false),
                onPauseChanged: onQueuePauseChanged ?? (_) {},
                onEdit: onQueuedEdit ?? (_) {},
                onRemove: onQueuedRemove ?? (_) {},
                onSendNow: onQueuedSendNow ?? (_) {},
              ),
            ),
          MarkdownComposer(
            attachments: _composerExtras(
              reply: replyTarget,
              onClearReply: canExecute && !submitting ? onClearReply : null,
              files: attachments,
              onRemoveFile:
                  canExecute && !submitting ? onRemoveAttachment : null,
            ),
            leadingControls: leadingControls,
            inputHeight: inputHeight,
            showControlTooltips: false,
            controller: requestController,
            hintText: 'Write a message...',
            chatStyle: true,
            minLines: 1,
            maxLines: 6,
            enabled: canExecute,
            onHistoryNavigate: onHistoryNavigate,
            onSend: () {
              if (_tryRunSlashCommand()) return;
              final missing = _missingSelection();
              if (missing.isNotEmpty) {
                onSelectionMissing?.call(_missingSelectionMessage(missing));
                return;
              }
              onRun();
            },
            sendTooltip: 'Send request',
            showSendTooltip: false,
            sendEnabled: canExecute &&
                !submitting &&
                !loadingWorkflows &&
                workflowCatalogError == null,
            showMarkdownControls: false,
            showEmojiPicker: false,
            showMarkdownControlsInSuffix: true,
            showSendInSuffix: true,
            twoRowLayout: true,
            executionControlsBuilder: (_) => _additionalControls(context),
          ),
          if (loadingWorkflows) const LinearProgressIndicator(),
          if (workflowCatalogError != null)
            Text(workflowCatalogError!, style: TextStyle(color: colors.error)),
          if (!canExecute)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Viewer access can read the thread but cannot run Work.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          if (submitError != null) ...[
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: SelectableText(
                  submitError!,
                  style: SyntilaMessageTypography.fromTheme(Theme.of(context))
                      .copyWith(color: colors.error),
                ),
              ),
              IconButton(
                tooltip: 'Copy request error',
                icon: const Icon(Icons.copy_outlined, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: submitError!));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showNotice(
                      const SnackBar(content: Text('Request error copied')),
                    );
                  }
                },
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

/// A command available from the `/` palette and the `+` menu. Commands are
/// local to the composer: they never create a Work Request.
class _ComposerCommand {
  const _ComposerCommand({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
  });

  final String id;
  final String label;
  final String description;
  final IconData icon;
}

/// Workflows with fixed Chat and Work buttons; others live under More.
const _primaryWorkflowIds = {'chat', 'direct'};

const _usageCommand = _ComposerCommand(
  id: 'usage',
  label: 'Usage',
  description: 'Show the selected Worker\'s usage and limits',
  icon: Icons.speed,
);

const _composerCommands = <_ComposerCommand>[_usageCommand];

/// Lists matching commands while the composer holds a lone `/word`.
class _SlashCommandPalette extends StatelessWidget {
  const _SlashCommandPalette({
    required this.textController,
    required this.commands,
    required this.onSelected,
  });

  final TextEditingController textController;
  final List<_ComposerCommand> commands;
  final ValueChanged<_ComposerCommand> onSelected;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: textController,
        builder: (context, value, _) {
          final text = value.text;
          if (!RegExp(r'^/[a-z]*$').hasMatch(text)) {
            return const SizedBox.shrink();
          }
          final matches = commands
              .where((command) => command.id.startsWith(text.substring(1)))
              .toList();
          if (matches.isEmpty) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          return Padding(
            key: const ValueKey('slash-command-palette'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final command in matches)
                    ListTile(
                      key: ValueKey('slash-command-${command.id}'),
                      dense: true,
                      leading: Icon(command.icon, size: 18),
                      title: Text('/${command.id}',
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(command.description,
                          style: const TextStyle(fontSize: 12)),
                      onTap: () => onSelected(command),
                    ),
                ],
              ),
            ),
          );
        },
      );
}

/// Shows a normalized usage table, or the report exactly as the Worker printed
/// it when it cannot be normalized or the user asks for the original.
class AxWorkerUsagePanel extends StatelessWidget {
  const AxWorkerUsagePanel(
      {super.key,
      required this.controller,
      required this.onRefresh,
      this.attached = false,
      this.joinsInput = true});

  final AxWorkerUsageController controller;
  final VoidCallback onRefresh;

  /// Composer-only presentation; dialogs retain the standalone card.
  final bool attached;
  final bool joinsInput;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (!controller.visible) return const SizedBox.shrink();
          final colors = Theme.of(context).colorScheme;
          final report = controller.report;
          final message = controller.message;
          final text = report == null
              ? ''
              : report.isOk
                  ? report.displayText
                  : report.status == 'unavailable'
                      ? 'This Worker does not provide a usage report.'
                      : (report.errorMessage ?? 'Usage could not be read.');
          final parsed = report != null && report.isOk
              ? parseWorkerUsage(report.output, now: report.fetchedAt)
              : null;
          final showTable = parsed != null && !controller.showOriginal;
          final panel = Container(
            key: const ValueKey('worker-usage-panel'),
            margin:
                attached ? EdgeInsets.zero : const EdgeInsets.only(bottom: 8),
            padding: attached
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
              color: attached ? null : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: attached
                      ? SyntilaColors.composerRail(
                          Theme.of(context).brightness == Brightness.dark)
                      : null,
                  padding: attached
                      ? const EdgeInsets.fromLTRB(12, 2, 4, 0)
                      : EdgeInsets.zero,
                  // Attached header: 2px top padding + 32px content row.
                  constraints:
                      attached ? const BoxConstraints(minHeight: 34) : null,
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${controller.workerName ?? 'Worker'} usage',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (parsed != null && !controller.loading)
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Semantics(
                          link: true,
                          child: InkWell(
                            key: const ValueKey('worker-usage-toggle-original'),
                            onTap: controller.toggleOriginal,
                            mouseCursor: SystemMouseCursors.click,
                            child: Text(
                              controller.showOriginal ? 'Summary' : 'Original',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: 'Refresh usage',
                      padding: EdgeInsets.zero,
                      style: composerIconButtonStyle(),
                      constraints: composerButtonConstraints,
                      icon: const Icon(Icons.refresh, size: composerIconSize),
                      onPressed: controller.loading ? null : onRefresh,
                    ),
                    if (!attached)
                      IconButton(
                        tooltip: 'Close usage',
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                            width: 28, height: 28),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: controller.dismiss,
                      ),
                  ]),
                ),
                Padding(
                  padding: attached
                      ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
                      : EdgeInsets.zero,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: LinearProgressIndicator(),
                        )
                      else if (message != null)
                        Text(message, style: const TextStyle(fontSize: 12))
                      else if (showTable)
                        AxLiveTicker(
                          active: parsed.windows.any((w) => w.resetsAt != null),
                          builder: (context, now) =>
                              _UsageTable(usage: parsed, now: now),
                        )
                      else ...[
                        if (report != null && report.isOk)
                          Text(
                              controller.showOriginal
                                  ? 'Original output'
                                  : 'Could not summarize this report. Original '
                                      'output:',
                              key: const ValueKey('worker-usage-unparsed'),
                              style: Theme.of(context).textTheme.bodySmall),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              text,
                              key: const ValueKey('worker-usage-text'),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                color: report != null && !report.isOk
                                    ? colors.error
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (report?.truncated ?? false)
                        Text('Output was shortened.',
                            style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
                if (attached)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Divider(
                      key: const ValueKey('worker-usage-bottom-line'),
                      height: 1,
                      thickness: 1,
                      color: SyntilaColors.composerRail(
                          Theme.of(context).brightness == Brightness.dark),
                    ),
                  ),
              ],
            ),
          );
          if (!attached) return panel;
          return TapRegion(
            onTapOutside: (_) => controller.dismiss(),
            child: _ComposerPanelLayer(
              backgroundKey: const ValueKey('worker-usage-layer-background'),
              horizontalInset: 40,
              background: SyntilaColors.composerBackground(
                  Theme.of(context).brightness == Brightness.dark),
              joinsInput: joinsInput,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(child: panel),
              ),
            ),
          );
        },
      );
}

class _UsageTable extends StatelessWidget {
  const _UsageTable({required this.usage, required this.now});

  final AxParsedUsage usage;

  final DateTime now;

  static const _labelStyle = TextStyle(fontSize: 12);

  /// Width of the label column: the widest label of this report, measured with
  /// the displayed font and text scale, plus a gap. Each Worker reports
  /// different labels, so a fixed width either wastes space or wraps. Capped
  /// at 40% of the row so the other columns retain room on narrow screens.
  double _labelWidth(BuildContext context, double maxWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final style = DefaultTextStyle.of(context).style.merge(_labelStyle);
    var widest = 0.0;
    for (final window in usage.windows) {
      final painter = TextPainter(
        text: TextSpan(text: window.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    final width = widest.ceilToDouble() + 12;
    return maxWidth.isFinite ? width.clamp(0, maxWidth * 0.4) : width;
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final labelWidth = _labelWidth(context, constraints.maxWidth);
        final style = DefaultTextStyle.of(context)
            .style
            .merge(Theme.of(context).textTheme.bodySmall);
        var resetWidth = 0.0;
        for (final window in usage.windows) {
          final painter = TextPainter(
            text: TextSpan(text: usageResetLabel(window, now), style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          if (painter.width > resetWidth) resetWidth = painter.width;
          painter.dispose();
        }
        // Reserve room for a useful bar, then give reset text all the room
        // it needs up to the space available beside that bar.
        resetWidth = resetWidth.ceilToDouble();
        final availableResetWidth =
            (constraints.maxWidth - labelWidth - 84 - 8 - 40)
                .clamp(0.0, double.infinity);
        final showBars = availableResetWidth >= resetWidth.clamp(0, 120);
        resetWidth = resetWidth.clamp(0, availableResetWidth);
        return _build(context, labelWidth,
            showBars: showBars, resetWidth: resetWidth);
      });

  Widget _build(BuildContext context, double labelWidth,
      {required bool showBars, required double resetWidth}) {
    final small = Theme.of(context).textTheme.bodySmall;
    final dark = Theme.of(context).brightness == Brightness.dark;
    String? group;
    final children = <Widget>[];
    for (final window in usage.windows) {
      if (window.group != null && window.group != group) {
        group = window.group;
        children.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(group!,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ));
      }
      children.add(Padding(
        key: ValueKey('worker-usage-row-${window.group ?? ''}-${window.label}'),
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(
              key: const ValueKey('worker-usage-label'),
              width: labelWidth,
              child: Text(window.label, style: _labelStyle)),
          if (showBars)
            Expanded(
              child: LinearProgressIndicator(
                  value: (window.usedPercent / 100).clamp(0.0, 1.0),
                  color: SyntilaColors.primaryForeground(dark),
                  backgroundColor: SyntilaColors.surfaceHover(dark),
                  stopIndicatorColor: Colors.transparent,
                  minHeight: 6,
                  semanticsLabel: '${window.group ?? ''} ${window.label} usage',
                  semanticsValue: '${window.usedPercent.round()}%'),
            ),
          SizedBox(
            width: 84,
            child: Text('${window.usedPercent.round()}% used',
                textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 8),
          if (showBars)
            SizedBox(
              width: resetWidth,
              child: Text(usageResetLabel(window, now),
                  overflow: TextOverflow.ellipsis, style: small),
            )
          else
            Flexible(
              child: Text(usageResetLabel(window, now),
                  overflow: TextOverflow.ellipsis, style: small),
            ),
        ]),
      ));
    }
    for (final note in usage.notes) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(note, style: small),
      ));
    }
    return Column(
        key: const ValueKey('worker-usage-table'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children);
  }
}

/// Keeps the parsed Markdown subtree stable while the surrounding Work card
/// receives activity/status updates. A changed source intentionally replaces
/// the child so selection handles cannot refer to stale response text.
class _MemoizedWorkMarkdown extends StatefulWidget {
  const _MemoizedWorkMarkdown({
    super.key,
    required this.data,
    this.fitContent = false,
  });

  final String data;
  final bool fitContent;

  @override
  State<_MemoizedWorkMarkdown> createState() => _MemoizedWorkMarkdownState();
}

class _MemoizedWorkMarkdownState extends State<_MemoizedWorkMarkdown> {
  late Widget _body;

  Widget _createBody() => SyntilaMarkdownBody(
        key: widget.key,
        data: widget.data,
        fitContent: widget.fitContent,
      );

  @override
  void initState() {
    super.initState();
    _body = _createBody();
  }

  @override
  void didUpdateWidget(covariant _MemoizedWorkMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.fitContent != widget.fitContent) {
      _body = _createBody();
    }
  }

  @override
  Widget build(BuildContext context) => _body;
}

/// Rewrites a "Please retry" ending for failures that offer no Retry action,
/// so the text never points at a control that is not there.
String _withoutRetryPromise(String message) {
  for (final ending in [' Please retry your request.', ' Please retry.']) {
    if (message.endsWith(ending)) {
      return '${message.substring(0, message.length - ending.length)} '
          'Send a new message to try again.';
    }
  }
  return message;
}

/// The user-facing failure for [request]; diagnostics stay in Engine logs.
/// [canRetry] says whether the timeline shows a Retry action for it.
String? _workFailureText(AxWorkRequest request, {required bool canRetry}) {
  // A user cancellation (including Send now from the queue) is not a failure,
  // even when the stopped Worker step recorded an error code.
  if (request.status == 'cancelled') return null;
  final failedStep =
      request.steps.where((step) => step.status == 'failed').firstOrNull;
  final rawError = request.error?.trim().isNotEmpty == true
      ? request.error!
      : failedStep?.errorMessage;
  if (request.status != 'failed' && rawError?.isNotEmpty != true) return null;
  final message = _publicFailureMessage(
    failedStep,
    _executionFailureMessage(
      failedStep?.errorCode,
      validationMessage: failedStep == null ? rawError : null,
    ),
  );
  return canRetry ? message : _withoutRetryPromise(message);
}

String? _workResponseText(AxWorkRequest request) =>
    request.finalText?.trim().isNotEmpty == true
        ? request.finalText!
        : request.turns
                .where((turn) =>
                    turn.status == 'completed' &&
                    turn.resultText?.trim().isNotEmpty == true)
                .lastOrNull
                ?.resultText ??
            request.steps
                .map((step) => step.resultText)
                .whereType<String>()
                .where((text) => text.trim().isNotEmpty)
                .firstOrNull;

/// A tap on selectable request text. The text's selection gestures win the
/// gesture arena, so a raw pointer press and release that barely moves counts
/// as the tap; a drag still selects text without toggling.
class _PromptTapListener extends StatefulWidget {
  const _PromptTapListener(
      {super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  State<_PromptTapListener> createState() => _PromptTapListenerState();
}

class _PromptTapListenerState extends State<_PromptTapListener> {
  Offset? _down;

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _down = event.position,
        onPointerCancel: (_) => _down = null,
        onPointerUp: (event) {
          final down = _down;
          _down = null;
          if (down != null && (event.position - down).distance < kTouchSlop) {
            widget.onTap();
          }
        },
        child: widget.child,
      );
}

/// AI History opens responses that still need attention: work in progress
/// shows its progress, and a failure shows Retry and Report. Finished
/// responses start hidden.
bool aiHistoryResponseOpenByDefault(AxWorkRequest request) =>
    !const {'completed', 'cancelled'}.contains(request.status);

class _WorkTimelineCard extends StatelessWidget {
  const _WorkTimelineCard({
    this.responseAnchorKey,
    this.showPromptBubble = true,
    this.showResponse = true,
    this.onPromptTap,
    required this.request,
    required this.activities,
    required this.realtimeStatus,
    this.clockOffset = Duration.zero,
    this.progressText,
    required this.currentUserId,
    required this.currentUserName,
    required this.workflowCatalog,
    required this.onReportIssue,
    required this.reportedIssue,
    required this.reportingIssue,
    required this.issueReportError,
    required this.onRetryStep,
    required this.onCancelRun,
    this.onReply,
  });

  /// Starts a reply to this request or its answer (Reply v1).
  final ValueChanged<AxReplyReference>? onReply;
  final GlobalKey? responseAnchorKey;
  final bool showPromptBubble;

  /// AI History hides the response until its request is tapped.
  final bool showResponse;
  final VoidCallback? onPromptTap;
  final AxWorkRequest request;
  final List<AxWorkActivity> activities;
  final AxWorkRealtimeStatus realtimeStatus;
  final Duration clockOffset;
  final String? progressText;
  final String? currentUserId;
  final String? currentUserName;
  final List<AxBuiltinWorkflow> workflowCatalog;
  final Future<void> Function(String)? onReportIssue;
  final AxIssueReport? reportedIssue;
  final bool reportingIssue;
  final String? issueReportError;
  final Future<void> Function(String, AxWorkRequestStep)? onRetryStep;
  final Future<void> Function(String)? onCancelRun;

  String get _workflowName =>
      request.workflowName ??
      workflowCatalog
          .where((workflow) =>
              workflow.id == request.workflowId &&
              workflow.version == request.workflowVersion)
          .map((workflow) => workflow.name)
          .firstOrNull ??
      request.workflowId;

  String _elapsed(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    return minutes > 0 ? '${minutes}m ${remainder}s' : '${remainder}s';
  }

  int get _totalElapsedMs => request.steps
      .map((step) => step.elapsedMs)
      .whereType<int>()
      .fold<int>(0, (total, value) => total + value);

  String _totalElapsed() {
    final elapsed = _totalElapsedMs;
    return elapsed == 0 ? '' : _elapsed(elapsed);
  }

  /// In AI History the request bubble toggles its response.
  Widget _tappablePrompt(Widget bubble) {
    final onTap = onPromptTap;
    if (onTap == null) return bubble;
    return Tooltip(
      message: showResponse ? 'Hide response' : 'Show response',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: _PromptTapListener(
          key: ValueKey('ai-history-request-${request.id}'),
          onTap: onTap,
          child: bubble,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final metaColor = SyntilaColors.textSecondary(isDark);

    final timestamp = DateTime.tryParse(request.createdAt)?.toLocal();
    final timeLabel =
        timestamp == null ? '' : _relativeChatTimestamp(timestamp);
    final rawRequesterName = request.requestedByName.trim();
    final effectiveRequesterName = (rawRequesterName.isEmpty ||
            rawRequesterName == request.requestedByUserId ||
            rawRequesterName.startsWith('usr_'))
        ? 'Team member'
        : rawRequesterName;
    final requesterInitials = effectiveRequesterName.isNotEmpty
        ? effectiveRequesterName
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';
    final isOwnRequest =
        _isOwnWorkRequest(request, currentUserId, currentUserName);
    final showRequesterIdentity = !isOwnRequest;

    final failedStep =
        request.steps.where((step) => step.status == 'failed').firstOrNull;
    final lastCompletedStep = request.steps
        .where((step) =>
            step.status == 'completed' &&
            step.resultText?.trim().isNotEmpty == true)
        .lastOrNull;
    final activeStep = request.steps
        .where((step) => step.status == 'running' || step.status == 'waiting')
        .firstOrNull;
    final stepForContext =
        activeStep ?? lastCompletedStep ?? request.steps.firstOrNull;
    final response = _workResponseText(request);
    // Cloud's phase of the step that currently matters. A terminal request
    // always wins, so a delayed step event can never show it as running.
    final requestIsTerminal =
        AxWorkProgress.terminalStatuses.contains(request.status);
    final activeSteps = request.steps
        .where((step) => !AxExecutionPhase.isTerminal(step.effectivePhase))
        .toList();
    final phaseStep = activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.uncertain)
            .firstOrNull ??
        activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.running)
            .firstOrNull ??
        activeSteps
            .where((step) => step.effectivePhase == AxExecutionPhase.starting)
            .firstOrNull ??
        activeSteps.firstOrNull;
    final executionPhase = requestIsTerminal
        ? request.status
        : (phaseStep?.effectivePhase ?? request.executionPhase);
    final error = _workFailureText(request,
        canRetry: request.status == 'failed' &&
            failedStep?.retryAllowed == true &&
            onRetryStep != null);
    final isError = error?.isNotEmpty == true;

    // Waiting/queued messages belong to Syntila. A running Step is the
    // product's worker execution signal; no final text is required to attribute it.
    final senderStep = activeStep?.status == 'running'
        ? activeStep
        : lastCompletedStep ?? stepForContext;
    final stepStartedAt =
        DateTime.tryParse((activeStep ?? senderStep)?.startedAt ?? '')
            ?.toLocal();
    AxWorkProgress resolveProgress(DateTime now) => AxWorkProgress.resolve(
          requestStatus: request.status,
          activities: activities,
          now: now,
          stepStartedAt: stepStartedAt,
          serverElapsedMs: _totalElapsedMs == 0 ? null : _totalElapsedMs,
          clockOffset: clockOffset,
          executionPhase: executionPhase,
        );
    final progress = resolveProgress(DateTime.now());
    final senderTurn = request.turns
        .where((turn) => turn.assignmentId == senderStep?.assignmentId)
        .lastOrNull;
    final selectedModel =
        (senderTurn != null ? senderTurn.modelId : senderStep?.model)?.trim();
    final selectedReasoningEffort =
        (senderTurn != null ? senderTurn.effort : senderStep?.reasoningEffort)
            ?.trim();
    final workerType = (senderTurn?.workerTypeId ?? senderStep?.workerTypeId)
        ?.trim()
        .toLowerCase();
    final workerDisplayName =
        (senderTurn?.workerDisplayName ?? senderStep?.workerDisplayName)
            ?.trim();
    final presentation =
        WorkerPresentation.resolve(workerType, workerDisplayName);
    final workerName = presentation.name;
    final hasWorkerIdentity =
        workerDisplayName?.isNotEmpty == true || workerType?.isNotEmpty == true;
    final isPreStart =
        const {'queued', 'starting', 'acknowledged'}.contains(request.status) ||
            (!requestIsTerminal &&
                AxExecutionPhase.isKnown(executionPhase) &&
                !AxExecutionPhase.isExecuting(executionPhase));
    final isWorkerResponse = !isError &&
        hasWorkerIdentity &&
        (isPreStart ||
            progress.isExecuting ||
            senderStep?.status == 'running' ||
            response?.isNotEmpty == true);

    final frozenModelName = senderTurn?.modelName ?? senderStep?.modelName;
    final modelDisplayName =
        frozenModelName ?? _modelDisplayName(selectedModel);
    final hasModel = (selectedModel != null && selectedModel.isNotEmpty) ||
        (frozenModelName != null && frozenModelName.isNotEmpty);
    final modelPresentation = ModelPresentation.resolve(
      modelId: selectedModel,
      modelDisplayName: modelDisplayName.isNotEmpty ? modelDisplayName : null,
      fallbackWorkerTypeId: workerType,
      fallbackWorkerDisplayName: workerDisplayName,
    );
    final modelName = modelPresentation.name;
    final modelIcon =
        modelPresentation.iconAssetForBrightness(Theme.of(context).brightness);

    final senderName =
        isWorkerResponse ? (hasModel ? modelName : workerName) : 'Syntila';
    final workerOwnerName = senderTurn?.workerOwnerName?.trim();
    final workerIcon =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    final effectiveIcon = hasModel ? (modelIcon ?? workerIcon) : workerIcon;
    final effectiveIconLabel = hasModel ? modelName : workerName;
    final effortLabel = selectedReasoningEffort?.isNotEmpty == true
        ? executionEffortDisplayName(selectedReasoningEffort)
        : 'Default effort';
    // Live elapsed time comes from the Worker flow while the request is
    // unfinished; the server-reported duration replaces it once it is not.
    String metadataAt(DateTime now) {
      final live = progress.showsLiveElapsed
          ? resolveProgress(now).elapsedAt(now)
          : null;
      final elapsed = live != null
          ? AxWorkProgress.formatDuration(live)
          : progress.showsLiveElapsed
              ? ''
              : _totalElapsed();
      final segments = [
        if (_workflowName.isNotEmpty) _workflowName,
        if (elapsed.isNotEmpty) elapsed,
      ];
      return segments.isEmpty ? '' : '· ${segments.join(' · ')}';
    }

    final requestMeta = <Widget>[
      if (timeLabel.isNotEmpty) ...[
        Tooltip(
          message: _chatTimestamp(timestamp!),
          child: Text(
            timeLabel,
            style: TextStyle(fontSize: 11, color: metaColor),
          ),
        ),
        const SizedBox(width: 8),
      ],
      _TimelineActionsMenu(color: metaColor, actions: [
        if (onReply != null)
          _TimelineAction(
            tooltip: 'Reply',
            icon: Icons.reply_rounded,
            color: metaColor,
            onTap: () => onReply!(AxReplyReference(
              kind: 'request',
              id: request.id,
              authorName: effectiveRequesterName,
              excerpt: replyExcerpt(request.prompt.trim().isEmpty
                  ? attachmentsLabel(
                      request.attachments.map((file) => file.toJson()).toList())
                  : request.prompt),
            )),
          ),
        _TimelineAction(
          tooltip: 'Copy',
          icon: Icons.copy_rounded,
          color: metaColor,
          onTap: () {
            Clipboard.setData(ClipboardData(text: request.prompt));
          },
        ),
      ]),
    ];

    final hasMetadata = _workflowName.isNotEmpty ||
        progress.showsLiveElapsed ||
        _totalElapsedMs != 0;
    final senderIconOpacity = isDark ? 0.72 : 0.85;

    final Widget senderAvatar = isWorkerResponse
        ? (effectiveIcon != null
            ? Opacity(
                opacity: senderIconOpacity,
                child: Image.asset(effectiveIcon,
                    width: 24,
                    height: 24,
                    fit: BoxFit.contain,
                    semanticLabel: '$effectiveIconLabel icon'),
              )
            : CircleAvatar(
                radius: 12,
                backgroundColor: SyntilaColors.primarySoftColor(isDark),
                child: Text(effectiveIconLabel.substring(0, 1).toUpperCase(),
                    style: TextStyle(fontSize: 12, color: metaColor)),
              ))
        : Opacity(
            opacity: senderIconOpacity,
            child: Image.asset(
              SyntilaBrandAssets.logoPng32For(isDark),
              width: 24,
              height: 24,
              fit: BoxFit.contain,
              errorBuilder: (ctx, err, stack) => Icon(
                Icons.auto_awesome,
                size: 24,
                color: metaColor,
              ),
            ),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showPromptBubble) ...[
          // User prompt bubble
          _MessageHover(
            builder: (context, showMeta) => LayoutBuilder(
              builder: (context, constraints) {
                final maxBubbleWidth =
                    math.min(640.0, constraints.maxWidth * 0.9);
                return Align(
                  alignment: isOwnRequest
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minWidth: maxBubbleWidth, maxWidth: maxBubbleWidth),
                    child: _withMessageMeta(
                      own: isOwnRequest,
                      visible: showMeta,
                      meta: requestMeta,
                      background: isOwnRequest
                          ? SyntilaColors.ownMessageBackground(isDark)
                          : Colors.transparent,
                      bubble: _tappablePrompt(Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: EdgeInsets.fromLTRB(
                            isOwnRequest ? 14 : 0, 8, 14, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (showRequesterIdentity) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor:
                                        SyntilaColors.primarySoftColor(isDark),
                                    child: Text(
                                      requesterInitials,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: SyntilaColors.primaryForeground(
                                            isDark),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    effectiveRequesterName,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          SyntilaColors.textSecondary(isDark),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (request.replyTo != null)
                              _ReplyQuote(reference: request.replyTo!),
                            CollapsibleOwnMessage(
                              key: ValueKey(request.id),
                              data: request.prompt,
                              enabled: isOwnRequest,
                              toggleColor: metaColor,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              child: _MemoizedWorkMarkdown(
                                data: request.prompt,
                                fitContent: true,
                              ),
                            ),
                            if (request.attachments.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final file in request.attachments)
                                    AttachmentCard(file: file.toJson()),
                                ],
                              ),
                            ],
                          ],
                        ),
                      )),
                    ),
                  ),
                );
              },
            ),
          ),
          if (showResponse) const SizedBox(height: 20),
        ],
        // AI Execution & response bubble
        if (showResponse)
          _MessageHover(
            builder: (context, showMeta) => LayoutBuilder(
              builder: (context, constraints) {
                final maxBubbleWidth =
                    math.min(680.0, constraints.maxWidth * 0.9);
                return Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minWidth: maxBubbleWidth, maxWidth: maxBubbleWidth),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.fromLTRB(0, 6, 14, 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            // The answer anchor sits on the sender line so a
                            // held answer is revealed with its sender visible.
                            key: responseAnchorKey,
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              senderAvatar,
                              Text(
                                senderName,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: metaColor,
                                ),
                              ),
                              if (isWorkerResponse &&
                                  workerOwnerName?.isNotEmpty == true) ...[
                                Tooltip(
                                  message: 'Worker owned by $workerOwnerName',
                                  child: Text(
                                    "· $workerOwnerName's Worker",
                                    key: const ValueKey('worker-owner-label'),
                                    style: TextStyle(
                                        fontSize: 12, color: metaColor),
                                  ),
                                ),
                              ],
                              if (isWorkerResponse) ...[
                                Text(
                                  '· $effortLabel',
                                  key: const ValueKey('response-effort-label'),
                                  style:
                                      TextStyle(fontSize: 12, color: metaColor),
                                ),
                              ],
                              if (hasMetadata) ...[
                                AxLiveTicker(
                                  active: progress.isTicking &&
                                      realtimeStatus !=
                                          AxWorkRealtimeStatus.checking,
                                  builder: (context, now) => Text(
                                    metadataAt(now),
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12, color: metaColor),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          // The trail is the only place that shows live progress;
                          // it goes away once the request has finished.
                          // A streamed answer or error also retires it, so the
                          // text never lands inside the trail before it hides.
                          if (!progress.isTerminal &&
                              response?.isNotEmpty != true &&
                              error?.isNotEmpty != true &&
                              (activities.isNotEmpty ||
                                  progress.currentAction != null)) ...[
                            const SizedBox(height: 8),
                            _WorkActivityTrail(
                              activities: activities,
                              fallbackAction: progress.currentAction,
                              color: metaColor,
                              accentColor: colors.primary,
                            ),
                          ],
                          const SizedBox(height: 6),
                          Builder(builder: (context) {
                            // The body shows the Worker's live status while the
                            // request is unfinished and the real outcome at the end.
                            final String? message = error?.isNotEmpty == true
                                ? error
                                : response?.isNotEmpty == true
                                    ? response
                                    : request.status == 'cancelled'
                                        ? 'Request cancelled.'
                                        : (progress.isExecuting
                                                ? null
                                                : progressText) ??
                                            switch (request.status) {
                                              'completed' =>
                                                'Request completed.',
                                              'failed' =>
                                                'Your request could not be completed.',
                                              'timed_out' =>
                                                'The worker took too long to respond. Send a new message to try again.',
                                              'lost' =>
                                                'The connection to the worker was lost. Send a new message to try again.',
                                              _ => null,
                                            };
                            final isError = error?.isNotEmpty == true;
                            final platform = Theme.of(context).platform;
                            final touch = platform == TargetPlatform.iOS ||
                                platform == TargetPlatform.android;
                            final actionSize = touch ? 48.0 : 32.0;
                            Widget compactAction({
                              required String tooltip,
                              required IconData icon,
                              required VoidCallback? onPressed,
                            }) =>
                                SizedBox.square(
                                  dimension: actionSize,
                                  child: IconButton(
                                    tooltip: tooltip,
                                    constraints: BoxConstraints.tightFor(
                                      width: actionSize,
                                      height: actionSize,
                                    ),
                                    padding: EdgeInsets.zero,
                                    style: IconButton.styleFrom(
                                        shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(6))),
                                    icon:
                                        Icon(icon, size: 16, color: metaColor),
                                    onPressed: onPressed,
                                  ),
                                );
                            final responseActions = <_TimelineAction>[
                              if (onReply != null &&
                                  request.status == 'completed' &&
                                  response?.isNotEmpty == true)
                                _TimelineAction(
                                    tooltip: 'Reply',
                                    icon: Icons.reply_rounded,
                                    onTap: () => onReply!(AxReplyReference(
                                          kind: 'response',
                                          id: request.id,
                                          authorName: senderName,
                                          excerpt: replyExcerpt(response!),
                                        ))),
                              if (response?.isNotEmpty == true ||
                                  error?.isNotEmpty == true)
                                _TimelineAction(
                                    tooltip: 'Copy',
                                    icon: Icons.copy_outlined,
                                    onTap: () => Clipboard.setData(
                                        ClipboardData(
                                            text:
                                                isError ? error! : response!))),
                              if (request.status == 'failed' &&
                                  failedStep != null &&
                                  failedStep.retryAllowed &&
                                  onRetryStep != null)
                                _TimelineAction(
                                    tooltip: failedStep.errorCode ==
                                            'space_folder_exists'
                                        ? 'Use the existing folder and retry'
                                        : failedStep.retryRequiresConfirmation
                                            ? 'Retry anyway'
                                            : 'Retry',
                                    icon: Icons.refresh_rounded,
                                    onTap: () =>
                                        onRetryStep!(request.id, failedStep)),
                              if (request.status == 'failed' &&
                                  onReportIssue != null &&
                                  reportedIssue == null)
                                _TimelineAction(
                                    tooltip: reportingIssue
                                        ? 'Sending issue report'
                                        : 'Report issue',
                                    icon: Icons.flag_outlined,
                                    onTap: reportingIssue
                                        ? null
                                        : () => onReportIssue!(request.id)),
                            ];
                            final footer = AnimatedOpacity(
                                // Terminal footers reveal on hover/focus;
                                // active and failed controls remain available.
                                opacity: showMeta ||
                                        !const {'completed', 'cancelled'}
                                            .contains(request.status)
                                    ? 1
                                    : 0,
                                duration: const Duration(milliseconds: 120),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if ((request.status == 'queued' ||
                                            request.status == 'running') &&
                                        onCancelRun != null)
                                      compactAction(
                                        tooltip: 'Cancel request',
                                        icon: Icons.cancel_outlined,
                                        onPressed: () =>
                                            onCancelRun!(request.id),
                                      ),
                                    if (reportedIssue != null)
                                      Text('Reported',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: colors.primary)),
                                    // Separates leading controls only, so
                                    // the time aligns with the answer text.
                                    if (reportedIssue != null ||
                                        ((request.status == 'queued' ||
                                                request.status == 'running') &&
                                            onCancelRun != null))
                                      const SizedBox(width: 8),
                                    if (timeLabel.isNotEmpty)
                                      Tooltip(
                                        message: _chatTimestamp(timestamp!),
                                        child: Text(
                                          timeLabel,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: metaColor,
                                          ),
                                        ),
                                      ),
                                    if (responseActions.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      _TimelineActionsMenu(
                                          actions: responseActions,
                                          color: metaColor),
                                    ],
                                  ],
                                ));
                            // Finished answers carry their time and actions
                            // over the last text row; live ones stay in flow.
                            final overlayFooter = message != null &&
                                const {'completed', 'cancelled'}
                                    .contains(request.status);
                            final body = Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (message != null) ...[
                                  isError
                                      ? SelectableText(
                                          message,
                                          style: SyntilaMessageTypography
                                                  .fromTheme(Theme.of(context))
                                              .copyWith(color: colors.error),
                                        )
                                      : _MemoizedWorkMarkdown(
                                          key: ValueKey((request.id, message)),
                                          data: message,
                                        ),
                                ],
                                if (!overlayFooter) footer,
                                if (reportedIssue != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Thanks — sanitized technical diagnostics were sent.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: metaColor,
                                    ),
                                  ),
                                ],
                                if (issueReportError != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    "Couldn't send the report. Try again.",
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.error,
                                    ),
                                  ),
                                ],
                              ],
                            );
                            if (!overlayFooter) return body;
                            return _withMessageMeta(
                              bubble: body,
                              own: false,
                              visible: showMeta,
                              meta: [footer],
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Rebuilds [builder] once a second while [active], handing it the current
/// time. Used for live elapsed time and stale-progress hints that must keep
/// moving between Worker events.
/// "Ran a command · git status": prefer the safe short summary; when a
/// provider only supplies a tool name, keep that context visible as a fallback.
String _activityLabel(AxWorkActivity activity) {
  final summary = activity.details['summary'];
  final description = summary is String && summary.trim().isNotEmpty
      ? summary.trim()
      : activity.toolName?.trim();
  if (description == null || description.isEmpty) return activity.title;
  return '${activity.title} · $description';
}

class _WorkActivityTrail extends StatelessWidget {
  const _WorkActivityTrail({
    required this.activities,
    required this.color,
    required this.accentColor,
    this.fallbackAction,
  });

  final List<AxWorkActivity> activities;
  final Color color;
  final Color accentColor;

  /// Shown as the active row before the Worker reports any activity.
  final String? fallbackAction;

  /// Earlier rows kept above the active one.
  static const _history = 8;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeIndex = activities.lastIndexWhere((item) => !item.isFinished);
    final active = activeIndex < 0 ? null : activities[activeIndex];
    // Oldest first, the active row last. Narration the Worker moved on from
    // never gets an end event, but it is a message to keep, not to drop.
    final earlier = <AxWorkActivity>[
      for (var i = 0; i < activities.length; i++)
        if (i != activeIndex &&
            (activities[i].isFinished ||
                activities[i].details['preview'] is String))
          activities[i],
    ];
    final completed = earlier.length <= _history
        ? earlier
        : earlier.sublist(earlier.length - _history);
    final activeLabel =
        active != null ? _activityLabel(active) : fallbackAction;
    if (activeLabel == null && completed.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (earlier.length > completed.length)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '+${earlier.length - completed.length} earlier steps',
                key: const ValueKey('work-earlier-activities'),
                style: TextStyle(fontSize: 11, color: color),
              ),
            ),
          for (final item in completed)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    item.isError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 14,
                    color:
                        item.isError ? SyntilaColors.errorText(isDark) : color,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      _activityLabel(item),
                      key: ValueKey('work-completed-${item.eventId}'),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: color),
                    ),
                  ),
                ],
              ),
            ),
          if (activeLabel != null)
            Row(
              children: [
                // Before the Worker reports anything there is nothing to
                // animate yet; a still icon also keeps idle screens settled.
                if (active == null)
                  Icon(Icons.more_horiz_rounded, size: 14, color: accentColor)
                else
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: accentColor,
                    ),
                  ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    activeLabel,
                    key: const ValueKey('work-active-activity'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Live status line that does not flicker through short-lived pre-start
/// phases. See [AxStatusSettler] for the rules. Errors, a running provider
/// and new Worker activity are passed with [urgent] and show immediately.
class AxSettledStatusText extends StatefulWidget {
  const AxSettledStatusText({
    super.key,
    required this.text,
    required this.urgent,
    this.style,
    this.clock,
    this.settleDelay = const Duration(milliseconds: 700),
    this.minDisplay = const Duration(milliseconds: 600),
  });

  final String text;
  final bool urgent;
  final TextStyle? style;

  /// Overrides the wall clock; used by tests.
  final DateTime Function()? clock;
  final Duration settleDelay;
  final Duration minDisplay;

  @override
  State<AxSettledStatusText> createState() => _AxSettledStatusTextState();
}

class _AxSettledStatusTextState extends State<AxSettledStatusText> {
  late final AxStatusSettler _settler = AxStatusSettler(
    settleDelay: widget.settleDelay,
    minDisplay: widget.minDisplay,
  );
  Timer? _timer;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _settler.update(widget.text, _now(), urgent: widget.urgent);
    _timer?.cancel();
    _timer = null;
    final wait = _settler.nextCheck;
    if (wait != null) {
      _timer = Timer(wait, () {
        if (mounted) setState(() {});
      });
    }
    return Text(shown ?? '', style: widget.style);
  }
}

class AxLiveTicker extends StatefulWidget {
  const AxLiveTicker({
    super.key,
    required this.active,
    required this.builder,
    this.clock,
  });

  final bool active;
  final Widget Function(BuildContext context, DateTime now) builder;

  /// Overrides the wall clock; used by tests.
  final DateTime Function()? clock;

  @override
  State<AxLiveTicker> createState() => _AxLiveTickerState();
}

class _AxLiveTickerState extends State<AxLiveTicker> {
  Timer? _timer;
  late DateTime _now;

  DateTime _clock() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _now = _clock();
    _sync();
  }

  @override
  void didUpdateWidget(covariant AxLiveTicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    _now = _clock();
    _sync();
  }

  void _sync() {
    if (widget.active && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = _clock());
      });
    } else if (!widget.active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _now);
}

bool _continuesDiscussionGroup(List<_DiscussionItem> items, int index,
    {String? breakAt}) {
  if (index <= 0) return false;
  final item = items[index];
  if (item.id == breakAt) return false;
  final previous = items[index - 1];
  return continuesMessageGroup(
    authorId: item.authorId,
    previousAuthorId: previous.trailingAuthorId,
    sentAt: item.date,
    previousSentAt: previous.date,
    confirmed: !item.id.startsWith('temp-'),
    previousConfirmed: !previous.id.startsWith('temp-'),
  );
}

class _DiscussionItem {
  const _DiscussionItem({
    required this.id,
    required this.author,
    required this.text,
    this.authorId,
    this.date,
    this.sentAt,
    this.editedAt,
    this.editedDate,
    this.isMe = true,
    this.aiKind,
    this.eventType,
    this.workRequest,
    this.attachments = const [],
    this.replyTo,
  });

  /// The message this one replies to (Reply v1).
  final AxReplyReference? replyTo;
  final String id;
  final String author;
  final String? authorId;

  // Live Work cards contain a human prompt followed by a Worker response.
  // Their leading and trailing authors differ when comparing adjacent rows.
  String? get trailingAuthorId =>
      workRequest == null ? authorId : 'ai:${workRequest!.id}';
  final DateTime? date;
  final String text;
  final String? sentAt;
  final String? editedAt;
  final DateTime? editedDate;
  final bool isMe;

  /// `ai_request` or `ai_answer` for an AI exchange archived from Work history.
  final String? aiKind;
  final String? eventType;
  bool get isAiAnswer => aiKind == 'ai_answer';

  /// Set for a Work Request still in Work history; it renders as the Work
  /// card and has no Chat message to edit or delete.
  final AxWorkRequest? workRequest;
  final List<Map<String, dynamic>> attachments;
}

bool _isOwnWorkRequest(
  AxWorkRequest request,
  String? currentUserId,
  String? currentUserName,
) {
  final rawRequesterName = request.requestedByName.trim();
  final effectiveRequesterName = (rawRequesterName.isEmpty ||
          rawRequesterName == request.requestedByUserId ||
          rawRequesterName.startsWith('usr_'))
      ? 'Team member'
      : rawRequesterName;
  final normalizedRequesterName = effectiveRequesterName.trim().toLowerCase();
  final normalizedCurrentName = currentUserName?.trim().toLowerCase();
  return (currentUserId != null &&
          currentUserId.isNotEmpty &&
          request.requestedByUserId == currentUserId) ||
      (normalizedCurrentName != null &&
          normalizedCurrentName.isNotEmpty &&
          (normalizedRequesterName == normalizedCurrentName ||
              rawRequesterName.toLowerCase() == normalizedCurrentName));
}

/// A Work Request still in Work history, shown in the Conversation with its
/// live Work card rather than as a Chat bubble.
_DiscussionItem _workConversationItem(AxWorkRequest request,
        {String? currentUserId, String? currentUserName}) =>
    _DiscussionItem(
      id: 'work-${request.id}-request',
      author: request.requestedByName,
      authorId: _isOwnWorkRequest(request, currentUserId, currentUserName)
          ? currentUserId
          : request.requestedByUserId,
      date: DateTime.tryParse(request.createdAt)?.toLocal(),
      text: request.prompt,
      aiKind: 'ai_request',
      workRequest: request,
    );

class _DiscussionMessageBubble extends StatefulWidget {
  const _DiscussionMessageBubble({
    required this.item,
    required this.onCopy,
    required this.onEdit,
    this.grouped = false,
    this.onDelete,
    this.onReply,
    this.onEditingChanged,
  });

  /// Reports when the message enters or leaves edit mode, so the page stops
  /// following the newest content while it is being edited.
  final ValueChanged<bool>? onEditingChanged;

  /// Replies to this message; null for removed or unsaved messages.
  final VoidCallback? onReply;
  final _DiscussionItem item;
  final bool grouped;
  final VoidCallback onCopy;
  final ValueChanged<String> onEdit;
  final VoidCallback? onDelete;

  @override
  State<_DiscussionMessageBubble> createState() =>
      _DiscussionMessageBubbleState();
}

class _DiscussionMessageBubbleState extends State<_DiscussionMessageBubble> {
  bool _isEditing = false;
  late TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.item.text);
  }

  @override
  void didUpdateWidget(covariant _DiscussionMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text && !_isEditing) {
      _editController.text = widget.item.text;
    }
  }

  @override
  void dispose() {
    if (_isEditing) widget.onEditingChanged?.call(false);
    _editController.dispose();
    super.dispose();
  }

  void _setEditing(bool editing) {
    if (_isEditing == editing) return;
    setState(() => _isEditing = editing);
    widget.onEditingChanged?.call(editing);
  }

  void _saveEdit() {
    final text = _editController.text;
    if (text.trim().isNotEmpty) {
      widget.onEdit(text);
    }
    _setEditing(false);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        constraints: SyntilaDialogStyle.small,
        title: const Text('Delete message?'),
        content: const Text(
            'Are you sure you want to delete this message? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: SyntilaDialogStyle.destructiveButton(),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && widget.onDelete != null) {
      widget.onDelete!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (widget.item.eventType != null) {
      final removed = widget.item.eventType == 'message.removed';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(removed ? Icons.delete_outline : Icons.info_outline,
              size: 16,
              color: removed
                  ? SyntilaColors.errorText(isDark)
                  : SyntilaColors.textSecondary(isDark)),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
                  '${removed ? "${widget.item.author} · ${widget.item.sentAt ?? ""}\n" : ""}${widget.item.text}${!removed ? " · ${widget.item.sentAt ?? ""}" : ""}',
                  style: TextStyle(
                      color: SyntilaColors.textSecondary(isDark),
                      fontSize: 13))),
        ]),
      );
    }
    final isMe = widget.item.isMe;

    final initials = widget.item.author.isNotEmpty
        ? widget.item.author
            .trim()
            .split(' ')
            .where((s) => s.isNotEmpty)
            .map((s) => s[0])
            .take(2)
            .join()
            .toUpperCase()
        : 'U';

    final metaColor = SyntilaColors.textSecondary(isDark);
    final sent = widget.item.date;
    final sentLabel =
        sent == null ? widget.item.sentAt : _relativeChatTimestamp(sent);
    final edited = widget.item.editedDate;
    final editedLabel =
        edited == null ? widget.item.editedAt : _relativeChatTimestamp(edited);
    final meta = <Widget>[
      if (editedLabel != null) ...[
        Tooltip(
          message: widget.item.editedAt ?? editedLabel,
          child: Text(
            'Edited $editedLabel',
            style: TextStyle(
              fontSize: 12,
              color: metaColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
      ] else if (sentLabel != null) ...[
        Tooltip(
          message: widget.item.sentAt ?? sentLabel,
          child: Text(
            widget.item.aiKind == 'ai_request'
                ? 'Asked AI · $sentLabel'
                : sentLabel,
            style: TextStyle(
              fontSize: 12,
              color: metaColor,
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
      _TimelineActionsMenu(color: metaColor, actions: [
        if (widget.onReply != null && !widget.item.id.startsWith('temp-'))
          _TimelineAction(
            tooltip: 'Reply',
            icon: Icons.reply_rounded,
            color: metaColor,
            onTap: widget.onReply,
          ),
        if (widget.item.aiKind == null &&
            widget.onDelete != null &&
            !widget.item.id.startsWith('temp-')) ...[
          _TimelineAction(
            tooltip: 'Delete',
            icon: Icons.delete_outline_rounded,
            color: metaColor,
            onTap: () => _confirmDelete(context),
          ),
        ],
        if (isMe &&
            !widget.item.id.startsWith('temp-') &&
            widget.item.aiKind == null) ...[
          _TimelineAction(
            tooltip: 'Edit',
            icon: Icons.edit_outlined,
            color: metaColor,
            onTap: () {
              _editController.text = widget.item.text;
              _setEditing(true);
            },
          ),
        ],
        _TimelineAction(
          tooltip: 'Copy',
          icon: Icons.copy_rounded,
          color: metaColor,
          onTap: widget.onCopy,
        ),
      ]),
    ];
    return _MessageHover(
        builder: (context, showMeta) => LayoutBuilder(
              builder: (context, constraints) {
                final maxBubbleWidth =
                    math.min(640.0, constraints.maxWidth * 0.9);
                return Align(
                  alignment:
                      isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minWidth: maxBubbleWidth, maxWidth: maxBubbleWidth),
                    child: _withMessageMeta(
                      own: isMe,
                      visible: showMeta && !_isEditing,
                      meta: meta,
                      background: isMe
                          ? SyntilaColors.ownMessageBackground(isDark)
                          : Colors.transparent,
                      bubble: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: EdgeInsets.fromLTRB(isMe ? 14 : 0, 8, 14, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!isMe && !widget.grouped) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircleAvatar(
                                    radius: 12,
                                    backgroundColor:
                                        SyntilaColors.primarySoftColor(isDark),
                                    child: widget.item.isAiAnswer
                                        ? Icon(Icons.auto_awesome_rounded,
                                            size: 13,
                                            color:
                                                SyntilaColors.primaryForeground(
                                                    isDark))
                                        : Text(
                                            initials,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: SyntilaColors
                                                  .primaryForeground(isDark),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    widget.item.author,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color:
                                          SyntilaColors.textSecondary(isDark),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                            ],
                            if (widget.item.replyTo != null)
                              _ReplyQuote(reference: widget.item.replyTo!),
                            if (widget.item.attachments.isNotEmpty)
                              AttachmentCards(files: widget.item.attachments),
                            if (_isEditing) ...[
                              MarkdownComposer(
                                controller: _editController,
                                compact: true,
                                maxLines: 6,
                                autofocus: true,
                                chatStyle: true,
                                onSubmit: _saveEdit,
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      _editController.text = widget.item.text;
                                      _setEditing(false);
                                    },
                                    child: const Text('Cancel'),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton(
                                    onPressed: _saveEdit,
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            ] else ...[
                              CollapsibleOwnMessage(
                                data: widget.item.text,
                                enabled: isMe,
                                toggleColor: metaColor,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                child: _MemoizedWorkMarkdown(
                                  data: widget.item.text,
                                  fitContent: true,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ));
  }
}

/// Reveals a message's date/time and actions while the pointer is over it.
/// Touch platforms have no hover, so a tap on the message toggles it.
class _MessageHover extends StatefulWidget {
  const _MessageHover({required this.builder});

  final Widget Function(BuildContext context, bool showMeta) builder;

  @override
  State<_MessageHover> createState() => _MessageHoverState();
}

class _MessageHoverState extends State<_MessageHover> {
  bool _hovered = false;
  bool _focused = false;
  bool _tapped = false;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: touch ? () => setState(() => _tapped = !_tapped) : null,
        child: Focus(
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: widget.builder(
              context, _hovered || _focused || (touch && _tapped)),
        ),
      ),
    );
  }
}

/// Recent messages read as "5m ago"; anything older than a week shows the
/// full date and time.
String _relativeChatTimestamp(DateTime value) {
  final age = DateTime.now().difference(value);
  if (age.isNegative || age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  if (age.inDays < 1) return '${age.inHours}h ago';
  if (age.inDays < 7) {
    return age.inDays == 1 ? 'yesterday' : '${age.inDays}d ago';
  }
  return _chatTimestamp(value);
}

class _TimelineAction {
  const _TimelineAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;
}

/// Every action as its own icon button; no popup menu.
class _TimelineActionsMenu extends StatelessWidget {
  const _TimelineActionsMenu({required this.actions, required this.color});

  final List<_TimelineAction> actions;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touch =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final buttonSize = touch ? 40.0 : 28.0;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final action in actions)
        SizedBox.square(
          dimension: buttonSize,
          child: IconButton(
            tooltip: action.tooltip,
            constraints:
                BoxConstraints.tightFor(width: buttonSize, height: buttonSize),
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6))),
            icon: Icon(action.icon, size: 16, color: action.color ?? color),
            onPressed: action.onTap,
          ),
        ),
    ]);
  }
}

/// A message bubble with its date/time and action icons laid over the
/// bottom-right corner, on the bubble's own background. A short last line
/// leaves them beside the text; a long one is covered at its end. The row
/// fades in on hover (or tap on touch) and takes no layout space.
Widget _withMessageMeta({
  required Widget bubble,
  required bool own,
  required bool visible,
  required List<Widget> meta,
  Color background = Colors.transparent,
}) =>
    Builder(builder: (context) {
      final base = background.a == 0
          ? Theme.of(context).scaffoldBackgroundColor
          : background;
      return DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            bubble,
            Positioned(
              right: own ? 14 : 4,
              bottom: own ? 2 : -4,
              child: IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                        base.withAlpha(0),
                        base,
                      ], stops: const [
                        0,
                        0.2
                      ]),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: meta,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });

/// Keyboard-driven list of earlier requests, opened with Arrow Up/Down in an
/// empty composer. Enter copies the highlighted prompt into the composer.
class _RequestHistoryPanel extends StatefulWidget {
  const _RequestHistoryPanel({
    required this.prompts,
    required this.openDirection,
    required this.onSelected,
    required this.onClosed,
    this.joinsInput = true,
  });

  final List<String> prompts;
  final int openDirection;
  final ValueChanged<String> onSelected;
  final VoidCallback onClosed;
  final bool joinsInput;

  @override
  State<_RequestHistoryPanel> createState() => _RequestHistoryPanelState();
}

class _RequestHistoryPanelState extends State<_RequestHistoryPanel> {
  final _focus = FocusNode(debugLabel: 'request-history');
  final _scroll = ScrollController();
  FocusNode? _previousFocus;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _previousFocus = FocusManager.instance.primaryFocus;
    if (widget.openDirection < 0 && widget.prompts.isNotEmpty) {
      _selected = widget.prompts.length - 1;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      if (_scroll.hasClients) {
        _scroll.jumpTo(_selected == 0 ? 0 : _scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _previousFocus?.requestFocus();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _move(int delta) {
    if (widget.prompts.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, widget.prompts.length - 1);
    });
    const itemExtent = 48.0;
    final target = _selected * itemExtent;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (target < position.pixels) {
      _scroll.jumpTo(target);
    } else if (target + itemExtent >
        position.pixels + position.viewportDimension) {
      _scroll.jumpTo(target + itemExtent - position.viewportDimension);
    }
  }

  void _select(int index) {
    if (index < 0 || index >= widget.prompts.length) return;
    widget.onSelected(widget.prompts[index]);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _ComposerPanelLayer(
      backgroundKey: const ValueKey('request-history-layer-background'),
      joinsInput: widget.joinsInput,
      horizontalInset: 40,
      background: SyntilaColors.composerBackground(isDark),
      child: TapRegion(
        onTapOutside: (_) => widget.onClosed(),
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            final key = event.logicalKey;
            if (key == LogicalKeyboardKey.arrowUp) {
              _move(-1);
            } else if (key == LogicalKeyboardKey.arrowDown) {
              _move(1);
            } else if (key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.numpadEnter) {
              _select(_selected);
            } else if (key == LogicalKeyboardKey.escape) {
              widget.onClosed();
            } else {
              return KeyEventResult.ignored;
            }
            return KeyEventResult.handled;
          },
          child: Container(
            key: const ValueKey('request-history-panel'),
            constraints: const BoxConstraints(maxHeight: 289),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: widget.prompts.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No earlier requests in this thread.',
                              style: TextStyle(fontSize: 12)),
                        )
                      : ListView.builder(
                          key: const ValueKey('request-history-list'),
                          controller: _scroll,
                          shrinkWrap: true,
                          itemExtent: 48,
                          itemCount: widget.prompts.length,
                          itemBuilder: (context, index) => InkWell(
                            onTap: () => _select(index),
                            child: Container(
                              color: index == _selected
                                  ? SyntilaColors.navigationSelectedColor(
                                      isDark)
                                  : null,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.prompts[index].trim(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Divider(
                    key: const ValueKey('request-history-bottom-line'),
                    height: 1,
                    thickness: 1,
                    color: SyntilaColors.composerRail(isDark),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A Work message waiting to be sent after the processing request finishes.
class _QueuedWorkMessage {
  const _QueuedWorkMessage({
    required this.text,
    required this.attachments,
    required this.executionSelection,
    required this.workflow,
    this.replyTo,
    this.id,
    this.authorName = '',
    this.own = true,
  });

  /// A request in the Thread's shared queue, which only its author changes.
  factory _QueuedWorkMessage.fromQueueItem(AxThreadQueueItem item,
          {required bool own}) =>
      _QueuedWorkMessage(
        id: item.id,
        text: item.text,
        attachments: item.attachments,
        executionSelection: item.executionSelection,
        workflow: '${item.workflowId}:v${item.workflowVersion}',
        replyTo: item.replyTo,
        authorName: item.authorName,
        own: own,
      );

  /// The shared queue item; null for a message in the local queue.
  final String? id;
  final String authorName;

  /// Whether the viewer queued it and so may edit, remove or send it now.
  final bool own;

  final AxReplyReference? replyTo;
  final String text;
  final List<Map<String, dynamic>> attachments;
  final Map<String, dynamic> executionSelection;
  final String workflow;
}

/// Why queued messages are not being sent.
enum _WorkQueuePause {
  /// A send or the processing request failed.
  failure,

  /// The user paused the queue.
  user,
}

/// An inset queue layer whose background extends behind the active composer.
class _QueuedMessagesPanel extends StatelessWidget {
  const _QueuedMessagesPanel({
    required this.messages,
    required this.pause,
    required this.onPauseChanged,
    required this.onEdit,
    required this.onRemove,
    required this.onSendNow,
    required this.hasPanelAbove,
  });

  final List<_QueuedWorkMessage> messages;
  final _WorkQueuePause? pause;
  final ValueChanged<bool> onPauseChanged;
  final ValueChanged<_QueuedWorkMessage> onEdit;
  final ValueChanged<_QueuedWorkMessage> onRemove;
  final ValueChanged<_QueuedWorkMessage> onSendNow;
  final bool hasPanelAbove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const iconConstraints = BoxConstraints.tightFor(width: 28, height: 28);
    return _ComposerPanelLayer(
      backgroundKey: const ValueKey('work-queue-layer-background'),
      // Span the input's central area, between the 40px composer rails.
      horizontalInset: 40,
      background: SyntilaColors.composerBackground(isDark),
      child: Container(
        key: const ValueKey('work-queue-panel'),
        constraints: const BoxConstraints(maxHeight: 192),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasPanelAbove)
              Divider(
                key: const ValueKey('work-queue-panel-divider'),
                height: 1,
                thickness: 1,
                color: SyntilaColors.navigationBorder(isDark),
              ),
            Container(
              key: const ValueKey('work-queue-header'),
              color: SyntilaColors.composerRail(isDark),
              padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
              child: Row(children: [
                Expanded(
                  child: Text(
                    switch (pause) {
                      _WorkQueuePause.failure =>
                        'Queued · ${messages.length} — paused after an error',
                      _WorkQueuePause.user =>
                        'Queued · ${messages.length} — paused',
                      null => 'Queued · ${messages.length}',
                    },
                    key: const ValueKey('work-queue-status'),
                    style: TextStyle(
                      fontSize: 11,
                      color: pause == _WorkQueuePause.failure
                          ? colors.error
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('work-queue-pause-toggle'),
                  tooltip: pause == null ? 'Pause queue' : 'Resume queue',
                  iconSize: 16,
                  constraints: iconConstraints,
                  padding: EdgeInsets.zero,
                  onPressed: () => onPauseChanged(pause == null),
                  icon: Icon(pause == null
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
                ),
              ]),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemExtent: 48,
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  final body = message.text.trim().isEmpty
                      ? '${message.attachments.length} attachment(s)'
                      : message.text.trim();
                  // Other members' requests are shown, never changed.
                  final text = message.own || message.authorName.isEmpty
                      ? body
                      : '${message.authorName}: $body';
                  return InkWell(
                    key: ValueKey('work-queue-item-$index'),
                    onTap: message.own ? () => onEdit(message) : null,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 4),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (message.own) ...[
                          IconButton(
                            tooltip: 'Edit',
                            iconSize: 16,
                            constraints: iconConstraints,
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => onEdit(message),
                          ),
                          IconButton(
                            tooltip: 'Send now',
                            iconSize: 16,
                            constraints: iconConstraints,
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.arrow_upward_rounded),
                            onPressed: () => onSendNow(message),
                          ),
                          IconButton(
                            tooltip: 'Remove from queue',
                            iconSize: 16,
                            constraints: iconConstraints,
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => onRemove(message),
                          ),
                        ],
                      ]),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Divider(
                key: const ValueKey('work-queue-bottom-line'),
                height: 1,
                thickness: 1,
                color: SyntilaColors.composerRail(isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared geometry for composer panels. Only the nearest panel extends its
/// background behind the input; upper panels end flush against the next layer.
class _ComposerPanelLayer extends StatelessWidget {
  const _ComposerPanelLayer({
    required this.backgroundKey,
    required this.child,
    this.joinsInput = true,
    this.horizontalInset = 8,
    this.background,
  });

  final Key backgroundKey;
  final Widget child;
  final bool joinsInput;
  final double horizontalInset;
  final Color? background;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: horizontalInset),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              bottom: joinsInput ? -10 : 0,
              child: DecoratedBox(
                key: backgroundKey,
                decoration: BoxDecoration(
                  color: background ??
                      SyntilaColors.composerRail(
                          Theme.of(context).brightness == Brightness.dark),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(10),
                  ),
                ),
              ),
            ),
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(10)),
              child: child,
            ),
          ],
        ),
      );
}

/// Longest quote shown in the UI; Cloud keeps a longer one for the Worker.
const _replyPreviewChars = 240;

/// Trims text for the quote shown in a composer or message.
String replyExcerpt(String text) {
  final trimmed = text.trim();
  return trimmed.length > _replyPreviewChars
      ? '${trimmed.substring(0, _replyPreviewChars - 1)}…'
      : trimmed;
}

/// Names the attachments of a message that has no text.
String attachmentsLabel(List<Map<String, dynamic>> files) {
  final names = files.map((file) => file['name']?.toString() ?? 'file');
  return names.isEmpty ? '' : '📎 ${names.join(', ')}';
}

/// The reply banner and attachment cards shown above a composer's input.
Widget? _composerExtras({
  required AxReplyReference? reply,
  required VoidCallback? onClearReply,
  required List<Map<String, dynamic>> files,
  required ValueChanged<int>? onRemoveFile,
}) {
  if (reply == null && files.isEmpty) return null;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (reply != null)
        _ReplyComposerBanner(reference: reply, onClear: onClearReply),
      if (files.isNotEmpty)
        AttachmentCards(files: files, onRemove: onRemoveFile),
    ],
  );
}

String _replyKindLabel(String kind) => switch (kind) {
      'response' => 'AI response',
      'request' => 'request',
      _ => 'message',
    };

/// "Replying to …" banner above the composer, with a clear button.
class _ReplyComposerBanner extends StatelessWidget {
  const _ReplyComposerBanner({required this.reference, required this.onClear});

  final AxReplyReference reference;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.textSecondary(isDark);
    return Semantics(
      container: true,
      label: 'Replying to ${reference.authorName}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(children: [
          Icon(Icons.reply_rounded, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: 'Replying to ${reference.authorName}  ',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: reference.excerpt.replaceAll('\n', ' ')),
              ]),
              key: const ValueKey('reply-composer-banner'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
          IconButton(
            key: const ValueKey('reply-clear'),
            tooltip: 'Cancel reply',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: Icon(Icons.close_rounded, size: 16, color: muted),
            onPressed: onClear,
          ),
        ]),
      ),
    );
  }
}

class _ReplyNavigation extends InheritedWidget {
  const _ReplyNavigation({required this.navigate, required super.child});
  final ValueChanged<AxReplyReference> navigate;
  @override
  bool updateShouldNotify(_ReplyNavigation oldWidget) => true;
}

/// The quoted message shown above a reply, as in other messengers.
class _ReplyQuote extends StatelessWidget {
  const _ReplyQuote({required this.reference});

  final AxReplyReference reference;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = SyntilaColors.textSecondary(isDark);
    final excerpt = reference.excerpt.isEmpty
        ? 'Original message unavailable'
        : replyExcerpt(reference.excerpt);
    return Semantics(
      container: true,
      label:
          'Reply to ${_replyKindLabel(reference.kind)} from ${reference.authorName}: $excerpt',
      child: InkWell(
        onTap: () => context
            .findAncestorWidgetOfExactType<_ReplyNavigation>()
            ?.navigate(reference),
        child: Container(
          key: ValueKey('reply-quote-${reference.id}'),
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          decoration: BoxDecoration(
            border: Border(
                left:
                    BorderSide(color: muted.withValues(alpha: 0.6), width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(reference.authorName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: muted)),
              Text(excerpt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: muted)),
            ],
          ),
        ),
      ),
    );
  }
}
