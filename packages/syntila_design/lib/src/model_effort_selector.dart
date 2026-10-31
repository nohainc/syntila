import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart';

import 'menu_style.dart';
import 'colors.dart';

/// Controlled selector: catalog refreshes never modify a saved selection.
class ModelEffortSelector extends StatefulWidget {
  const ModelEffortSelector(
      {super.key,
      required this.catalog,
      required this.value,
      this.inherited = const ExecutionSelection(),
      this.onChanged,
      this.showWorker = true,
      this.showModel = true,
      this.showEffort = true,
      this.readOnly = false,
      this.loading = false,
      this.compact = false,
      this.menuPickers = false,
      this.immediatePopup = false,
      this.workerIconBuilder,
      this.modelIconBuilder,
      this.compactModelLabelBuilder,
      this.scope = 'execution',
      this.validationMessage,
      this.helperMessage,
      this.onShowUsage,
      this.showCatalog = true,
      this.allowWorkerChange = true,
      this.allowModelChange = true,
      this.allowEffortChange = true,
      this.showValidationMessage = true,
      this.hideExplicitModelRequirement = false,
      this.hiddenValidationMessages = const <String>{},
      this.showSelectionStateText = true,
      this.showModelEffortGuidance = true,
      this.showWorkerInCompactSummary = true,
      this.compactHeight,
      this.compactIconSize = 18});
  final ExecutionSelectionCatalog catalog;
  final ExecutionSelection value, inherited;
  final ValueChanged<ExecutionSelection>? onChanged;
  final bool showWorker, showModel, showEffort, readOnly, loading, compact;
  final bool showCatalog;

  /// Use application menus for fields inside the compact settings popup.
  final bool menuPickers;

  /// Content-sized Work composer popup with immediately applied selections.
  final bool immediatePopup;
  final Widget Function(WorkerSelectionCapability worker)? workerIconBuilder;
  final Widget Function(WorkerSelectionCapability? worker, String? modelId,
      String? modelName)? modelIconBuilder;
  final String Function(String modelId, String? modelName)?
      compactModelLabelBuilder;
  final bool allowWorkerChange, allowModelChange, allowEffortChange;

  /// Keeps validation available to callers without rendering duplicate inline
  /// errors when the host already gates its primary action.
  final bool showValidationMessage;
  final bool hideExplicitModelRequirement;
  final Set<String> hiddenValidationMessages;
  final bool showSelectionStateText;
  final bool showModelEffortGuidance;
  final bool showWorkerInCompactSummary;

  /// Fixes the compact button height (width stays content-sized) when set.
  final double? compactHeight;
  final double compactIconSize;
  final String scope;
  final String? validationMessage, helperMessage;

  /// Opens the selected Worker's usage report; shown before Restore in the
  /// immediate popup when non-null.
  final VoidCallback? onShowUsage;
  @override
  State<ModelEffortSelector> createState() => _ModelEffortSelectorState();
}

