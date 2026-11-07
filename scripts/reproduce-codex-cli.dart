import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Diagnostic-only invocation of Codex, outside the Syntila Service/Engine.
/// Raw evidence may contain private prompt/response content; keep it local.
Future<void> main(List<String> arguments) async {
  final options = <String, String>{};
  for (var index = 0; index < arguments.length; index += 2) {
    if (!arguments[index].startsWith('--') || index + 1 == arguments.length) {
      throw ArgumentError('Expected --option value pairs');
    }
    options[arguments[index].substring(2)] = arguments[index + 1];
  }
  String requiredOption(String key) =>
      options[key] ?? (throw ArgumentError('Missing --$key'));
  final prompt = await File(requiredOption('prompt-file')).readAsBytes();
  final workDirectory = Directory(requiredOption('work-directory')).absolute;
  final evidence = Directory(requiredOption('output-directory')).absolute;
  // Do not overwrite evidence from an earlier run.
  if (await evidence.exists()) {
    throw ArgumentError('Output directory already exists: ${evidence.path}');
  }
  await evidence.create(recursive: true);
  final executable = options['executable'] ?? 'codex';
  final profile = jsonDecode(
    await File(requiredOption('profile-file')).readAsString(),
  ) as Map<String, dynamic>;
  final policy = options['sandbox-policy'] ?? 'restricted';
  final context = <String, String>{
    'workingDirectory': workDirectory.path,
    'sessionPolicy': options['session-id'] == null ? 'stateless' : 'durable',
    if (options['model'] != null) 'model': options['model']!,
    if (options['reasoning-effort'] != null)
      'reasoningEffort': options['reasoning-effort']!,
    if (options['session-id'] != null) 'sessionId': options['session-id']!,
  };
  String expand(String template) => template.replaceAllMapped(
    RegExp(r'\{\{([A-Za-z]+)\}\}'),
    (match) =>
        context[match[1]] ??
        (throw ArgumentError('Missing template value ${match[1]}')),
  );
  final providerArguments = <String>[];
  void append(dynamic values) {
    providerArguments.addAll((values as List).cast<String>().map(expand));
  }

  for (final argument in profile['execution']['arguments'] as List) {
    if (argument is String) {
      providerArguments.add(expand(argument));
    } else if (argument['sandboxPolicyMapping'] == true) {
      append(profile['sandbox']['mappings'][policy]);
    } else if (argument['modelArguments'] == true) {
      if (context.containsKey('model')) append(profile['model']['arguments']);
    } else if (argument['sessionResumeArguments'] == true) {
      if (context.containsKey('sessionId')) {
        append(profile['session']['resumeArguments']);
      }
    } else if (argument['providerTimeoutArguments'] == true) {
      final values = profile['timeout']['providerArguments'] as List;
      if (values.isNotEmpty) {
        throw ArgumentError('This harness expects no provider timeout flags');
      }
    } else if (argument['ifPresent'] != null) {
      if (context.containsKey(argument['ifPresent']))
        append(argument['values']);
    } else if (argument['ifAbsent'] != null) {
      if (!context.containsKey(argument['ifAbsent']) &&
          argument['ifSessionPolicy'] == context['sessionPolicy']) {
        append(argument['values']);
      }
    } else {
      throw ArgumentError('Unsupported argument marker');
    }
  }
  if (profile['execution']['stdin']['mode'] != 'raw_text' ||
      profile['execution']['stdin']['value'] != '{{prompt}}' ||
      providerArguments.last != '-') {
    throw ArgumentError('Expected raw prompt stdin and a final - argument');
  }
  final environment = <String, String>{};
  for (final key in profile['environment']['passthrough'] as List) {
    final value = Platform.environment[key];
    if (value != null) environment[key as String] = value;
  }
  environment.addAll(
    (profile['environment']['set'] as Map).cast<String, String>(),
  );
  final summary = <String, Object?>{
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'executable': executable,
    'arguments': providerArguments,
    'promptBytes': prompt.length,
    'promptTransport': 'stdin',
    'workingDirectory': workDirectory.path,
    'profileDefinitionId': profile['profileDefinitionId'],
    'timeoutSeconds': 0,
    'note': 'Direct CLI diagnostic; does not verify Service or Cloud transport',
  };
  final clock = Stopwatch()..start();
  final stdoutFile = File('${evidence.path}/stdout.jsonl').openWrite();
  final stderrFile = File('${evidence.path}/stderr.txt').openWrite();
  final finalFile = File('${evidence.path}/final-response.txt');
  final eventCounts = <String, int>{};
  var malformedLines = 0;
  String? finalResponse;
  try {
    final process = await Process.start(
      executable,
      providerArguments,
      workingDirectory: workDirectory.path,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    summary['pid'] = process.pid;
    stdout.writeln(
      'Started Codex pid=${process.pid}; prompt=${prompt.length} bytes',
    );
    final outputTask = () async {
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        stdoutFile.writeln(line);
        try {
          final event = jsonDecode(line) as Map<String, dynamic>;
          final type = event['type'] as String? ?? 'unknown';
          eventCounts.update(type, (count) => count + 1, ifAbsent: () => 1);
          stdout.writeln('${clock.elapsedMilliseconds}ms $type');
          final item = event['item'];
          if (type == 'item.completed' &&
              item is Map &&
              item['type'] == 'agent_message' &&
              item['text'] is String) {
            finalResponse = item['text'] as String;
          }
        } on Object {
          malformedLines++;
        }
      }
    }();
    final errorTask = stderrFile.addStream(process.stderr);
    final inputTask = () async {
      try {
        process.stdin.add(prompt);
        await process.stdin.close();
        summary['stdinDelivered'] = true;
      } on Object catch (error) {
        summary['stdinError'] = error.toString();
      }
    }();
    summary['exitCode'] = await process.exitCode;
    await Future.wait([inputTask, outputTask, errorTask]);
    if (finalResponse != null) {
      await File('${evidence.path}/last-agent-message.txt')
          .writeAsString(finalResponse!);
      if (eventCounts.containsKey('turn.completed')) {
        await finalFile.writeAsString(finalResponse!);
      }
    }
  } on Object catch (error) {
    summary['harnessError'] = error.toString();
  } finally {
    await stdoutFile.close();
    await stderrFile.close();
    summary.addAll({
      'durationMs': clock.elapsedMilliseconds,
      'eventCounts': eventCounts,
      'malformedLines': malformedLines,
      'turnCompleted': eventCounts.containsKey('turn.completed'),
      'finalResponsePresent':
          finalResponse != null && eventCounts.containsKey('turn.completed'),
    });
    final json = const JsonEncoder.withIndent('  ').convert(summary);
    await File('${evidence.path}/summary.json').writeAsString('$json\n');
    stdout.writeln(json);
    stdout.writeln('Evidence: ${evidence.path}');
  }
  if (summary['exitCode'] != 0 ||
      summary['harnessError'] != null ||
      summary['stdinError'] != null ||
      finalResponse == null ||
      !eventCounts.containsKey('turn.completed')) {
    exitCode = 1;
  }
}
