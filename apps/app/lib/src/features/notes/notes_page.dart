import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';
import 'note_editor.dart';

/// My Notes: every private note of the signed-in user, including notes from
/// Threads that were deleted or that the user can no longer open.
class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.source, this.onOpenThread});

  final AxNotesDataSource source;
  final void Function(String spaceId, String threadId)? onOpenThread;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  List<AxNote>? _notes;
  String? _error;
  // The note open in the page's editor; null shows the list.
  AxNote? _selected;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final notes = await widget.source.loadNotes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _error = null;
      });
    } on Object {
      if (mounted) setState(() => _error = 'Notes could not be loaded.');
    }
  }

  // A new note is only a local draft until it has text.
  Future<void> _create() async => _open(AxNote(
      id: 'draft-${DateTime.now().microsecondsSinceEpoch}',
      title: '',
      body: '',
      revision: 1,
      updatedAt: ''));

  static bool _isDraft(AxNote note) => note.id.startsWith('draft-');

  Future<void> _open(AxNote note) async => setState(() => _selected = note);

  Future<void> _close() async {
    setState(() => _selected = null);
    await _reload();
    // Existing notes left completely empty are removed.
    final empty = (_notes ?? const <AxNote>[])
        .where((n) => n.title.trim().isEmpty && n.body.trim().isEmpty);
    if (empty.isNotEmpty) {
      for (final note in empty) {
        try {
          await widget.source.deleteNote(note.id);
        } on Object {/* Kept; retried on the next close. */}
      }
      await _reload();
    }
  }

  Future<void> _delete(AxNote note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete note'),
        content: Text('Delete "${note.displayTitle}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              key: const ValueKey('confirm-delete-note'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.source.deleteNote(note.id);
    } on Object {
      if (mounted) setState(() => _error = 'The note could not be deleted.');
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) => TooltipVisibility(
        visible: false,
        child: _buildContent(context),
      );

  Widget _buildContent(BuildContext context) {
    final selected = _selected;
    if (selected != null) return _editor(selected);
    // Completely empty notes are never listed.
    final notes = _notes
        ?.where((n) => n.title.trim().isNotEmpty || n.body.trim().isNotEmpty)
        .toList();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    // The page gets the full height (no outer scroll), so the list scrolls
    // itself and the editor can fill it.
    return SingleChildScrollView(
        child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text('My Notes',
                style: Theme.of(context).textTheme.headlineMedium),
          ),
          FilledButton.icon(
            key: const ValueKey('new-note'),
            onPressed: () => unawaited(_create()),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New note'),
          ),
        ]),
        const SizedBox(height: 20),
        if (_error != null) ...[
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
        ],
        if (notes == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (notes != null && notes.isEmpty)
          const Text('No notes yet. Create one here or open the Notes tab in '
              'a Thread.')
        else if (notes != null)
          for (final note in notes)
            Card(
              key: ValueKey('note-${note.id}'),
              margin: const EdgeInsets.only(bottom: 10),
              // Line 1: name left, path right across the full width.
              // Below: the text preview with Delete beside it.
              child: InkWell(
                onTap: () => unawaited(_open(note)),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Row(children: [
                          Expanded(
                            child: Text(note.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                          ),
                          if (note.path case final path?
                              when path.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                note.linked
                                    ? path
                                    : '$path (Thread no longer available)',
                                key: ValueKey('note-path-${note.id}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: TextStyle(fontSize: 12, color: muted),
                              ),
                            ),
                          ],
                        ]),
                      ),
                      Row(children: [
                        Expanded(
                          child: Text(note.body.trim(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: muted)),
                        ),
                        IconButton(
                          key: ValueKey('delete-note-${note.id}'),
                          tooltip: 'Delete note',
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18),
                          onPressed: () => unawaited(_delete(note)),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
      ],
    ));
  }

  // Id of the stored copy of the open note; null while it is not stored
  // because it is empty.
  String? _storedId;
  String? _storedFor;

  /// Empty notes (no title, no body) are not stored: an existing one is
  /// deleted and a new one is only created once there is text.
  Future<AxNote> _saveNote(
      AxNote note, String title, String body, int? revision) async {
    if (_storedFor != note.id) {
      _storedFor = note.id;
      _storedId = _isDraft(note) ? null : note.id;
    }
    final empty = title.trim().isEmpty && body.trim().isEmpty;
    if (empty) {
      final id = _storedId;
      if (id != null) {
        await widget.source.deleteNote(id);
        _storedId = null;
        if (mounted && _selected == null) unawaited(_reload());
      }
      return note;
    }
    final id = _storedId;
    if (id == null) {
      final created = await widget.source.createNote(title: title, body: body);
      _storedId = created.id;
      if (mounted && _selected == null) unawaited(_reload());
      return created;
    }
    return widget.source.updateNote(id,
        title: title, body: body, revision: revision ?? note.revision);
  }

  /// The selected note's editor, shown in place of the list.
  Widget _editor(AxNote note) {
    final path = note.spacePath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          TextButton.icon(
            key: const ValueKey('notes-back'),
            onPressed: () => unawaited(_close()),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('All notes'),
          ),
          const SizedBox(width: 12),
          // Path and Open Thread sit on the right.
          Expanded(
            child: path == null || path.isEmpty
                ? const SizedBox.shrink()
                : Text(
                    note.linked ? path : '$path (Thread no longer available)',
                    key: const ValueKey('notes-editor-path'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),
          if (note.linked && widget.onOpenThread != null)
            TextButton(
                key: const ValueKey('notes-open-thread'),
                onPressed: () =>
                    widget.onOpenThread!(note.spaceId!, note.threadId!),
                child: const Text('Open Thread')),
        ]),
        const SizedBox(height: 8),
        Expanded(
          child: NoteEditor(
            key: ValueKey('notes-editor-${note.id}'),
            showTitle: true,
            load: () async =>
                _isDraft(note) ? null : widget.source.loadNote(note.id),
            save: ({required title, required body, revision}) =>
                _saveNote(note, title, body, revision),
          ),
        ),
      ],
    );
  }
}
