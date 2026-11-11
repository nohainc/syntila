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
    GuiFormat format = GuiFormat.text,
    bool destructive = false,
    bool interactive = false,
    bool longRunning = false,
    bool firstRun = false,
    bool inGroup = false,
    String? icon,
    bool navigation = false,
    bool info = false,
  }) =>
      CliCommand(
        name: name,
        title: title,
        description: description,
        handler: handler,
        parameters: parameters,
        output: GuiOutput(format: format, view: GuiView.raw),
        destructive: destructive,
        interactive: interactive,
        longRunning: longRunning,
        icon: icon,
        navigation: navigation,
        kind: info ? GuiCommandKind.info : GuiCommandKind.action,
        section: switch (name) {
          'setup' || 'work-dir' || 'reset' => 'WORKSPACE',
          'login' ||
          'logout' ||
          'register' ||
          'unregister' ||
          'connect' ||
          'disconnect' ||
          'pause' ||
          'resume' =>
            'ACCOUNT & CLOUD',
          'metrics' || 'version' || 'logs' || 'slots' => 'DIAGNOSTICS',
          _ => null,
        },
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
    String? section,
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
        section: section,
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

  const mcpServerId = <GuiParameter>[
    GuiParameter(
      name: 'id',
      kind: GuiParamKind.positional,
      type: GuiParamType.string,
      required: true,
      label: 'Server ID',
    ),
  ];
  const externalWorkerId = GuiParameter(
    name: 'id',
    kind: GuiParamKind.positional,
    type: GuiParamType.string,
    required: true,
    label: 'External Worker ID',
  );
  const acceptConsent = GuiParameter(
    name: 'accept',
    kind: GuiParamKind.option,
    type: GuiParamType.string,
    label: 'Accept the consent document with this hash',
  );

  CliCommand workerAction(
    String name,
    String title,
    String description,
    String ipc, {
    String? icon,
    bool info = false,
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
        icon: icon,
        info: info,
        destructive: destructive,
        longRunning: longRunning,
        inGroup: true,
      );

  CliCommand serviceAction(
    String action,
    String title,
    String description, {
    String? icon,
    bool info = false,
    bool destructive = false,
    bool longRunning = true,
  }) =>
      command(
        action,
        title,
        description,
        (run) => cli._service(dataDir(run), action, json(run)),
        icon: icon,
        info: info,
        destructive: destructive,
        longRunning: longRunning,
        inGroup: true,
      );

  CliCommand configAction(
    String action,
    String title,
    String description, {
    required String icon,
    bool info = false,
  }) =>
      command(
        action,
        title,
        description,
        (run) => cli._config(dataDir(run), action, json(run)),
        icon: icon,
        info: info,
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
        icon: GuiIcons.pulse,
        info: true,
        'status',
        'Status',
        'Service summary',
        service('service.getStatus'),
        firstRun: true,
        navigation: true,
      ),
      command(
        icon: GuiIcons.rocket,
        'setup',
        'Set up',
        'Start service, sign in and connect (headless)',
        (run) => cli._setup(dataDir(run), json(run),
            workspaceName: run.option('name'),
            email: run.option('email'),
            passwordStdin: run.flag('password-stdin')),
        parameters: const [
          GuiParameter(
              name: 'name',
              kind: GuiParamKind.option,
              type: GuiParamType.string,
              label: 'Workspace name'),
          GuiParameter(
              name: 'email',
              kind: GuiParamKind.option,
              type: GuiParamType.string,
              label: 'Email'),
          GuiParameter(
              name: 'password-input',
              kind: GuiParamKind.option,
              type: GuiParamType.secret,
              label: 'Password',
              required: true,
              stdinFlag: 'password-stdin'),
          GuiParameter(
              name: 'password-stdin',
              kind: GuiParamKind.flag,
              type: GuiParamType.boolean,
              hidden: true),
        ],
        view: GuiView.raw,
        longRunning: true,
        firstRun: true,
      ),
      command(
        icon: GuiIcons.login,
        'login',
        'Sign in',
        'Sign in with Cloud email and password (does not register)',
        (run) => cli._login(dataDir(run), json(run),
            email: run.option('email'),
            passwordStdin: run.flag('password-stdin')),
        // Older scripts pass `login --password`; the password is always asked.
        parameters: const [
          GuiParameter(
              name: 'email',
              kind: GuiParamKind.option,
              type: GuiParamType.string,
              label: 'Email'),
          GuiParameter(
              name: 'password-input',
              kind: GuiParamKind.option,
              type: GuiParamType.secret,
              label: 'Password',
              required: true,
              stdinFlag: 'password-stdin'),
          GuiParameter(
              name: 'password-stdin',
              kind: GuiParamKind.flag,
              type: GuiParamType.boolean,
              hidden: true),
          GuiParameter(
            name: 'password',
            kind: GuiParamKind.flag,
            type: GuiParamType.boolean,
            hidden: true,
          ),
        ],
        view: GuiView.raw,
      ),
      command(
        icon: GuiIcons.logout,
        'logout',
        'Sign out',
        'Delete the stored sign-in session on this computer',
        (run) => cli._logout(dataDir(run), json(run)),
        view: GuiView.raw,
        destructive: true,
      ),
      command(
        icon: GuiIcons.id,
        'register',
        'Register',
        'Register this Workspace with Cloud (after login)',
        (run) => cli._register(dataDir(run), json(run)),
      ),
      command(
        icon: GuiIcons.unlink,
        'unregister',
        'Unregister',
        'Unregister workspace from Cloud and clear local identity',
        (run) => cli._unregister(dataDir(run), json(run)),
        destructive: true,
      ),
      command(
        icon: GuiIcons.cloud,
        'connect',
        'Connect',
        'Connect to Cloud',
        service('connection.connect'),
        longRunning: true,
      ),
      command(
        icon: GuiIcons.cloudOff,
        'disconnect',
        'Disconnect',
        'Disconnect from Cloud',
        service('connection.disconnect'),
      ),
      command(
        icon: GuiIcons.pause,
        'pause',
        'Pause',
        'Stop accepting new work',
        service('connection.pause'),
      ),
      command(
        icon: GuiIcons.play,
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
        icon: GuiIcons.cpu,
        navigation: true,
        [
          command(
            icon: GuiIcons.list,
            info: true,
            'list',
            'Workers',
            'List configured Workers',
            service('workers.list'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.package,
            info: true,
            'catalog',
            'Worker catalog',
            'List available catalog Workers',
            service('workers.getCatalogSnapshot'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.plus,
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
          command(
            icon: GuiIcons.trash,
            'remove',
            'Remove Worker',
            'Remove a configured Worker or an External Worker package',
            (run) => cli._runWorkerLifecycle(
                dataDir(run), json(run), 'remove', run.positional('type')!),
            parameters: const [workerType],
            destructive: true,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.check,
            info: true,
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
            icon: GuiIcons.test,
            'test',
            'Test Worker',
            'Run a Worker test',
            'workers.testWorker',
            longRunning: true,
          ),
          command(
            icon: GuiIcons.power,
            'enable',
            'Enable Worker',
            'Enable a Worker; an External Worker shows a consent document first',
            (run) => cli._runWorkerLifecycle(
              dataDir(run),
              json(run),
              'enable',
              run.positional('type')!,
              acceptHash: run.option('accept'),
            ),
            parameters: const [workerType, acceptConsent],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.stop,
            'disable',
            'Disable Worker',
            'Disable a Worker',
            (run) => cli._runWorkerLifecycle(
                dataDir(run), json(run), 'disable', run.positional('type')!),
            parameters: const [workerType],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.server,
            info: true,
            'external',
            'External Workers',
            'List imported External Worker packages and their state',
            service('externalWorkers.list'),
            inGroup: true,
          ),
          command(
            icon: GuiIcons.package,
            'import',
            'Import External Worker',
            'Import an External Worker package (directory or .zip); nothing runs yet',
            service(
              'externalWorkers.import',
              payload: (run) =>
                  {'path': File(run.positional('path')!).absolute.path},
            ),
            parameters: const [
              GuiParameter(
                name: 'path',
                kind: GuiParamKind.positional,
                type: GuiParamType.path,
                required: true,
                label: 'Package directory or .zip',
              ),
            ],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.test,
            'inspect',
            'Inspect External Worker',
            'Start the package, check its MCP Worker tools and pin their definitions',
            service(
              'externalWorkers.test',
              payload: (run) => {'externalWorkerId': run.positional('id')},
            ),
            parameters: const [externalWorkerId],
            longRunning: true,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.shield,
            'register',
            'Register External Worker',
            'Show the consent document; accept with --accept to register with Cloud',
            service(
              'externalWorkers.register',
              payload: (run) => {
                'externalWorkerId': run.positional('id'),
                if (run.option('accept') != null)
                  'acceptHash': run.option('accept'),
              },
            ),
            parameters: const [externalWorkerId, acceptConsent],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.list,
            info: true,
            'show',
            'External Worker details',
            'Show an External Worker package: versions, digests and state',
            service(
              'externalWorkers.show',
              payload: (run) => {'externalWorkerId': run.positional('id')},
            ),
            parameters: const [externalWorkerId],
            inGroup: true,
          ),
        ],
      ),
      group(
        'folders',
        'Folders',
        'Manage the folders Spaces may use',
        defaultCommand: 'list',
        icon: GuiIcons.folder,
        navigation: true,
        [
          command(
            icon: GuiIcons.list,
            info: true,
            'list',
            'Folders',
            'List allowed Space folders',
            service('folders.list'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.plus,
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
            icon: GuiIcons.trash,
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
      group(
        'mcp',
        'MCP servers',
        'Manage MCP servers that official Workers may use (tools you consent to)',
        defaultCommand: 'list',
        icon: GuiIcons.server,
        navigation: true,
        [
          command(
            icon: GuiIcons.list,
            info: true,
            'list',
            'MCP servers',
            'List configured MCP servers and their state',
            service('mcp.list'),
            inGroup: true,
          ),
          command(
            icon: GuiIcons.plus,
            'add',
            'Add MCP server',
            'Register a local MCP server command (nothing runs until you consent)',
            service(
              'mcp.add',
              payload: (run) {
                // Malformed values are sent as-is so the Service rejects them
                // with a stable invalid_request.
                Object? args = const <String>[];
                final rawArgs = run.option('args');
                if (rawArgs != null) {
                  try {
                    args = jsonDecode(rawArgs);
                  } on FormatException {
                    args = rawArgs;
                  }
                }
                final rawEnv = run.option('env');
                return {
                  'serverId': run.positional('id'),
                  'displayName': run.option('name') ?? run.positional('id'),
                  'command': File(run.positional('command')!).absolute.path,
                  'arguments': args,
                  'environmentNames': rawEnv == null
                      ? <String>[]
                      : rawEnv
                          .split(',')
                          .map((n) => n.trim())
                          .where((n) => n.isNotEmpty)
                          .toList(),
                };
              },
            ),
            parameters: const [
              GuiParameter(
                name: 'id',
                kind: GuiParamKind.positional,
                type: GuiParamType.string,
                required: true,
                label: 'Server ID',
              ),
              GuiParameter(
                name: 'command',
                kind: GuiParamKind.positional,
                type: GuiParamType.path,
                required: true,
                label: 'Server command',
              ),
              GuiParameter(
                name: 'name',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label: 'Display name',
              ),
              GuiParameter(
                name: 'args',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label:
                    'Arguments as a JSON array, for example ["--root","/tmp"]',
              ),
              GuiParameter(
                name: 'env',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label:
                    'Environment variable names it may read, comma-separated',
              ),
            ],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.link,
            'add-remote',
            'Add remote MCP server',
            'Register a remote MCP server by https URL (nothing is contacted until you consent)',
            service(
              'mcp.addRemote',
              payload: (run) => {
                'serverId': run.positional('id'),
                'displayName': run.option('name') ?? run.positional('id'),
                'endpoint': run.positional('url'),
                if (run.option('token-env') != null)
                  'tokenEnv': run.option('token-env'),
                if (run.flag('insecure-loopback')) 'insecureLoopback': true,
              },
            ),
            parameters: const [
              GuiParameter(
                name: 'id',
                kind: GuiParamKind.positional,
                type: GuiParamType.string,
                required: true,
                label: 'Server ID',
              ),
              GuiParameter(
                name: 'url',
                kind: GuiParamKind.positional,
                type: GuiParamType.string,
                required: true,
                label: 'Endpoint URL (https)',
              ),
              GuiParameter(
                name: 'name',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label: 'Display name',
              ),
              GuiParameter(
                name: 'token-env',
                kind: GuiParamKind.option,
                type: GuiParamType.string,
                label:
                    'Name of the environment variable that holds the bearer token (the token itself is never stored)',
              ),
              GuiParameter(
                name: 'insecure-loopback',
                kind: GuiParamKind.flag,
                type: GuiParamType.boolean,
                label:
                    'Allow plain http to a loopback address (development only)',
              ),
            ],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.shield,
            'consent',
            'Consent to MCP server',
            'Show the server and every tool definition; accept with --accept',
            service(
              'mcp.consent',
              payload: (run) => {
                'serverId': run.positional('id'),
                if (run.option('accept') != null)
                  'acceptHash': run.option('accept'),
              },
            ),
            parameters: mcpServerId + [acceptConsent],
            inGroup: true,
          ),
          command(
            icon: GuiIcons.power,
            'enable',
            'Enable MCP server',
            'Allow Steps to use this consented server',
            service(
              'mcp.enable',
              payload: (run) => {'serverId': run.positional('id')},
            ),
            parameters: mcpServerId,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.stop,
            'disable',
            'Disable MCP server',
            'Stop offering this server to Workers',
            service(
              'mcp.disable',
              payload: (run) => {'serverId': run.positional('id')},
            ),
            parameters: mcpServerId,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.trash,
            'remove',
            'Remove MCP server',
            'Forget this server and its consent',
            service(
              'mcp.remove',
              payload: (run) => {'serverId': run.positional('id')},
            ),
            parameters: mcpServerId,
            destructive: true,
            inGroup: true,
          ),
        ],
      ),
      command(
        icon: GuiIcons.home,
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
        icon: GuiIcons.gauge,
        info: true,
        'slots',
        'Slots',
        'Parallel execution slots',
        service('execution.getSlots'),
        format: GuiFormat.nano,
      ),
      group(
        'assignments',
        'Assignments',
        'Inspect and cancel running assignments',
        defaultCommand: 'list',
        icon: GuiIcons.tasks,
        navigation: true,
        [
          command(
            icon: GuiIcons.tasks,
            info: true,
            'list',
            'Assignments',
            'Active assignment ids',
            service('execution.listActiveAssignments'),
            view: GuiView.table,
            inGroup: true,
          ),
          command(
            icon: GuiIcons.stop,
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
        icon: GuiIcons.log,
        info: true,
        'logs',
        'Logs',
        'Recent service logs',
        service('diagnostics.getLogs'),
        view: GuiView.log,
      ),
      command(
        icon: GuiIcons.chart,
        info: true,
        'metrics',
        'Metrics',
        'Service metrics',
        service('diagnostics.getMetrics'),
        format: GuiFormat.nano,
      ),
      group(
        'service',
        'Service',
        'Manage the host background service (macOS/Linux/Windows)',
        navigationCommand: 'status',
        icon: GuiIcons.server,
        navigation: true,
        [
          serviceAction(
            icon: GuiIcons.info,
            info: true,
            'status',
            'Service status',
            'Show whether the service is installed and running',
            longRunning: false,
          ),
          serviceAction(
            icon: GuiIcons.download,
            'install',
            'Install service',
            'Install the host background service',
          ),
          serviceAction(
            icon: GuiIcons.trash,
            'uninstall',
            'Uninstall service',
            'Remove the host background service',
            destructive: true,
            longRunning: false,
          ),
          serviceAction(
              icon: GuiIcons.play,
              'start',
              'Start service',
              'Start the service'),
          serviceAction(
              icon: GuiIcons.stop, 'stop', 'Stop service', 'Stop the service'),
          serviceAction(
              icon: GuiIcons.refresh,
              'restart',
              'Restart service',
              'Restart the service'),
        ],
      ),
      group(
        'config',
        'Config',
        'Manage the restart-applied workspace.nano file',
        section: 'WORKSPACE',
        defaultCommand: 'show',
        navigation: true,
        icon: GuiIcons.sliders,
        firstRun: true,
        [
          configAction(
            icon: GuiIcons.plus,
            'init',
            'Create config',
            'Create workspace.nano with defaults if it is missing',
          ),
          configAction(
              icon: GuiIcons.eye,
              info: true,
              'show',
              'Show config',
              'Show workspace.nano'),
          configAction(
            icon: GuiIcons.check,
            info: true,
            'validate',
            'Validate config',
            'Check that workspace.nano is valid',
          ),
          configAction(
              icon: GuiIcons.file,
              info: true,
              'path',
              'Config path',
              'Print the workspace.nano path'),
        ],
      ),
      command(
        icon: GuiIcons.wrench,
        'reset',
        'Reset',
        'Stop service, unregister and erase local runtime state',
        (run) => cli._reset(dataDir(run), json(run)),
        destructive: true,
        longRunning: true,
        firstRun: true,
      ),
      command(
        icon: GuiIcons.tag,
        info: true,
        'version',
        'Version',
        'Show the version',
        service('service.getVersion'),
        firstRun: true,
      ),
    ],
  );
}
