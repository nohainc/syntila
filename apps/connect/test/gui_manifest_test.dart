import 'package:gui_manifest/gui_manifest.dart';
import 'package:syntila_connect/src/gui_manifest.dart';
import 'package:test/test.dart';

void main() {
  group('--gui-manifest', () {
    test('answers version 1 with a valid grouped manifest', () {
      final answer = answerGuiManifest(['--gui-manifest=1'], version: '0.1.0');

      expect(answer, isNotNull);
      expect(answer!.refusal, isNull);
      final document = answer.document!;
      expect(validateManifestSource(document), isEmpty);

      // Core groups and subcommands
      expect(document, contains('id status'));
      expect(document, contains('id pair'));
      expect(document, contains('Add Worker'));
      expect(document, contains('id unpair'));
      expect(document, contains('Remove Worker'));
      expect(document, isNot(contains('id run')));
      expect(document, isNot(contains('id uninstall')));
      expect(document, contains('id service.status'));
      expect(document, contains('id service.start'));
      expect(document, contains('id service.stop'));
      expect(document, contains('id service.restart'));
      expect(document, contains('id service.install'));
      expect(document, contains('id service.uninstall'));
      expect(document, contains('id folders.list'));
      expect(document, contains('id folders.add'));
      expect(document, contains('id folders.remove'));
      expect(document, contains('id folders.workRoot'));
      expect(document, isNot(contains('id folders.adoptSpace')));
      expect(document, isNot(contains('id folders.importWorkspace')));
      expect(document, contains('id mcpWorker.list'));
      expect(document, contains('id mcpWorker.import'));
      expect(document, contains('id mcpWorker.test'));
      expect(document, contains('id mcpWorker.approve'));
      expect(document, contains('id mcpWorker.remove'));
      expect(document, contains('id config.show'));
      expect(document, contains('id config.set'));
      expect(document, isNot(contains('id update.stage')));
      expect(document, isNot(contains('id update.prepare')));
      expect(document, contains('id rotateCredential'));
      expect(document, contains('Update credentials'));
      expect(document, contains('id version'));

      // Sidebar sections
      expect(document, contains('RUNTIME & SERVICE'));
      expect(document, isNot(contains('WORKSPACE & TOOLS')));
      expect(document, contains('DIAGNOSTICS & MAINTENANCE'));

      // Config keys enum and stdin secret
      expect(document, contains('maxConcurrent'));
      expect(document, isNot(contains('engineExecutable')));
      expect(document, isNot(contains('data-dir')));
      expect(document, contains('stdinFlag pairing-code-stdin'));
      expect(document, contains('longRunning true'));
    });

    test('the pairing code is never offered as a plain argument', () {
      final document = answerGuiManifest([
        '--gui-manifest=1',
      ], version: '0.1.0')!.document!;

      expect(document, contains('type secret'));
    });

    test('accepts the bare flag as version 1', () {
      final answer = answerGuiManifest(['--gui-manifest'], version: '0.1.0');

      expect(answer!.document, isNotNull);
    });

    test('refuses a version the Agent does not support', () {
      final answer = answerGuiManifest(['--gui-manifest=0'], version: '0.1.0');

      expect(answer!.document, isNull);
      expect(answer.refusal, isNotNull);
    });

    test('ordinary command lines are not manifest requests', () {
      expect(answerGuiManifest(['status', '--json'], version: '0.1.0'), isNull);
    });
  });
}
