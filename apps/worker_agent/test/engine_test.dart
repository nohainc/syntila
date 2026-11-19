import 'package:syntila_worker_agent/syntila_worker_agent.dart';
import 'package:test/test.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

EngineRequest request(String id) =>
    EngineRequest(assignmentId: id, attemptId: 'att-$id', payload: const {});

void main() {
  test('slots are bounded per Agent and passed on in order', () async {
    final engine = FakeEngine()..hold = true;
    final supervisor = EngineSupervisor(engine, maxConcurrent: 2);
    await supervisor.start(request('a'));
    await supervisor.start(request('b'));
    expect(supervisor.activeSlots, 2);
    var thirdStarted = false;
    final third = supervisor.start(request('c')).then((run) {
      thirdStarted = true;
      return run;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(thirdStarted, isFalse);
    expect(supervisor.queued, 1);
    engine.finish('a', const EngineOutcome(TerminalKind.completed, {}));
    await third;
    expect(engine.launches, ['a', 'b', 'c']);
    engine.finish('b', const EngineOutcome(TerminalKind.completed, {}));
    engine.finish('c', const EngineOutcome(TerminalKind.completed, {}));
    await waitFor(() => supervisor.activeSlots == 0);
  });

  test('an assignment is never started twice', () async {
    final engine = FakeEngine();
    final supervisor = EngineSupervisor(engine);
    final run = await supervisor.start(request('a'));
    await run!.outcome;
    await waitFor(() => supervisor.activeSlots == 0);
    await expectLater(
      supervisor.start(request('a')),
      throwsA(isA<EngineAlreadyStartedException>()),
    );
    expect(engine.launchCount('a'), 1);
    expect(
      supervisor.activeSlots,
      0,
      reason: 'a refused start gives its slot back',
    );
  });

  test('a refused permit launches nothing and frees the slot', () async {
    final engine = FakeEngine();
    final supervisor = EngineSupervisor(engine);
    expect(
      await supervisor.start(request('a'), authorize: () => false),
      isNull,
    );
    expect(engine.launches, isEmpty);
    expect(supervisor.activeSlots, 0);
    expect(
      await supervisor.start(request('a')),
      isNotNull,
      reason: 'a refused start did not use the one start',
    );
  });

  test('the start is recorded before the launch call', () async {
    final events = <String>[];
    final engine = FakeEngine();
    final supervisor = EngineSupervisor(engine);
    await supervisor.start(
      request('a'),
      onLaunching: () => events.add('recorded'),
    );
    events.add('launched:${engine.launchCount('a')}');
    expect(events, ['recorded', 'launched:1']);
  });

  test('the unconfigured launcher fails closed', () async {
    final launcher = UnconfiguredEngineLauncher();
    expect(await launcher.probe(), 'engine_unavailable');
    await expectLater(launcher.launch(request('a')), throwsStateError);
  });
}
