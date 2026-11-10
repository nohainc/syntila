import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/attachment_limits.dart';
import '../../ax/ax_data.dart';
import '../profile/account_plan.dart';

/// My Files: every file the signed-in user uploaded, with storage usage
/// against their quota. Deleting a file frees its space.
class FilesPage extends StatefulWidget {
  const FilesPage({super.key, required this.source, this.onOpenThread});

  final AxUserFilesDataSource source;
  final void Function(String spaceId, String threadId)? onOpenThread;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  List<AxUserFile>? _files;
  AxStorageUsage? _usage;
  String? _nextCursor;
  String? _error;
  bool _loadingMore = false;
  bool _syncing = false;
  String? _syncStatus;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final page = await widget.source.loadUserFiles();
      if (!mounted) return;
      setState(() {
        _files = page.files;
        _usage = page.usage;
        AxAttachmentPolicy.instance.updateFromUsage(page.usage);
        _nextCursor = page.nextCursor;
        _error = null;
      });
    } on Object {
      if (mounted) setState(() => _error = 'Files could not be loaded.');
    }
  }

  Future<void> _sync() async {
    if (_syncing || _loadingMore) return;
    setState(() {
      _syncing = true;
      _syncStatus = null;
      _error = null;
    });
    try {
      await widget.source.syncUserFiles();
      await _reload();
      if (mounted && _error == null) {
        setState(() => _syncStatus = 'Files synchronized with storage.');
      }
    } on Object {
      if (mounted) {
        setState(() =>
            _error = 'Synchronization could not finish. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.source.loadUserFiles(before: cursor);
      if (!mounted) return;
      setState(() {
        _files = [...?_files, ...page.files];
        _usage = page.usage;
        AxAttachmentPolicy.instance.updateFromUsage(page.usage);
        _nextCursor = page.nextCursor;
      });
    } on Object {
      if (mounted) setState(() => _error = 'More files could not be loaded.');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _delete(AxUserFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file'),
        content: Text(file.inUse
            ? '"${file.name}" is attached to messages or Work. They will '
                'keep its name, but it can no longer be downloaded. This '
                'cannot be undone.'
            : 'Delete "${file.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              key: const ValueKey('confirm-delete-file'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final usage = await widget.source.deleteUserFile(file.fileId);
      if (!mounted) return;
      setState(() {
        _usage = usage;
        AxAttachmentPolicy.instance.updateFromUsage(usage);
        _files = [
          for (final item in _files ?? const <AxUserFile>[])
            if (item.fileId != file.fileId) item,
        ];
      });
    } on Object {
      if (mounted) setState(() => _error = 'The file could not be deleted.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final usage = _usage;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final syncButton = TextButton(
      onPressed: _syncing || _loadingMore ? null : () => unawaited(_sync()),
      child: Text(_syncing ? 'Synchronizing…' : 'Synchronize storage'),
    );
    return SingleChildScrollView(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('My Files', style: theme.textTheme.headlineMedium),
        if (usage == null) ...[
          syncButton,
          const SizedBox(height: 16),
        ] else ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  '${formatFileSize(usage.usedBytes)} of '
                  '${formatFileSize(usage.quotaBytes)} used · '
                  '${usage.fileCount} ${usage.fileCount == 1 ? 'file' : 'files'}',
                  key: const ValueKey('files-usage'),
                  style: TextStyle(color: muted),
                ),
              ),
              syncButton,
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: usage.fraction,
            color: usage.fraction >= 0.9 ? theme.colorScheme.error : null,
          ),
          const SizedBox(height: 8),
          Text(
            'Each file can be up to ${formatFileSize(usage.maxFileBytes)}.',
            key: const ValueKey('files-file-limit'),
            style: TextStyle(color: muted),
          ),
          if (usage.isFull) ...[
            const SizedBox(height: 8),
            Text(
              'Storage is full. New uploads are blocked until you delete files '
              'or upgrade to Syntila Plus for more storage. Your existing '
              'files stay available to download.',
              key: const ValueKey('files-full'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ] else if (usage.nearLimit) ...[
            const SizedBox(height: 8),
            Text(
              'You have used ${(usage.fraction * 100).floor()}% of your '
              'storage. Delete files you no longer need, or upgrade to Syntila '
              'Plus for more.',
              key: const ValueKey('files-near-limit'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          if ((usage.isFull || usage.nearLimit) &&
              !AxAccountPlanCache.instance.plan.isPaid)
            const ViewPlansLink(),
          const SizedBox(height: 16),
        ],
        if (_syncStatus != null) ...[
          Text(_syncStatus!),
          const SizedBox(height: 12),
        ],
        if (_error != null) ...[
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 12),
        ],
        if (files == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (files != null && files.isEmpty)
          const Text('No files yet. Files you attach in a Thread appear here.')
        else if (files != null) ...[
          for (final file in files)
            Card(
              key: ValueKey('file-${file.fileId}'),
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          [
                            formatFileSize(file.sizeBytes),
                            _date(file.createdAt),
                            file.path ?? 'Thread no longer available',
                            if (file.inUse) 'In use',
                          ].where((part) => part.isNotEmpty).join(' · '),
                          key: ValueKey('file-meta-${file.fileId}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (file.threadId != null &&
                      file.spaceId != null &&
                      widget.onOpenThread != null)
                    TextButton(
                        onPressed: () =>
                            widget.onOpenThread!(file.spaceId!, file.threadId!),
                        child: const Text('Open Thread')),
                  IconButton(
                    key: ValueKey('delete-file-${file.fileId}'),
                    tooltip: 'Delete file',
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: _syncing ? null : () => unawaited(_delete(file)),
                  ),
                ]),
              ),
            ),
          if (_nextCursor != null)
            Center(
              child: TextButton(
                key: const ValueKey('files-load-more'),
                onPressed: _loadingMore || _syncing
                    ? null
                    : () => unawaited(_loadMore()),
                child: const Text('Load more'),
              ),
            ),
        ],
      ],
    ));
  }

  static String _date(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return '';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${parsed.year}-${two(parsed.month)}-${two(parsed.day)}';
  }
}
