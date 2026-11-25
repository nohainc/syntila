import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/ax_data.dart'
    show
        AxWorkerManagementSource,
        AxWorkerModelsSource,
        AxWorkerPersonShareSource;
import '../../ax/ax_people.dart' show AxPeopleDataSource;
import '../../ax/ax_models.dart' show AxSpace, AxWorker;
import '../../ax/mcp_worker_pin.dart';
import '../../ax/worker_presentation.dart';
import '../../ax/worker_execution_options.dart';
import '../../ax/worker_usage.dart' show AxWorkerUsageDataSource;
import 'worker_member_models_section.dart';
import 'worker_person_shares_section.dart';
import 'worker_model_visibility_table.dart';
import 'worker_usage_dialog.dart';

/// Read-only identity view during the Worker-first rollout. Management is P6.
class WorkerInstancesSection extends StatelessWidget {
  const WorkerInstancesSection({
    super.key,
    required this.catalogs,
    this.selectedWorkerId,
    this.onSelectWorker,
    this.onBackToList,
    this.spaces = const [],
    this.currentUserId,
  });

  final AxSessionCatalogs catalogs;

  /// The user's Spaces; shared ones they manage can get Worker access.
  final List<AxSpace> spaces;
  final String? currentUserId;
  final String? selectedWorkerId;
  final ValueChanged<String>? onSelectWorker;
  final VoidCallback? onBackToList;

  @override
  Widget build(BuildContext context) => AxQueryBuilder<List<WorkerInstance>>(
        engine: catalogs.engine,
        query: catalogs.workerInstances,
        builder: (context, state) => WorkerInstancesList(
          workers: state.data,
          error: state.error,
          selectedWorkerId: selectedWorkerId,
          onSelectWorker: onSelectWorker,
          onBackToList: onBackToList,
          shareSpaces: [
            for (final space in spaces)
              if (!space.archived &&
                  space.kind != 'direct' &&
                  (space.role == 'owner' || space.role == 'collaborator'))
                space
          ],
          currentUserId: currentUserId,
          // A change was just made: supersede any load already in
          // flight, which started before it and would show stale data.
          onRefresh: () async {
            // Read the list now and apply it directly: the same
            // authoritative path local edits use, so a change made here
            // (add, enable, rename...) shows at once instead of waiting
            // for the shared reader to reuse or replace a load.
            final source = catalogs.source;
            if (source == null) {
              return catalogs.engine
                  .refresh(catalogs.workerInstances, supersede: true);
            }
            final fresh = await source.loadWorkerInstances();
            catalogs.engine.update<List<WorkerInstance>>(
                catalogs.workerInstances, (_) => List.unmodifiable(fresh));
            return fresh;
          },
          onLocalUpdate: (transform) =>
              catalogs.engine.update<List<WorkerInstance>>(
            catalogs.workerInstances,
            (current) => List.unmodifiable(
                transform(current.data ?? const <WorkerInstance>[])),
          ),
          management: catalogs.source is AxWorkerManagementSource
              ? catalogs.source as AxWorkerManagementSource
              : null,
          usageSource: catalogs.source is AxWorkerUsageDataSource
              ? catalogs.source as AxWorkerUsageDataSource
              : null,
        ),
      );
}

class WorkerInstancesList extends StatelessWidget {
  const WorkerInstancesList({
    super.key,
    required this.workers,
    required this.error,
    required this.onRefresh,
    this.onLocalUpdate,
    this.management,
    this.usageSource,
    this.selectedWorkerId,
    this.onSelectWorker,
    this.onBackToList,
    this.shareSpaces = const [],
    this.currentUserId,
  });

  final List<WorkerInstance>? workers;

  /// Spaces whose members this Worker can be shared with.
  final List<AxSpace> shareSpaces;
  final String? currentUserId;
  final Object? error;
  final Future<Object?> Function() onRefresh;
  final void Function(
          List<WorkerInstance> Function(List<WorkerInstance>) transform)?
      onLocalUpdate;
  final AxWorkerManagementSource? management;
  final AxWorkerUsageDataSource? usageSource;
  final String? selectedWorkerId;
  final ValueChanged<String>? onSelectWorker;
  final VoidCallback? onBackToList;

