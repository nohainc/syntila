/// Declares `syntila-connect` for the GUI Manifest protocol (gui-manifest
/// spec/SPEC.md, v1).
///
/// A GUI runs `syntila-connect --gui-manifest=1` and builds its sidebar and
/// command pages from the answer. This file only describes the commands. The
/// command lines a GUI runs are dispatched by `WorkerCli.run` as usual.
library;

import 'package:gui_manifest/gui_manifest.dart';

import 'config.dart';

/// The answer to a `--gui-manifest` request: the document, or the reason it
/// is refused.
final class GuiManifestAnswer {
  const GuiManifestAnswer.accepted(this.document) : refusal = null;
  const GuiManifestAnswer.refused(this.refusal) : document = null;

  final String? document;
  final String? refusal;
}

/// The answer to [arguments] when they are a `--gui-manifest` request, or null
/// when they are an ordinary command line.
GuiManifestAnswer? answerGuiManifest(
  List<String> arguments, {
  required String version,
}) {
  final request = GuiManifestRequest.parse(arguments);
  return switch (request) {
    null => null,
    GuiManifestAccepted() => GuiManifestAnswer.accepted(
      encodeManifest(manifestFromSpec(workerGuiSpec(version: version))),
    ),
    GuiManifestRejected(:final message) => GuiManifestAnswer.refused(message),
  };
}

/// The GUI's Worker selector. The manifest does not carry global options, so
/// commands that target a specific Worker repeat this required parameter.
const _selectors = <GuiParameter>[
  GuiParameter(
    name: 'worker',
    kind: GuiParamKind.option,
    type: GuiParamType.string,
    required: true,
    label: 'Worker ID',
  ),
];

List<GuiParameter> _withSelectors(List<GuiParameter> own) => [
  ..._selectors,
  ...own,
];

const _folderPath = GuiParameter(
  name: 'path',
  kind: GuiParamKind.positional,
  type: GuiParamType.path,
  required: true,
  label: 'Folder',
);

const _text = GuiOutput(format: GuiFormat.text, view: GuiView.raw);

const _runtimeSection = 'RUNTIME & SERVICE';
const _maintenanceSection = 'DIAGNOSTICS & MAINTENANCE';

/// Never called: the GUI runs `syntila-connect` with the command line, and
/// `WorkerCli.run` does the work. The handler exists because the SDK requires
/// one.
int _dispatchedByWorkerCli(CliInvocation _) => 2;