class _ModelEffortSelectorState extends State<ModelEffortSelector> {
  String? _explanation;
  @override
  Widget build(BuildContext context) {
    final effective = widget.inherited.overlay(widget.value);
    final worker = widget.catalog.worker(effective.worker);
    final modelAutoAllowed = worker?.allowsAutoModel ?? true;
    final effortAutoAllowed = worker?.allowsAutoEffort(effective.model) ?? true;
    if (widget.compact) {
      // Model and effort have no meaning until the compact model-only host
      // resolves a Worker. Keep the saved value intact during catalog refreshes.
      final rawModelName = effective.model != null &&
              worker?.supportsModel(effective.model) == true
          ? worker?.model(effective.model)?.name ?? effective.model!
          : effective.model;
      final displayModelName =
          rawModelName != null && widget.compactModelLabelBuilder != null
              ? widget.compactModelLabelBuilder!(effective.model!, rawModelName)
              : rawModelName;

      final label = worker == null && !widget.showWorkerInCompactSummary
          ? 'Select a Worker'
          : [
              if (widget.showWorkerInCompactSummary)
                worker?.name ??
                    (effective.worker == null
                        ? 'Select Worker...'
                        : '${effective.worker} · Unavailable'),
              if (widget.showModel)
                effective.model == null
                    ? worker == null
                        ? 'Select model'
                        : modelAutoAllowed
                            ? 'Auto'
                            : 'Select model'
                    : worker?.supportsModel(effective.model) == true
                        ? displayModelName!
                        : '${displayModelName ?? effective.model!} · Unavailable',
              if (widget.showEffort &&
                  effective.effort == null &&
                  !effortAutoAllowed)
                'Select effort',
              if (widget.showEffort && effective.effort != null)
                worker
                            ?.effortsForModel(effective.model)
                            .contains(effective.effort) ==
                        true
                    ? executionEffortDisplayName(effective.effort!)
                    : '${executionEffortDisplayName(effective.effort!)} · Unavailable',
              if (widget.loading || worker?.state == CapabilityState.loading)
                'Loading…',
              if (worker?.state == CapabilityState.stale) 'Stale',
            ].join(' · ');

      final modelIconWidget = widget.modelIconBuilder != null
          ? widget.modelIconBuilder!(
              worker,
              effective.model,
              effective.model != null
                  ? worker?.model(effective.model)?.name
                  : null,
            )
          : null;

      return Builder(
        builder: (anchorContext) => TextButton(
          key: ValueKey('${widget.scope}-open'),
          style: TextButton.styleFrom(
            foregroundColor:
                Theme.of(anchorContext).textTheme.bodySmall?.color ??
                    Theme.of(anchorContext).colorScheme.onSurface,
            textStyle: Theme.of(anchorContext)
                .textTheme
                .bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
            padding: EdgeInsets.symmetric(
                horizontal: 8, vertical: widget.compactHeight == null ? 5 : 0),
            minimumSize: widget.compactHeight == null
                ? null
                : Size(0, widget.compactHeight!),
            maximumSize: widget.compactHeight == null
                ? null
                : Size(double.infinity, widget.compactHeight!),
            tapTargetSize: widget.compactHeight == null
                ? null
                : MaterialTapTargetSize.shrinkWrap,
            // Density would shave 8px off the fixed height on desktop.
            visualDensity:
                widget.compactHeight == null ? null : VisualDensity.standard,
          ),
          onPressed: () => _open(anchorContext),
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (modelIconWidget != null) ...[
                  Semantics(
                    key: ValueKey('${widget.scope}-selected-model-icon'),
                    label: displayModelName ?? worker?.name ?? 'Model',
                    image: true,
                    child: ExcludeSemantics(
                      child: SizedBox.square(
                        dimension: widget.compactIconSize,
                        child: FittedBox(
                          child: modelIconWidget,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ] else if (widget.showWorker &&
                    worker != null &&
                    widget.workerIconBuilder != null) ...[
                  Semantics(
                    key: ValueKey('${widget.scope}-selected-worker-icon'),
                    label: worker.name,
                    image: true,
                    child: ExcludeSemantics(
                      child: SizedBox.square(
                        dimension: widget.compactIconSize,
                        child: FittedBox(
                          child: widget.workerIconBuilder!(worker),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
              ])),
        ),
      );
    }

    final enabled =
        !widget.readOnly && !widget.loading && widget.onChanged != null;
    final canSelect = enabled && worker?.state != CapabilityState.loading;
    final models = {
      for (final m in worker?.models ?? const <ExecutionModelCapability>[])
        m.id: '${m.name}${m.available ? '' : ' · Unavailable'}'
    };
    if (widget.value.model != null &&
        worker?.supportsModel(widget.value.model) == true) {
      models.putIfAbsent(widget.value.model!, () => widget.value.model!);
    }
    for (final id in worker?.allowedModelIds ?? const <String>[]) {
      models.putIfAbsent(id, () => id);
    }
    final efforts =
        worker?.effortsForModel(effective.model) ?? const <String>[];
    final issue = widget.validationMessage ??
        (effective.worker == null
            ? 'Select a Worker.'
            : worker == null
                ? 'Selected Worker is unavailable. Your saved selection is kept.'
                : worker.validatePreference(effective));
    return FocusTraversalGroup(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.loading || worker?.state == CapabilityState.loading)
          const LinearProgressIndicator(
              semanticsLabel: 'Loading Worker capabilities'),
        if (widget.showWorker) ...[
          _picker(
              'Worker',
              widget.value.worker,
              widget.inherited.worker,
              {for (final w in widget.catalog.workers) w.id: w.name},
              (_) => true,
              enabled && widget.allowWorkerChange,
              true, (id) {
            _explanation = null;
            widget.onChanged!(ExecutionSelection(
                worker: id,
                catalogRevision: widget.catalog
                    .worker(id ?? widget.inherited.worker)
                    ?.catalogRevision));
          }),
          const SizedBox(height: 12),
        ],
        if (widget.showModel)
          _picker(
              'Model',
              widget.value.model,
              widget.inherited.model,
              models,
              (id) => worker?.supportsModel(id) == true,
              canSelect &&
                  widget.allowModelChange &&
                  worker != null &&
                  (worker.modelSupported || widget.value.model != null) &&
                  worker.state != CapabilityState.unavailable,
              modelAutoAllowed, (id) {
            final next = widget.catalog
                .changeModel(widget.value, id, inherited: widget.inherited);
            final combined = worker?.model(id)?.selectionMode == 'combined';
            setState(() => _explanation = widget.value.effort != null &&
                    next.effort == null
                ? combined
                    ? 'The previous effort is unavailable for this model. Choose an explicit supported effort.'
                    : 'The previous effort is unavailable for this model. Effort reset to Auto / Provider default.'
                : null);
            widget.onChanged!(next);
          }),
        const SizedBox(height: 12),
        if (widget.showEffort)
          _picker(
              'Effort',
              widget.value.effort,
              widget.inherited.effort,
              {for (final id in efforts) id: executionEffortDisplayName(id)},
              (_) => true,
              canSelect &&
                  widget.allowEffortChange &&
                  (efforts.isNotEmpty || widget.value.effort != null) &&
                  worker?.state != CapabilityState.unavailable,
              effortAutoAllowed, (id) {
            setState(() => _explanation = null);
            widget.onChanged!(ExecutionSelection(
                worker: widget.value.worker,
                model: widget.value.model,
                catalogRevision: worker?.catalogRevision,
                effort: id));
          }),
        if (widget.showModelEffortGuidance &&
            (worker?.modelSupported == false ||
                worker?.state == CapabilityState.unsupported))
          _message('Model selection is unsupported by this Worker.'),
        if (widget.showModelEffortGuidance &&
            worker != null &&
            efforts.isEmpty &&
            worker.state != CapabilityState.loading &&
            worker.state != CapabilityState.unavailable)
          _message(!worker.supportsModel(effective.model)
              ? 'Effort choices are unavailable for the selected model.'
              : effective.model == null &&
                      worker.models.any((model) => model.efforts.isNotEmpty)
                  ? 'Effort choices depend on the model.'
                  : 'Effort selection is unsupported for this model; the provider default applies.'),
        if (effective.effort == null &&
            worker?.model(effective.model)?.defaultEffort != null)
          _message(
              'Provider default effort: ${executionEffortDisplayName(worker!.model(effective.model)!.defaultEffort!)}'),
        if (worker?.availabilityMessage != null)
          _message(worker!.availabilityMessage!),
        if (widget.helperMessage != null) _message(widget.helperMessage!),
        if (issue != null &&
            widget.showValidationMessage &&
            !(widget.hideExplicitModelRequirement &&
                issue == 'Select an explicit model for this Worker.') &&
            !widget.hiddenValidationMessages.contains(issue))
          _message(issue, error: true),
        if (_explanation != null) _message(_explanation!),
        if (widget.showSelectionStateText &&
            (widget.inherited.worker != null ||
                widget.inherited.model != null ||
                widget.inherited.effort != null))
          _message(
              'Effective selection: ${worker?.name ?? effective.worker ?? "Auto"} · ${worker?.model(effective.model)?.name ?? effective.model ?? "Auto / Provider default"} · ${effective.effort == null ? "Auto / Provider default" : executionEffortDisplayName(effective.effort!)}'),
        if (widget.readOnly && widget.showCatalog) ...[
          for (final model
              in worker?.models ?? const <ExecutionModelCapability>[])
            _message(
                '${model.name} · ${model.efforts.isEmpty ? 'Provider default' : model.efforts.map(executionEffortDisplayName).join(', ')} · ${executionEffortDisplayName(model.status)}${model.defaultEffort == null ? '' : ' · Default: ${executionEffortDisplayName(model.defaultEffort!)}'}'),
        ],
      ],
    ));
  }

  Widget _picker(
    String label,
    String? value,
    String? inherited,
    Map<String, String> choices,
    bool Function(String) available,
    bool enabled,
    bool allowAuto,
    ValueChanged<String?> changed,
  ) {
    final items = {...choices};
    if (value != null && !items.containsKey(value))
      items[value] = '$value · Unavailable';
    if (widget.menuPickers) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final defaultLabel = label == 'Worker'
          ? inherited == null
              ? 'Select Worker...'
              : 'Inherit workflow Worker'
          : inherited != null
              ? 'Inherit workflow $label'
              : allowAuto
                  ? 'Auto'
                  : 'Select $label...';
      return MenuAnchor(
        key: ValueKey('${widget.scope}-$label-menu'),
        style: SyntilaMenuStyle.surface(isDark, composer: true),
        menuChildren: [
          for (final entry in {'': defaultLabel, ...items}.entries)
            MenuItemButton(
              autofocus: entry.key == (value ?? ''),
              style: SyntilaMenuStyle.item(isDark),
              leadingIcon: Icon(
                entry.key == (value ?? '')
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                size: 15,
              ),
              onPressed: enabled &&
                      (entry.key.isEmpty
                          ? allowAuto || inherited != null
                          : choices.containsKey(entry.key) &&
                              available(entry.key))
                  ? () => changed(entry.key.isEmpty ? null : entry.key)
                  : null,
              child: Text(entry.value, style: SyntilaMenuStyle.textStyle),
            ),
        ],
        builder: (context, controller, child) => TextButton(
          onPressed: enabled
              ? () {
                  controller.isOpen ? controller.close() : controller.open();
                }
              : null,
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: label, enabled: enabled),
            child: Row(children: [
              Expanded(
                  child: Text(items[value] ?? defaultLabel,
                      style: SyntilaMenuStyle.textStyle,
                      overflow: TextOverflow.ellipsis)),
              const Icon(Icons.keyboard_arrow_down, size: 16),
            ]),
          ),
        ),
      );
    }
    return DropdownButtonFormField<String>(
      key: ValueKey('${widget.scope}-$label-$value-${items.keys.join(',')}'),
      initialValue: value ?? '',
      isExpanded: true,
      style: Theme.of(context).textTheme.bodySmall,
      decoration: InputDecoration(
          labelText: label,
          helperText: !widget.showSelectionStateText
              ? null
              : value == null
                  ? inherited == null && allowAuto
                      ? (label == 'Worker' ? null : 'Auto / Provider default')
                      : inherited == null
                          ? 'Select an explicit ${label.toLowerCase()}'
                          : 'Inherited: ${choices[inherited] ?? inherited}'
                  : 'Explicit selection'),
      items: [
        DropdownMenuItem(
            value: '',
            enabled: allowAuto || inherited != null,
            child: Text(label == 'Worker'
                ? widget.inherited.worker == null
                    ? 'Select Worker...'
                    : 'Inherit workflow Worker'
                : inherited != null
                    ? 'Inherit workflow $label'
                    : allowAuto
                        ? 'Auto'
                        : 'Select $label...')),
        for (final entry in items.entries)
          DropdownMenuItem(
              value: entry.key,
              enabled: choices.containsKey(entry.key) && available(entry.key),
              child: Text(entry.value, overflow: TextOverflow.ellipsis))
      ],
      onChanged: enabled ? (id) => changed(id == '' ? null : id) : null,
    );
  }

