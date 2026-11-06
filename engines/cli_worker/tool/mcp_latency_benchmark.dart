// Latency of the three ways the Engine can run a custom Worker (ADR-028 M4).
//
//   dart run tool/mcp_latency_benchmark.dart [--rebuild] [--quick]
//
// The driver compiles the Engine, an NDJSON fixture plugin, the MCP echo Worker
// and this tool itself (the real Engine is AOT; JIT warm-up would distort the
// numbers), then runs the measurement. Every path uses the production
// LimitedPluginSupervisor, so each spawn includes the limits wrapper.
//
//   NDJSON per execute : PluginHost.run - spawns the plugin for every execute
//   MCP cold           : fresh host - spawn + initialize + tools/list + call
//   MCP warm           : pooled server - one McpWorkerRunner.run
//   MCP ping           : one JSON-RPC round trip on an open connection
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/src/mcp_host.dart';
import 'package:syntila_cli_worker_engine/src/mcp_worker_runner.dart';
import 'package:syntila_cli_worker_engine/src/plugin_host.dart';
import 'package:syntila_cli_worker_engine/src/plugin_process_limits.dart';
import 'package:syntila_mcp_protocol/syntila_mcp_protocol.dart';

Future<void> main(List<String> args) async {
  // The limits wrapper re-executes the Engine binary in this mode.
  if (args.isNotEmpty && args.first == '--plugin-child') {
    await runLimitedPluginChild(args);
    return;
  }
  if (args.contains('--measure')) {
    await _measure(args);
    return;
  }
  await _drive(args);
}

Future<void> _compile(String source, String output, String cwd) async {
  stdout.writeln('compiling ${output.split('/').last} ...');
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'exe',
    source,
    '-o',
    output,
  ], workingDirectory: cwd);
  if (result.exitCode != 0) {
    stderr.writeln('${result.stdout}${result.stderr}');
    exit(1);
  }
}

Future<void> _drive(List<String> args) async {
  final cwd = Directory.current.path;
  final cache = Directory('$cwd/.dart_tool/mcp-latency')
    ..createSync(recursive: true);
  final rebuild = args.contains('--rebuild');
  Future<String> ensure(String name, String source, String where) async {
    final out = '${cache.path}/$name';
    if (rebuild || !File(out).existsSync()) await _compile(source, out, where);
    return out;
  }

  final engine = await ensure('engine', 'bin/syntila_cli_worker.dart', cwd);
  final ndjson = await ensure(
    'ndjson',
    'test/fixtures/plugin_fixture.dart',
    cwd,
  );
  final mcp = await ensure(
    'mcp-echo',
    'echo_worker.dart',
    '$cwd/../../examples/mcp/echo_worker',
  );
  // Always rebuild the benchmark: it is cheap and must match the sources.
  final bench = '${cache.path}/bench';
  await _compile('tool/mcp_latency_benchmark.dart', bench, cwd);
  final run = await Process.start(bench, [
    '--measure',
    '--engine',
    engine,
    '--ndjson',
    ndjson,
    '--mcp',
    mcp,
    if (args.contains('--quick')) '--quick',
  ], mode: ProcessStartMode.inheritStdio);
  exit(await run.exitCode);
}

class Stats {
  Stats(List<Duration> samples)
    : _us = samples.map((d) => d.inMicroseconds).toList()..sort();
  final List<int> _us;

  double _ms(int us) => us / 1000;
  double percentile(double p) =>
      _ms(_us[((_us.length - 1) * p).round().clamp(0, _us.length - 1)]);
  double get min => _ms(_us.first);
  double get max => _ms(_us.last);
  int get n => _us.length;
}

