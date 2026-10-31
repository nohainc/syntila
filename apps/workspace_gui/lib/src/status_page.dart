import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';

/// Live Workspace dashboard replacing the generated `status` page.
///
/// Polls `syntila status --json` and offers the matching actions. Everything
/// still goes through the CLI.
class StatusPage extends StatefulWidget {
  const StatusPage({
    super.key,
    required this.runner,
    this.interval = const Duration(seconds: 5),
  });

  final CliRunner runner;
  final Duration interval;

  @override
  State<StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<StatusPage> {
  Timer? _timer;
  Map<String, Object?>? _status;
  CliResult? _failure;
  String? _busy;
  CliResult? _actionFailure;

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

  Future<void> _refresh() async {
    final result = await widget.runner.start(['status', '--json']).result;
    if (!mounted) return;
    Map<String, Object?>? parsed;
    if (result.ok) {
      try {
        parsed = (jsonDecode(result.stdout) as Map).cast<String, Object?>();
      } on FormatException {
        parsed = null;
      }
    }
    setState(() {
      _status = parsed;
      _failure = parsed == null ? result : null;
    });
  }

  Future<void> _action(String label, List<String> args) async {
    setState(() {
      _busy = label;
      _actionFailure = null;
    });
    final result = await widget.runner.start(args).result;
    if (!mounted) return;
    setState(() {
      _busy = null;
      _actionFailure = result.ok ? null : result;
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _status;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Status', style: theme.textTheme.headlineSmall),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (status == null && _failure == null)
          const Center(child: CircularProgressIndicator())
        else if (status == null)
          _ServiceDown(
            result: _failure!,
            busy: _busy,
            onStart: () => _action('Starting', ['service', 'start', '--json']),
          )
        else
          ..._cards(context, status),
        if (_actionFailure != null) ...[
          const SizedBox(height: 16),
          _Message(result: _actionFailure!),
        ],
      ],
    );
  }

  List<Widget> _cards(BuildContext context, Map<String, Object?> s) {
    Map<String, Object?> section(String key) =>
        (s[key] as Map?)?.cast<String, Object?>() ?? const {};
    final workspace = section('workspace');
    final cloud = section('cloud');
    final service = section('service');
    final assignments = section('assignments');
    final config = section('config');
    final connected = cloud['connected'] == true;
    final accepting = cloud['acceptingNewWork'] == true;
    final healthy = service['serviceHealthy'] == true;
    final busy = _busy != null;

    return [
      Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          _Card(
            icon: Icons.computer,
            title: '${workspace['name'] ?? 'Workspace'}',
            value: healthy ? 'Healthy' : 'Unhealthy',
            good: healthy,
            detail: 'Config: ${config['state'] ?? 'unknown'}',
          ),
          _Card(
            icon: Icons.cloud_outlined,
            title: 'Cloud',
            value: connected ? 'Connected' : 'Disconnected',
            good: connected,
            detail:
                '${(connected ? cloud['transport'] : cloud['lifecycleState'] ?? cloud['state']) ?? ''}',
          ),
          _Card(
            icon: Icons.folder_outlined,
            title: 'Work Root',
            value: '${workspace['workRoot'] ?? 'Not configured'}',
            good: workspace['workRoot'] != null,
          ),
          _Card(
            icon: Icons.memory,
            title: 'Workers',
            value: '${(s['workers'] as List?)?.length ?? 0} configured',
            good: true,
          ),
          _Card(
            icon: Icons.checklist,
            title: 'Active work',
            value: '${assignments['activeCount'] ?? 0} running',
            good: true,
            detail: accepting ? 'Accepting new work' : 'Paused',
          ),
        ],
      ),
      const SizedBox(height: 24),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (connected)
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => _action('Disconnecting', ['disconnect', '--json']),
              icon: const Icon(Icons.cloud_off_outlined),
              label: const Text('Disconnect'),
            )
          else
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => _action('Connecting', ['connect', '--json']),
              icon: const Icon(Icons.cloud_outlined),
              label: const Text('Connect'),
            ),
          if (accepting)
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => _action('Pausing', ['pause', '--json']),
              icon: const Icon(Icons.pause),
              label: const Text('Pause new work'),
            )
          else
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () => _action('Resuming', ['resume', '--json']),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Resume new work'),
            ),
          if (_busy != null)
            Padding(padding: const EdgeInsets.all(8), child: Text('$_busy…')),
        ],
      ),
    ];
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.value,
    required this.good,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool good;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 260,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                value,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: good ? null : theme.colorScheme.error,
                ),
              ),
              if (detail != null && detail!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  detail!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ServiceDown extends StatelessWidget {
  const _ServiceDown({
    required this.result,
    required this.busy,
    required this.onStart,
  });

  final CliResult result;
  final String? busy;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'The Workspace service is not available.',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      _Message(result: result),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: busy == null ? onStart : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(busy == null ? 'Start service' : '$busy…'),
      ),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message({required this.result});

  final CliResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = [
      result.stderr,
      result.stdout,
    ].map((s) => s.trim()).where((s) => s.isNotEmpty).join('\n');
    return SelectableText(
      text.isEmpty ? 'Exit code ${result.exitCode}' : text,
      style: theme.textTheme.bodySmall?.copyWith(
        fontFamily: 'JetBrains Mono',
        color: theme.colorScheme.error,
      ),
    );
  }
}
