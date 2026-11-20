import 'package:syntila_connect/syntila_connect.dart';

class RecordingRunner implements CommandRunner {
  final List<List<String>> calls = [];
  final List<Map<String, String>> environments = [];
  int exitCode = 0;
  String stdout = '';

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) async {
    calls.add([executable, ...arguments]);
    environments.add(environment);
    return CommandResult(exitCode, stdout);
  }
}