  static WorkerInstance _copyWorker(
    WorkerInstance w, {
    String? name,
    bool? enabled,
    bool? paired,
    bool? online,
    bool? ready,
    List<String>? hiddenModels,
    Map<String, List<String>>? hiddenEfforts,
  }) =>
      WorkerInstance(
        id: w.id,
        actorId: w.actorId,
        workerTypeId: w.workerTypeId,
        workerTypeName: w.workerTypeName,
        name: name ?? w.name,
        description: w.description,
        enabled: enabled ?? w.enabled,
        online: online ?? w.online,
        paired: paired ?? w.paired,
        ready: ready ?? w.ready,
        readinessKnown: w.readinessKnown,
        defaultModel: w.defaultModel,
        deviceId: w.deviceId,
        deviceName: w.deviceName,
        providerToolName: w.providerToolName,
        providerToolVersion: w.providerToolVersion,
        executionOptions: w.executionOptions,
        hiddenModels: hiddenModels ?? w.hiddenModels,
        hiddenEfforts: hiddenEfforts ?? w.hiddenEfforts,
        modelsStatus: w.modelsStatus,
        modelsReportedAt: w.modelsReportedAt,
        createdAt: w.createdAt,
        updatedAt: w.updatedAt,
        revokedAt: w.revokedAt,
      );

