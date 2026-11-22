import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';

/// Live multi-Worker dashboard replacing the generated `status` page.
///
/// Polls `syntila-connect status --json`, lists every paired Worker on this
/// machine as a card widget with a one-click Copy Worker ID button, and runs
/// per-Worker service controls (`start`, `stop`, `restart`, `install`) with
/// `--worker <workerId>`.
class ConnectStatusPage extends StatefulWidget {
  const ConnectStatusPage({
    super.key,
    required this.runner,
    this.interval = const Duration(seconds: 2),
  });

  final CliRunner runner;
  final Duration interval;

  @override
  State<ConnectStatusPage> createState() => _ConnectStatusPageState();
}

class _ConnectStatusPageState extends State<ConnectStatusPage> {
  Timer? _timer;
  List<Map<String, Object?>>? _workers;
  String? _problem;
  bool _loaded = false;
  String? _busy;
  String? _actionProblem;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(widget.interval, (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  List<Map<String, Object?>>? _parseWorkers(Object? decoded) {
    if (decoded is! Map) return null;
    final map = decoded.cast<String, Object?>();
    final list = map['workers'];
    if (list is List) {
      // By name, so the order does not change as Workers start and stop.
      return [
        for (final item in list)
          if (item is Map) item.cast<String, Object?>(),
      ]..sort((a, b) {
        final byName = _workerDisplayName(
          a,
        ).toLowerCase().compareTo(_workerDisplayName(b).toLowerCase());
        return byName != 0
            ? byName
            : '${a['workerId']}'.compareTo('${b['workerId']}');
      });
    }
    if (map['workerId'] is String) {
      return [map];
    }
    return null;
  }

  bool _refreshing = false;
  bool _forceNext = false;

  /// [force] is the refresh button: it also asks the server whether a stopped
  /// Worker was removed in the app, instead of waiting for the next minute.
  Future<void> _refresh({bool force = false}) async {
    // A slow status call must not pile up behind the timer.
    if (_refreshing) {
      if (force) _forceNext = true;
      return;
    }
    _refreshing = true;
    try {
      await _refreshOnce(force: force);
    } finally {
      _refreshing = false;
    }
    if (_forceNext && mounted) {
      _forceNext = false;
      await _refresh(force: true);
    }
  }

  Future<void> _refreshOnce({bool force = false}) async {
    final result = await widget.runner.start([
      'status',
      '--json',
      if (force) '--check-server',
    ]).result;
    if (!mounted) return;
    List<Map<String, Object?>>? parsed;
    String? problem;
    try {
      parsed = _parseWorkers(jsonDecode(result.stdout));
      if (parsed == null) {
        final text = '${result.stdout}${result.stderr}'.trim();
        problem = text.isEmpty ? 'The Worker CLI returned no status.' : text;
      }
    } on Object {
      final text = '${result.stdout}${result.stderr}'.trim();
      problem = text.isEmpty ? 'The Worker CLI returned no status.' : text;
    }
    setState(() {
      _loaded = true;
      _workers = parsed;
      _problem = problem;
    });
  }

  Future<void> _runServiceAction(
    String label,
    String workerId,
    String action,
  ) async {
    setState(() {
      _busy = label;
      _actionProblem = null;
    });
    final result = await widget.runner.start([
      'service',
      action,
      '--worker',
      workerId,
    ]).result;
    if (!mounted) return;
    String? problem;
    if (!result.ok) {
      final text = '${result.stderr}${result.stdout}'.trim();
      problem = text.isEmpty
          ? 'The command failed (exit ${result.exitCode}).'
          : text;
    }
    setState(() {
      _busy = null;
      _actionProblem = problem;
    });
    await _refresh();
  }

  Future<void> _refreshModels(String label, String workerId) async {
    setState(() {
      _busy = label;
      _actionProblem = null;
    });
    final result = await widget.runner.start([
      'models',
      'refresh',
      '--worker',
      workerId,
    ]).result;
    if (!mounted) return;
    String? problem;
    if (!result.ok) {
      final text = '${result.stderr}${result.stdout}'.trim();
      problem = text.isEmpty
          ? 'Could not read models (exit ${result.exitCode}).'
          : text;
    }
    setState(() {
      _busy = null;
      _actionProblem = problem;
    });
    await _refresh();
  }

  /// Full access is the owner's decision on this computer: turning it on asks
  /// first, and it applies to the next request without restarting the service.
  Future<void> _setFullAccess(String label, String workerId, bool on) async {
    if (on) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Allow full access?'),
          content: Text(
            '$label will be allowed to run any command on this computer, with your '
            'account, without asking. That includes requests from anyone who can '
            'send Work to this Worker. Turn it on only for Workers and folders you '
            'trust.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('worker-full-access-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow full access'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = label;
      _actionProblem = null;
    });
    final result = await widget.runner.start([
      'full-access',
      on ? 'on' : 'off',
      '--worker',
      workerId,
    ]).result;
    if (!mounted) return;
    String? problem;
    if (!result.ok) {
      final text = '${result.stderr}${result.stdout}'.trim();
      problem = text.isEmpty
          ? 'Could not change full access (exit ${result.exitCode}).'
          : text;
    }
    setState(() {
      _busy = null;
      _actionProblem = problem;
    });
    await _refresh();
  }

  Future<void> _removeWorker(String label, String workerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Worker?'),
        content: Text(
          'This deletes $label from this computer and unpairs it in the web app. '
          'Your working folders are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('worker-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = label;
      _actionProblem = null;
    });
    final result = await widget.runner.start([
      'unpair',
      '--worker',
      workerId,
      '--yes',
    ]).result;
    if (!mounted) return;
    String? problem;
    if (!result.ok) {
      final text = '${result.stderr}${result.stdout}'.trim();
      problem = text.isEmpty
          ? 'Could not remove the Worker (exit ${result.exitCode}).'
          : text;
    } else if (result.stdout.contains('Could not unpair')) {
      // The Worker is gone here, but the app still lists it: say so.
      problem = result.stdout
          .split('\n')
          .firstWhere((line) => line.contains('Could not unpair'));
    }
    setState(() {
      _busy = null;
      _actionProblem = problem;
    });
    await _refresh();
  }

