import 'package:nanomarkup/nanomarkup.dart' as nano;

import 'workspace_registration_models.dart';

/// GUI Manifest versions this CLI can produce (gui-manifest spec §1).
const _supportedGuiManifestVersions = <int>[1];

/// Outcome of `syntila --gui-manifest[=N]`: [document] on success,
/// otherwise [error] for stderr (exit 2).
typedef GuiManifestResponse = ({String? document, String? error});

/// True when [args] is exactly one `--gui-manifest` request.
bool isGuiManifestRequest(List<String> args) =>
    args.length == 1 &&
    (args.single == '--gui-manifest' ||
        args.single.startsWith('--gui-manifest='));

/// Negotiates the version for [arg] and returns the Nano Markup manifest.
GuiManifestResponse guiManifestResponse(String arg) {
  final raw =
      arg == '--gui-manifest' ? '1' : arg.substring('--gui-manifest='.length);
  if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(raw)) {
    return (document: null, error: 'invalid manifest version "$raw"');
  }
  final requested = int.parse(raw);
  final usable = _supportedGuiManifestVersions.where((v) => v <= requested);
  if (usable.isEmpty) {
    return (
      document: null,
      error: 'manifest version $requested is not supported; '
          'supported: ${_supportedGuiManifestVersions.join(', ')}',
    );
  }
  return (document: nano.encode(workspaceGuiManifest()), error: null);
}