Future<void> _measure(List<String> args) async {
  String arg(String name) => args[args.indexOf(name) + 1];
  final engine = arg('--engine');
  final quick = args.contains('--quick');
  final plugins = PluginHost(
    supervisor: LimitedPluginSupervisor(engine: engine),
  );
  final root = Directory.systemTemp.createTempSync('mcp-latency');

  PluginLaunch launch(
    String exe,
    List<String> exeArgs,
    String digest, {
    String id = 'bench',
  }) => PluginLaunch(
    executable: exe,
    arguments: exeArgs,
    artifactSha256: digest,
    pluginId: id,
    version: '1.0.0',
    dataDirectory: root.path,
    workingDirectory: root.path,
    environment: PluginHost.buildEnvironment(),
    hostVersion: '1.4.0',
  );

  final request = PluginRunRequest(
    executeId: 'e1',
    prompt: 'hello',
    access: 'read_write',
    deadline: const Duration(seconds: 30),
  );
  final results = <String, Stats>{};

  Future<List<Duration>> time(int n, Future<void> Function() once) async {
    final out = <Duration>[];
    for (var i = 0; i < n; i++) {
      final clock = Stopwatch()..start();
      await once();
      out.add(clock.elapsed);
    }
    return out;
  }

  // 1. NDJSON: a new plugin process for every execute.
  final ndjsonPath = arg('--ndjson');
  final ndjsonDigest = await plugins.sha256OfFile(ndjsonPath);
  // The fixture identifies itself as `fixture-plugin`; the host checks it.
  final ndjsonLaunch = launch(
    ndjsonPath,
    ['--fault='],
    ndjsonDigest,
    id: 'fixture-plugin',
  );
  final ndjsonRuns = quick ? 10 : 40;
  final warm = await plugins.run(ndjsonLaunch, request); // untimed warm-up
  if (warm is! PluginRunSuccess) {
    throw StateError(
      'ndjson warm-up failed: ${warm is PluginRunFailure ? '${warm.code}: ${warm.message}' : warm}',
    );
  }
  results['NDJSON plugin, per execute (spawns)'] = Stats(
    await time(ndjsonRuns, () async {
      final outcome = await plugins.run(ndjsonLaunch, request);
      if (outcome is! PluginRunSuccess) throw StateError('ndjson: $outcome');
    }),
  );

  // What an assignment does in the Engine: a readiness probe, then the execute.
  // The NDJSON host starts the plugin for each of those calls.
  final probeRequest = PluginRunRequest.probe(
    executeId: 'p1',
    mode: 'passive',
    deadline: const Duration(seconds: 10),
  );
  results['NDJSON assignment (probe + execute = 2 spawns)'] = Stats(
    await time(ndjsonRuns, () async {
      final probe = await plugins.run(ndjsonLaunch, probeRequest);
      if (probe is! PluginProbeSuccess)
        throw StateError('ndjson probe: $probe');
      final outcome = await plugins.run(ndjsonLaunch, request);
      if (outcome is! PluginRunSuccess) throw StateError('ndjson: $outcome');
    }),
  );

  // 2/3/4. MCP.
  final mcpPath = arg('--mcp');
  final mcpDigest = await plugins.sha256OfFile(mcpPath);
  McpServerSpec spec([ToolPins? pins]) => McpServerSpec(
    serverId: 'bench',
    workspaceId: 'bench',
    requireWorkerProfile: true,
    pins: pins,
    launch: launch(mcpPath, const [], mcpDigest),
  );

  Future<ToolPins> pinsFor(McpHost host) async {
    final lease = await host.acquire(spec());
    final pins = ToolPins.fromTools(lease.tools);
    lease.release();
    return pins;
  }

  // Cold: a fresh host and server each time (the first run after enabling, or
  // after the idle server expired).
  final coldRuns = quick ? 10 : 40;
  final cold = <Duration>[];
  for (var i = 0; i < coldRuns + 1; i++) {
    final host = McpHost(pluginHost: plugins);
    final runner = McpWorkerRunner(host);
    // Consent is a one-time cost outside the measurement: pin from a probe host.
    final pinHost = McpHost(pluginHost: plugins);
    final pins = await pinsFor(pinHost);
    await pinHost.closeAll();
    final clock = Stopwatch()..start();
    final outcome = await runner.run(spec(pins), request);
    final elapsed = clock.elapsed;
    if (outcome is! PluginRunSuccess) throw StateError('mcp cold: $outcome');
    if (i > 0) cold.add(elapsed); // the first iteration is a warm-up
    await host.closeAll();
  }
  results['MCP cold (spawn + initialize + tools/list + call)'] = Stats(cold);

  // The same assignment on an MCP Worker: one spawn, the probe and the execute
  // share the connection. The pool lives and dies with the Engine process, which
  // the supervisor starts for each assignment.
  final assignmentPins = await () async {
    final h = McpHost(pluginHost: plugins);
    final p = await pinsFor(h);
    await h.closeAll();
    return p;
  }();
  final assignments = <Duration>[];
  for (var i = 0; i < ndjsonRuns + 1; i++) {
    final h = McpHost(pluginHost: plugins);
    final r = McpWorkerRunner(h);
    final clock = Stopwatch()..start();
    final probe = await r.probe(spec(assignmentPins), 'passive');
    if (probe is! PluginProbeSuccess) throw StateError('mcp probe: $probe');
    final outcome = await r.run(spec(assignmentPins), request);
    final elapsed = clock.elapsed;
    if (outcome is! PluginRunSuccess) throw StateError('mcp: $outcome');
    if (i > 0) assignments.add(elapsed);
    await h.closeAll();
  }
  results['MCP assignment (probe + execute = 1 spawn)'] = Stats(assignments);

  // Diagnostic: the same cold run without the limits wrapper (no Engine
  // re-exec around the plugin), to attribute the spawn cost.
  final plain = PluginHost();
  McpServerSpec plainSpec([ToolPins? pins]) => McpServerSpec(
    serverId: 'bench',
    workspaceId: 'bench',
    requireWorkerProfile: true,
    pins: pins,
    launch: launch(mcpPath, const [], mcpDigest),
  );
  final plainCold = <Duration>[];
  for (var i = 0; i < coldRuns + 1; i++) {
    final h = McpHost(pluginHost: plain);
    final r = McpWorkerRunner(h);
    final clock = Stopwatch()..start();
    final outcome = await r.run(plainSpec(assignmentPins), request);
    final elapsed = clock.elapsed;
    if (outcome is! PluginRunSuccess) throw StateError('plain cold: $outcome');
    if (i > 0) plainCold.add(elapsed);
    await h.closeAll();
  }
  results['MCP cold, no limits wrapper (diagnostic)'] = Stats(plainCold);

  // Warm: the server is already running.
  final host = McpHost(pluginHost: plugins);
  final runner = McpWorkerRunner(host);
  final pins = await pinsFor(host);
  final warmRuns = quick ? 100 : 500;
  for (var i = 0; i < 20; i++) {
    await runner.run(spec(pins), request); // untimed warm-up
  }
  results['MCP warm, per execute (pooled server)'] = Stats(
    await time(warmRuns, () async {
      final outcome = await runner.run(spec(pins), request);
      if (outcome is! PluginRunSuccess) throw StateError('mcp warm: $outcome');
    }),
  );

  // Pure protocol: one JSON-RPC round trip, no tool call.
  final lease = await host.acquire(spec(pins));
  final pings = quick ? 300 : 2000;
  for (var i = 0; i < 50; i++) {
    await lease.client.ping();
  }
  results['MCP ping (JSON-RPC round trip)'] = Stats(
    await time(pings, () => lease.client.ping()),
  );
  lease.release();
  await host.closeAll();

  stdout.writeln('');
  stdout.writeln('| Path | n | p50 ms | p95 ms | min ms | max ms |');
  stdout.writeln('| --- | ---: | ---: | ---: | ---: | ---: |');
  for (final e in results.entries) {
    final s = e.value;
    stdout.writeln(
      '| ${e.key} | ${s.n} | ${s.percentile(0.5).toStringAsFixed(2)} | '
      '${s.percentile(0.95).toStringAsFixed(2)} | ${s.min.toStringAsFixed(2)} | '
      '${s.max.toStringAsFixed(2)} |',
    );
  }
  stdout.writeln('');
  stdout.writeln(
    'host: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}, '
    '${Platform.numberOfProcessors} cores, ${jsonEncode(Platform.version.split(' ').first)}',
  );
  root.deleteSync(recursive: true);
}
