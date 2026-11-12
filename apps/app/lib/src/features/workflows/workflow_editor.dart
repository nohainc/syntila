import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:flutter/material.dart';
import '../common/page_width.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/workflow_configuration_options.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_worker_visibility_preferences.dart';
import '../../ax/ax_worker_visibility.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';

/// Fixed, Syntila-owned steps. Only execution preferences are editable here.
///
/// Shown as a full page (see [WorkflowEditor.open]) rather than a dialog:
/// step editing is too large for a pop-up and must not be lost by an
/// accidental click outside.
class WorkflowEditor extends StatefulWidget {
  const WorkflowEditor(
      {super.key,
      required this.definition,
      required this.configuration,
      required this.catalogs,
      required this.cache,
      this.workspaceId,
      this.visibility,
      this.stepsOnly = false});
  final AxWorkerVisibilityPreferences? visibility;
  final bool stepsOnly;
  final String? workspaceId;
  final AxBuiltinWorkflow definition;
  final AxUserWorkflowConfiguration configuration;
  final AxSessionCatalogs catalogs;
  final AxWorkflowConfigurations cache;

  /// Pushes the editor as a page and completes when it is closed.
  static Future<void> open(BuildContext context, WorkflowEditor editor) =>
      Navigator.of(context).push<void>(MaterialPageRoute(
          builder: (_) => editor,
          settings: const RouteSettings(name: 'workflow-editor')));
  @override
  State<WorkflowEditor> createState() => _WorkflowEditorState();
}

class _WorkflowEditorState extends State<WorkflowEditor> {
  late bool enabled = widget.configuration.enabled;
  late AxWorkflowSelection defaults = widget.configuration.defaults;
  late final overrides =
      Map<String, AxWorkflowSelection>.from(widget.configuration.stepOverrides);
  late final overriding = overrides.keys.toSet();
  bool busy = false;
  String? error;

  bool get _research =>
      widget.definition.id == 'research' &&
      (widget.definition.version >= 2 ||
          widget.definition.steps.length > 1 ||
          widget.definition.steps.any((step) => step.id != null));

  bool get _planImplement => widget.definition.id == 'plan_implement';

  /// Researchers to run (Research v2), 2 to 4; Cloud enforces the same bounds.
  late int researcherCount = widget.configuration.researcherCount ?? 2;

  List<AxBuiltinWorkflowStep> get steps {
    if (_research) {
      return [
        for (var i = 1; i <= researcherCount; i++)
          AxBuiltinWorkflowStep(
              kind: 'research', order: i - 1, id: 'research-$i'),
        AxBuiltinWorkflowStep(
            kind: 'synthesis', order: researcherCount, id: 'synthesis'),
      ];
    }
    if (_planImplement) {
      return const [
        AxBuiltinWorkflowStep(kind: 'plan', order: 0, id: 'plan'),
        AxBuiltinWorkflowStep(kind: 'implement', order: 1, id: 'implement'),
        AxBuiltinWorkflowStep(kind: 'verify', order: 2, id: 'verify'),
      ];
    }
    final sorted = [...widget.definition.steps]
      ..sort((a, b) => a.order.compareTo(b.order));
    final seen = <String, int>{};
    for (final step in sorted) {
      seen[step.instanceId] = (seen[step.instanceId] ?? 0) + 1;
    }
    if (seen.values.any((count) => count > 1)) {
      final occurrences = <String, int>{};
      return [
        for (final step in sorted)
          if ((seen[step.instanceId] ?? 0) > 1)
            AxBuiltinWorkflowStep(
              kind: step.kind,
              order: step.order,
              id: '${step.instanceId}-${occurrences[step.instanceId] = (occurrences[step.instanceId] ?? 0) + 1}',
            )
          else
            step
      ];
    }
    return sorted;
  }

