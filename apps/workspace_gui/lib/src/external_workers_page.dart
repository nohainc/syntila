import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';

/// External Worker management replacing the generated `workers external` page.
///
/// Import, inspect, register, enable, disable and remove an MCP Worker package.
/// Register and enable show the consent document as a review dialog and rerun
/// with `--accept <hash>` only after the person accepts. Everything still goes
/// through the CLI.
class ExternalWorkersPage extends StatefulWidget {
  const ExternalWorkersPage({super.key, required this.runner});

  final CliRunner runner;

  @override
  State<ExternalWorkersPage> createState() => _ExternalWorkersPageState();
}

/// The CLI exits 3 when a consent document still needs acceptance.
const _consentPendingExit = 3;

class _ExternalWorkersPageState extends State<ExternalWorkersPage> {
  final _path = TextEditingController();
  List<Map<String, Object?>>? _workers;
  CliResult? _loadFailure;
  String? _busy;
  String? _notice;
  CliResult? _actionFailure;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Map<String, Object?>? _json(CliResult result) {
    try {
      final value = jsonDecode(result.stdout);
      return value is Map ? value.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _refresh() async {
    final result = await widget.runner.start([
      'workers',
      'external',
      '--json',
    ]).result;
    if (!mounted) return;
    final parsed = result.ok ? _json(result) : null;
    setState(() {
      _workers = parsed == null
          ? null
          : [
              for (final w in (parsed['plugins'] as List? ?? const []))
                if (w is Map) w.cast<String, Object?>(),
            ];
      _loadFailure = parsed == null ? result : null;
    });
  }

  /// Runs one action. Returns the parsed JSON on success, null otherwise.
  Future<Map<String, Object?>?> _run(String label, List<String> args) async {
    setState(() {
      _busy = label;
      _notice = null;
      _actionFailure = null;
    });
    final result = await widget.runner.start([...args, '--json']).result;
    if (!mounted) return null;
    final parsed = _json(result);
    final pending =
        result.exitCode == _consentPendingExit &&
        parsed?['consentRequired'] == true;
    setState(() {
      _busy = null;
      _actionFailure = result.ok || pending ? null : result;
    });
    return result.ok || pending ? parsed : null;
  }

  Future<void> _import() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final result = await _run('Importing', ['workers', 'import', path]);
    if (result == null) return;
    _path.clear();
    setState(
      () => _notice =
          'Imported ${result['pluginId']} ${result['version']}. '
          'Inspect it next.',
    );
    await _refresh();
  }

  Future<void> _inspect(String id) async {
    final result = await _run('Inspecting $id', ['workers', 'inspect', id]);
    if (result == null) return;
    final failed = [
      for (final c in (result['cases'] as List? ?? const []))
        if (c is Map && c['status'] != 'passed') '${c['id']}',
    ];
    setState(
      () => _notice = result['passed'] == true
          ? '$id passed inspection. Register it next.'
          : '$id failed inspection: ${failed.join(', ')}',
    );
    await _refresh();
  }

  /// Register or enable: shows the consent document, then accepts it.
  Future<void> _consent(String verb, String id) async {
    final first = await _run('Preparing $verb', ['workers', verb, id]);
    if (first == null || !mounted) return;
    if (first['consentRequired'] == true) {
      final document = (first['document'] as Map).cast<String, Object?>();
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => ConsentDialog(verb: verb, document: document),
      );
      if (accepted != true || !mounted) return;
      final hash = first['documentHash'] as String;
      final done = await _run('${_capitalized(verb)}ing $id', [
        'workers',
        verb,
        id,
        '--accept',
        hash,
      ]);
      if (done == null) return;
    }
    setState(
      () => _notice = verb == 'register'
          ? 'Registered $id. Enable it to attach it as a Worker.'
          : 'Enabled $id. It now runs like any other Worker.',
    );
    await _refresh();
  }

  Future<void> _simple(String verb, String id) async {
    if (verb == 'remove') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Remove $id?'),
          content: const Text(
            'This removes the package from this Workspace and from your '
            'account library.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    final result = await _run('${_capitalized(verb)} $id', [
      'workers',
      verb,
      id,
    ]);
    if (result == null) return;
    setState(
      () => _notice = '$id ${verb == 'remove' ? 'removed' : 'disabled'}.',
    );
    await _refresh();
  }

  static String _capitalized(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final workers = _workers;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'External Workers',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _busy == null ? _refresh : null,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'MCP Worker packages you attach to this Workspace. Once enabled they '
          'run like any other Worker.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('external-worker-path'),
                controller: _path,
                decoration: const InputDecoration(
                  labelText: 'Package directory or .zip',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _import(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const Key('external-worker-import'),
              onPressed: _busy == null ? _import : null,
              icon: const Icon(Icons.download),
              label: const Text('Import'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_busy != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('$_busy…'),
              ],
            ),
          ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_notice!, key: const Key('external-worker-notice')),
          ),
        if (_actionFailure != null) _FailureText(result: _actionFailure!),
        if (_loadFailure != null) _FailureText(result: _loadFailure!),
        if (workers != null && workers.isEmpty)
          const Text('No External Workers yet.'),
        if (workers != null)
          for (final worker in workers)
            _WorkerCard(
              worker: worker,
              enabled: _busy == null,
              onInspect: _inspect,
              onRegister: (id) => _consent('register', id),
              onEnable: (id) => _consent('enable', id),
              onDisable: (id) => _simple('disable', id),
              onRemove: (id) => _simple('remove', id),
            ),
      ],
    );
  }
}

