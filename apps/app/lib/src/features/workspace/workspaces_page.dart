import 'package:syntila_design/syntila_design.dart';
import '../../ax/ax_people.dart';
import '../../ax/ax_data.dart'
    show
        AxAccountPlanDataSource,
        AxWorkflowWorkspaceDataSource,
        AxWorkflowWorkspaceSettings;
import '../../ax/sync/ax_query_builder.dart';
import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/worker_presentation.dart';
import '../../ax/worker_usage.dart';
import 'worker_usage_dialog.dart';
import '../common/quiet_notices.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/sync/ax_workflow_configurations.dart';
import '../../ax/ax_workspace_member_access.dart';
import '../workflows/workflows_page.dart';
import 'workspace_member_access_section.dart';
import 'workspace_sharing_section.dart';

export 'workspaces_overview.dart';

/// Workspace-owned execution capacity, its Workers, and its Workflows.
///
/// Each registered Workspace is a tab; Workflows are configured inside the tab
/// of the Workspace they run on. Workspace routes always render this view.
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    super.key,
    required this.workspaces,
    this.workspaceWorkers = const [],
    this.workerUsageSource,
    this.initialWorkspaceId,
    this.workflowCatalogs,
    this.workflowConfigurations,
    this.viewerEmail,
    this.memberAccessSource,
    this.sharingSource,
    this.accountPlanSource,
    this.people = const [],
    this.personAccessSource,
    this.sharingRefresh,
    this.onSetParallelSlots,
    this.onRevoke,
    this.onLeaveShared,
    // Retained as optional compatibility inputs while callers are audited.
    VoidCallback? onAdd,
    ValueChanged<AxWorkspace>? onRename,
    ValueChanged<AxWorkspace>? onUpdate,
    Future<void> Function(AxWorkspace)? onConnect,
  });

  final ValueChanged<AxWorkspace>? onRevoke;

  /// Ends the viewer's own access to a Workspace someone shared with them.
  final ValueChanged<AxWorkspace>? onLeaveShared;

  /// Owner-only, Profile-defined usage commands; reports remain local view state.
  final AxWorkerUsageDataSource? workerUsageSource;
  final List<AxWorkspace> workspaces;
  final List<AxWorker> workspaceWorkers;
  final String? initialWorkspaceId;

  /// Workflow inputs. When either is null the Workflows section is hidden.
  final AxSessionCatalogs? workflowCatalogs;
  final AxWorkflowConfigurations? workflowConfigurations;
  final String? viewerEmail;

  /// Enables the owner's "Member access" section of each Workspace tab.
  final AxWorkspaceMemberAccessDataSource? memberAccessSource;

  /// Enables lending: the owner's sharing section and the invited person's banner.
  final AxWorkspaceSharingDataSource? sharingSource;
  final AxAccountPlanDataSource? accountPlanSource;

  /// People the owner can share a Workspace with.
  final List<AxPerson> people;

  /// Enables editing one person's Workers, models and mode.
  final AxWorkspacePersonAccessDataSource? personAccessSource;

  /// Fires when an invitation changes elsewhere; the sharing section reloads.
  final Listenable? sharingRefresh;

  /// Owner-only: how many requests run at once. Cloud enforces it; the
  /// Workspace app has no slot setting of its own.
  final Future<void> Function(AxWorkspace workspace, int slots)?
      onSetParallelSlots;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage>
    with TickerProviderStateMixin {
  TabController? _tabs;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.initialWorkspaceId;
    _syncTabs();
  }

  @override
  void didUpdateWidget(WorkspacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialWorkspaceId != widget.initialWorkspaceId &&
        widget.initialWorkspaceId != null) {
      _selectedId = widget.initialWorkspaceId;
    }
    _syncTabs();
  }

  @override
  void dispose() {
    _tabs?.dispose();
    super.dispose();
  }

  void _syncTabs() {
    final count = widget.workspaces.length;
    if (count == 0) {
      _tabs?.dispose();
      _tabs = null;
      return;
    }
    var index = widget.workspaces.indexWhere((w) => w.id == _selectedId);
    if (index < 0) index = 0;
    if (_tabs?.length != count) {
      _tabs?.dispose();
      _tabs = TabController(length: count, vsync: this, initialIndex: index)
        ..addListener(_onTabChanged);
    } else if (_tabs!.index != index) {
      _tabs!.index = index;
    }
    _selectedId = widget.workspaces[index].id;
  }

  void _onTabChanged() {
    final tabs = _tabs;
    if (tabs == null || tabs.indexIsChanging) return;
    final id = widget.workspaces[tabs.index].id;
    if (id != _selectedId) setState(() => _selectedId = id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tabs = _tabs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tabs == null)
          const _EmptyWorkspaces()
        else ...[
          SizedBox(
            width: double.infinity,
            child: TabBar(
              key: const Key('workspace-tabs'),
              controller: tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              labelColor: SyntilaColors.primaryForeground(isDark),
              unselectedLabelColor: SyntilaColors.textSecondary(isDark),
              indicatorColor: SyntilaColors.primaryForeground(isDark),
              dividerHeight: 0,
              tabs: [
                for (final workspace in widget.workspaces)
                  Tab(
                      key: Key('workspace-tab-${workspace.id}'),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        _StatusDot(status: _statusLabel(workspace)),
                        const SizedBox(width: 6),
                        Text(workspace.name),
                      ])),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 1),
          const SizedBox(height: 16),
          _workspaceDetail(context, widget.workspaces[tabs.index]),
        ],
      ],
    );
  }

  Widget _workspaceDetail(BuildContext context, AxWorkspace workspace) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final workers = widget.workspaceWorkers
        .where((worker) =>
            worker.workspaceId == workspace.id && worker.status != 'removed')
        .toList(growable: false);
    final catalogs = widget.workflowCatalogs;
    final configurations = widget.workflowConfigurations;
    final machineName =
        workspace.hostname.isNotEmpty && workspace.hostname != '—'
            ? workspace.hostname
            : workspace.name;
    final machineOs = _machine(workspace);

    return Column(
      key: Key('workspace-detail-${workspace.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (machineName.isNotEmpty && machineName != '—')
                    Text(
                      machineName,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  if (machineOs != '—')
                    Text(
                      machineOs,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  if (workspace.shared)
                    const Chip(
                        key: ValueKey('workspace-shared-badge'),
                        avatar: Icon(Icons.people_outline, size: 16),
                        label: Text('Shared with you')),
                ],
              ),
            ),
            if (configurations != null &&
                configurations.source is AxWorkflowWorkspaceDataSource)
              _DefaultWorkspaceControl(
                key: ValueKey('default-workspace-${workspace.id}'),
                configurations: configurations,
                workspace: workspace,
              ),
          ],
        ),
        if (widget.onSetParallelSlots != null &&
            !workspace.shared &&
            workspace.parallelSlots != null)
          _ParallelSlotsControl(
            key: ValueKey('parallel-slots-${workspace.id}'),
            slots: workspace.parallelSlots!,
            onChanged: (slots) => widget.onSetParallelSlots!(workspace, slots),
          ),
        const SizedBox(height: 16),
        _WorkspaceCardBody(
          workers: workers,
          usageSource:
              workspace.role == 'owner' ? widget.workerUsageSource : null,
          online: workspace.status.toLowerCase() == 'online',
        ),
        if (catalogs != null && configurations != null) ...[
          const SizedBox(height: 24),
          WorkflowsPage(
            key: ValueKey('workspace-workflows-${workspace.id}'),
            catalogs: catalogs,
            configurations: configurations.forWorkspace(workspace.id),
            viewerEmail: widget.viewerEmail,
            workspaceId: workspace.id,
            showWorkspaceAction: false,
          ),
        ],
        // A lent Workspace is used, not managed: its owner controls access.
        if (widget.sharingSource != null && !workspace.shared) ...[
          const SizedBox(height: 24),
          WorkspaceSharingSection(
            key: ValueKey('workspace-sharing-${workspace.id}'),
            workspaceId: workspace.id,
            source: widget.sharingSource!,
            planSource: widget.accountPlanSource,
            people: widget.people,
            memberAccessSource: widget.memberAccessSource,
            personAccessSource: widget.personAccessSource,
            workers: widget.workspaceWorkers,
            refresh: widget.sharingRefresh,
            expandable: true,
          ),
        ],
        if (widget.memberAccessSource != null && !workspace.shared) ...[
          const SizedBox(height: 24),
          WorkspaceMemberAccessSection(
            key: ValueKey('workspace-member-access-${workspace.id}'),
            workspaceId: workspace.id,
            workers: widget.workspaceWorkers,
            source: widget.memberAccessSource!,
            expandable: true,
          ),
        ],
        if (workspace.shared && widget.onLeaveShared != null) ...[
          const SizedBox(height: 32),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('leave-shared-workspace-${workspace.id}'),
              icon: Icon(Icons.link_off,
                  size: 18, color: SyntilaColors.errorText(isDark)),
              label: Text(
                'Revoke shared Workspace',
                style: TextStyle(color: SyntilaColors.errorText(isDark)),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: SyntilaColors.errorText(isDark)),
              ),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    constraints: SyntilaDialogStyle.small,
                    title: Text('Revoke ${workspace.name}?'),
                    content: const Text(
                      'You will no longer be able to run on this Workspace. Work already running finishes. The owner can invite you again.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        key: const ValueKey('confirm-leave-shared-workspace'),
                        style: SyntilaDialogStyle.destructiveButton(),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Revoke'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) widget.onLeaveShared!(workspace);
              },
            ),
          ),
        ],
        if (!workspace.shared && widget.onRevoke != null) ...[
          const SizedBox(height: 32),
          Divider(color: Theme.of(context).colorScheme.outlineVariant),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: ValueKey('revoke-workspace-${workspace.id}'),
              icon: Icon(Icons.delete_outline,
                  size: 18, color: SyntilaColors.errorText(isDark)),
              label: Text(
                'Unregister Workspace',
                style: TextStyle(color: SyntilaColors.errorText(isDark)),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: SyntilaColors.errorText(isDark)),
              ),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    constraints: SyntilaDialogStyle.small,
                    title: Text('Unregister ${workspace.name}?'),
                    content: const Text(
                      'This will disconnect and revoke the Workspace registration in Cloud. You can register it again at any time with syntila login.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        key: const ValueKey('confirm-revoke-workspace'),
                        style: SyntilaDialogStyle.destructiveButton(),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Unregister'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  widget.onRevoke!(workspace);
                }
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _WorkspaceCardBody extends StatelessWidget {
  const _WorkspaceCardBody({
    required this.workers,
    required this.usageSource,
    required this.online,
  });

  final List<AxWorker> workers;
  final AxWorkerUsageDataSource? usageSource;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (workers.isEmpty) {
      return Text(
        'No Workers are available for this Workspace yet. Configure Workers in Syntila Workspace on this computer.',
        style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // Compute columns based on compact card minimum width of ~240px
        const double gap = 12;
        final double availableWidth = constraints.maxWidth;
        final int columns = (availableWidth / 240).floor().clamp(1, 4);

        if (columns == 1) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (int i = 0; i < workers.length; i++) ...[
                if (i > 0) const SizedBox(height: gap),
                _WorkerCard(
                    worker: workers[i],
                    usageSource: usageSource,
                    online: online),
              ],
            ],
          );
        }

        // When multiple columns, group into rows and wrap in IntrinsicHeight
        // so all worker widgets in the row share the same height.
        final List<List<AxWorker>> rows = [];
        for (int i = 0; i < workers.length; i += columns) {
          rows.add(workers.sublist(i,
              (i + columns < workers.length) ? i + columns : workers.length));
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (int r = 0; r < rows.length; r++) ...[
              if (r > 0) const SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int c = 0; c < columns; c++) ...[
                      if (c > 0) const SizedBox(width: gap),
                      Expanded(
                        child: c < rows[r].length
                            ? _WorkerCard(
                                worker: rows[r][c],
                                usageSource: usageSource,
                                online: online)
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
    );
  }
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard(
      {required this.worker, required this.usageSource, required this.online});
  final AxWorkerUsageDataSource? usageSource;
  final bool online;
  final AxWorker worker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = worker.executionOptions?.models
            .where((model) => model.status != 'unavailable')
            .map((model) => model.name)
            .toList() ??
        const <String>[];
    final toolName = worker.providerToolName ?? 'Provider CLI';
    final toolVersion = worker.providerToolVersion ?? 'Not detected';
    final toolInfo = '$toolName $toolVersion';

    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.displayName,
      profileDefinitionId: worker.profileDefinitionId,
      providerToolName: worker.providerToolName,
    );
    final workerIcon =
        presentation.iconAssetForBrightness(Theme.of(context).brightness);
    final isDark = theme.brightness == Brightness.dark;

    final Widget iconWidget = workerIcon != null
        ? Image.asset(
            workerIcon,
            width: 32,
            height: 32,
            fit: BoxFit.contain,
            semanticLabel: '${worker.displayName} icon',
          )
        : Icon(
            worker.isReady ? Icons.smart_toy_outlined : Icons.warning_amber,
            size: 32,
            color: worker.isReady ? null : SyntilaColors.warningText(isDark),
          );

    final modelsText = models.isEmpty ? 'Unavailable' : models.join(' · ');

    return Card(
      key: Key('workspace-worker-row-${worker.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: iconWidget,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              worker.displayName,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          if (!worker.isReady)
                            Icon(
                              Icons.warning_amber,
                              size: 16,
                              color: SyntilaColors.warningText(isDark),
                            )
                          else
                            Icon(
                              Icons.check_circle_outline,
                              size: 16,
                              color: SyntilaColors.successText(isDark),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              toolInfo,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (usageSource != null) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              key: ValueKey(
                                  'workspace-worker-usage-${worker.id}'),
                              icon: const Icon(Icons.speed, size: 16),
                              iconSize: 16,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 20, height: 20),
                              style: const ButtonStyle(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: online && worker.isReady
                                  ? () => showDialog<void>(
                                        context: context,
                                        builder: (_) => WorkerUsageDialog(
                                            source: usageSource!,
                                            worker: worker),
                                      )
                                  : null,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              modelsText,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final online = status.toLowerCase() == 'online';
    return Tooltip(
      message: _display(status),
      child: Icon(Icons.circle,
          size: 9,
          semanticLabel: _display(status),
          color: online
              ? SyntilaColors.successText(
                  Theme.of(context).brightness == Brightness.dark)
              : SyntilaColors.neutral),
    );
  }
}

class _EmptyWorkspaces extends StatelessWidget {
  const _EmptyWorkspaces();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('No Workspaces connected',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              SizedBox(height: 8),
              Text(
                  'Download and register Syntila Workspace to make a Workspace and its Workers available here.'),
            ],
          ),
        ),
      );
}

