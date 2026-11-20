import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';
import '../../ax/ax_data.dart' show AxWorkerManagementSource;
import '../../ax/mcp_worker_pin.dart';

/// Read-only identity view during the Worker-first rollout. Management is P6.
class WorkerInstancesSection extends StatelessWidget {
  const WorkerInstancesSection({super.key, required this.catalogs});

  final AxSessionCatalogs catalogs;

  @override
  Widget build(BuildContext context) => AxQueryBuilder<bool>(
        engine: catalogs.engine,
        query: catalogs.workerIdentityEnabled,
        builder: (context, flag) {
          if (flag.data != true) return const SizedBox.shrink();
          return AxQueryBuilder<List<WorkerInstance>>(
            engine: catalogs.engine,
            query: catalogs.workerInstances,
            builder: (context, state) => AxQueryBuilder<bool>(
              engine: catalogs.engine,
              query: catalogs.workersUxEnabled,
              builder: (context, ux) => WorkerInstancesList(
                workers: state.data,
                error: state.error,
                onRefresh: () =>
                    catalogs.engine.refresh(catalogs.workerInstances),
                management: ux.data == true &&
                        catalogs.source is AxWorkerManagementSource
                    ? catalogs.source as AxWorkerManagementSource
                    : null,
              ),
            ),
          );
        },
      );
}

class WorkerInstancesList extends StatelessWidget {
  const WorkerInstancesList({
    super.key,
    required this.workers,
    required this.error,
    required this.onRefresh,
    this.management,
  });

  final List<WorkerInstance>? workers;
  final Object? error;
  final Future<Object?> Function() onRefresh;
  final AxWorkerManagementSource? management;

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
      var selected = types.first.id;
      var name = '';
      final choice = await showDialog<({String id, String name})>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, setDialogState) => AlertDialog(
                    title: const Text('Add Worker'),
                    content: Column(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButtonFormField<String>(
                          initialValue: selected,
                          decoration: const InputDecoration(labelText: 'Type'),
                          items: [
                            for (final type in types)
                              DropdownMenuItem(
                                  value: type.id, child: Text(type.name))
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setDialogState(() => selected = value);
                            }
                          }),
                      TextField(
                          autofocus: true,
                          decoration: const InputDecoration(labelText: 'Name'),
                          onChanged: (value) => name = value),
                    ]),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () {
                            if (name.trim().isNotEmpty) {
                              Navigator.pop(
                                  context, (id: selected, name: name.trim()));
                            }
                          },
                          child: const Text('Add'))
                    ],
                  )));
      if (choice == null) return;
      await source.createWorkerInstance(choice.id, choice.name);
      await onRefresh();
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
                            'On that machine, import and test it with `syntila-worker mcp-worker`, then reconnect.')
                      else
                        for (final version in state.available)
                          ListTile(
                            key: ValueKey('mcp-version-${version.manifestDigest}'),
                            dense: true,
                            title: Text('${version.id} ${version.version}'),
                            subtitle: Text(version.manifestDigest.substring(0, 12)),
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

  Future<void> _act(
      BuildContext context, WorkerInstance worker, String action) async {
    final source = management;
    if (source == null) return;
    try {
      if (action == 'rename' || action == 'alias') {
        var value = action == 'rename' ? worker.name : worker.description;
        final result = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
                  title:
                      Text(action == 'rename' ? 'Rename Worker' : 'Edit alias'),
                  content: TextFormField(
                      initialValue: value,
                      onChanged: (text) => value = text,
                      autofocus: true,
                      decoration: InputDecoration(
                          labelText: action == 'rename' ? 'Name' : 'Alias')),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, value.trim()),
                        child: const Text('Save'))
                  ],
                ));
        if (result == null || (action == 'rename' && result.isEmpty)) return;
        await source.updateWorkerInstance(
            worker.id, {action == 'rename' ? 'name' : 'description': result});
      } else if (action == 'toggle') {
        await source
            .updateWorkerInstance(worker.id, {'enabled': !worker.enabled});
      } else if (action == 'mcp') {
        await _chooseMcpWorker(context, source, worker);
        return;
      } else if (action == 'pair') {
        final code = await source.pairWorkerInstance(worker.id);
        if (!context.mounted) return;
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
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
                        child: const Text('Close'))
                  ],
                ));
      } else if (action == 'revoke') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Revoke Worker connection?'),
                  content: Text(
                      'Disconnect ${worker.name} and revoke its credential?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Revoke'))
                  ],
                ));
        if (confirmed != true) return;
        await source.revokeWorkerCredential(worker.id);
      } else if (action == 'remove') {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('Remove Worker?'),
                  content:
                      Text('Remove ${worker.name} and revoke its connection?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Remove'))
                  ],
                ));
        if (confirmed != true) return;
        await source.removeWorkerInstance(worker.id);
      }
      await onRefresh();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not update Worker. Please try again.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('Workers',
                    style: Theme.of(context).textTheme.titleMedium)),
            if (management != null)
              TextButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Worker')),
            IconButton(
              tooltip: 'Refresh Workers',
              onPressed: () {
                onRefresh().catchError((Object _) => null);
              },
              icon: const Icon(Icons.refresh),
            ),
          ]),
          if (error != null)
            const Text('Could not load Workers. Try refreshing.')
          else if (workers == null)
            const LinearProgressIndicator()
          else if (workers!.isEmpty)
            const Text('No Workers yet.')
          else
            for (final worker in workers!)
              ListTile(
                key: ValueKey('worker-instance-${worker.id}'),
                title: Text(worker.name),
                subtitle: Text([
                  worker.workerTypeName,
                  if (worker.description.isNotEmpty) worker.description,
                  worker.enabled ? 'Enabled' : 'Disabled',
                  worker.online ? 'Online' : 'Offline',
                  if (!worker.readinessKnown)
                    'Readiness unknown'
                  else if (worker.ready)
                    'Ready'
                  else
                    'Not ready',
                  worker.id.length > 8
                      ? worker.id.substring(worker.id.length - 8)
                      : worker.id,
                ].join(' · ')),
                trailing: management == null
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: 'Manage ${worker.name}',
                        onSelected: (action) => _act(context, worker, action),
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'rename', child: Text('Rename')),
                          const PopupMenuItem(
                              value: 'alias', child: Text('Edit alias')),
                          if (worker.workerTypeId.startsWith('plugin-'))
                            const PopupMenuItem(
                                value: 'mcp',
                                child: Text('MCP Worker version')),
                          const PopupMenuItem(
                              value: 'pair', child: Text('Pair')),
                          const PopupMenuItem(
                              value: 'revoke',
                              child: Text('Revoke connection')),
                          PopupMenuItem(
                              value: 'toggle',
                              child:
                                  Text(worker.enabled ? 'Disable' : 'Enable')),
                          const PopupMenuItem(
                              value: 'remove', child: Text('Remove')),
                        ],
                      ),
              ),
        ]),
      );
}