/// The v1 manifest tree. Keep in sync with the CLI dispatch and help text
/// in `workspace_cli.dart`; `workspace_gui_manifest_test.dart` routes every
/// service-backed argv through the CLI.
Map<String, Object> workspaceGuiManifest() => {
      'manifestVersion': '1',
      'cli': {
        'name': 'syntila',
        'version': syntilaWorkspaceAppVersion,
        'displayName': 'Syntila Workspace',
        'description': 'Machine-side execution and security runtime',
      },
      'navigation': [
        _nav('status', 'Status', 'pulse', 'status'),
        _nav('workers', 'Workers', 'cpu', 'workers.list'),
        _nav('folders', 'Folders', 'folder', 'folders.list'),
        _nav('assignments', 'Assignments', 'tasks', 'assignments.list'),
        _nav('logs', 'Logs', 'log', 'logs'),
        _nav('service', 'Service', 'server', 'service.status'),
      ],
      'commands': [
        _cmd('status', ['status'], 'Status', 'Service summary',
            view: 'keyValue'),
        _cmd('version', ['version'], 'Version', 'Show the version',
            view: 'keyValue'),
        _cmd('setup', ['setup'], 'Set up',
            'Start service, sign in and connect (headless)',
            interactive: true, longRunning: true, view: 'raw'),
        _cmd('login', ['login'], 'Sign in',
            'Sign in with Cloud email and password (does not register)',
            interactive: true, view: 'raw'),
        _cmd('logout', ['logout'], 'Sign out',
            'Delete the stored sign-in session on this computer',
            destructive: true, view: 'raw'),
        _cmd('register', ['register'], 'Register',
            'Register this Workspace with Cloud (after login)',
            view: 'keyValue'),
        _cmd('unregister', ['unregister'], 'Unregister',
            'Unregister workspace from Cloud and clear local identity',
            destructive: true, view: 'keyValue'),
        _cmd('connect', ['connect'], 'Connect', 'Connect to Cloud',
            view: 'keyValue'),
        _cmd(
            'disconnect', ['disconnect'], 'Disconnect', 'Disconnect from Cloud',
            view: 'keyValue'),
        _cmd('pause', ['pause'], 'Pause', 'Stop accepting new work',
            view: 'keyValue'),
        _cmd('resume', ['resume'], 'Resume', 'Resume accepting new work',
            view: 'keyValue'),
        _cmd('workers.list', ['workers'], 'Workers', 'List configured Workers',
            view: 'table'),
        _cmd('workers.catalog', ['workers', 'catalog'], 'Worker catalog',
            'List available catalog Workers',
            view: 'table'),
        _cmd('workers.add', ['workers', 'add'], 'Add Worker',
            'Add a Worker from the catalog (e.g. gemini)',
            params: [_workerType], view: 'keyValue'),
        _cmd('workers.remove', ['workers', 'remove'], 'Remove Worker',
            'Remove a configured Worker',
            params: [_workerType], destructive: true, view: 'keyValue'),
        _cmd('workers.check', ['workers', 'check'], 'Check Workers',
            'Check provider CLI readiness',
            params: [_optionalWorkerType], longRunning: true, view: 'table'),
        _cmd('workers.test', ['workers', 'test'], 'Test Worker',
            'Run a Worker test',
            params: [_workerType], longRunning: true, view: 'keyValue'),
        _cmd('workers.enable', ['workers', 'enable'], 'Enable Worker',
            'Enable a Worker',
            params: [_workerType], view: 'keyValue'),
        _cmd('workers.disable', ['workers', 'disable'], 'Disable Worker',
            'Disable a Worker',
            params: [_workerType], view: 'keyValue'),
        _cmd('folders.list', ['folders', 'list'], 'Folders',
            'List allowed Space folders',
            view: 'table'),
        _cmd('folders.add', ['folders', 'add'], 'Add folder',
            'Add an allowed Space folder',
            params: [
              _param('path', 'positional', 'path',
                  required: true, label: 'Folder'),
              _param('name', 'option', 'string', label: 'Name'),
            ],
            view: 'keyValue'),
        _cmd('folders.remove', ['folders', 'remove'], 'Remove folder',
            'Remove an allowed Space folder',
            params: [
              _param('id', 'positional', 'string',
                  required: true, label: 'Folder ID'),
            ],
            destructive: true,
            view: 'keyValue'),
        _cmd('workDir', ['work-dir'], 'Work Root',
            'View or update the Work Root directory',
            params: [_param('path', 'positional', 'path', label: 'New path')],
            view: 'keyValue'),
        _cmd('slots', ['slots'], 'Slots', 'Parallel execution slots',
            view: 'keyValue'),
        _cmd('assignments.list', ['assignments'], 'Assignments',
            'Active assignment ids',
            view: 'table'),
        _cmd('assignments.cancel', ['assignments', 'cancel'],
            'Cancel assignment', 'Cancel an active assignment',
            params: [
              _param('id', 'positional', 'string',
                  required: true, label: 'Assignment ID'),
            ],
            destructive: true,
            view: 'keyValue'),
        _cmd('logs', ['logs'], 'Logs', 'Recent service logs', view: 'log'),
        _cmd('metrics', ['metrics'], 'Metrics', 'Service metrics',
            view: 'keyValue'),
        for (final action in ['status', 'install', 'start', 'stop', 'restart'])
          _cmd('service.$action', ['service', action], 'Service $action',
              'Manage the host background service',
              longRunning: action != 'status', view: 'keyValue'),
        _cmd('service.uninstall', ['service', 'uninstall'], 'Service uninstall',
            'Remove the host background service',
            destructive: true, view: 'keyValue'),
        for (final action in ['show', 'validate', 'path', 'init'])
          _cmd('config.$action', ['config', action], 'Config $action',
              'Manage the restart-applied workspace.nano file',
              view: 'keyValue'),
        _cmd('reset', ['reset'], 'Reset',
            'Stop service, unregister and erase local runtime state',
            destructive: true, longRunning: true, view: 'keyValue'),
      ],
    };

final _workerType = _param('type', 'positional', 'string',
    required: true, label: 'Worker type');
final _optionalWorkerType =
    _param('type', 'positional', 'string', label: 'Worker type');

Map<String, Object> _nav(
        String id, String label, String icon, String command) =>
    {'id': id, 'label': label, 'icon': icon, 'command': command};

Map<String, Object> _param(String name, String kind, String type,
        {bool required = false, String? label}) =>
    {
      'name': name,
      'kind': kind,
      'type': type,
      if (required) 'required': 'true',
      if (label != null) 'label': label,
    };

/// Every command is run with `--json`; its output is JSON.
Map<String, Object> _cmd(
  String id,
  List<String> argv,
  String title,
  String description, {
  required String view,
  List<Map<String, Object>> params = const [],
  bool destructive = false,
  bool interactive = false,
  bool longRunning = false,
}) =>
    {
      'id': id,
      'argv': [...argv, '--json'],
      'title': title,
      'description': description,
      if (destructive) 'destructive': 'true',
      if (interactive) 'interactive': 'true',
      if (longRunning) 'longRunning': 'true',
      if (params.isNotEmpty) 'parameters': params,
      'output': {'format': 'json', 'view': view},
    };