String _machine(AxWorkspace workspace) {
  final os = switch (workspace.platform.toLowerCase()) {
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    _ => workspace.platform,
  };
  return os.isEmpty ? '—' : os;
}

String _display(String value) => value.isEmpty ? '—' : value;

String _statusLabel(AxWorkspace workspace) =>
    workspace.status.toLowerCase() == 'offline' && !workspace.hasRuntimeIdentity
        ? 'Not connected'
        : switch (workspace.status.toLowerCase()) {
            'online' => 'Online',
            'offline' => 'Offline',
            'busy' => 'Busy',
            'draining' => 'Draining',
            'revoked' => 'Revoked',
            _ => workspace.status,
          };

/// The same user selection inherited by Spaces and their Threads.
class _DefaultWorkspaceControl extends StatefulWidget {
  const _DefaultWorkspaceControl(
      {super.key, required this.configurations, required this.workspace});
  final AxWorkflowConfigurations configurations;
  final AxWorkspace workspace;
  @override
  State<_DefaultWorkspaceControl> createState() =>
      _DefaultWorkspaceControlState();
}

class _DefaultWorkspaceControlState extends State<_DefaultWorkspaceControl> {
  bool _busy = false;
  String? _error;

  Future<void> _makeDefault() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              constraints: SyntilaDialogStyle.small,
              title: const Text('Change default Workspace?'),
              content: Text(
                  'Spaces using the default Workspace, including new Spaces, will use ${widget.workspace.name}. Workflow overrides in inheriting Spaces are reset. Saved per-Workspace workflows and existing runs keep their settings.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('confirm-default-workspace'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Make default')),
              ],
            ));
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.configurations.selectWorkspace(widget.workspace.id);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      AxQueryBuilder<AxWorkflowWorkspaceSettings>(
        engine: widget.configurations.engine,
        query: widget.configurations.workspaceQuery,
        builder: (context, state) {
          final settings = state.data;
          final selected = settings?.workspaceId == widget.workspace.id;
          final eligible =
              settings?.workspaces.any((w) => w.id == widget.workspace.id) ??
                  false;
          return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (selected)
              const Chip(
                  key: ValueKey('default-workspace-badge'),
                  avatar: Icon(Icons.check, size: 16),
                  label: Text('Default Workspace'))
            else if (eligible)
              TextButton(
                  key: const ValueKey('make-default-workspace'),
                  onPressed: _busy ? null : _makeDefault,
                  child: const Text('Make default')),
            if (state.error != null)
              TextButton(
                  onPressed: () => widget.configurations.engine
                      .refresh(widget.configurations.workspaceQuery),
                  child: const Text('Retry default Workspace')),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ]);
        },
      );
}