  AxUserWorkflowConfiguration get draft => AxUserWorkflowConfiguration(
        workflowId: widget.definition.id,
        enabled: enabled,
        defaults: defaults,
        researcherCount: _research ? researcherCount : null,
        stepOverrides: {
          for (final id in overriding)
            if (overrides[id]?.toJson().isNotEmpty == true) id: overrides[id]!
        },
      );
  Map<String, String> _issues(AxWorkflowSelectionOptions options) {
    final result = <String, String>{};
    if (!enabled) return result;
    final defaultError =
        options.validate(defaults, saved: widget.configuration.defaults);
    if (defaultError != null) result['defaults'] = defaultError;
    for (final step in steps) {
      final issue = options.validate(draft.selectionFor(step.instanceId),
          saved: draft.stepOverrides[step.instanceId] == null
              ? widget.configuration.defaults
              : widget.configuration.selectionFor(step.instanceId));
      if (issue != null) result[step.instanceId] = issue;
    }
    if (_research) {
      // Same rule Cloud applies at acceptance: explicit, different models.
      final seen = <String, String>{};
      for (final step in steps.where((step) => step.kind == 'research')) {
        if (result[step.instanceId] != null) continue;
        final model = draft.selectionFor(step.instanceId).model?.trim();
        if (model == null || model.isEmpty) {
          result[step.instanceId] =
              'Choose a specific model; Auto cannot prove the researchers use different models.';
          continue;
        }
        final earlier = seen[model.toLowerCase()];
        if (earlier != null) {
          result[step.instanceId] =
              'Uses the same model as ${_title(earlier)}; each researcher needs a different model.';
        } else {
          seen[model.toLowerCase()] = step.instanceId;
        }
      }
    }
    return result;
  }

