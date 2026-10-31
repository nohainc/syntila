part of 'workspace_cli.dart';

/// Every command the `syntila` CLI accepts, declared once.
///
/// The same declaration drives argument parsing (`package:args`), `--help`
/// and `--gui-manifest`. Handlers call the CLI's existing implementations.
/// Commands outside the first-run set (`config`, `reset`, `setup`, `status`,
/// `version`) stay out of `--help` until `workspace.nano` exists, but always
/// run and always appear in the GUI manifest.
CliSpec _buildWorkspaceSpec(WorkspaceCli cli) {
  String? dataDir(CliInvocation run) => run.globalOption('data-dir');
  bool json(CliInvocation run) => run.globalFlag('json');
  bool showMore() => cli._showAllCommands();

  /// Sends [ipc] to the running service. [payload] builds the request; with
  /// [byWorkerType] the positional `type` is resolved to a Worker ID first.
  CliHandler service(
    String ipc, {
    Map<String, Object?> Function(CliInvocation run)? payload,
    bool byWorkerType = false,
  }) =>
      (run) => cli._runService(
            dataDir(run),
            json(run),
            ipc,
            payload?.call(run) ?? const {},
            workerType: byWorkerType ? run.positional('type') : null,
          );

  CliCommand command(
    String name,
    String title,
    String description,
    CliHandler handler, {
    List<GuiParameter> parameters = const [],
    GuiView view = GuiView.keyValue,
    bool destructive = false,
    bool interactive = false,
    bool longRunning = false,
    bool firstRun = false,
    bool inGroup = false,
    String? icon,
    bool navigation = false,
  }) =>
      CliCommand(
        name: name,
        title: title,
        description: description,
        handler: handler,
        parameters: parameters,
        output: GuiOutput(format: GuiFormat.json, view: view),
        destructive: destructive,
        interactive: interactive,
        longRunning: longRunning,
        icon: icon,
        navigation: navigation,
        // Group members follow their group's visibility.
        visible: firstRun || inGroup ? null : showMore,
      );

  CliGroup group(
    String name,
    String title,
    String description,
    List<CliNode> children, {
    String? defaultCommand,
    String? navigationCommand,
    String? icon,
    bool navigation = false,
    bool firstRun = false,
  }) =>
      CliGroup(
        name: name,
        title: title,
        description: description,
        children: children,
        defaultCommand: defaultCommand,
        navigationCommand: navigationCommand,
        icon: icon,
        navigation: navigation,
        visible: firstRun ? null : showMore,
      );

  const workerType = GuiParameter(
    name: 'type',
    kind: GuiParamKind.positional,
    type: GuiParamType.string,
    required: true,
    label: 'Worker type',
  );
  const optionalWorkerType = GuiParameter(
    name: 'type',
    kind: GuiParamKind.positional,
    type: GuiParamType.string,
    label: 'Worker type',
  );

  CliCommand workerAction(
    String name,
    String title,
    String description,
    String ipc, {
    bool destructive = false,
    bool longRunning = false,
  }) =>
      command(
        name,
        title,
        description,
        service(
          ipc,
          payload: (run) => {'workerId': run.positional('type')},
          byWorkerType: true,
        ),
        parameters: const [workerType],
        destructive: destructive,
        longRunning: longRunning,
        inGroup: true,
      );

  CliCommand serviceAction(
    String action,
    String title,
    String description, {
    bool destructive = false,
    bool longRunning = true,
  }) =>
      command(
        action,
        title,
        description,
        (run) => cli._service(dataDir(run), action, json(run)),
        destructive: destructive,
        longRunning: longRunning,
        inGroup: true,
      );

  CliCommand configAction(String action, String title, String description) =>
      command(
        action,
        title,
        description,
        (run) => cli._config(dataDir(run), action, json(run)),
        firstRun: true,
        inGroup: true,
      );

  return CliSpec(
    name: 'syntila',
    displayName: 'Syntila Workspace',
    description: 'Machine-side execution and security runtime',
    version: syntilaWorkspaceAppVersion,
    usageBuilder: (_) => cli._usageText(),
    globals: const [
      GuiParameter(
        name: 'data-dir',
        kind: GuiParamKind.option,
        type: GuiParamType.path,
        label: 'Data directory',
        help: 'Use this Workspace state directory.',
      ),
      GuiParameter(
        name: 'json',
        kind: GuiParamKind.flag,
        type: GuiParamType.boolean,
        help: 'Print machine-readable JSON.',
      ),
    ],
    nodes: [
      command(
        'status',
        'Status',
        'Service summary',
        service('service.getStatus'),
        firstRun: true,
        icon: 'pulse',
        navigation: true,
      ),
      command(
        'version',
        'Version',
        'Show the version',
        service('service.getVersion'),
        firstRun: true,
      ),
      command(
        'setup',
        'Set up',
        'Start service, sign in and connect (headless)',
        (run) => cli._setup(dataDir(run), json(run)),
        view: GuiView.raw,
        interactive: true,
        longRunning: true,
        firstRun: true,
      ),
      command(
        'login',
        'Sign in',
        'Sign in with Cloud email and password (does not register)',
        (run) => cli._login(dataDir(run), json(run)),
        // Older scripts pass `login --password`; the password is always asked.
        parameters: const [
          GuiParameter(
            name: 'password',
            kind: GuiParamKind.flag,
            type: GuiParamType.boolean,
            hidden: true,
          ),
        ],
        view: GuiView.raw,
        interactive: true,
      ),
      command(
        'logout',
        'Sign out',
        'Delete the stored sign-in session on this computer',
        (run) => cli._logout(dataDir(run), json(run)),
        view: GuiView.raw,
        destructive: true,
      ),
      command(
        'register',
        'Register',
        'Register this Workspace with Cloud (after login)',
        (run) => cli._register(dataDir(run), json(run)),
      ),
      command(
        'unregister',
        'Unregister',
        'Unregister workspace from Cloud and clear local identity',
        (run) => cli._unregister(dataDir(run), json(run)),
        destructive: true,
      ),
      command(
        'connect',
        'Connect',
        'Connect to Cloud',
        service('connection.connect'),
      ),
      command(
        'disconnect',
        'Disconnect',
        'Disconnect from Cloud',
        service('connection.disconnect'),
      ),
      command(
        'pause',
        'Pause',
        'Stop accepting new work',
        service('connection.pause'),
      ),
      command(
        'resume',
        'Resume',
        'Resume accepting new work',
        service('connection.resume'),
      ),
      group(
        'workers',
        'Workers',
        'Manage the Workers that run assignments',
        defaultCommand: 'list',
        icon: 'cpu',
        navigation: true,
        [
          command(
            'list',
            'Workers',
            'List configured Workers',
            service('workers.list'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            'catalog',
            'Worker catalog',
            'List available catalog Workers',
            service('workers.getCatalogSnapshot'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            'add',
            'Add Worker',
            'Add a Worker from the catalog (e.g. gemini)',
            service(
              'workers.configureWorker',
              payload: (run) => {'workerTypeId': run.positional('type')},
            ),
            parameters: const [workerType],
            inGroup: true,
          ),
          workerAction(
            'remove',
            'Remove Worker',
            'Remove a configured Worker',
            'workers.removeWorker',
            destructive: true,
          ),
          command(
            'check',
            'Check Workers',
            'Check provider CLI readiness',
            service(
              'workers.checkReadiness',
              payload: (run) {
                final type = run.positional('type');
                return {if (type != null) 'workerTypeId': type};
              },
            ),
            parameters: const [optionalWorkerType],
            view: GuiView.table,
            longRunning: true,
            inGroup: true,
          ),
          workerAction(
            'test',
            'Test Worker',
            'Run a Worker test',
            'workers.testWorker',
            longRunning: true,
          ),
          workerAction(
            'enable',
            'Enable Worker',
            'Enable a Worker',
            'workers.enableWorker',
          ),
          workerAction(
            'disable',
            'Disable Worker',
            'Disable a Worker',
            'workers.disableWorker',
          ),
        ],
      ),
      group(
        'folders',
        'Folders',
        'Manage the folders Spaces may use',
        defaultCommand: 'list',
        icon: 'folder',
        navigation: true,
        [
          command(
            'list',
            'Folders',
            'List allowed Space folders',
            service('folders.list'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            'add',
            'Add folder',
            'Add an allowed Space folder',
            (run) => cli._foldersAdd(
              dataDir(run),
              json(run),
              run.positional('path')!,
              run.option('name'),
            ),
            parameters: const [
              GuiParameter(
                name: 'path',
                kind: GuiParamKind.positional,
                type: GuiParamType.path,
                required: true,
                label: 'Folder',
              ),
              GuiParameter(
                name: 'name',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label: 'Name',
              ),
            ],
            inGroup: true,
          ),
          command(
            'remove',
            'Remove folder',
            'Remove an allowed Space folder',
            (run) => cli._foldersRemove(
              dataDir(run),
              json(run),
              run.positional('id')!,
            ),
            parameters: const [
              GuiParameter(
                name: 'id',
                kind: GuiParamKind.positional,
                type: GuiParamType.string,
                required: true,
                label: 'Folder ID',
              ),
            ],
            destructive: true,
            inGroup: true,
          ),
        ],
      ),
      command(
        'work-dir',
        'Work Root',
        'View or update the Work Root directory',
        (run) => cli._workDir(
          dataDir(run),
          [
            if (run.positional('path') != null) run.positional('path')!,
          ],
          json(run),
        ),
        parameters: const [
          GuiParameter(
            name: 'path',
            kind: GuiParamKind.positional,
            type: GuiParamType.path,
            label: 'New path',
          ),
        ],
      ),
      command(
        'slots',
        'Slots',
        'Parallel execution slots',
        service('execution.getSlots'),
      ),
      group(
        'assignments',
        'Assignments',
        'Inspect and cancel running assignments',
        defaultCommand: 'list',
        icon: 'tasks',
        navigation: true,
        [
          command(
            'list',
            'Assignments',
            'Active assignment ids',
            service('execution.listActiveAssignments'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            'cancel',
            'Cancel assignment',
            'Cancel an active assignment',
            service(
              'execution.cancelAssignment',
              payload: (run) => {'assignmentId': run.positional('id')},
            ),
            parameters: const [
              GuiParameter(
                name: 'id',
                kind: GuiParamKind.positional,
                type: GuiParamType.string,
                required: true,
                label: 'Assignment ID',
              ),
            ],
            destructive: true,
            inGroup: true,
          ),
        ],
      ),
      command(
        'logs',
        'Logs',
        'Recent service logs',
        service('diagnostics.getLogs'),
        view: GuiView.log,
        icon: 'log',
        navigation: true,
      ),
      command(
        'metrics',
        'Metrics',
        'Service metrics',
        service('diagnostics.getMetrics'),
      ),
      group(
        'service',
        'Service',
        'Manage the host background service (macOS/Linux/Windows)',
        navigationCommand: 'status',
        icon: 'server',
        navigation: true,
        [
          serviceAction(
            'status',
            'Service status',
            'Show whether the service is installed and running',
            longRunning: false,
          ),
          serviceAction(
            'install',
            'Install service',
            'Install the host background service',
          ),
          serviceAction(
            'uninstall',
            'Uninstall service',
            'Remove the host background service',
            destructive: true,
            longRunning: false,
          ),
          serviceAction('start', 'Start service', 'Start the service'),
          serviceAction('stop', 'Stop service', 'Stop the service'),
          serviceAction('restart', 'Restart service', 'Restart the service'),
        ],
      ),
      group(
        'config',
        'Config',
        'Manage the restart-applied workspace.nano file',
        firstRun: true,
        [
          configAction(
            'init',
            'Create config',
            'Create workspace.nano with defaults if it is missing',
          ),
          configAction('show', 'Show config', 'Show workspace.nano'),
          configAction(
            'validate',
            'Validate config',
            'Check that workspace.nano is valid',
          ),
          configAction('path', 'Config path', 'Print the workspace.nano path'),
        ],
      ),
      command(
        'reset',
        'Reset',
        'Stop service, unregister and erase local runtime state',
        (run) => cli._reset(dataDir(run), json(run)),
        destructive: true,
        longRunning: true,
        firstRun: true,
      ),
    ],
  );
}