class _FailureText extends StatelessWidget {
  const _FailureText({required this.result});

  final CliResult result;

  @override
  Widget build(BuildContext context) {
    final message = result.stderr.trim().isNotEmpty
        ? result.stderr.trim()
        : result.stdout.trim().isNotEmpty
        ? result.stdout.trim()
        : 'The command failed (exit ${result.exitCode}).';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message,
        key: const Key('external-worker-error'),
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

/// One package. The available actions follow its lifecycle:
/// imported → inspected → registered → enabled ⇄ disabled.
class _WorkerCard extends StatelessWidget {
  const _WorkerCard({
    required this.worker,
    required this.enabled,
    required this.onInspect,
    required this.onRegister,
    required this.onEnable,
    required this.onDisable,
    required this.onRemove,
  });

  final Map<String, Object?> worker;
  final bool enabled;
  final void Function(String id) onInspect;
  final void Function(String id) onRegister;
  final void Function(String id) onEnable;
  final void Function(String id) onDisable;
  final void Function(String id) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = '${worker['pluginId']}';
    final versions = [
      for (final v in (worker['versions'] as List? ?? const []))
        if (v is Map) v.cast<String, Object?>(),
    ];
    final latest = versions.isEmpty ? null : versions.last;
    final conformance = latest?['conformance'] as Map?;
    final inspected = conformance?['passed'] == true;
    final registered = latest?['registered'] == true;
    final local = worker['workspace'] as Map?;
    final isEnabled = local?['effective'] == 'enabled';
    final state = isEnabled
        ? 'Enabled'
        : local != null
        ? 'Disabled'
        : registered
        ? 'Registered'
        : inspected
        ? 'Inspected'
        : conformance != null
        ? 'Inspection failed'
        : 'Imported';
    VoidCallback? action(void Function(String) f) =>
        enabled ? () => f(id) : null;
    return Card(
      key: Key('external-worker-$id'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${worker['displayName']}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 2),
            Text(
              '$id · ${latest?['version'] ?? '-'} · $state',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: action(onInspect),
                  child: const Text('Inspect'),
                ),
                if (inspected && !registered)
                  FilledButton(
                    onPressed: action(onRegister),
                    child: const Text('Register'),
                  ),
                if (registered && !isEnabled)
                  FilledButton(
                    onPressed: action(onEnable),
                    child: const Text('Enable'),
                  ),
                if (isEnabled)
                  OutlinedButton(
                    onPressed: action(onDisable),
                    child: const Text('Disable'),
                  ),
                if (!isEnabled)
                  TextButton(
                    onPressed: action(onRemove),
                    child: const Text('Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The consent document in full. Tool descriptions come from the Worker and
/// are untrusted; the digests are what Syntila pins.
class ConsentDialog extends StatelessWidget {
  const ConsentDialog({super.key, required this.verb, required this.document});

  final String verb;
  final Map<String, Object?> document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final worker = (document['plugin'] as Map? ?? const {});
    final digest = (document['digest'] as Map? ?? const {});
    final signature = (document['signature'] as Map? ?? const {});
    final access = (document['requestedAccess'] as Map? ?? const {});
    final mcp = document['mcp'] as Map?;
    final tools = [
      for (final t in (mcp?['tools'] as List? ?? const []))
        if (t is Map) t,
    ];
    Widget row(String label, Object? value) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: theme.textTheme.labelMedium),
          ),
          Expanded(child: SelectableText('$value')),
        ],
      ),
    );
    return AlertDialog(
      title: Text(
        'Review before you $verb ${worker['displayName'] ?? worker['id']}',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              row('Worker', '${worker['id']} ${worker['version']}'),
              row('Author', '${worker['author']} (not verified)'),
              row('Signature', signature['status']),
              row('Manifest', digest['manifest']),
              row('Artifact', '${digest['artifact']} (${digest['platform']})'),
              for (final entry in access.entries)
                if (entry.key != 'note')
                  row('Access ${entry.key}', jsonEncode(entry.value)),
              if (access['note'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Text('${access['note']}'),
                ),
              if (tools.isNotEmpty) ...[
                Text(
                  'Tools (${tools.length})',
                  style: theme.textTheme.titleSmall,
                ),
                for (final tool in tools)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${tool['name']}: ${tool['description'] ?? ''}',
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              if (document['change'] != null)
                row('Change', jsonEncode(document['change'])),
              if (document['statement'] != null)
                Text(
                  '${document['statement']}',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('external-worker-accept'),
          onPressed: () => Navigator.pop(context, true),
          child: Text('Accept and $verb'),
        ),
      ],
    );
  }
}