  Widget _message(String text, {bool error = false}) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
          liveRegion: true,
          child: Text(text,
              style: TextStyle(
                  color: error ? Theme.of(context).colorScheme.error : null))));
  Future<void> _openImmediate(BuildContext context) async {
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final box = context.findRenderObject()! as RenderBox;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final openingSelection = widget.value;
    var value = openingSelection;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierColor: Colors.transparent,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        final effective = widget.inherited.overlay(value);
        final worker = widget.catalog.worker(effective.worker);
        final enabled =
            !widget.readOnly && !widget.loading && widget.onChanged != null;
        final ready = worker != null &&
            worker.state != CapabilityState.loading &&
            worker.state != CapabilityState.unavailable;
        final efforts =
            worker?.effortsForModel(effective.model) ?? const <String>[];
        final levels = <String?>[
          if (worker?.allowsAutoEffort(effective.model) ?? true) null,
          ...efforts,
        ];
        final index = levels.indexOf(effective.effort);
        void change(ExecutionSelection next) {
          update(() => value = next);
          widget.onChanged?.call(next);
        }

        void changeModel(String? id) {
          final next = widget.catalog
              .changeModel(value, id, inherited: widget.inherited);
          final choices = worker?.effortsForModel(id) ?? const <String>[];
          change(id != null &&
                  widget.allowEffortChange &&
                  next.effort == null &&
                  choices.isNotEmpty
              ? ExecutionSelection(
                  worker: next.worker,
                  model: next.model,
                  effort: choices.first,
                  catalogRevision: next.catalogRevision)
              : next);
        }

        final models = <String, String>{
          for (final model
              in worker?.models ?? const <ExecutionModelCapability>[])
            model.id: model.name,
          for (final id in worker?.allowedModelIds ?? const <String>[])
            id: worker?.model(id)?.name ?? id,
        };
        return CustomSingleChildLayout(
          delegate: _ExecutionPopupLayout(anchor),
          child: Material(
            key: ValueKey('${widget.scope}-popup'),
            color: SyntilaColors.composerBackground(isDark),
            surfaceTintColor: Colors.transparent,
            elevation: 12,
            shadowColor: SyntilaMenuStyle.shadow(isDark),
            shape: SyntilaMenuStyle.shape(isDark),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: SyntilaMenuStyle.padding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.showEffort) ...[
                    Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                        child: Text(
                            'Effort · ${index < 0 ? 'Select effort' : levels[index] == null ? 'Auto' : executionEffortDisplayName(levels[index])}',
                            style: SyntilaMenuStyle.textStyle)),
                    Slider(
                      key: ValueKey(
                          '${widget.scope}-effort-${effective.worker}-${effective.model}'),
                      value: math.max(0, index).toDouble(),
                      min: 0,
                      max: math.max(1, levels.length - 1).toDouble(),
                      divisions: math.max(1, levels.length - 1),
                      semanticFormatterCallback: (position) => levels.isEmpty
                          ? 'Unavailable'
                          : levels[position
                                      .round()
                                      .clamp(0, levels.length - 1)] ==
                                  null
                              ? 'Auto'
                              : executionEffortDisplayName(levels[position
                                  .round()
                                  .clamp(0, levels.length - 1)]),
                      onChanged: enabled &&
                              ready &&
                              widget.allowEffortChange &&
                              levels.isNotEmpty
                          ? (position) => change(ExecutionSelection(
                              worker: effective.worker,
                              model: effective.model,
                              effort: levels[
                                  position.round().clamp(0, levels.length - 1)],
                              catalogRevision: worker.catalogRevision))
                          : null,
                      onChangeEnd: enabled &&
                              ready &&
                              widget.allowEffortChange &&
                              levels.isNotEmpty
                          ? (position) {
                              // A tap on the displayed minimum may not emit
                              // onChanged when no effort has been selected yet.
                              final effort = levels[
                                  position.round().clamp(0, levels.length - 1)];
                              if (value.effort != effort || index < 0) {
                                change(ExecutionSelection(
                                    worker: effective.worker,
                                    model: effective.model,
                                    effort: effort,
                                    catalogRevision: worker.catalogRevision));
                              }
                              Navigator.of(context).pop();
                            }
                          : null,
                    ),
                  ],
                  if (widget.showModel) ...[
                    if (worker?.allowsAutoModel == true)
                      _modelRow(
                          'Auto',
                          effective.model == null,
                          enabled && ready && widget.allowModelChange
                              ? () => changeModel(null)
                              : null),
                    for (final model in models.entries)
                      _modelRow(
                          model.value,
                          model.key == effective.model,
                          enabled &&
                                  ready &&
                                  widget.allowModelChange &&
                                  worker.modelSupported &&
                                  worker.supportsModel(model.key)
                              ? () => changeModel(model.key)
                              : null),
                    if (models.isEmpty)
                      const Padding(
                          padding: EdgeInsets.all(10),
                          child: Text('No models available')),
                  ],
                  if (widget.helperMessage != null)
                    _message(widget.helperMessage!),
                  LayoutBuilder(builder: (context, constraints) {
                    const buttonSize = 48.0;
                    const workerSpacing = 4.0;
                    const separatorWidth = 12.0;
                    final candidates = widget.showWorker
                        ? widget.catalog.workers
                            .where((w) =>
                                w.state == CapabilityState.ready ||
                                w.state == CapabilityState.stale)
                            .toList()
                        : <WorkerSelectionCapability>[];
                    final showUsage = widget.onShowUsage != null;
                    final workersWidth = candidates.isEmpty
                        ? 0.0
                        : candidates.length * buttonSize +
                            (candidates.length - 1) * workerSpacing;
                    final stackActions = showUsage &&
                        workersWidth + separatorWidth + 2 * buttonSize >
                            constraints.maxWidth;
                    final usage = Semantics(
                      label: 'Worker usage',
                      button: true,
                      child: IconButton(
                        key: ValueKey('${widget.scope}-usage'),
                        icon: const Icon(Icons.speed),
                        onPressed: effective.worker == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                widget.onShowUsage!();
                              },
                      ),
                    );
                    final restore = Semantics(
                      label: 'Restore opening selection',
                      child: IconButton(
                        key: ValueKey('${widget.scope}-restore'),
                        icon: const Icon(Icons.settings_backup_restore_rounded),
                        onPressed: enabled &&
                                (value.worker != openingSelection.worker ||
                                    value.model != openingSelection.model ||
                                    value.effort != openingSelection.effort ||
                                    value.catalogRevision !=
                                        openingSelection.catalogRevision)
                            ? () {
                                change(openingSelection);
                                Navigator.of(context).pop();
                              }
                            : null,
                      ),
                    );
                    Widget slot(Widget child) => SizedBox(
                        width: buttonSize, height: buttonSize, child: child);
                    return Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                              child: Wrap(spacing: workerSpacing, children: [
                            for (final candidate in candidates)
                              Builder(builder: (context) {
                                final isSelected =
                                    candidate.id == effective.worker;
                                final rawIcon =
                                    widget.workerIconBuilder?.call(candidate) ??
                                        const Icon(Icons.smart_toy_outlined);
                                return slot(Semantics(
                                  label: candidate.name,
                                  selected: isSelected,
                                  child: IconButton(
                                    key: ValueKey(
                                        '${widget.scope}-worker-${candidate.id}'),
                                    isSelected: isSelected,
                                    onPressed:
                                        enabled && widget.allowWorkerChange
                                            ? () => change(ExecutionSelection(
                                                worker: candidate.id,
                                                catalogRevision:
                                                    candidate.catalogRevision))
                                            : null,
                                    icon: Opacity(
                                        opacity: isSelected ? 1.0 : 0.45,
                                        child: rawIcon),
                                  ),
                                ));
                              }),
                          ])),
                          if (showUsage)
                            SizedBox(
                              width: separatorWidth,
                              height:
                                  stackActions ? 2 * buttonSize : buttonSize,
                              child: Center(
                                  child: Container(
                                key:
                                    ValueKey('${widget.scope}-usage-separator'),
                                width: 1,
                                height: stackActions ? 64 : 24,
                                color: Theme.of(context).dividerColor,
                              )),
                            ),
                          if (stackActions)
                            Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [slot(usage), slot(restore)])
                          else ...[if (showUsage) slot(usage), slot(restore)],
                        ]);
                  }),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _modelRow(String name, bool selected, VoidCallback? onPressed) =>
      MenuItemButton(
        style: SyntilaMenuStyle.item(
            Theme.of(context).brightness == Brightness.dark),
        leadingIcon: Icon(
            selected ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 15),
        onPressed: onPressed,
        child: Text(name, style: SyntilaMenuStyle.textStyle),
      );

  Future<void> _open(BuildContext context) async {
    if (widget.immediatePopup) {
      await _openImmediate(context);
      return;
    }
    var value = widget.value;
    final box = context.findRenderObject()! as RenderBox;
    // showMenu positions against the Navigator's overlay, so measure there.
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final menuWidth = math.min(320.0, math.max(260.0, overlay.size.width - 32));
    final availableAbove = rect.top - 16;
    final maxMenuHeight = math.min(520.0,
        availableAbove >= 120 ? availableAbove : overlay.size.height - 16);
    final left =
        rect.left.clamp(8.0, overlay.size.width - menuWidth - 8).toDouble();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget body(BuildContext menuContext, StateSetter setMenuState) => SizedBox(
          width: menuWidth,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(0, maxMenuHeight - 44),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ModelEffortSelector(
                      menuPickers: true,
                      catalog: widget.catalog,
                      value: value,
                      inherited: widget.inherited,
                      scope: widget.scope,
                      showWorker: widget.showWorker,
                      showModel: widget.showModel,
                      showEffort: widget.showEffort,
                      readOnly: widget.readOnly,
                      showCatalog: widget.showCatalog,
                      allowWorkerChange: widget.allowWorkerChange,
                      allowModelChange: widget.allowModelChange,
                      allowEffortChange: widget.allowEffortChange,
                      showValidationMessage: widget.showValidationMessage,
                      hideExplicitModelRequirement:
                          widget.hideExplicitModelRequirement,
                      hiddenValidationMessages: widget.hiddenValidationMessages,
                      showSelectionStateText: false,
                      showModelEffortGuidance: false,
                      showWorkerInCompactSummary:
                          widget.showWorkerInCompactSummary,
                      loading: widget.loading,
                      validationMessage: widget.validationMessage,
                      helperMessage: widget.helperMessage,
                      onChanged: widget.onChanged == null
                          ? null
                          : (next) {
                              setMenuState(() => value = next);
                            },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.pop(menuContext),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.pop(menuContext, value),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
    // Measure the content offstage so the popup is exactly as tall as its
    // controls, then anchor its bottom edge above the button.
    final measureKey = GlobalKey();
    final entry = OverlayEntry(
      builder: (_) => Offstage(
        // Overlay entries get tight constraints; loosen them to measure.
        child: Align(
          alignment: Alignment.topLeft,
          child: Material(
            child: StatefulBuilder(
              builder: (c, set) => KeyedSubtree(
                key: measureKey,
                child: Theme(
                  data: Theme.of(context),
                  child: body(c, set),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    await WidgetsBinding.instance.endOfFrame;
    final measured =
        (measureKey.currentContext?.findRenderObject() as RenderBox?)
                ?.size
                .height ??
            maxMenuHeight;
    entry.remove();
    entry.dispose();
    if (!context.mounted) return;
    final menuHeight =
        math.min(maxMenuHeight, measured + SyntilaMenuStyle.padding.vertical);
    final top = math.max(8.0, rect.top - 8 - menuHeight);
    final result = await showMenu<ExecutionSelection>(
      context: context,
      position: RelativeRect.fromLTRB(
        left,
        top,
        overlay.size.width - left - menuWidth,
        overlay.size.height - top,
      ),
      constraints: BoxConstraints(
        maxWidth: menuWidth,
        minHeight: menuHeight,
        maxHeight: menuHeight,
      ),
      color: SyntilaColors.composerBackground(isDark),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: SyntilaMenuStyle.shadow(isDark),
      shape: SyntilaMenuStyle.shape(isDark),
      menuPadding: SyntilaMenuStyle.padding,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        PopupMenuItem<ExecutionSelection>(
          enabled: false,
          height: 0,
          padding: EdgeInsets.zero,
          child: StatefulBuilder(
            builder: (menuContext, setMenuState) =>
                body(menuContext, setMenuState),
          ),
        ),
      ],
    );
    if (result != null) widget.onChanged?.call(result);
  }
}

/// Shared labels for current selections and immutable execution history.
String executionEffortDisplayName(String? effort) {
  final value = effort?.trim() ?? '';
  if (value.isEmpty) return '';
  if (value == 'xhigh' || value == 'extra-high') return 'Extra High';
  return '${value[0].toUpperCase()}${value.substring(1)}';
}

/// Positions the measured surface above its button without estimated heights.
class _ExecutionPopupLayout extends SingleChildLayoutDelegate {
  _ExecutionPopupLayout(this.anchor);
  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: math.min(320, constraints.maxWidth - 16))
          .copyWith(minHeight: 0, maxHeight: math.max(0, anchor.top - 16));

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
      anchor.left.clamp(8.0, math.max(8, size.width - childSize.width - 8)),
      math.max(8, anchor.top - childSize.height - 8));

  @override
  bool shouldRelayout(_ExecutionPopupLayout oldDelegate) =>
      anchor != oldDelegate.anchor;
}
