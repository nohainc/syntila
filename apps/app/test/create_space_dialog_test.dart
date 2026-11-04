import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_workflow_configuration.dart';
import 'package:syntila_app/src/features/spaces/create_space_dialog.dart';

Future<CreateSpaceRequest?> Function() _open(
    WidgetTester tester, List<AxWorkflowWorkspace> workspaces) {
  CreateSpaceRequest? result;
  var closed = false;
  return () async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showCreateSpaceDialog(context,
                loadWorkspaces: () async => workspaces);
            closed = true;
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return closed ? result : null;
  };
}

void main() {
  testWidgets('never preselects a Workspace', (tester) async {
    await _open(tester, const [AxWorkflowWorkspace(id: 'ws', name: 'Mac')])();
    expect(find.text('No Workspace'), findsOneWidget);
    expect(
        find.text(
            'Work cannot run in this Space until you choose a Workspace.'),
        findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Plain');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('one click uses the only Workspace', (tester) async {
    CreateSpaceRequest? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showCreateSpaceDialog(context,
              loadWorkspaces: () async =>
                  const [AxWorkflowWorkspace(id: 'ws', name: 'Mac')]),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Mine');
    await tester
        .tap(find.byKey(const ValueKey('create-space-use-only-workspace')));
    await tester.pumpAndSettle();
    expect(find.text('Work in this Space will run on this Workspace.'),
        findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(result, (name: 'Mine', description: null, workspaceId: 'ws'));
  });

  testWidgets('no shortcut when several Workspaces exist', (tester) async {
    await _open(tester, const [
      AxWorkflowWorkspace(id: 'a', name: 'Mac'),
      AxWorkflowWorkspace(id: 'b', name: 'Linux'),
    ])();
    expect(find.byKey(const ValueKey('create-space-use-only-workspace')),
        findsNothing);
  });
}