  Future<void> _add(BuildContext context) async {
    final source = management;
    if (source == null) return;
    try {
      final types = await source.loadWorkerTypes();
      if (!context.mounted) return;
      if (types.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No Worker Types are available.')));
        return;
      }
      final added = await showDialog<bool>(
        context: context,
        builder: (_) => _AddWorkerDialog(
          types: types,
          onCreate: source.createWorkerInstance,
        ),
      );
      if (added == true) await onRefresh();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not add Worker. Please try again.')));
      }
    }
  }

  /// Pins the MCP Worker version this Worker runs (ADR-041). Cloud sends only
  /// this exact version; the Agent still runs it only if the machine's own list
  /// approves the same digest, so approval stays on that machine.
  Future<void> _chooseMcpWorker(BuildContext context,
      AxWorkerManagementSource source, WorkerInstance worker) async {
    McpWorkerPinState state;
    try {
      state = await source.loadMcpWorkerPin(worker.id);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('MCP Workers are not available right now.')));
      }
      return;
    }
    if (!context.mounted) return;
    final picked = await showDialog<Object>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('MCP Worker version'),
              content: SizedBox(
                width: 420,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(state.pin == null
                          ? 'No version is pinned, so this Worker cannot run work yet.'
                          : 'Pinned: ${state.pin!.version}'),
                      const SizedBox(height: 12),
                      if (state.available.isEmpty)
                        const Text(
                            'The connected Agent has not reported an MCP Worker it can run. '
                            'On that machine, import and test it with `syntila-connect mcp-worker`, then reconnect.')
                      else
                        for (final version in state.available)
                          ListTile(
                            key: ValueKey(
                                'mcp-version-${version.manifestDigest}'),
                            dense: true,
                            title: Text('${version.id} ${version.version}'),
                            subtitle:
                                Text(version.manifestDigest.substring(0, 12)),
                            selected: version == state.pin,
                            onTap: () => Navigator.pop(context, version),
                          ),
                    ]),
              ),
              actions: [
                if (state.pin != null)
                  TextButton(
                      onPressed: () => Navigator.pop(context, 'clear'),
                      child: const Text('Clear pin')),
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close')),
              ],
            ));
    if (picked == null) return;
    try {
      if (picked is McpWorkerVersion) {
        await source.setMcpWorkerPin(worker.id, picked);
      } else {
        await source.clearMcpWorkerPin(worker.id);
      }
      await onRefresh();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not pin that version. It must be in your MCP Worker library.')));
      }
    }
  }

  /// Asks the connected Worker to re-read its models, then watches the list
  /// until it reports (the Agent answers on its next heartbeat).
  Future<void> _refreshModels(
      BuildContext context, WorkerInstance worker) async {
    final source = management;
    final messenger = ScaffoldMessenger.of(context);
    if (source is! AxWorkerModelsSource) return;
    try {
      await (source as AxWorkerModelsSource)
          .requestWorkerModelsRefresh(worker.id);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    messenger.showSnackBar(const SnackBar(
        content: Text(
            'Asked the Worker to read its models. This can take up to a minute.')));
    final before = worker.modelsReportedAt;
    for (var i = 0; i < 24; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final list = await onRefresh();
        if (list is List<WorkerInstance>) {
          final now = list.where((w) => w.id == worker.id).firstOrNull;
          if (now != null && now.modelsReportedAt != before) return;
        }
      } catch (_) {
        // Try again on the next tick.
      }
    }
  }

  Future<void> _act(
      BuildContext context, WorkerInstance worker, String action) async {
    final source = management;
    if (source == null) return;
    try {
      if (action == 'rename') {
        var value = worker.name;
        final result = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                  constraints: SyntilaDialogStyle.small,
                  title: const Text('Rename Worker'),
                  content: TextFormField(
                      initialValue: value,
                      onChanged: (text) => value = text,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'Name')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, value.trim()),
                        child: const Text('Save'))
                  ],
                ));
        if (result == null || result.isEmpty) return;
        await source.updateWorkerInstance(worker.id, {'name': result});
        onLocalUpdate?.call((list) => [
              for (final w in list)
                if (w.id == worker.id) _copyWorker(w, name: result) else w
            ]);
      } else if (action == 'toggle') {
        final nextEnabled = !worker.enabled;
        await source.updateWorkerInstance(worker.id, {'enabled': nextEnabled});
        onLocalUpdate?.call((list) => [
              for (final w in list)
                if (w.id == worker.id)
                  _copyWorker(w, enabled: nextEnabled)
                else
                  w
            ]);
      } else if (action == 'mcp') {
        await _chooseMcpWorker(context, source, worker);
        return;
      } else if (action == 'pair') {
        final code = await source.pairWorkerInstance(worker.id);
        if (!context.mounted) return;
        var copied = false;
        await showDialog<void>(
            context: context,
            builder: (context) => StatefulBuilder(
                  builder: (context, setDialogState) => AlertDialog(
                    title: const Text('Pair Worker'),
                    content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                              'Use this single-use code on the machine running the Worker.'),
                          const SizedBox(height: 12),
                          SelectableText(code),
                        ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close')),
                      FilledButton.icon(
                        key: const ValueKey('copy-pairing-code-button'),
                        onPressed: () async {
                          setDialogState(() => copied = true);
                          await Clipboard.setData(ClipboardData(text: code));
                        },
                        icon: Icon(copied ? Icons.check : Icons.copy, size: 16),
                        label: Text(copied ? 'Copied' : 'Copy code'),
                      ),
                    ],
                  ),
                ));
      } else if (action == 'revoke') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  constraints: SyntilaDialogStyle.small,
                  title: const Text('Unpair Worker?'),
                  content: Text(
                      'Unpair ${worker.name} and revoke its device credential?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: SyntilaDialogStyle.destructiveButton(),
                        child: const Text('Unpair'))
                  ],
                ));
        if (confirmed != true) return;
        await source.revokeWorkerCredential(worker.id);
        onLocalUpdate?.call((list) => [
              for (final w in list)
                if (w.id == worker.id)
                  _copyWorker(w, paired: false, online: false, ready: false)
                else
                  w
            ]);
      } else if (action == 'remove') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  constraints: SyntilaDialogStyle.small,
                  title: const Text('Remove Worker?'),
                  content:
                      Text('Remove ${worker.name} and revoke its connection?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: SyntilaDialogStyle.destructiveButton(),
                        child: const Text('Remove'))
                  ],
                ));
        if (confirmed != true) return;
        await source.removeWorkerInstance(worker.id);
        onLocalUpdate?.call((list) => [
              for (final w in list)
                if (w.id != worker.id) w
            ]);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update Worker: $error')),
        );
      }
      return;
    }
    try {
      await onRefresh();
    } catch (_) {
      // Mutation succeeded; ignore transient refresh failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    // By name, case-insensitive; the id keeps equal names in a stable order.
    final allWorkers = workers == null
        ? null
        : ([...workers!]..sort((a, b) {
            final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            return byName != 0 ? byName : a.id.compareTo(b.id);
          }));
    if (selectedWorkerId != null) {
      if (error != null) {
        return _missingWorkerView(context, 'Could not load Worker.');
      }
      if (allWorkers == null) {
        return const LinearProgressIndicator();
      }
      final selected =
          allWorkers.where((w) => w.id == selectedWorkerId).firstOrNull;
      if (selected == null) {
        return _missingWorkerView(context, 'Worker not found.');
      }
      return _buildDetailView(context, selected);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Workers',
                  style: Theme.of(context).textTheme.headlineMedium),
            ),
            IconButton(
              tooltip: 'Refresh Workers',
              onPressed: () {
                onRefresh().catchError((Object _) => null);
              },
              icon: const Icon(Icons.refresh),
            ),
            if (management != null) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('add-worker-button'),
                onPressed: () => _add(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Worker'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Text('Workers run AI tasks and tools on your connected devices.'),
        const SizedBox(height: 16),
        if (error != null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('Could not load Workers. Try refreshing.'),
          )
        else if (allWorkers == null)
          const LinearProgressIndicator()
        else if (allWorkers.isEmpty)
          _emptyState(context)
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < allWorkers.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                _workerCard(context, allWorkers[i]),
              ],
            ],
          ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(
                'No Workers yet.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (management != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const ValueKey('empty-add-worker-button'),
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Worker'),
                ),
              ],
            ],
          ),
        ),
      );

  Widget _workerCard(BuildContext context, WorkerInstance worker) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.name,
      providerToolName: worker.providerToolName,
    );
    final workerIcon = presentation.iconAssetForBrightness(theme.brightness);
    final Widget iconWidget = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: workerIcon != null
          ? Image.asset(
              workerIcon,
              width: 48,
              height: 48,
              fit: BoxFit.contain,
              semanticLabel: '${worker.name} icon',
            )
          : Icon(
              worker.ready ? Icons.smart_toy_outlined : Icons.warning_amber,
              size: 48,
              color: worker.ready ? null : SyntilaColors.warningText(isDark),
            ),
    );

    final cliName = worker.providerToolName?.trim();
    final cliVersion = worker.providerToolVersion?.trim();
    final cliInfo = [
      if (cliName != null && cliName.isNotEmpty) cliName,
      if (cliVersion != null && cliVersion.isNotEmpty) cliVersion,
    ].join(' ');
    final typeAndCliLine = [
      worker.workerTypeName,
      if (cliInfo.isNotEmpty) cliInfo,
    ].join(' · ');

    final hasDeviceName =
        worker.deviceName != null && worker.deviceName!.isNotEmpty;

    final cardContent = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              iconWidget,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  worker.name,
                                  style: theme.textTheme.titleMedium,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _workerStatusBadge(worker, isDark),
                            ],
                          ),
                        ),
                        if (usageSource != null)
                          IconButton(
                            key: ValueKey('worker-instance-usage-${worker.id}'),
                            tooltip: 'Usage',
                            icon: const Icon(Icons.speed, size: 18),
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                                width: 28, height: 28),
                            style: const ButtonStyle(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: worker.online && worker.ready
                                ? () => showDialog<void>(
                                      context: context,
                                      builder: (_) => WorkerUsageDialog(
                                        source: usageSource!,
                                        worker: AxWorker(
                                          id: worker.id,
                                          workerTypeId: worker.workerTypeId,
                                          displayName: worker.name,
                                          status: worker.online
                                              ? 'online'
                                              : 'offline',
                                          localConcurrencyLimit: 1,
                                          activationState: worker.enabled
                                              ? 'enabled'
                                              : 'disabled',
                                          readinessState: worker.ready
                                              ? 'ready'
                                              : 'not_ready',
                                          catalogLifecycleState: 'active',
                                          catalogVisibilityState: 'visible',
                                          shared: false,
                                        ),
                                      ),
                                    )
                                : null,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      typeAndCliLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _modelsSection(context, worker),
          if (hasDeviceName) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.computer_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  worker.deviceName!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    return Card(
      key: ValueKey('worker-instance-${worker.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: onSelectWorker == null
          ? cardContent
          : InkWell(
              onTap: () => onSelectWorker!(worker.id),
              child: cardContent,
            ),
    );
  }

  Widget _missingWorkerView(BuildContext context, String message) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onBackToList != null)
            TextButton.icon(
              onPressed: onBackToList,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('Back to Workers'),
            ),
          const SizedBox(height: 16),
          Text(message, style: Theme.of(context).textTheme.bodyLarge),
        ],
      );

  Widget _buildDetailView(BuildContext context, WorkerInstance worker) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final presentation = WorkerPresentation.resolve(
      worker.workerTypeId,
      worker.name,
      providerToolName: worker.providerToolName,
    );
    final workerIcon = presentation.iconAssetForBrightness(theme.brightness);
    final iconWidget = workerIcon != null
        ? Image.asset(
            workerIcon,
            width: 48,
            height: 48,
            fit: BoxFit.contain,
            semanticLabel: '${worker.name} icon',
          )
        : Icon(
            worker.ready ? Icons.smart_toy_outlined : Icons.warning_amber,
            size: 48,
            color: worker.ready ? null : SyntilaColors.warningText(isDark),
          );

    final cliName = worker.providerToolName?.trim();
    final cliVersion = worker.providerToolVersion?.trim();
    final cliInfo = [
      if (cliName != null && cliName.isNotEmpty) cliName,
      if (cliVersion != null && cliVersion.isNotEmpty) cliVersion,
    ].join(' ');

    final shortId =
        worker.id.length > 12 ? '${worker.id.substring(0, 12)}..' : worker.id;

    return Column(
      key: ValueKey('worker-detail-${worker.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onBackToList != null) ...[
          TextButton.icon(
            key: const ValueKey('worker-detail-back'),
            onPressed: onBackToList,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Workers'),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            iconWidget,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          worker.name,
                          style: theme.textTheme.headlineSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _workerStatusBadge(worker, isDark),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      worker.workerTypeName,
                      if (cliInfo.isNotEmpty) cliInfo,
                    ].join(' · '),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (cliInfo.isNotEmpty) _detailRow(theme, 'CLI', cliInfo),
        _detailRow(theme, 'Provider', worker.workerTypeName),
        if (worker.deviceName != null && worker.deviceName!.isNotEmpty)
          _detailRow(theme, 'Device', worker.deviceName!),
        _detailRow(theme, 'Pairing', worker.isPaired ? 'Paired' : 'Not paired'),
        _detailRow(theme, 'Enabled', worker.enabled ? 'Enabled' : 'Disabled'),
        _detailRow(theme, 'Connection', worker.online ? 'Online' : 'Offline'),
        if (worker.readinessKnown)
          _detailRow(theme, 'Readiness', worker.ready ? 'Ready' : 'Not ready'),
        if (worker.defaultModel != null && worker.defaultModel!.isNotEmpty)
          _detailRow(theme, 'Default model', worker.defaultModel!),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  'Worker ID',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(
                shortId,
                key: const ValueKey('worker-detail-id'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('worker-detail-copy-id'),
                tooltip: 'Copy Worker ID',
                icon: const Icon(Icons.copy, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: worker.id)).ignore();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Worker ID copied.')),
                  );
                },
              ),
            ],
          ),
        ),
        if (management != null) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _act(context, worker, 'rename'),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Rename'),
              ),
              if (worker.workerTypeId.startsWith('plugin-'))
                OutlinedButton.icon(
                  onPressed: () => _act(context, worker, 'mcp'),
                  icon: const Icon(Icons.extension_outlined, size: 16),
                  label: const Text('MCP Worker version'),
                ),
              if (!worker.isPaired)
                OutlinedButton.icon(
                  onPressed: () => _act(context, worker, 'pair'),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Pair'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _act(context, worker, 'revoke'),
                  icon: const Icon(Icons.link_off, size: 16),
                  label: const Text('Unpair'),
                ),
              if (management is AxWorkerModelsSource && worker.isPaired)
                OutlinedButton.icon(
                  key: ValueKey('worker-models-refresh-${worker.id}'),
                  onPressed: () => _refreshModels(context, worker),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Refresh models'),
                ),
              OutlinedButton.icon(
                onPressed: () => _act(context, worker, 'toggle'),
                icon: Icon(
                  worker.enabled
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  size: 16,
                ),
                label: Text(worker.enabled ? 'Disable' : 'Enable'),
              ),
              OutlinedButton.icon(
                onPressed: () => _act(context, worker, 'remove'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Remove'),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        _WorkerVisibilityCard(
          worker: worker,
          management: management,
          onSaved: (hiddenModels, hiddenEfforts) async {
            onLocalUpdate?.call((list) => [
                  for (final w in list)
                    if (w.id == worker.id)
                      _copyWorker(
                        w,
                        hiddenModels: hiddenModels,
                        hiddenEfforts: hiddenEfforts,
                      )
                    else
                      w,
                ]);
            try {
              await onRefresh();
            } catch (_) {}
          },
        ),
        if (management != null) ...[
          if (management is AxWorkerPersonShareSource) ...[
            const SizedBox(height: 16),
            WorkerPersonSharesSection(
              worker: worker,
              shares: management as AxWorkerPersonShareSource,
              people: management is AxPeopleDataSource
                  ? management as AxPeopleDataSource
                  : null,
            ),
          ],
          const SizedBox(height: 16),
          WorkerMemberModelsSection(worker: worker, management: management),
        ],
      ],
    );
  }

  Widget _detailRow(ThemeData theme, String label, String value,
          {bool mono = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontFamily: mono ? 'monospace' : null,
                ),
              ),
            ),
          ],
        ),
      );

  /// The models this Worker's provider CLI offered when its service last
  /// started, or why none are listed.
  Widget _modelsSection(BuildContext context, WorkerInstance worker) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    AxWorkerExecutionOptions? options;
    final json = worker.executionOptions;
    if (json != null) {
      try {
        options =
            AxWorkerExecutionOptions.fromJson(Map<String, dynamic>.from(json));
      } on Object {
        options = null;
      }
    }
    final models = options?.models ?? const <AxWorkerModelOption>[];
    if (models.isEmpty) {
      final status = worker.modelsStatus;
      final text = !worker.isPaired
          ? 'Models appear after this Worker is paired and running.'
          : status == null
              ? 'No models yet. Use Refresh models from the menu while the Worker is online.'
              : status == 'ok'
                  ? 'The provider reported no models.'
                  : 'Could not read models ($status). Try Refresh models from the menu.';
      return Text(
        text,
        key: ValueKey('worker-models-empty-${worker.id}'),
        style: muted,
      );
    }
    return Wrap(
      key: ValueKey('worker-models-${worker.id}'),
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final model in models)
          Tooltip(
            message: model.effort.supported && model.effort.values.isNotEmpty
                ? 'Efforts: ${model.effort.values.join(', ')}'
                : 'No effort levels',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Text(model.name, style: const TextStyle(fontSize: 11.5)),
            ),
          ),
      ],
    );
  }

  Widget _workerStatusBadge(WorkerInstance worker, bool isDark) {
    final Color bg;
    final Color fg;
    final String label;
    if (!worker.enabled) {
      bg = Colors.grey.withValues(alpha: 0.2);
      fg = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
      label = 'Disabled';
    } else if (worker.online && worker.ready) {
      bg = Colors.green.withValues(alpha: 0.15);
      fg = isDark ? Colors.green.shade300 : Colors.green.shade800;
      label = 'Ready';
    } else if (worker.online) {
      bg = Colors.orange.withValues(alpha: 0.15);
      fg = isDark ? Colors.orange.shade300 : Colors.orange.shade800;
      label = 'Online';
    } else {
      bg = Colors.grey.withValues(alpha: 0.2);
      fg = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
      label = 'Offline';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

class _WorkerVisibilityCard extends StatefulWidget {
  const _WorkerVisibilityCard({
    required this.worker,
    required this.management,
    required this.onSaved,
  });

  final WorkerInstance worker;
  final AxWorkerManagementSource? management;
  final Future<void> Function(
          List<String> hiddenModels, Map<String, List<String>> hiddenEfforts)
      onSaved;

  @override
  State<_WorkerVisibilityCard> createState() => _WorkerVisibilityCardState();
}

class _WorkerVisibilityCardState extends State<_WorkerVisibilityCard> {
  late Set<String> _hiddenModels;
  late Map<String, Set<String>> _hiddenEfforts;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _adopt(widget.worker);
  }

  @override
  void didUpdateWidget(_WorkerVisibilityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.worker.id != widget.worker.id ||
        oldWidget.worker.hiddenModels != widget.worker.hiddenModels ||
        oldWidget.worker.hiddenEfforts != widget.worker.hiddenEfforts) {
      _adopt(widget.worker);
    }
  }

  void _adopt(WorkerInstance worker) {
    _hiddenModels = worker.hiddenModels.toSet();
    _hiddenEfforts = {
      for (final e in worker.hiddenEfforts.entries) e.key: e.value.toSet(),
    };
  }

  void _toggleModel(String modelId, bool visible) {
    setState(() {
      if (visible) {
        _hiddenModels.remove(modelId);
      } else {
        _hiddenModels.add(modelId);
      }
    });
  }

  void _toggleEffort(String modelId, String effort, bool visible) {
    setState(() {
      final set = _hiddenEfforts.putIfAbsent(modelId, () => {});
      if (visible) {
        set.remove(effort);
      } else {
        set.add(effort);
      }
    });
  }

  Future<void> _write({bool reset = false}) async {
    final source = widget.management;
    if (source == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final nextModels = reset ? const <String>[] : _hiddenModels.toList();
    final nextEfforts = reset
        ? const <String, List<String>>{}
        : {
            for (final entry in _hiddenEfforts.entries)
              if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
          };
    try {
      await source.updateWorkerInstance(widget.worker.id, {
        'visibility': {
          'hiddenModels': nextModels,
          'hiddenEfforts': nextEfforts,
        },
      });
      await widget.onSaved(nextModels, nextEfforts);
      if (mounted && reset) {
        setState(() {
          _hiddenModels.clear();
          _hiddenEfforts.clear();
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not update visibility: $error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final models = workerModelOptions(widget.worker);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Execution selector visibility',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Choose which models and effort levels appear in the Thread execution selector.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            if (models.isEmpty)
              Text(
                'No models available yet. Refresh models while the Worker is online.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else ...[
              WorkerModelVisibilityTable(
                models: models,
                hiddenModels: _hiddenModels,
                hiddenEfforts: _hiddenEfforts,
                keyPrefix: 'worker-visibility',
                editable: widget.management != null && !_saving,
                onModelChanged: _toggleModel,
                onEffortChanged: _toggleEffort,
              ),
              if (widget.management != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      key: const ValueKey('worker-visibility-save'),
                      onPressed: _saving ? null : () => _write(),
                      child: const Text('Save'),
                    ),
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => setState(() {
                                _adopt(widget.worker);
                                _error = null;
                              }),
                      child: const Text('Cancel'),
                    ),
                    OutlinedButton(
                      key: const ValueKey('worker-visibility-reset'),
                      onPressed: _saving ? null : () => _write(reset: true),
                      child: const Text('Reset'),
                    ),
                  ],
                ),
                if (_saving) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _AddWorkerDialog extends StatefulWidget {
  const _AddWorkerDialog({required this.types, required this.onCreate});

  final List<({String id, String name})> types;
  final Future<void> Function(String typeId, String name) onCreate;

  @override
  State<_AddWorkerDialog> createState() => _AddWorkerDialogState();
}

class _AddWorkerDialogState extends State<_AddWorkerDialog> {
  late String _selected;
  late final TextEditingController _nameController;
  bool _nameEdited = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initialType = widget.types.first;
    _selected = initialType.id;
    _nameController = TextEditingController(text: initialType.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _selectType(String typeId) {
    if (typeId == _selected) return;
    final nextType = widget.types.firstWhere((type) => type.id == typeId);
    setState(() {
      _selected = typeId;
      if (!_nameEdited) {
        _nameController.value = TextEditingValue(
          text: nextType.name,
          selection: TextSelection.collapsed(offset: nextType.name.length),
        );
      }
    });
  }

  Future<void> _submit() async {
    final trimmed = _nameController.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _error = 'Please enter a Worker name.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onCreate(_selected, trimmed);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Could not add Worker: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        constraints: SyntilaDialogStyle.medium,
        title: const Text('Add Worker'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose a Worker type and name to create a new Worker.'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const ValueKey('add-worker-type-selector'),
              initialValue: _selected,
              borderRadius: SyntilaRadius.radiusMd,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [
                for (final type in widget.types)
                  DropdownMenuItem(value: type.id, child: Text(type.name)),
              ],
              onChanged: _submitting
                  ? null
                  : (value) {
                      if (value != null) _selectType(value);
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              autofocus: true,
              enabled: !_submitting,
              maxLines: 1,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Work Laptop',
                errorText: _error,
              ),
              onChanged: (_) {
                if (!_nameEdited) _nameEdited = true;
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Add Worker'),
          ),
        ],
      );
}