  void _copyWorkerId(String workerId) {
    Clipboard.setData(ClipboardData(text: workerId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied Worker ID: $workerId'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workers = _workers;
    // Progress and errors sit over the bottom of the page, not in the list, so
    // clicking a button never moves the content or its scroll position.
    final notice = _busy != null || _actionProblem != null;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Stack(
          children: [
            ListView(
              padding: EdgeInsets.fromLTRB(28, 28, 28, notice ? 140 : 28),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Workers',
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _busy == null
                          ? () => _refresh(force: true)
                          : null,
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (workers == null)
                  _Panel(
                    child: Text(
                      _problem ?? 'No status.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                else if (workers.isEmpty)
                  _Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'No Workers on this computer yet',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Open "Add Worker" in the sidebar and enter a pairing code from the web app to add your first Worker.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  )
                else
                  for (final worker in workers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: _WorkerCard(
                        worker: worker,
                        busy: _busy != null,
                        onCopyId: _copyWorkerId,
                        onServiceAction: _runServiceAction,
                        onRefreshModels: _refreshModels,
                        onFullAccess: _setFullAccess,
                        onRemove: _removeWorker,
                      ),
                    ),
              ],
            ),
            if (notice)
              Positioned(
                left: 28,
                right: 28,
                bottom: 16,
                child: _Panel(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_busy != null)
                            Row(
                              children: [
                                const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '$_busy…',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                          if (_busy != null && _actionProblem != null)
                            const SizedBox(height: 8),
                          if (_actionProblem != null)
                            SelectableText(
                              _actionProblem!,
                              key: const Key('status-action-error'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'JetBrains Mono',
                                color: theme.colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The name a Worker is listed under: its own name, else its type.
String _workerDisplayName(Map<String, Object?> worker) {
  final workerId = '${worker['workerId'] ?? '-'}';
  final rawName = worker['workerName']?.toString().trim();
  final rawType = worker['workerType']?.toString().trim();
  return (rawName != null && rawName.isNotEmpty && rawName != workerId)
      ? rawName
      : (rawType != null && rawType.isNotEmpty && rawType != workerId)
      ? rawType
      : 'Worker';
}

class _WorkerCard extends StatelessWidget {
  const _WorkerCard({
    required this.worker,
    required this.busy,
    required this.onCopyId,
    required this.onServiceAction,
    required this.onRefreshModels,
    required this.onFullAccess,
    required this.onRemove,
  });

  final void Function(String label, String workerId, bool on) onFullAccess;
  final void Function(String label, String workerId) onRemove;
  final void Function(String label, String workerId) onRefreshModels;
  final Map<String, Object?> worker;
  final bool busy;
  final void Function(String workerId) onCopyId;
  final void Function(String label, String workerId, String action)
  onServiceAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final workerId = '${worker['workerId'] ?? '-'}';
    final rawType = worker['workerType']?.toString().trim();
    final displayName = _workerDisplayName(worker);
    final running = worker['running'] == true;
    final connection = '${worker['connection'] ?? 'unknown'}';
    final service = '${worker['service'] ?? 'unknown'}';
    final tone = running && connection != 'revoked'
        ? Colors.green
        : scheme.outline;
    final journal =
        (worker['journal'] as Map?)?.cast<String, Object?>() ?? const {};

    return _Panel(
      key: ValueKey('worker-card-$workerId'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: tone),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayName,
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (rawType != null &&
                            rawType.isNotEmpty &&
                            rawType != displayName &&
                            rawType != workerId) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              rawType,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${running ? 'Running' : 'Stopped'} · Connection: $connection',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (service == 'notInstalled')
                FilledButton.icon(
                  key: ValueKey('status-service-install-$workerId'),
                  onPressed: busy
                      ? null
                      : () => onServiceAction(
                          'Installing service for $displayName',
                          workerId,
                          'install',
                        ),
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Install service'),
                )
              else ...[
                if (service != 'running')
                  FilledButton.icon(
                    key: ValueKey('status-service-start-$workerId'),
                    onPressed: busy
                        ? null
                        : () => onServiceAction(
                            'Starting $displayName',
                            workerId,
                            'start',
                          ),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Start'),
                  ),
                if (service == 'running')
                  OutlinedButton.icon(
                    key: ValueKey('status-service-stop-$workerId'),
                    onPressed: busy
                        ? null
                        : () => onServiceAction(
                            'Stopping $displayName',
                            workerId,
                            'stop',
                          ),
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop'),
                  ),
                OutlinedButton.icon(
                  key: ValueKey('status-service-restart-$workerId'),
                  onPressed: busy
                      ? null
                      : () => onServiceAction(
                          'Restarting $displayName',
                          workerId,
                          'restart',
                        ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Restart'),
                ),
              ],
              OutlinedButton.icon(
                key: const Key('worker-models-refresh'),
                onPressed: (busy || !running)
                    ? null
                    : () => onRefreshModels(
                        'Reading models for $displayName',
                        workerId,
                      ),
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('Refresh models'),
              ),
              OutlinedButton.icon(
                key: ValueKey('status-remove-$workerId'),
                onPressed: busy ? null : () => onRemove(displayName, workerId),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Remove'),
              ),
            ],
          ),
          const Divider(height: 24),
          _Row(
            'Worker ID',
            workerId,
            mono: true,
            trailing: IconButton(
              key: ValueKey('status-copy-id-$workerId'),
              tooltip: 'Copy Worker ID',
              icon: const Icon(Icons.copy, size: 16),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: () => onCopyId(workerId),
            ),
          ),
          _Row('Server', '${worker['server'] ?? '-'}'),
          _Row('Service', service),
          _Row(
            'Starts automatically',
            worker['autoStart'] == true ? 'Yes' : 'No',
          ),
          const Divider(height: 24),
          SwitchListTile(
            key: ValueKey('status-full-access-$workerId'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Full access to this computer'),
            value: worker['fullAccess'] == true,
            onChanged: busy
                ? null
                : (value) => onFullAccess(displayName, workerId, value),
          ),
          const Divider(height: 24),
          _ModelsSection(models: worker['models']),
          if (journal.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final e in journal.entries)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${e.value}', style: theme.textTheme.titleMedium),
                      Text(e.key, style: theme.textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
          ],
          if (worker['journalProblem'] != null) ...[
            const SizedBox(height: 10),
            Text(
              'Journal problem: ${worker['journalProblem']}',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// The models this machine's provider CLI offered when the owner last asked to
/// read them (on request from the Workers page).
class _ModelsSection extends StatelessWidget {
  const _ModelsSection({required this.models});
  final Object? models;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = models is Map ? (models as Map).cast<String, Object?>() : null;
    final list = data?['models'];
    final entries = <Map<String, Object?>>[
      if (list is List)
        for (final item in list)
          if (item is Map) item.cast<String, Object?>(),
    ];
    final status = data?['status']?.toString();
    if (entries.isEmpty) {
      final text = data == null
          ? 'No models yet. Use Refresh models while the service is running.'
          : status == 'ok'
          ? 'The provider reported no models.'
          : data['message'] is String && (data['message'] as String).isNotEmpty
          ? 'Could not read models: ${data['message']}'
          : 'Could not read models ($status). Try Refresh models.';
      final isError = data != null && status != 'ok';
      final label = Text(
        text,
        key: const Key('worker-models-empty'),
        style: theme.textTheme.bodySmall,
      );
      if (!isError) return label;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: label),
          IconButton(
            key: const Key('worker-models-error-copy'),
            tooltip: 'Copy message',
            icon: const Icon(Icons.copy, size: 16),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      );
    }
    final tool = [
      data?['providerToolName'],
      data?['providerToolVersion'],
    ].whereType<String>().join(' ');
    return Column(
      key: const Key('worker-models'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tool.isNotEmpty) Text(tool, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final model in entries)
              Tooltip(
                message:
                    (model['efforts'] is List &&
                        (model['efforts'] as List).isNotEmpty)
                    ? 'Efforts: ${(model['efforts'] as List).join(', ')}'
                    : 'No effort levels',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    '${model['name']}',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.mono = false, this.trailing});
  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 160,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Flexible(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: mono ? 'JetBrains Mono' : null,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    );
  }
}