CliSpec workerGuiSpec({required String version}) => CliSpec(
  name: 'syntila-connect',
  displayName: 'Syntila Connect',
  description: 'Connect and manage Syntila Workers on this computer.',
  version: version,
  nodes: [
    CliCommand(
      name: 'status',
      title: 'Status',
      description: 'Registration, connection, journal and service state.',
      icon: GuiIcons.pulse,
      navigation: true,
      kind: GuiCommandKind.info,
      parameters: const [],
      output: const GuiOutput(format: GuiFormat.json, view: GuiView.keyValue),
      handler: _dispatchedByWorkerCli,
    ),
    CliCommand(
      name: 'pair',
      title: 'Add Worker',
      description:
          'Add a Worker to this computer using the pairing code from Workers in the web app. The code works once and expires after ten minutes.',
      icon: GuiIcons.plus,
      navigation: true,
      parameters: const [
        GuiParameter(
          name: 'pairing-code',
          kind: GuiParamKind.option,
          type: GuiParamType.secret,
          required: true,
          label: 'Pairing code',
          stdinFlag: 'pairing-code-stdin',
        ),
        GuiParameter(
          name: 'pairing-code-stdin',
          kind: GuiParamKind.flag,
          type: GuiParamType.boolean,
          hidden: true,
        ),
        GuiParameter(
          name: 'name',
          kind: GuiParamKind.option,
          type: GuiParamType.string,
          label: 'Worker name (optional)',
        ),
        GuiParameter(
          name: 'auto-start',
          kind: GuiParamKind.flag,
          type: GuiParamType.boolean,
          label: 'Start automatically at login',
        ),
      ],
      output: _text,
      handler: _dispatchedByWorkerCli,
    ),
    CliCommand(
      name: 'unpair',
      title: 'Remove Worker',
      description:
          'Remove the background service and this Worker private state. Your working folders are never touched.',
      icon: GuiIcons.trash,
      destructive: true,
      parameters: _withSelectors(const [
        GuiParameter(
          name: 'yes',
          kind: GuiParamKind.flag,
          type: GuiParamType.boolean,
          defaultValue: 'true',
          label: 'Confirm removal of key and private state',
        ),
        GuiParameter(
          name: 'keep-data',
          kind: GuiParamKind.flag,
          type: GuiParamType.boolean,
          label: 'Keep configuration, folder grants and logs',
        ),
      ]),
      output: _text,
      handler: _dispatchedByWorkerCli,
    ),
    CliGroup(
      name: 'mcp-worker',
      title: 'MCP Workers',
      description: 'MCP Workers this machine may run.',
      icon: GuiIcons.package,
      defaultCommand: 'list',
      children: [
        CliCommand(
          name: 'list',
          title: 'List MCP Workers',
          description: 'MCP Workers approved on this machine.',
          icon: GuiIcons.list,
          kind: GuiCommandKind.info,
          parameters: const [],
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'import',
          title: 'Import MCP Worker',
          description:
              'Import and approve an MCP Worker package directory or archive on this machine.',
          icon: GuiIcons.download,
          parameters: const [
            GuiParameter(
              name: 'path',
              kind: GuiParamKind.positional,
              type: GuiParamType.path,
              required: true,
              label: 'Package directory or .zip',
            ),
          ],
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'test',
          title: 'Test MCP Worker',
          description:
              'Inspect an MCP Worker through the Engine and record its tool pins.',
          icon: GuiIcons.test,
          longRunning: true,
          parameters: const [
            GuiParameter(
              name: 'id',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'MCP Worker ID',
            ),
          ],
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'approve',
          title: 'Approve MCP Worker',
          description:
              'Approve an exact MCP Worker version and manifest digest.',
          icon: GuiIcons.check,
          destructive: true,
          parameters: const [
            GuiParameter(
              name: 'id',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'MCP Worker ID',
            ),
            GuiParameter(
              name: 'version',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'Version',
            ),
            GuiParameter(
              name: 'manifest-digest',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'Manifest digest',
            ),
          ],
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'remove',
          title: 'Remove MCP Worker',
          description: 'Stop this machine from running an MCP Worker version.',
          icon: GuiIcons.trash,
          destructive: true,
          parameters: const [
            GuiParameter(
              name: 'id',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'MCP Worker ID',
            ),
            GuiParameter(
              name: 'manifest-digest',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'Manifest digest',
            ),
          ],
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
      ],
    ),
    CliGroup(
      name: 'folders',
      title: 'Folders',
      description: 'Folders this Worker may use, and its Work Root.',
      icon: GuiIcons.folder,
      defaultCommand: 'list',
      children: [
        CliCommand(
          name: 'list',
          title: 'List folders',
          description: 'Folders this Worker may use.',
          icon: GuiIcons.list,
          kind: GuiCommandKind.info,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'add',
          title: 'Add folder',
          description:
              'Grant this Worker a folder. Read only unless Write is set.',
          icon: GuiIcons.plus,
          parameters: _withSelectors(const [
            _folderPath,
            GuiParameter(
              name: 'write',
              kind: GuiParamKind.flag,
              type: GuiParamType.boolean,
              label: 'Write access',
            ),
          ]),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'remove',
          title: 'Remove folder',
          description: 'Stop this Worker from using a folder.',
          icon: GuiIcons.trash,
          destructive: true,
          parameters: _withSelectors(const [
            GuiParameter(
              name: 'id',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'Folder ID',
            ),
          ]),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'work-root',
          title: 'Work Root',
          description: 'Show the Work Root, or set it when a path is given.',
          icon: GuiIcons.home,
          parameters: _withSelectors(const [
            GuiParameter(
              name: 'path',
              kind: GuiParamKind.positional,
              type: GuiParamType.path,
              label: 'Work Root (optional)',
            ),
          ]),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
      ],
    ),
    CliGroup(
      name: 'service',
      title: 'Service',
      description: 'Manage the Worker background service.',
      icon: GuiIcons.server,
      section: _runtimeSection,
      defaultCommand: 'status',
      children: [
        CliCommand(
          name: 'status',
          title: 'Service status',
          description:
              'Show whether the background service is installed and running.',
          icon: GuiIcons.info,
          kind: GuiCommandKind.info,
          parameters: _withSelectors(const []),
          output: const GuiOutput(
            format: GuiFormat.json,
            view: GuiView.keyValue,
          ),
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'start',
          title: 'Start service',
          description:
              'Start the Worker background service. Needs the service installed.',
          icon: GuiIcons.play,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'stop',
          title: 'Stop service',
          description:
              'Stop the Worker background service. It stops taking work.',
          icon: GuiIcons.stop,
          destructive: true,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'restart',
          title: 'Restart service',
          description: 'Stop and start the Worker background service.',
          icon: GuiIcons.refresh,
          destructive: true,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'install',
          title: 'Install service',
          description:
              'Install the background service for an already paired Worker.',
          icon: GuiIcons.download,
          parameters: _withSelectors(const [
            GuiParameter(
              name: 'auto-start',
              kind: GuiParamKind.flag,
              type: GuiParamType.boolean,
              label: 'Start automatically at login',
            ),
          ]),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'uninstall',
          title: 'Uninstall service',
          description:
              'Remove the background service registration while keeping the paired Worker.',
          icon: GuiIcons.trash,
          destructive: true,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
      ],
    ),
    CliGroup(
      name: 'config',
      title: 'Settings',
      description: 'Worker settings.',
      icon: GuiIcons.sliders,
      section: _runtimeSection,
      defaultCommand: 'show',
      children: [
        CliCommand(
          name: 'show',
          title: 'Show settings',
          description: 'Show the Worker settings.',
          icon: GuiIcons.eye,
          kind: GuiCommandKind.info,
          parameters: _withSelectors(const []),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
        CliCommand(
          name: 'set',
          title: 'Change a setting',
          description: 'Set maxConcurrent, autoStart or logLevel.',
          icon: GuiIcons.edit,
          parameters: _withSelectors(const [
            GuiParameter(
              name: 'key',
              kind: GuiParamKind.positional,
              type: GuiParamType.enumeration,
              values: AgentConfig.keys,
              required: true,
              label: 'Setting',
            ),
            GuiParameter(
              name: 'value',
              kind: GuiParamKind.positional,
              type: GuiParamType.string,
              required: true,
              label: 'Value',
            ),
          ]),
          output: _text,
          handler: _dispatchedByWorkerCli,
        ),
      ],
    ),
    CliCommand(
      name: 'rotate-credential',
      title: 'Update credentials',
      description:
          'Generate a new security key for this Worker and update it on the server. Stop the Worker first.',
      icon: GuiIcons.key,
      section: _maintenanceSection,
      destructive: true,
      parameters: _withSelectors(const []),
      output: _text,
      handler: _dispatchedByWorkerCli,
    ),
    CliCommand(
      name: 'logs',
      title: 'Logs',
      description: 'The Agent log. Ids and codes only, no secrets.',
      icon: GuiIcons.log,
      section: _maintenanceSection,
      kind: GuiCommandKind.info,
      parameters: _withSelectors(const [
        GuiParameter(
          name: 'lines',
          kind: GuiParamKind.option,
          type: GuiParamType.integer,
          defaultValue: '50',
          label: 'Lines',
        ),
      ]),
      output: const GuiOutput(format: GuiFormat.text, view: GuiView.log),
      handler: _dispatchedByWorkerCli,
    ),
    CliCommand(
      name: 'version',
      title: 'Version',
      description: 'Show the Syntila Connect version.',
      icon: GuiIcons.tag,
      section: _maintenanceSection,
      kind: GuiCommandKind.info,
      parameters: const [],
      output: _text,
      handler: _dispatchedByWorkerCli,
    ),
  ],
);
