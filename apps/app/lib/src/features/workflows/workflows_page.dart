import 'dart:async';
import 'package:syntila_design/syntila_design.dart';
import 'dart:math' as math;
import '../common/quiet_notices.dart';
import 'package:flutter/material.dart';
import '../../ax/ax_models.dart';
import '../../ax/worker_presentation.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import 'workflow_editor.dart';
import 'workflow_visibility.dart';

class WorkflowsPage extends StatefulWidget {
  const WorkflowsPage(
      {super.key,
      required this.catalogs,
      required this.configurations,
      this.viewerEmail,
      required this.workspaceId,
      this.canEdit = true,
      this.showWorkspaceAction = true});
  final bool canEdit;
  final bool showWorkspaceAction;

  /// The Workspace whose workflows this section edits, shown in its tab.
  /// [configurations] must be scoped to the same Workspace
  /// (`AxWorkflowConfigurations.forWorkspace`). Whether the Workspace is the
  /// one new Work runs on is shown and changed here.
  final String workspaceId;
  final AxSessionCatalogs catalogs;
  final AxWorkflowConfigurations configurations;
  final String? viewerEmail;
  @override
  State<WorkflowsPage> createState() => _WorkflowsPageState();
}

class _WorkflowsPageState extends State<WorkflowsPage> {
  bool _changingWorkspace = false;
  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(WorkflowsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.configurations != widget.configurations ||
        oldWidget.catalogs != widget.catalogs) {
      _ensure();
    }
  }

  void _ensure() {
    unawaited(widget.configurations
        .ensureWorkspace()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.configurations
        .ensure()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.configurations
        .ensureDefault()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.catalogs.engine
        .ensure(widget.catalogs.workflows, policy: AxCachePolicy.cacheFirst)
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    unawaited(widget.catalogs
        .ensureWorkers()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> _refresh() async {
    try {
      await Future.wait([
        widget.configurations.refresh(),
        widget.configurations.refreshDefault(),
        widget.configurations.engine
            .refresh(widget.configurations.workspaceQuery),
        widget.catalogs.engine.refresh(widget.catalogs.workflows),
        widget.catalogs.refreshWorkers(),
      ]);
    } catch (_) {/* Errors are shown by the resource queries. */}
  }

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        ensure: false,
        builder: (context, workspaceState) =>
            _buildPage(context, workspaceState),
      );
  Widget _buildPage(BuildContext context,
          AxQueryState<AxWorkflowWorkspaceSettings> workspaceState) =>
      AxQueryBuilder(
        engine: widget.catalogs.engine,
        query: widget.catalogs.workflows,
        ensure: false,
        builder: (context, definitions) => AxQueryBuilder(
          engine: widget.configurations.engine,
          query: widget.configurations.query,
          ensure: false,
          builder: (context, preferences) => AxQueryBuilder(
            engine: widget.configurations.engine,
            query: widget.configurations.defaultQuery,
            ensure: false,
            builder: (context, defaultState) => AxQueryBuilder(
              engine: widget.catalogs.engine,
              query: widget.catalogs.workers,
              ensure: false,
              builder: (context, inventory) {
                final workflows = <String, AxBuiltinWorkflow>{};
                for (final definition in visibleWorkflowDefinitions(
                    definitions.data ?? const <AxBuiltinWorkflow>[],
                    viewerEmail: widget.viewerEmail)) {
                  if ((workflows[definition.id]?.version ?? 0) <
                      definition.version) {
                    workflows[definition.id] = definition;
                  }
                }
                final workers = (inventory.data ?? const <AxWorker>[])
                    .where((worker) => worker.workspaceId == widget.workspaceId)
                    .toList();
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Workflows',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      if (workspaceState.hasData) ...[
                        if (_activeRow(context, workspaceState.data!) !=
                            null) ...[
                          _activeRow(context, workspaceState.data!)!,
                          const SizedBox(height: 12),
                        ],
                      ] else if (workspaceState.error != null)
                        TextButton.icon(
                          onPressed: _refresh,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text(
                              'Workspace settings could not be loaded. Tap to retry.'),
                        ),
                      if (definitions.error != null ||
                          preferences.error != null ||
                          inventory.error != null)
                        Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                                'Some workflow data could not be loaded.',
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error))),
                      const SizedBox(height: 18),
                      if (!definitions.hasData || !preferences.hasData)
                        if (definitions.isFetching || preferences.isFetching)
                          const Padding(
                              padding: EdgeInsets.all(24),
                              child: Center(child: CircularProgressIndicator()))
                        else
                          Row(
                            children: [
                              const Text(
                                  'Workflow configuration is unavailable.'),
                              const SizedBox(width: 8),
                              TextButton.icon(
                                onPressed: _refresh,
                                icon: const Icon(Icons.refresh, size: 16),
                                label: const Text('Retry'),
                              ),
                            ],
                          )
                      else if (workflows.isEmpty)
                        const Text('No workflows are available.')
                      else
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final workflowList = workflows.values.toList();
                            final cards = [
                              for (final definition in workflowList)
                                _card(
                                    definition,
                                    _configuration(
                                        preferences.data!, definition.id),
                                    workers,
                                    defaultState.data == definition.id &&
                                        (definition.id == 'chat' ||
                                            _configuration(preferences.data!,
                                                    definition.id)
                                                .enabled)),
                            ];

                            const double gap = 12;
                            final double availableWidth = constraints.maxWidth;
                            final int columns =
                                (availableWidth / 240).floor().clamp(1, 4);

                            if (columns == 1) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (int i = 0; i < cards.length; i++) ...[
                                    if (i > 0) const SizedBox(height: gap),
                                    // Cards use a Spacer, so they need a
                                    // bounded height in this unbounded Column.
                                    IntrinsicHeight(child: cards[i]),
                                  ],
                                ],
                              );
                            }

                            final List<List<Widget>> rows = [];
                            for (int i = 0; i < cards.length; i += columns) {
                              rows.add(cards.sublist(
                                  i,
                                  (i + columns < cards.length)
                                      ? i + columns
                                      : cards.length));
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (int r = 0; r < rows.length; r++) ...[
                                  if (r > 0) const SizedBox(height: gap),
                                  IntrinsicHeight(
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        for (int c = 0; c < columns; c++) ...[
                                          if (c > 0) const SizedBox(width: gap),
                                          Expanded(
                                            child: c < rows[r].length
                                                ? rows[r][c]
                                                : const SizedBox.shrink(),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                    ]);
              },
            ),
          ),
        ),
      );

  /// Embedded tab header: whether new Work runs on this Workspace, or a way to
  /// make it so.
  /// Embedded tab header: whether another Workspace is active, offering a way to
  /// make this Workspace active for new Work.
  Widget? _activeRow(
      BuildContext context, AxWorkflowWorkspaceSettings settings) {
    final active = settings.workspaceId == widget.workspaceId;
    if (active || !widget.showWorkspaceAction) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
          key: const ValueKey('use-workspace-for-workflows'),
          onPressed: widget.canEdit && !_changingWorkspace
              ? () => _selectWorkspace(settings)
              : null,
          child: const Text('Use this Workspace')),
    );
  }

  AxUserWorkflowConfiguration _configuration(
          List<AxUserWorkflowConfiguration> values, String id) =>
      values.firstWhere((value) => value.workflowId == id,
          orElse: () => AxUserWorkflowConfiguration(workflowId: id));
  Widget _card(
      AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration,
      List<AxWorker> workers,
      bool isDefault) {
    final selection = definition.steps.length == 1
        ? configuration.selectionFor(definition.steps.first.kind)
        : configuration.defaults;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final selectedWorker =
        workers.where((worker) => worker.id == selection.worker).firstOrNull;

    final models = selectedWorker?.executionOptions?.models
            .where((m) => m.status != 'unavailable')
            .toList() ??
        const <AxWorkerModelOption>[];
    final allowsAutoModel = selectedWorker == null ||
        (selectedWorker.executionOptions?.models
                .every((m) => m.selectionMode != 'combined') ??
            true);

    final selectedModelOption =
        models.where((m) => m.id == selection.model).firstOrNull;
    final modelEfforts = selectedModelOption?.effort.supported == true
        ? selectedModelOption!.effort.values
        : (selectedWorker?.executionOptions?.effort.supported == true
            ? selectedWorker!.executionOptions!.effort.values
            : const <String>[]);

    final descriptionStyle = TextStyle(color: colors.onSurfaceVariant);
    final descriptionMetrics = TextPainter(
      text: TextSpan(
          text: ' ',
          style: DefaultTextStyle.of(context).style.merge(descriptionStyle)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final descriptionHeight = descriptionMetrics.preferredLineHeight * 2;
    descriptionMetrics.dispose();

    final isChat = definition.id == 'chat';
    final isEnabled = isChat || configuration.enabled;

    Future<void> updateSelection(AxWorkflowSelection next) async {
      try {
        final AxUserWorkflowConfiguration updated;
        if (definition.steps.length == 1) {
          final stepKind = definition.steps.first.kind;
          final overrides = Map<String, AxWorkflowSelection>.from(
              configuration.stepOverrides);
          overrides[stepKind] = next;
          updated = AxUserWorkflowConfiguration(
            workflowId: definition.id,
            enabled: configuration.enabled,
            defaults: next,
            stepOverrides: overrides,
          );
        } else {
          updated = AxUserWorkflowConfiguration(
            workflowId: definition.id,
            enabled: configuration.enabled,
            defaults: next,
            stepOverrides: configuration.stepOverrides,
          );
        }
        await widget.configurations.save(updated);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showNotice(SnackBar(content: Text(error.toString())));
        }
      }
    }

    return Card(
        key: ValueKey('workflow-${definition.id}'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    definition.name,
                    maxLines: 1,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Transform.scale(
                  scale: 0.8,
                  alignment: Alignment.centerRight,
                  child: Switch(
                    value: isEnabled,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: widget.canEdit && !_changingWorkspace && !isChat
                        ? (value) async {
                            try {
                              await widget.configurations
                                  .save(AxUserWorkflowConfiguration(
                                workflowId: configuration.workflowId,
                                enabled: value,
                                defaults: configuration.defaults,
                                stepOverrides: configuration.stepOverrides,
                              ));
                            } catch (error) {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showNotice(
                                    SnackBar(content: Text(error.toString())));
                              }
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Reserve both description lines so Worker selectors align across cards.
            SizedBox(
              height: descriptionHeight,
              child: Text(definition.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: descriptionStyle),
            ),
            const SizedBox(height: 12),
            // Worker selection with icons
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final worker in workers)
                  Builder(builder: (context) {
                    final isSelected = worker.id == selection.worker;
                    return Semantics(
                      label: worker.displayName,
                      selected: isSelected,
                      child: Tooltip(
                        message:
                            '${worker.displayName}${worker.isReady ? '' : ' · Unavailable'}',
                        child: Material(
                          color: isSelected
                              ? colors.secondaryContainer
                              : colors.surfaceContainerHighest
                                  .withValues(alpha: 0.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: SyntilaRadius.radiusSm,
                            side: BorderSide(
                              color: isSelected
                                  ? colors.primary
                                  : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          child: InkWell(
                            key: ValueKey(
                                'workflow-worker-${definition.id}-${worker.id}'),
                            borderRadius: SyntilaRadius.radiusSm,
                            onTap: widget.canEdit && !_changingWorkspace
                                ? () {
                                    final newWorkerId =
                                        isSelected ? null : worker.id;
                                    updateSelection(AxWorkflowSelection(
                                      worker: newWorkerId,
                                      model: null,
                                      effort: null,
                                    ));
                                  }
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Opacity(
                                opacity: isSelected ? 1.0 : 0.6,
                                child: _workerIconWidget(worker),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                if (selectedWorker != null && !selectedWorker.isReady)
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning_amber,
                            size: 16, color: SyntilaColors.warningText(isDark)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${selectedWorker.displayName} · Unavailable',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color: colors.onErrorContainer,
                                    fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (selection.worker != null &&
                    selection.worker!.isNotEmpty &&
                    !workers.any((w) => w.id == selection.worker))
                  Container(
                    margin: const EdgeInsets.only(top: 4),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: colors.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.warning_amber,
                            size: 16, color: SyntilaColors.warningText(isDark)),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            // The saved Worker id belongs to a Worker that is
                            // not in this Workspace (removed, or a different
                            // Workspace/environment). Do not show the raw id.
                            'Saved Worker is no longer available',
                            key: ValueKey(
                                'workflow-missing-worker-${definition.id}'),
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color: colors.onErrorContainer,
                                    fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (widget.canEdit && !_changingWorkspace)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: InkWell(
                              key: ValueKey(
                                  'workflow-clear-worker-${definition.id}'),
                              onTap: () => updateSelection(
                                  const AxWorkflowSelection(
                                      worker: null, model: null, effort: null)),
                              child: Text('Clear',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(
                                          color: colors.onErrorContainer,
                                          decoration:
                                              TextDecoration.underline)),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            // Compact selector shared visually with the Work composer.
            PopupMenuButton<String>(
              key: ValueKey('workflow-model-${definition.id}'),
              enabled: widget.canEdit &&
                  !_changingWorkspace &&
                  selectedWorker != null,
              tooltip: 'Choose model',
              color: SyntilaColors.composerBackground(
                  Theme.of(context).brightness == Brightness.dark),
              surfaceTintColor: Colors.transparent,
              elevation: 12,
              shadowColor: SyntilaMenuStyle.shadow(
                  Theme.of(context).brightness == Brightness.dark),
              shape: SyntilaMenuStyle.shape(
                  Theme.of(context).brightness == Brightness.dark),
              menuPadding: SyntilaMenuStyle.padding,
              itemBuilder: (context) {
                final choices = <String, String>{
                  '': allowsAutoModel ? 'Auto' : 'Select model...',
                  if (selection.model?.isNotEmpty == true)
                    selection.model!: selection.model!,
                  for (final model in models) model.id: model.name,
                };
                return [
                  for (final choice in choices.entries)
                    SyntilaMenuEntry<String>(
                      value: choice.key,
                      child: MenuItemButton(
                        style: SyntilaMenuStyle.item(
                            Theme.of(context).brightness == Brightness.dark),
                        leadingIcon: Icon(
                          choice.key == (selection.model ?? '')
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          size: 15,
                        ),
                        onPressed: () => Navigator.pop(context, choice.key),
                        child: Text(choice.value,
                            style: SyntilaMenuStyle.textStyle),
                      ),
                    ),
                ];
              },
              onSelected: widget.canEdit &&
                      !_changingWorkspace &&
                      selectedWorker != null
                  ? (modelId) {
                      final newModelId = modelId.isEmpty ? null : modelId;
                      final newModel =
                          models.where((m) => m.id == newModelId).firstOrNull;
                      final newEfforts = newModel?.effort.supported == true
                          ? newModel!.effort.values
                          : modelEfforts;
                      String? newEffort = newEfforts.contains(selection.effort)
                          ? selection.effort
                          : null;
                      if (newEffort == null &&
                          newModel != null &&
                          newModel.selectionMode == 'combined' &&
                          newModel.effort.supported &&
                          newEfforts.isNotEmpty &&
                          newModel.effort.defaultValue == null) {
                        newEffort = newEfforts.first;
                      }
                      updateSelection(AxWorkflowSelection(
                        worker: selection.worker,
                        model: newModelId,
                        effort: newEffort,
                      ));
                    }
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  children: [
                    Flexible(
                        child: Text(
                      models
                              .where((model) => model.id == selection.model)
                              .firstOrNull
                              ?.name ??
                          selection.model ??
                          (allowsAutoModel ? 'Auto' : 'Select model...'),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    )),
                    const SizedBox(width: 2),
                    const Icon(Icons.keyboard_arrow_down, size: 14),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            // Effort line
            Builder(builder: (context) {
              final levels = <String?>[
                null,
                ...modelEfforts,
              ];
              var activeIndex = levels.indexOf(selection.effort);
              if (activeIndex < 0 &&
                  selection.effort != null &&
                  selection.effort!.isNotEmpty) {
                levels.add(selection.effort);
                activeIndex = levels.length - 1;
              }
              final sliderValue =
                  math.max(0, activeIndex < 0 ? 0 : activeIndex).toDouble();
              final maxDivision = math.max(1, levels.length - 1);
              final displayEffortName = activeIndex < 0
                  ? (selection.effort != null && selection.effort!.isNotEmpty
                      ? _label(selection.effort)
                      : 'Auto')
                  : (levels[activeIndex] == null
                      ? 'Auto'
                      : _label(levels[activeIndex]));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Effort · ',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          displayEffortName,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      key: ValueKey('workflow-effort-${definition.id}'),
                      value: sliderValue,
                      min: 0,
                      max: maxDivision.toDouble(),
                      divisions: maxDivision,
                      semanticFormatterCallback: (pos) {
                        final idx = pos.round().clamp(0, levels.length - 1);
                        final val = levels[idx];
                        return val == null ? 'Auto' : _label(val);
                      },
                      onChanged: widget.canEdit &&
                              !_changingWorkspace &&
                              modelEfforts.isNotEmpty
                          ? (pos) {
                              final idx =
                                  pos.round().clamp(0, levels.length - 1);
                              final nextEffort = levels[idx];
                              updateSelection(AxWorkflowSelection(
                                worker: selection.worker,
                                model: selection.model,
                                effort: nextEffort,
                              ));
                            }
                          : null,
                    ),
                  ),
                ],
              );
            }),
            const Spacer(),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (isDefault)
                  Flexible(
                    child: Container(
                      key: ValueKey('workflow-default-${definition.id}'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        border: Border.all(
                          color: colors.primary.withValues(alpha: 0.35),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle_rounded,
                              size: 13, color: colors.primary),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'Default',
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: colors.primary,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!isEnabled)
                  Flexible(
                    child: Container(
                      key: ValueKey('workflow-status-${definition.id}'),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Disabled',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: TextButton(
                      key: ValueKey('workflow-make-default-${definition.id}'),
                      onPressed: widget.canEdit && !_changingWorkspace
                          ? () async {
                              try {
                                await widget.configurations
                                    .setDefault(definition.id);
                              } catch (error) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showNotice(
                                      SnackBar(
                                          content: Text(error.toString())));
                                }
                              }
                            }
                          : null,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                      ),
                      child: const Text(
                        'Make default',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                if (definition.steps.length > 1)
                  InkWell(
                    key: ValueKey('open-workflow-${definition.id}'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: widget.canEdit && !_changingWorkspace
                        ? () => _edit(definition, configuration)
                        : null,
                    child: TextButton.icon(
                      key: ValueKey('workflow-advanced-${definition.id}'),
                      onPressed: widget.canEdit && !_changingWorkspace
                          ? () => _edit(definition, configuration)
                          : null,
                      icon: const Icon(Icons.tune, size: 14),
                      label: Text(
                          '${definition.steps.length} ${definition.steps.length == 1 ? 'step' : 'steps'}'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                      ),
                    ),
                  ),
              ],
            ),
          ]),
        ));
  }

  Widget _workerIconWidget(AxWorker worker) {
    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.displayName,
      profileDefinitionId: worker.profileDefinitionId,
      providerToolName: worker.providerToolName,
    );
    final workerIcon =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    if (workerIcon != null) {
      return Image.asset(
        workerIcon,
        width: 18,
        height: 18,
        fit: BoxFit.contain,
        semanticLabel: '${worker.displayName} icon',
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Icon(
      worker.isReady ? Icons.smart_toy_outlined : Icons.warning_amber,
      size: 18,
      color: worker.isReady ? null : SyntilaColors.warningText(isDark),
    );
  }

  /// Makes this Workspace the one new Work runs on. Workflow settings are kept
  /// per Workspace, so nothing of the other Workspaces is lost.
  Future<void> _selectWorkspace(AxWorkflowWorkspaceSettings current) async {
    if (widget.workspaceId == current.workspaceId || _changingWorkspace) return;
    setState(() => _changingWorkspace = true);
    try {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  constraints: SyntilaDialogStyle.small,
                  title: const Text('Use this Workspace?'),
                  content: const Text(
                      'New Work will run on this Workspace using its own workflow settings. Workflow settings of other Workspaces are kept. Workflow overrides of Spaces using the global Workspace are reset, and existing runs keep their recorded settings.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Use Workspace'))
                  ]));
      if (confirmed != true || !mounted) return;
      await widget.configurations.selectWorkspace(widget.workspaceId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _changingWorkspace = false);
    }
  }

  Future<void> _edit(AxBuiltinWorkflow definition,
      AxUserWorkflowConfiguration configuration) async {
    await WorkflowEditor.open(
        context,
        WorkflowEditor(
          stepsOnly: true,
          definition: definition,
          configuration: configuration,
          catalogs: widget.catalogs,
          workspaceId: widget.workspaceId,
          cache: widget.configurations,
        ));
  }
}

String _label(String? value) =>
    value == null ? 'Auto' : '${value[0].toUpperCase()}${value.substring(1)}';