/// Bounds match Cloud's accepted range for a Workspace's slot total.
const _minParallelSlots = 1;
const _maxParallelSlots = 10;

class _ParallelSlotsControl extends StatefulWidget {
  const _ParallelSlotsControl(
      {super.key, required this.slots, required this.onChanged});

  final int slots;
  final Future<void> Function(int slots) onChanged;

  @override
  State<_ParallelSlotsControl> createState() => _ParallelSlotsControlState();
}

class _ParallelSlotsControlState extends State<_ParallelSlotsControl> {
  bool _saving = false;

  Future<void> _change(int? slots) async {
    if (slots == null || slots == widget.slots) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(slots);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          Text('Parallel requests',
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: 12),
          Builder(builder: (context) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(1),
                child: PopupMenuButton<int>(
                  key: const ValueKey('parallel-slots-select'),
                  enabled: !_saving,
                  tooltip: 'Choose parallel requests',
                  color: SyntilaColors.composerBackground(isDark),
                  surfaceTintColor: Colors.transparent,
                  elevation: 12,
                  shadowColor: SyntilaMenuStyle.shadow(isDark),
                  shape: SyntilaMenuStyle.shape(isDark),
                  menuPadding: SyntilaMenuStyle.padding,
                  onSelected: _change,
                  itemBuilder: (context) => [
                    for (var n = _minParallelSlots; n <= _maxParallelSlots; n++)
                      SyntilaMenuEntry<int>(
                        value: n,
                        child: MenuItemButton(
                          style: SyntilaMenuStyle.item(isDark),
                          leadingIcon: Icon(
                            n == widget.slots
                                ? Icons.check_circle_rounded
                                : Icons.circle_outlined,
                            size: 15,
                          ),
                          onPressed: () => Navigator.pop(context, n),
                          child: Text('$n', style: SyntilaMenuStyle.textStyle),
                        ),
                      ),
                  ],
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('${widget.slots}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    )),
                        const SizedBox(width: 2),
                        const Icon(Icons.keyboard_arrow_down, size: 14),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ]),
      );
}
