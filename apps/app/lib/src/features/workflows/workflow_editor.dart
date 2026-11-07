import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_protocol/syntila_protocol.dart';
import 'package:flutter/material.dart';
import '../common/page_width.dart';
import '../../ax/ax_models.dart';
import '../../ax/ax_workflow_configuration.dart';
import '../../ax/workflow_configuration_options.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/ax_mcp_inventory.dart';
import '../../ax/sync/ax_mcp_inventories.dart';

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
      this.stepsOnly = false});
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

  /// Sanitized MCP inventory of this Workspace, shared per session. A failed
  /// load keeps whatever was last known; selections are never dropped for it.
  late final AxMcpInventories _inventories =
      AxMcpInventories(widget.cache.source, engine: widget.cache.engine);
  AxMcpInventory? _inventory;
  bool _inventoryUnavailable = false;

  Future<void> _loadInventory({bool force = false}) async {
    final workspaceId = widget.workspaceId;
    if (workspaceId == null || !_inventories.isSupported) {
      _inventoryUnavailable = true;
      return;
    }
    try {
      final loaded = force
          ? await _inventories.refresh(workspaceId)
          : await _inventories.ensure(workspaceId);
      _inventory = loaded ?? _inventory;
      _inventoryUnavailable = loaded == null && _inventory == null;
    } on Object {
      _inventoryUnavailable = _inventory == null;
    }
  }

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
  Widget build(BuildContext context) => PopScope(
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
                                onChanged:
                                    busy || widget.definition.id == 'chat'
                                        ? null
                                        : (value) =>
                                            setState(() => enabled = value)),
                            Text('Default execution',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 12),
                            _selection(
                                'defaults',
                                defaults,
                                const AxWorkflowSelection(),
                                options,
                                (value) => defaults = value),
                            _mcpServers('defaults', defaults,
                                isDefault: true,
                                update: (value) => defaults = value),
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
                                for (var index = 0;
                                    index < steps.length;
                                    index++)
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
                                      onPressed: busy
                                          ? null
                                          : () => _save(reset: true),
                                      child: Text(
                                          widget.cache.spaceId == null ||
                                                  widget.cache.engine
                                                          .peek(widget.cache
                                                              .workspaceQuery)
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
                                    onPressed: busy || issues.isNotEmpty
                                        ? null
                                        : _save,
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
          _mcpServers(step.instanceId, selection,
              isDefault: false,
              update: (value) => overrides[step.instanceId] = value),
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

  /// What a Step gets from MCP, in words. A missing selection grants nothing:
  /// Worker bindings only cap what a Step may choose, they never grant it.
  String _mcpSummary(List<String>? servers, {required bool isDefault}) {
    String names(List<String> ids) =>
        ids.map((id) => _inventory?.byId(id)?.displayName ?? id).join(', ');
    if (servers != null) {
      return servers.isEmpty
          ? 'No MCP servers (set explicitly)'
          : names(servers);
    }
    if (isDefault) return 'No MCP servers (default)';
    final inherited = defaults.mcpTools;
    if (inherited == null || inherited.isEmpty) {
      return 'Inherits the workflow default: no MCP servers';
    }
    return 'Inherits the workflow default: ${names(inherited)}';
  }

  Widget _mcpServers(String scope, AxWorkflowSelection value,
      {required bool isDefault,
      required ValueChanged<AxWorkflowSelection> update}) {
    final servers = value.mcpTools;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('MCP servers'),
      subtitle: Text(_mcpSummary(servers, isDefault: isDefault)),
      trailing: TextButton(
        key: ValueKey('mcp-edit-$scope'),
        onPressed: busy
            ? null
            : () async {
                await _loadInventory();
                if (!mounted) return;
                final result = await showDialog<_McpServerChoice>(
                  context: context,
                  builder: (_) => _McpServerDialog(
                    initial: servers,
                    isDefault: isDefault,
                    inventory: _inventory,
                    inventoryUnavailable: _inventoryUnavailable,
                    refresh: () async {
                      await _loadInventory(force: true);
                      return _inventory;
                    },
                  ),
                );
                if (result != null && mounted) {
                  setState(() {
                    error = null;
                    update(value.withMcpTools(result.servers));
                  });
                }
              },
        child: const Text('Edit'),
      ),
    );
  }

  Widget _selection(
      String scope,
      AxWorkflowSelection value,
      AxWorkflowSelection base,
      AxWorkflowSelectionOptions options,
      ValueChanged<AxWorkflowSelection> update) {
    return ModelEffortSelector(
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

class _McpServerChoice {
  const _McpServerChoice(this.servers);
  final List<String>? servers;
}

class _McpServerDialog extends StatefulWidget {
  const _McpServerDialog({
    required this.initial,
    required this.isDefault,
    required this.inventory,
    required this.inventoryUnavailable,
    required this.refresh,
  });
  final List<String>? initial;
  final bool isDefault;

  /// Null when nothing was published or it could not be loaded.
  final AxMcpInventory? inventory;
  final bool inventoryUnavailable;
  final Future<AxMcpInventory?> Function() refresh;
  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  static const maxServers = 8;
  final form = GlobalKey<FormState>();
  final search = TextEditingController();
  late AxMcpInventory? inventory = widget.inventory;
  late bool unavailable = widget.inventoryUnavailable;
  bool refreshing = false;
  bool emptyChoice = false;
  late String mode = widget.initial == null
      ? 'inherit'
      : widget.initial!.isEmpty
          ? 'none'
          : 'selected';

  /// Chosen server IDs in the order they were chosen. IDs the inventory does
  /// not list stay here (shown as unavailable) so an edit never drops them.
  late final List<String> chosen = [...?widget.initial];
  late final manual = TextEditingController(text: chosen.join('\n'));

  @override
  void dispose() {
    search.dispose();
    manual.dispose();
    super.dispose();
  }

  bool get _manualEntry => inventory == null;

  List<String> get _manualIds => manual.text
      .split(RegExp(r'[\n,]'))
      .map((id) => id.trim())
      .where((id) => id.isNotEmpty)
      .toList();

  List<String> get _result => _manualEntry ? _manualIds : chosen;

  void _toggle(String id, bool on) => setState(() {
        chosen.remove(id);
        if (on) chosen.add(id);
      });

  Future<void> _refresh() async {
    setState(() => refreshing = true);
    final loaded = await widget.refresh();
    if (!mounted) return;
    setState(() {
      inventory = loaded ?? inventory;
      unavailable = loaded == null && inventory == null;
      refreshing = false;
    });
  }

  Widget _banner(String text, {bool warning = false}) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text,
            style: TextStyle(
                color: warning ? Theme.of(context).colorScheme.error : null)),
      );

  Widget _serverList() {
    final current = inventory!;
    final needle = search.text.trim().toLowerCase();
    final shown = [
      for (final server in current.servers)
        if (needle.isEmpty ||
            server.displayName.toLowerCase().contains(needle) ||
            server.serverId.contains(needle))
          server
    ];
    final missing = [
      for (final id in chosen)
        if (current.byId(id) == null) id
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('mcp-search'),
          controller: search,
          decoration: const InputDecoration(
              labelText: 'Search servers', prefixIcon: Icon(Icons.search)),
          onChanged: (_) => setState(() {}),
        ),
        if (current.isStale)
          _banner(
              'The Workspace is not connected. These are the servers it last '
              'reported${current.ageSeconds == null ? '' : ' ${_age(current.ageSeconds!)} ago'}.',
              warning: true),
        if (current.servers.isEmpty)
          _banner('This Workspace has no MCP servers yet. Add one with '
              'syntila mcp add, then refresh.'),
        for (final server in shown)
          CheckboxListTile(
            key: ValueKey('mcp-server-${server.serverId}'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: chosen.contains(server.serverId),
            // An unauthorized server can be unchecked but not newly chosen.
            onChanged:
                (server.isAuthorized || chosen.contains(server.serverId)) &&
                        (chosen.length < maxServers ||
                            chosen.contains(server.serverId))
                    ? (on) => _toggle(server.serverId, on ?? false)
                    : null,
            title: Text(server.displayName),
            subtitle: Text([
              server.serverId,
              server.isRemote ? 'remote' : 'local',
              '${server.tools.length} tool${server.tools.length == 1 ? '' : 's'}',
              server.blocker ?? 'Ready to use',
            ].join(' · ')),
          ),
        if (shown.isEmpty && current.servers.isNotEmpty)
          _banner('No server matches "$needle".'),
        if (missing.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Chosen but not in the Workspace inventory'),
          for (final id in missing)
            CheckboxListTile(
              key: ValueKey('mcp-server-$id'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: true,
              onChanged: (on) => _toggle(id, on ?? false),
              title: Text(id),
              subtitle: const Text(
                  'Not found. A run that needs it will fail until it is '
                  'available.'),
            ),
        ],
        if (chosen.length >= maxServers)
          _banner('You can choose up to $maxServers servers.'),
        if (emptyChoice && chosen.isEmpty)
          _banner('Choose at least one server, or pick "No servers".',
              warning: true),
      ],
    );
  }

  static String _age(int seconds) {
    if (seconds < 90) return '${seconds}s';
    if (seconds < 5400) return '${(seconds / 60).round()} min';
    return '${(seconds / 3600).round()} h';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('MCP servers'),
        content: SizedBox(
          width: 460,
          child: Form(
              key: form,
              child: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    key: const ValueKey('mcp-mode'),
                    isExpanded: true,
                    initialValue: mode,
                    decoration:
                        const InputDecoration(labelText: 'Server selection'),
                    items: [
                      DropdownMenuItem(
                          value: 'inherit',
                          child: Text(widget.isDefault
                              ? 'Default: no servers'
                              : 'Inherit workflow defaults')),
                      const DropdownMenuItem(
                          value: 'none', child: Text('No servers (explicit)')),
                      const DropdownMenuItem(
                          value: 'selected', child: Text('Choose servers')),
                    ],
                    onChanged: (value) => setState(() => mode = value ?? mode),
                  ),
                  if (mode == 'selected') ...[
                    if (_manualEntry) ...[
                      _banner(
                          unavailable
                              ? 'The Workspace server list could not be loaded, '
                                  'so servers cannot be chosen by name.'
                              : 'This Workspace has not published its server '
                                  'list yet.',
                          warning: true),
                      TextFormField(
                        key: const ValueKey('mcp-server-ids'),
                        controller: manual,
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          labelText: 'Server IDs',
                          helperText:
                              'Up to 8 IDs, one per line or separated by commas.',
                        ),
                        validator: (_) {
                          final values = _manualIds;
                          if (values.isEmpty) {
                            return 'Enter at least one server ID.';
                          }
                          if (values.length > maxServers) {
                            return 'Choose no more than $maxServers servers.';
                          }
                          if (values.toSet().length != values.length) {
                            return 'Remove duplicate IDs.';
                          }
                          if (values.any((id) =>
                              !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$')
                                  .hasMatch(id))) {
                            return 'Use lowercase letters, numbers, hyphens, or underscores.';
                          }
                          return null;
                        },
                      ),
                    ] else
                      _serverList(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey('mcp-refresh'),
                        onPressed: refreshing ? null : _refresh,
                        icon: const Icon(Icons.refresh),
                        label: Text(refreshing
                            ? 'Refreshing'
                            : 'Refresh from Workspace'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                      'A Step only gets servers chosen here that are also '
                      'consented, enabled and bound to its Worker on the '
                      'Workspace. Nothing is chosen by default.'),
                ],
              ))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              key: const ValueKey('mcp-apply'),
              onPressed: () {
                if (mode == 'selected' && !_manualEntry && chosen.isEmpty) {
                  setState(() => emptyChoice = true);
                  return;
                }
                if (mode == 'selected' &&
                    _manualEntry &&
                    !form.currentState!.validate()) {
                  return;
                }
                Navigator.pop(
                    context,
                    _McpServerChoice(
                      mode == 'inherit'
                          ? null
                          : mode == 'none'
                              ? const []
                              : List.unmodifiable(_result),
                    ));
              },
              child: const Text('Apply')),
        ],
      );
}
