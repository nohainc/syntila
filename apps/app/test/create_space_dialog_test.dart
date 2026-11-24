import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/features/spaces/create_space_dialog.dart';

void main() {
  testWidgets('creates a Space with name and optional description',
      (tester) async {
    CreateSpaceRequest? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showCreateSpaceDialog(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Plain');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, (name: 'Plain', description: null));
  });

  testWidgets('stays open and shows server problems next to the fields',
      (tester) async {
    var attempts = 0;
    CreateSpaceRequest? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result =
              await showCreateSpaceDialog(context, create: (request) async {
            if (attempts++ == 0) {
              throw const AxApiException(
                  'Space creation failed (400): name: Too long; settings: Unknown',
                  statusCode: 400,
                  code: 'invalid_request',
                  details: [
                    AxApiFieldError('name', 'Too long'),
                    AxApiFieldError('settings', 'Unknown'),
                  ]);
            }
          }),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'A long name');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Too long'), findsOneWidget);
    expect(find.text('settings: Unknown'), findsOneWidget);
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result?.name, 'A long name');
  });
}
