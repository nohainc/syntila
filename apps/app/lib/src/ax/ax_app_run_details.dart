part of 'ax_app.dart';

extension _AxAppRunDetails on _AxAppStateMixin {
  Widget _runDetailsView(bool compact) {
    switch (navigation.kind) {
      case AxRouteKind.people:
        return PeoplePage(people: store.people);
      case AxRouteKind.notes:
        final source = widget.dataSource;
        if (source is! AxNotesDataSource) break;
        return NotesPage(
          source: source as AxNotesDataSource,
          onOpenThread: (spaceId, threadId) =>
              _navigateTo(AxNavigation.thread(spaceId, threadId)),
        );
      case AxRouteKind.files:
        final source = widget.dataSource;
        if (source is! AxUserFilesDataSource) break;
        return FilesPage(
          source: source as AxUserFilesDataSource,
          onOpenThread: (spaceId, threadId) =>
              _navigateTo(AxNavigation.thread(spaceId, threadId)),
        );
      case AxRouteKind.archivedSpaces:
        return ArchivedSpacesPage(
          archivedSpaces: store.archivedSpaces,
          mutations: store.collaboration,
        );
      case AxRouteKind.workspaces:
        return _workspacesView();
      case AxRouteKind.profileSecurity:
        return _profileSecurityView();
      case AxRouteKind.settings:
        return SettingsPage(
          preferences: _viewPreferences,
          onChanged: _setViewPreferences,
        );
      case AxRouteKind.spaces:
        return _homeView();
      case AxRouteKind.space:
        return _spaceOverviewView();
      case AxRouteKind.spaceMembers:
        return _spaceResourceView(SpacePageSection.members);
      case AxRouteKind.thread:
        return _threadView();
      case AxRouteKind.search:
        return _searchView();
      case AxRouteKind.run:
      case AxRouteKind.home:
      case AxRouteKind.login:
      case AxRouteKind.desktopAuthApproval:
        break;
    }
    return ListenableBuilder(
        listenable: store.executionChanges,
        builder: (context, _) =>
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                spacing: 16,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(selectedSpace?.name ?? 'Space',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 12)),
                        const SizedBox(height: 7),
                        Text('Run details',
                            style: TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w700,
                                color: Theme.of(context).colorScheme.onSurface,
                                letterSpacing: -.5)),
                        const SizedBox(height: 5),
                        Text(
                            'Follow execution, results, verification, and diagnostics.',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 13)),
                      ]),
                ],
              ),
              const SizedBox(height: 20),
              _runSection(
                title: 'Overview',
                subtitle: 'Status, elapsed work, Engine, Profile, and findings',
                icon: Icons.dashboard_outlined,
                child: Column(children: [
                  _runHeader(compact),
                  const SizedBox(height: 16),
                  _runContextCard(),
                  const SizedBox(height: 16),
                ]),
              ),
              const SizedBox(height: 16),
              _runSection(
                title: 'Workspaces',
                subtitle: 'Task DAG, progress, and active Worker details',
                icon: Icons.account_tree_outlined,
                child: compact
                    ? Column(children: [
                        _executionCard(),
                        const SizedBox(height: 16),
                        _taskDetailsCard(),
                      ])
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                            Expanded(flex: 6, child: _executionCard()),
                            const SizedBox(width: 16),
                            Expanded(flex: 4, child: _taskDetailsCard()),
                          ]),
              ),
              const SizedBox(height: 16),
              _runSection(
                title: 'Results',
                subtitle: 'Candidate answers, synthesis, and artifacts',
                icon: Icons.auto_awesome_outlined,
                child: _resultsDetailsCard(),
              ),
              const SizedBox(height: 16),
              _runSection(
                title: 'Verification',
                subtitle: 'Tests, findings, and completion criteria',
                icon: Icons.verified_outlined,
                child: _evidenceCard(),
              ),
              const SizedBox(height: 16),
              _runSection(
                title: 'Technical',
                subtitle:
                    'Events, model calls, correlation IDs, and diagnostics',
                icon: Icons.code_outlined,
                initiallyExpanded: false,
                child: Column(children: [
                  _technicalDetailsCard(),
                  const SizedBox(height: 16),
                  _timelineCard(),
                ]),
              ),
            ]));
  }

  Widget _runSection({
    required String title,
    required String subtitle,
    required IconData icon,
    required Widget child,
    bool initiallyExpanded = true,
  }) =>
      Card(
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon,
              color: SyntilaColors.primaryForeground(
                  Theme.of(context).brightness == Brightness.dark)),
          title: Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
          children: [child],
        ),
      );

  Color _runStatusColor(RunStatus status) => switch (status) {
        RunStatus.completed => SyntilaColors.success,
        RunStatus.failed || RunStatus.cancelled => SyntilaColors.error,
        RunStatus.paused || RunStatus.waiting => SyntilaColors.warning,
        _ => SyntilaColors.primary,
      };

  String _statusLabel(RunStatus status) =>
      status.name[0].toUpperCase() + status.name.substring(1);

  Future<void> _controlRun(String command) async {
    final runId = executionSnapshot.run?.id ?? executionSnapshot.activeRunId;
    if (runId == null) return;
    try {
      await store.runs.control(runId, command);
      if (!mounted) return;
      _updateState(() {
        optimisticRunStatus = switch (command) {
          'pause' => RunStatus.paused,
          'resume' => RunStatus.running,
          'cancel' => RunStatus.cancelled,
          _ => optimisticRunStatus,
        };
      });
    } catch (error) {
      if (mounted) _updateState(() => loadError = error.toString());
    }
  }

  Widget _runHeader(bool compact) {
    final run = executionSnapshot.run;
    final status = optimisticRunStatus ?? run?.status ?? RunStatus.completed;
    final canControl = run != null &&
        {
          RunStatus.active,
          RunStatus.running,
          RunStatus.waiting,
          RunStatus.paused
        }.contains(status);
    final paused = status == RunStatus.paused;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Wrap(
                spacing: 18,
                runSpacing: 15,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Icon(Icons.bolt_rounded,
                      color: SyntilaColors.primaryForeground(
                          Theme.of(context).brightness == Brightness.dark),
                      size: 24),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            run?.objective ??
                                'No work request has been started',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 14)),
                        const SizedBox(height: 4),
                        Text(
                            run == null
                                ? 'Select New work request to begin'
                                : 'Work Request ${run.id}',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 11))
                      ]),
                  _statusChip(_statusLabel(status), _runStatusColor(status)),
                  const SizedBox(width: 5),
                  if (!compact)
                    Text(
                        '${run?.verifiedCriterionCount ?? 0} / ${run?.criterionCount ?? 0} criteria verified',
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 11)),
                  OutlinedButton.icon(
                      onPressed: canControl
                          ? () => _controlRun(paused ? 'resume' : 'pause')
                          : null,
                      icon: Icon(
                          paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 16),
                      label: Text(paused ? 'Resume' : 'Pause'),
                      style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                  OutlinedButton.icon(
                      onPressed:
                          canControl ? () => _controlRun('cancel') : null,
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                              color: Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9))),
                ])));
  }

  Widget _executionCard() {
    final run = executionSnapshot.run;
    if (executionSnapshot.tasks.isEmpty) {
      return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(run == null
              ? 'No active run for this space.'
              : 'The run has not created tasks yet.'),
        ),
      );
    }
    final completed = executionSnapshot.tasks
        .where((task) => task.status == TaskStatus.completed)
        .length;
    return _panel(
        title: 'Execution tree',
        subtitle: 'Live run state',
        trailing: _statusChip(
            '$completed / ${executionSnapshot.tasks.length} tasks',
            SyntilaColors.primary),
        child: Column(children: [
          TaskPipelineDAG(
            tasks: executionSnapshot.tasks,
            selectedTaskId: selectedTaskId,
            onSelectTask: (taskId) =>
                _updateState(() => selectedTaskId = taskId),
          ),
          ...executionSnapshot.tasks.map(_taskRow),
        ]));
  }

  Widget _runContextCard() {
    final task = selectedTask ?? executionSnapshot.tasks.firstOrNull;
    final worker = task?.worker.isNotEmpty == true ? task!.worker : 'Auto';
    return _panel(
      title: 'Execution context',
      subtitle: 'Trusted assignment details',
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _contextLine(Icons.extension_outlined, 'Worker', worker),
          _contextLine(Icons.extension_outlined, 'Worker connection', 'Auto'),
          _contextLine(Icons.computer_outlined, 'Workspace', 'Auto'),
          _contextLine(Icons.smart_toy_outlined, 'Model', 'Auto'),
        ],
      ),
    );
  }

  Widget _contextLine(IconData icon, String label, String value) => SizedBox(
        width: 190,
        child: Row(children: [
          Icon(icon,
              size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11)),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      );

  Widget _resultsDetailsCard() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _candidateOutputsCard(),
          const SizedBox(height: 16),
          _panel(
            title: 'Artifacts and changes',
            subtitle:
                '${executionSnapshot.artifacts.length} stored result artifacts',
            child: executionSnapshot.artifacts.isEmpty
                ? const Text(
                    'Artifacts will appear here as the Run produces results.')
                : Column(
                    children: executionSnapshot.artifacts
                        .map((artifact) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.description_outlined),
                              title: Text(artifact.name),
                              subtitle:
                                  Text('${artifact.type} · ${artifact.size}'),
                              trailing: Text(artifact.source),
                            ))
                        .toList(),
                  ),
          ),
        ],
      );

  Widget _technicalDetailsCard() => _panel(
        title: 'Technical context',
        subtitle: 'Read-only execution diagnostics',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (executionSnapshot.events.isEmpty)
              const Text('Diagnostics will appear as Workers execute.')
            else
              Text(
                  'Correlation IDs: ${executionSnapshot.events.where((event) => event.correlationId != null).map((event) => event.correlationId).toSet().join(', ')}',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );

  Widget _candidateOutputsCard() {
    final outputs = executionSnapshot.candidateOutputs;
    final decision = executionSnapshot.synthesisDecision;
    if (outputs.isEmpty && decision == null) {
      return _panel(
        title: 'Candidate outputs',
        subtitle: 'Read-only multi-worker synthesis',
        child: const Text('No candidate outputs are available.'),
      );
    }
    return _panel(
      title: 'Candidate outputs',
      subtitle: '${outputs.length} independent results',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...outputs.map(
            (output) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: SyntilaColors.surface(
                    Theme.of(context).brightness == Brightness.dark),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: SyntilaColors.border(
                        Theme.of(context).brightness == Brightness.dark)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.account_tree_outlined,
                      size: 18,
                      color: SyntilaColors.primaryForeground(
                          Theme.of(context).brightness == Brightness.dark)),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${output.worker} · ${output.role}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12)),
                        const SizedBox(height: 4),
                        Text(output.summary,
                            style: TextStyle(
                                color: SyntilaColors.textSecondary(
                                    Theme.of(context).brightness ==
                                        Brightness.dark),
                                fontSize: 11)),
                      ],
                    ),
                  ),
                  _statusChip(output.status, SyntilaColors.success),
                ],
              ),
            ),
          ),
          if (decision != null) ...[
            const SizedBox(height: 4),
            Row(children: [
              Icon(Icons.auto_awesome,
                  color: SyntilaColors.primaryForeground(
                      Theme.of(context).brightness == Brightness.dark),
                  size: 18),
              const SizedBox(width: 8),
              const Text('Synthesis decision',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
              const Spacer(),
              _statusChip(decision.status, SyntilaColors.success),
            ]),
            const SizedBox(height: 6),
            Text(decision.summary,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11)),
            const SizedBox(height: 4),
            Text('${decision.worker} · ${decision.evidence}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _taskRow(AxTask task, {bool selected = false}) {
    final active = selectedTaskId == task.id;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = task.status == TaskStatus.completed
        ? SyntilaColors.success
        : task.status.isFailed
            ? SyntilaColors.error
            : task.status == TaskStatus.running
                ? SyntilaColors.primary
                : SyntilaColors.textSecondary(isDark);
    return InkWell(
        onTap: () => _updateState(() => selectedTaskId = task.id),
        borderRadius: BorderRadius.circular(9),
        child: Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: active
                    ? SyntilaColors.primarySoftColor(isDark)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                    color: active
                        ? (isDark
                            ? SyntilaColors.primaryForegroundDark
                            : SyntilaColors.primarySoft)
                        : Colors.transparent)),
            child: Row(children: [
              Icon(
                  task.status == TaskStatus.completed
                      ? Icons.check_circle_rounded
                      : task.status.isFailed
                          ? Icons.error_rounded
                          : task.status == TaskStatus.running
                              ? Icons.timelapse_rounded
                              : Icons.radio_button_unchecked,
                  size: 17,
                  color: color),
              const SizedBox(width: 9),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(task.title,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${task.worker}  ·  ${task.status.name}',
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant))
                  ])),
              if (task.status == TaskStatus.running)
                SizedBox(
                    width: 45,
                    child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 5,
                        borderRadius: BorderRadius.circular(4),
                        color: SyntilaColors.primary,
                        backgroundColor:
                            SyntilaColors.primarySoftColor(isDark))),
              const SizedBox(width: 5),
              Icon(Icons.chevron_right_rounded,
                  size: 17,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)
            ])));
  }

  Widget _taskDetailsCard() {
    final task = selectedTask ?? executionSnapshot.tasks.firstOrNull;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (task == null) {
      return _panel(
        title: 'Task details',
        subtitle: 'No task selected',
        child: const Text('Tasks will appear here when a run begins.'),
      );
    }
    return _panel(
        title: 'Task details',
        subtitle: task.id.toUpperCase(),
        trailing: _statusChip(
            task.status.name,
            task.status == TaskStatus.running
                ? SyntilaColors.primary
                : SyntilaColors.success),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(task.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          const SizedBox(height: 8),
          Text(task.detail,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.45)),
          if (task.errorCode != null) ...[
            const SizedBox(height: 8),
            Text(task.errorMessage ?? 'The assignment could not be completed.',
                key: const ValueKey('task-execution-error-message'),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text('Error code: ${task.errorCode}',
                key: const ValueKey('task-execution-error-code'),
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 18),
          _detailLine(Icons.person_outline, 'Worker', task.worker),
          _detailLine(
              Icons.account_tree_outlined,
              'Dependencies',
              task.dependencies.isEmpty
                  ? 'None'
                  : task.dependencies.join(', ')),
          if (task.detail.contains('diff') ||
              task.detail.contains('@@') ||
              task.detail.startsWith('---') ||
              task.detail.startsWith('+++')) ...[
            const SizedBox(height: 16),
            const Text('Generated Artifact / Diff',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            const SizedBox(height: 8),
            DiffViewer(filePath: task.title, diffContent: task.detail),
          ],
          const SizedBox(height: 15),
          if (task.status == TaskStatus.running)
            FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.refresh_rounded, size: 16),
                label: const Text('Retry task'),
                style: FilledButton.styleFrom(
                    backgroundColor: SyntilaColors.primarySoftColor(isDark),
                    foregroundColor: SyntilaColors.primaryForeground(isDark),
                    elevation: 0))
        ]));
  }

  Widget _detailLine(IconData icon, String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 11),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon,
            size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 9),
        SizedBox(
            width: 82,
            child: Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 11))),
        Expanded(
            child: Text(value,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)))
      ]));

  Widget _timelineCard() => _panel(
        title: 'Run timeline',
        subtitle: 'Ordered events',
        trailing: TextButton(
            onPressed: _copyRunDiagnostics,
            child: const Text('Export diagnostics')),
        child: Column(
          children: executionSnapshot.events
              .map(
                (event) => Padding(
                  padding: const EdgeInsets.only(bottom: 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: 42,
                          child: Text(event.time,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant))),
                      Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 3, right: 11),
                          decoration: const BoxDecoration(
                              color: SyntilaColors.primary,
                              shape: BoxShape.circle)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(event.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 12)),
                            const SizedBox(height: 3),
                            Text(event.detail,
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontSize: 11)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      );

  Widget _evidenceCard() => _panel(
      title: 'Evidence & findings',
      subtitle:
          '${executionSnapshot.findings.length} findings · ${executionSnapshot.artifacts.length} artifacts',
      trailing: TextButton(
          onPressed: () {
            final space = selectedSpace;
            final run = executionSnapshot.run;
            if (space != null && run != null) {
              _navigateTo(AxNavigation.run(space.id, run.id));
            }
          },
          child: const Text('Open run details')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _metric('Tasks', '${executionSnapshot.tasks.length}'),
          _metric('Findings', '${executionSnapshot.findings.length}'),
          _metric('Checks',
              '${executionSnapshot.run?.verifiedCriterionCount ?? 0} / ${executionSnapshot.run?.criterionCount ?? 0}')
        ]),
        const SizedBox(height: 16),
        ...executionSnapshot.findings.map((finding) => _findingRow(finding))
      ]));

  Widget _metric(String label, String value) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface))
      ]));

  Widget _findingRow(AxFinding finding) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.outline)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(
            finding.status == FindingStatus.verified
                ? Icons.verified_rounded
                : Icons.warning_amber_rounded,
            size: 17,
            color: finding.status == FindingStatus.verified
                ? SyntilaBrand.success
                : SyntilaBrand.warning),
        const SizedBox(width: 8),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(finding.title,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
          const SizedBox(height: 3),
          Text('${finding.severity.name} · ${finding.status.name}',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 11))
        ]))
      ]));

  Widget _panel(
          {required String title,
          required String subtitle,
          required Widget child,
          Widget? trailing}) =>
      Builder(
        builder: (context) {
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final mutedColor =
              isDark ? SyntilaBrand.darkInkMuted : SyntilaBrand.lightInkMuted;
          return Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(subtitle,
                                style:
                                    TextStyle(color: mutedColor, fontSize: 11)),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (trailing != null) trailing,
                    ],
                  ),
                  const SizedBox(height: 15),
                  child,
                ],
              ),
            ),
          );
        },
      );

  Widget _statusChip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .11),
          borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 11, fontWeight: FontWeight.w700))
      ]));
}
