import 'dart:async';

import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/ax_data.dart' show AxWorkerPersonShareSource;
import '../../ax/ax_models.dart';
import '../../ax/ax_people.dart';

/// Owner control on the Worker detail view (ADR-043): share this Worker with
/// a person from People for Chat in their own Spaces and personal Threads.
/// It never allows Work or shell; models and efforts follow "Models for
/// members".
class WorkerPersonSharesSection extends StatefulWidget {
  const WorkerPersonSharesSection({
    super.key,
    required this.worker,
    required this.shares,
    this.people,
  });

  final WorkerInstance worker;
  final AxWorkerPersonShareSource shares;

  /// The owner's People; only they can be chosen.
  final AxPeopleDataSource? people;

  @override
  State<WorkerPersonSharesSection> createState() =>
      _WorkerPersonSharesSectionState();
}

class _WorkerPersonSharesSectionState extends State<WorkerPersonSharesSection> {
  bool _loading = true;
  bool _saving = false;
  Object? _error;
  List<AxWorkerPersonShare> _shares = const [];
  List<AxPerson> _people = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkerPersonSharesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.worker.id != widget.worker.id) unawaited(_load());
  }

  Future<void> _load() async {
    final workerId = widget.worker.id;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final shares = await widget.shares.loadWorkerPersonShares(workerId);
      final people = await widget.people?.loadPeople() ?? const <AxPerson>[];
      if (!mounted || workerId != widget.worker.id) return;
      setState(() {
        _shares = shares;
        _people = people;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || workerId != widget.worker.id) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _run(Future<List<AxWorkerPersonShare>> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final shares = await action();
      if (!mounted) return;
      setState(() {
        _shares = shares;
        _saving = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _saving = false;
      });
    }
  }

  Future<void> _edit({AxWorkerPersonShare? existing}) async {
    final candidates = [
      for (final person in _people)
        if (existing == null && !_shares.any((s) => s.userId == person.userId))
          person,
    ];
    final share = await showDialog<AxWorkerPersonShare>(
      context: context,
      builder: (_) => _PersonShareDialog(
        workerName: widget.worker.name,
        candidates: candidates,
        existing: existing,
      ),
    );
    if (share == null) return;
    await _run(
        () => widget.shares.saveWorkerPersonShare(widget.worker.id, share));
  }

  static String _limits(AxWorkerPersonShare share) {
    final seconds = share.maxRunSecondsPerMonth;
    final monthly = seconds == null
        ? 'no monthly limit'
        : '${(seconds / 3600).toStringAsFixed(seconds % 3600 == 0 ? 0 : 1)} h a month';
    return '${share.maxConcurrentRequests} at a time · $monthly';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      key: const ValueKey('worker-person-shares'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text('Share with people',
                      style: theme.textTheme.titleMedium)),
              TextButton.icon(
                key: const ValueKey('worker-person-share-add'),
                onPressed: _loading || _saving ? null : () => _edit(),
                icon: const Icon(Icons.person_add_alt, size: 18),
                label: const Text('Share'),
              ),
            ]),
            Text(
              'People you share with can use this Worker for Chat in their '
              'own Spaces and personal Threads. It runs on this computer with '
              'your provider logins, without your folders, Work or shell. '
              'Models follow "Models for members".',
              style: TextStyle(fontSize: 13, color: muted),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const LinearProgressIndicator()
            else if (_shares.isEmpty)
              Text('Not shared with anyone.',
                  style: TextStyle(fontSize: 13, color: muted))
            else
              for (final share in _shares)
                ListTile(
                  key: ValueKey('worker-person-share-${share.userId}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(share.displayName.isNotEmpty
                      ? share.displayName
                      : share.email),
                  subtitle: Text(_limits(share)),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Change limits',
                      icon: const Icon(Icons.tune, size: 18),
                      onPressed: _saving ? null : () => _edit(existing: share),
                    ),
                    IconButton(
                      key: ValueKey(
                          'worker-person-share-remove-${share.userId}'),
                      tooltip: 'Stop sharing',
                      icon: const Icon(Icons.person_remove_outlined, size: 18),
                      onPressed: _saving
                          ? null
                          : () => _run(() => widget.shares
                              .removeWorkerPersonShare(
                                  widget.worker.id, share.userId)),
                    ),
                  ]),
                ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('$_error',
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}

class _PersonShareDialog extends StatefulWidget {
  const _PersonShareDialog({
    required this.workerName,
    required this.candidates,
    this.existing,
  });

  final String workerName;
  final List<AxPerson> candidates;
  final AxWorkerPersonShare? existing;

  @override
  State<_PersonShareDialog> createState() => _PersonShareDialogState();
}

class _PersonShareDialogState extends State<_PersonShareDialog> {
  String? _userId;
  int _concurrent = 1;
  final _hours = TextEditingController();

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _userId = existing?.userId;
    _concurrent = existing?.maxConcurrentRequests ?? 1;
    final seconds = existing?.maxRunSecondsPerMonth;
    if (seconds != null) _hours.text = (seconds / 3600).toString();
  }

  @override
  void dispose() {
    _hours.dispose();
    super.dispose();
  }

  /// Hours a month as seconds; empty is no limit, anything else invalid.
  int? get _seconds {
    final text = _hours.text.trim();
    if (text.isEmpty) return null;
    final hours = double.tryParse(text);
    return hours == null || hours <= 0 ? -1 : (hours * 3600).round();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final valid = _userId != null && (_seconds ?? 1) > 0;
    return AlertDialog(
      title: Text(existing == null
          ? 'Share ${widget.workerName}'
          : 'Limits for ${existing.displayName.isNotEmpty ? existing.displayName : existing.email}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (existing == null)
              widget.candidates.isEmpty
                  ? const Text(
                      'Everyone in your People already has access, or your People is empty.')
                  : DropdownButtonFormField<String>(
                      key: const ValueKey('worker-person-share-person'),
                      initialValue: _userId,
                      decoration: const InputDecoration(labelText: 'Person'),
                      items: [
                        for (final person in widget.candidates)
                          DropdownMenuItem(
                            value: person.userId,
                            child: Text(person.displayName.isNotEmpty
                                ? '${person.displayName} (${person.email})'
                                : person.email),
                          ),
                      ],
                      onChanged: (value) => setState(() => _userId = value),
                    ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('worker-person-share-concurrent'),
              initialValue: _concurrent,
              decoration:
                  const InputDecoration(labelText: 'Requests at a time'),
              items: [
                for (var n = 1; n <= 10; n++)
                  DropdownMenuItem(value: n, child: Text('$n')),
              ],
              onChanged: (value) => setState(() => _concurrent = value ?? 1),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('worker-person-share-hours'),
              controller: _hours,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Run time a month (hours)',
                helperText: 'Leave empty for no limit',
                errorText:
                    (_seconds ?? 1) > 0 ? null : 'Enter a positive number',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('worker-person-share-save'),
          onPressed: valid
              ? () => Navigator.pop(
                    context,
                    AxWorkerPersonShare(
                      userId: _userId!,
                      maxConcurrentRequests: _concurrent,
                      maxRunSecondsPerMonth: _seconds,
                    ),
                  )
              : null,
          child: Text(existing == null ? 'Share' : 'Save'),
        ),
      ],
    );
  }
}