  Future<void> _save({bool reset = false}) async {
    final workers = widget.catalogs.engine.peek(widget.catalogs.workers).data ??
        const <AxWorker>[];
    if (!reset &&
        _issues(AxWorkflowSelectionOptions(workers
                .where((worker) =>
                    widget.workspaceId == null ||
                    worker.workspaceId == widget.workspaceId)
                .toList()))
            .isNotEmpty) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (reset) {
        await widget.cache.reset(widget.definition.id);
      } else {
        await widget.cache.save(draft);
      }
      if (mounted) {
        setState(() => busy = false);
        Navigator.pop(context);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          busy = false;
          error = failure.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibility = widget.visibility;
    if (visibility == null) return _editor(context, null);
    return AxQueryBuilder<AxWorkerVisibility>(
        engine: visibility.engine,
        query: visibility.query,
        builder: (context, state) => _editor(context, state.data));
  }

  AxWorkerVisibility? _visibility;
  Widget _editor(BuildContext context, AxWorkerVisibility? visibility) {
    _visibility = visibility;
    return PopScope(
      canPop: !busy,
      child: AxQueryBuilder(
        engine: widget.catalogs.engine,
        query: widget.catalogs.workers,
        ensure: false,
        builder: (context, state) {
          final options = AxWorkflowSelectionOptions(
              (state.data ?? const <AxWorker>[])
                  .where((worker) =>
                      widget.workspaceId == null ||
                      worker.workspaceId == widget.workspaceId)
                  .toList());
          final issues = _issues(options);
          final visibleIssues = issues.entries
              .where((entry) => !_hideValidationMessage(entry.value))
              .toList();
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.definition.name),
              leading: IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: busy ? null : () => Navigator.pop(context)),
            ),
            body: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: PageWidth.of(context).pageWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!widget.stepsOnly) ...[
                          SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Enabled'),
                              value: enabled,
                              subtitle: widget.definition.id == 'chat'
                                  ? const Text('Chat is always available.')
                                  : null,
                              onChanged: busy || widget.definition.id == 'chat'
                                  ? null
                                  : (value) => setState(() => enabled = value)),
                          Text('Default execution',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 12),
                          _selection(
                              'defaults',
                              defaults,
                              const AxWorkflowSelection(),
                              options,
                              (value) => defaults = value),
                          if (issues['defaults'] != null &&
                              !_hideValidationMessage(issues['defaults']))
                            _notice(issues['defaults']!, error: true),
                          const SizedBox(height: 8),
                        ],
                        if (widget.stepsOnly) ...[
                          Text('Workflow steps',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 8),
                          if (_research) _researcherCountControl(),
                          for (var index = 0; index < steps.length; index++)
                            _step(index, steps[index], options,
                                issues[steps[index].instanceId]),
                        ] else
                          ExpansionTile(
                            key: const ValueKey('workflow-advanced'),
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Advanced'),
                            children: [
                              const Divider(),
                              const Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Workflow steps',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600))),
                              const SizedBox(height: 8),
                              if (_research) _researcherCountControl(),
                              for (var index = 0; index < steps.length; index++)
                                _step(index, steps[index], options,
                                    issues[steps[index].instanceId]),
                            ],
                          ),
                        if (visibleIssues.isNotEmpty)
                          _notice(
                              'Resolve incompatible choices before saving.\n${visibleIssues.where((entry) => entry.key != 'defaults').map((entry) => '${_title(entry.key)}: ${entry.value}').join('\n')}',
                              error: true),
                        if (state.error != null)
                          _notice(
                              'Worker details could not be refreshed. Saved selections are retained.'),
                        if (error != null) _notice(error!, error: true),
                        const SizedBox(height: 8),
                        Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (!widget.stepsOnly)
                                TextButton(
                                    key: const ValueKey('reset-workflow'),
                                    onPressed:
                                        busy ? null : () => _save(reset: true),
                                    child: Text(widget.cache.spaceId == null ||
                                            widget.cache.engine
                                                    .peek(widget
                                                        .cache.workspaceQuery)
                                                    .data
                                                    ?.inherited ==
                                                false
                                        ? 'Reset'
                                        : 'Use global defaults')),
                              TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => Navigator.pop(context),
                                  child: const Text('Cancel')),
                              FilledButton(
                                  key: const ValueKey('save-workflow'),
                                  onPressed:
                                      busy || issues.isNotEmpty ? null : _save,
                                  child: Text(busy ? 'Saving…' : 'Save')),
                            ]),
                      ],
                    ),
                  ),
                )),
          );
        },
      ),
    );
  }

  Widget _researcherCountControl() => Row(children: [
        const Text('Researchers'),
        const SizedBox(width: 12),
        DropdownButton<int>(
          key: const ValueKey('research-researcher-count'),
          value: researcherCount,
          items: [
            for (final count in const [2, 3, 4])
              DropdownMenuItem(value: count, child: Text('$count')),
          ],
          onChanged: busy
              ? null
              : (value) => setState(() {
                    researcherCount = value ?? researcherCount;
                    // Overrides of removed researchers are dropped.
                    overriding.removeWhere((id) {
                      final n = RegExp(r'^research-(\d+)$').firstMatch(id);
                      return n != null &&
                          int.parse(n.group(1)!) > researcherCount;
                    });
                  }),
        ),
      ]);

  String _stepDescription(String instanceId) {
    if (instanceId == 'plan') {
      return 'Prepares structured implementation phases and completion criteria.';
    }
    if (instanceId == 'implement') {
      return 'Executes implementation phase by phase according to the approved plan.';
    }
    if (instanceId == 'verify') {
      return 'Audits changes and validates criteria after phases or at final review.';
    }
    return '';
  }

  Widget _step(int index, AxBuiltinWorkflowStep step,
      AxWorkflowSelectionOptions options, String? issue) {
    final custom = overriding.contains(step.instanceId);
    final selection = overrides[step.instanceId] ?? const AxWorkflowSelection();
    return ExpansionTile(
      key: ValueKey('workflow-step-${step.instanceId}'),
      tilePadding: EdgeInsets.zero,
      title: Text('${index + 1}. ${_title(step.instanceId)}'),
      subtitle: Text(custom && selection.toJson().isNotEmpty
          ? _summary(selection, options)
          : 'Inherit defaults'),
      trailing: const Icon(Icons.chevron_right),
      children: [
        if (_stepDescription(step.instanceId).isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _stepDescription(step.instanceId),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const Align(
            alignment: Alignment.centerLeft,
            child: Text('Execution',
                style: TextStyle(fontWeight: FontWeight.w600))),
        RadioGroup<bool>(
            groupValue: custom,
            onChanged: (value) {
              if (busy || value == null) return;
              setState(() {
                error = null;
                if (value) {
                  overriding.add(step.instanceId);
                } else {
                  overriding.remove(step.instanceId);
                  overrides.remove(step.instanceId);
                }
              });
            },
            child: Column(children: [
              RadioListTile<bool>(
                  key: ValueKey('inherit-${step.instanceId}'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use workflow defaults'),
                  value: false,
                  enabled: !busy),
              RadioListTile<bool>(
                  key: ValueKey('override-${step.instanceId}'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Override'),
                  value: true,
                  enabled: !busy),
            ])),
        if (custom) ...[
          const Text(
              'Auto model and effort values inherit the workflow defaults.'),
          const SizedBox(height: 12),
          _selection(step.instanceId, selection, defaults, options,
              (value) => overrides[step.instanceId] = value),
          Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                  key: ValueKey('reset-step-${step.instanceId}'),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            overriding.remove(step.instanceId);
                            overrides.remove(step.instanceId);
                            error = null;
                          }),
                  child: const Text('Reset step to inherited values'))),
        ] else
          _notice('Uses the workflow Worker, model, and effort defaults.'),
        if (issue != null && !_hideValidationMessage(issue))
          _notice(issue, error: true),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _selection(
      String scope,
      AxWorkflowSelection value,
      AxWorkflowSelection base,
      AxWorkflowSelectionOptions options,
      ValueChanged<AxWorkflowSelection> update) {
    final preferences = _visibility;
    AxWorkerVisibilityProjection project(ExecutionSelection selection) =>
        options.displayProjection(preferences!, selected: selection);
    return ModelEffortSelector(
      displayWorkers: preferences == null
          ? null
          : (s) => {
                for (final w in project(s).workers)
                  w.id: project(s).workerLabel(w)
              },
      displayModels:
          preferences == null ? null : (s) => project(s).models(s.worker ?? ''),
      displayEfforts: preferences == null
          ? null
          : (s) => {
                for (final e in project(s).efforts(s.worker ?? '', s.model))
                  e: project(s).effortLabel(
                      s.worker ?? '',
                      s.model ??
                          options.sharedCatalog
                              .worker(s.worker)
                              ?.defaultModelId ??
                          '',
                      e)
              },
      scope: scope,
      catalog: options.sharedCatalog,
      value: ExecutionSelection(
          worker: value.worker,
          model: value.model,
          effort: value.effort,
          catalogRevision: value.catalogRevision),
      inherited: ExecutionSelection(
          worker: base.worker,
          model: base.model,
          effort: base.effort,
          catalogRevision: base.catalogRevision),
      readOnly: busy,
      showCatalog: false,
      showSelectionStateText: false,
      showValidationMessage: true,
      hideExplicitModelRequirement: true,
      hiddenValidationMessages: const {
        'Select a Worker.',
        'Select an effort for this model.',
      },
      onChanged: (selection) => setState(() {
        error = null;
        update(AxWorkflowSelection(
            worker: selection.worker,
            model: selection.model,
            effort: selection.effort,
            catalogRevision: selection.catalogRevision,
            mcpTools: value.mcpTools));
      }),
    );
  }

  Widget _notice(String text, {bool error = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text,
          style: TextStyle(
              color: error
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant)));

  bool _hideValidationMessage(String? message) => const {
        'Select an explicit model for this Worker.',
        'Select a Worker.',
        'Select an effort for this model.',
      }.contains(message);
  String _summary(
          AxWorkflowSelection value, AxWorkflowSelectionOptions options) =>
      [
        if (value.worker != null)
          options.worker(value.worker)?.displayName ?? 'Unavailable Worker',
        if (value.model != null)
          options.models(value.worker)[value.model] ?? value.model!,
        if (value.effort != null) '${_title(value.effort!)} effort',
      ].join(' · ');
}

String _title(String value) {
  final researcher = RegExp(r'^research-(\d+)$').firstMatch(value);
  if (researcher != null) return 'Researcher ${researcher.group(1)}';
  if (value == 'synthesis') return 'Synthesis';
  return value.isEmpty
      ? value
      : '${value[0].toUpperCase()}${value.substring(1)}';
}
