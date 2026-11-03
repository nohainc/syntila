import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:syntila_app/src/ax/sync/ax_archived_spaces.dart';
import 'package:syntila_app/src/ax/sync/ax_collaboration_mutations.dart';
import 'package:syntila_app/src/ax/sync/ax_sync_engine.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:syntila_app/src/features/spaces/archived_spaces_page.dart';

import 'ax_fixture_data.dart';

class _ArchivedSource extends AxFixtureDataSource {
  _ArchivedSource(this.archived);

  final List<AxSpace> archived;
  final restored = <String>[];
  final deleted = <String>[];
  Completer<void>? restoreGate;

  @override
  Future<AxSpace> updateSpace(
      {required String spaceId,
      String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) async {
    restored.add(spaceId);
    await restoreGate?.future;
    final space = archived.firstWhere((space) => space.id == spaceId);
    archived.remove(space);
    return space.copyWith(archived: false);
  }

  @override
  Future<void> deleteSpace({required String spaceId}) async {
    deleted.add(spaceId);
    archived.removeWhere((space) => space.id == spaceId);
  }

  @override
  Future<List<AxSpace>> loadSpaces({bool includeArchived = false}) async =>
      includeArchived ? archived : const [];
}

void main() {
  const first = AxSpace(
    id: 'archived-1',
    name: 'Research',
    branch: 'main',
    lastActivity: 'yesterday',
    description: 'Research notes',
    archived: true,
  );
  const second = AxSpace(
    id: 'archived-2',
    name: 'Holiday planning',
    branch: 'main',
    lastActivity: 'last week',
    description: 'Trip planning',
    archived: true,
  );

  test('refreshes an existing archived inventory cache', () async {
    final source = _ArchivedSource([]);
    final engine = AxSyncEngine();
    final archivedSpaces = AxArchivedSpaces(source, engine: engine);

    await archivedSpaces.ensure();
    source.archived.add(first);
    await archivedSpaces.ensure();
    await Future<void>.delayed(Duration.zero);

    expect(engine.peek(archivedSpaces.query).data?.single.name, first.name);
  });

  testWidgets('shows archived Spaces in one column', (tester) async {
    final source = _ArchivedSource([first, second]);
    final engine = AxSyncEngine();
    final archivedSpaces = AxArchivedSpaces(source, engine: engine);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(1000, 800)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ArchivedSpacesPage(
                archivedSpaces: archivedSpaces,
                mutations: AxCollaborationMutations(source, engine: engine),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Archived Spaces'), findsOneWidget);
    expect(find.text('Spaces you archived are kept here until restored.'),
        findsOneWidget);
    expect(find.byIcon(Icons.archive_outlined), findsNothing);
    expect(find.byKey(const ValueKey('archived-space-archived-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('archived-space-archived-2')),
        findsOneWidget);
    final firstCard =
        tester.getRect(find.byKey(const ValueKey('archived-space-archived-1')));
    final secondCard =
        tester.getRect(find.byKey(const ValueKey('archived-space-archived-2')));
    expect(secondCard.left, firstCard.left);
    expect(secondCard.width, firstCard.width);
    expect(secondCard.top - firstCard.bottom, 12);
    expect(find.text('Restore'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    expect(find.byTooltip('Archived Space actions'), findsNWidgets(2));

    await tester
        .tap(find.byKey(const ValueKey('archived-space-actions-archived-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Research?'), findsOneWidget);
    expect(
        find.text(
            'This permanently deletes the Space and its archived record.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Research?'), findsNothing);
    expect(source.deleted, isEmpty);
    await tester
        .tap(find.byKey(const ValueKey('archived-space-actions-archived-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(source.deleted, ['archived-1']);
    expect(find.text('Research'), findsNothing);
    expect(find.text('Holiday planning'), findsOneWidget);
  });
  testWidgets('compact menus restore the selected Space and disable while busy',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final width in [390.0, 1000.0]) {
      await tester.binding.setSurfaceSize(Size(width, 800));
      final source = _ArchivedSource([
        first,
        second.copyWith(description: width == 390 ? '' : '   '),
      ]);
      final gate = Completer<void>();
      source.restoreGate = gate;
      final engine = AxSyncEngine();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: ArchivedSpacesPage(
          key: ValueKey(width),
          archivedSpaces: AxArchivedSpaces(source, engine: engine),
          mutations: AxCollaborationMutations(source, engine: engine),
        ))),
      ));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('archived-space-archived-2'));
      final trigger =
          find.byKey(const ValueKey('archived-space-actions-archived-2'));
      expect(tester.getSize(trigger), const Size(48, 48));
      expect(find.text('No description'), findsNothing);
      expect(
          tester.getSize(card).height,
          lessThan(tester
              .getSize(find.byKey(const ValueKey('archived-space-archived-1')))
              .height));
      expect(tester.getTopRight(trigger).dx,
          lessThanOrEqualTo(tester.getTopRight(card).dx));
      await tester.tap(trigger);
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Restore'));
      await tester.pump();
      expect(source.restored, ['archived-2']);
      expect(tester.widget<PopupMenuButton<String>>(trigger).enabled, isFalse);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Holiday planning'), findsNothing);
      expect(find.text('Research'), findsOneWidget);
      expect(source.deleted, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });
}
