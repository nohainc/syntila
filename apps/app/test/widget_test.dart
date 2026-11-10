import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/features/spaces/spaces_pages.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

import 'ax_fixture_data.dart';

void main() {
  const space = AxSpace(
    id: 'space-1',
    name: 'Authentication',
    branch: 'main',
    lastActivity: 'today',
    role: 'collaborator',
  );
  const thread = AxThread(
    id: 'thread-1',
    spaceId: 'space-1',
    name: 'Login reliability',
    lead: 'Owner',
    status: 'active',
    brief: 'Make login reliable.',
    primaryWorkspace: 'Mac Workspace',
    queueStatus: 'Idle',
  );

  testWidgets('Space exposes Threads and archive filtering', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SpacePage(
            space: space,
            dataSource: const AxFixtureDataSource(),
            onOpenThread: (_) {},
            onArchive: () {},
            onDelete: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Threads'), findsNothing);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Archived'), findsOneWidget);
    expect(find.text('Workspaces'), findsNothing);
    expect(find.text('Workflows'), findsNothing);
    expect(find.text('Members'), findsNothing);
    expect(find.byTooltip('Create Thread'), findsOneWidget);
    expect(find.text('Overview'), findsNothing);
    expect(find.text('Runs'), findsNothing);
    expect(find.text('Artifacts'), findsNothing);
    expect(find.text('Execution'), findsNothing);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Thread UI uses product vocabulary', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: ThreadPage(
            space: space,
            thread: thread,
            onBackToSpace: () {},
            onArchive: () {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('AI History'), findsOneWidget);
    expect(find.text('No chat messages yet'), findsOneWidget);
    await tester.tap(find.text('AI History'));
    await tester.pumpAndSettle();
    expect(find.text('What should Syntila do?'), findsNothing);
    expect(find.text('lease'), findsNothing);
    expect(find.text('fencing token'), findsNothing);
    expect(find.text('Durable Object'), findsNothing);
    expect(find.text('checkout key'), findsNothing);
  });
}
