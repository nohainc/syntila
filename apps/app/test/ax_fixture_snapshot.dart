import 'package:syntila_app/src/ax/ax_models.dart';

AxSnapshot axFixtureSnapshot() => const AxSnapshot(
      activeRunId: 'run-fixture',
      run: AxRun(
        id: 'run-fixture',
        status: RunStatus.running,
        objective: 'Improve authentication architecture',
        taskCount: 4,
        completedTaskCount: 1,
        openFindingCount: 1,
        verifiedCriterionCount: 0,
        criterionCount: 2,
      ),
      spaces: [
        AxSpace(
          id: 'space-auth',
          name: 'Authentication',
          branch: 'main',
          lastActivity: '2 min ago',
          threads: [
            AxThread(
              id: 'thread-auth',
              spaceId: 'space-auth',
              name: 'Authentication hardening',
              lead: 'Vitalii',
              status: 'active',
              brief:
                  'Harden the authentication boundaries before the next release.',
              queueStatus: 'Idle',
            ),
          ],
        ),
        AxSpace(
          id: 'atlas',
          name: 'Atlas API',
          branch: 'develop',
          lastActivity: 'Yesterday',
        ),
      ],
      tasks: [
        AxTask(
          id: 'research',
          title: 'Research repository structure',
          phase: 'Understand',
          status: TaskStatus.completed,
          worker: 'Lead',
          detail:
              'Mapped app boundaries and identified the Flutter entry point.',
          progress: 1,
          dependencies: [],
        ),
        AxTask(
          id: 'implement',
          title: 'Build the Ax execution surface',
          phase: 'Build',
          status: TaskStatus.running,
          worker: 'Lead',
          detail: 'Implementing the first usable run dashboard and controls.',
          progress: .68,
          dependencies: ['Research repository structure'],
        ),
        AxTask(
          id: 'review',
          title: 'Review implementation independently',
          phase: 'Verify',
          status: TaskStatus.ready,
          worker: 'Reviewer',
          detail:
              'Waiting for implementation output before starting isolated review.',
          progress: 0,
          dependencies: ['Build the Ax execution surface'],
        ),
        AxTask(
          id: 'tests',
          title: 'Run Flutter and TypeScript checks',
          phase: 'Verify',
          status: TaskStatus.pending,
          worker: 'Local Runtime',
          detail:
              'Will collect executable evidence for the completion criteria.',
          progress: 0,
          dependencies: ['Build the Ax execution surface'],
        ),
      ],
      findings: [
        AxFinding(
          id: 'F-104',
          title: 'Add persistence boundary',
          description:
              'The dashboard currently uses a local snapshot; connect this surface to the run aggregate before production use.',
          severity: FindingSeverity.major,
          status: FindingStatus.open,
          taskId: 'implement',
          author: 'Reviewer',
        ),
        AxFinding(
          id: 'F-098',
          title: 'Show empty state for spaces',
          description: 'Spaces without active goals need a clear next action.',
          severity: FindingSeverity.minor,
          status: FindingStatus.verified,
          taskId: 'research',
          author: 'Reviewer',
        ),
      ],
      events: [
        AxEvent(
            time: '09:42',
            title: 'Task started',
            detail: 'Build the Ax execution surface · Lead',
            kind: 'task'),
        AxEvent(
            time: '09:41',
            title: 'Plan accepted',
            detail: '4 tasks across 3 phases',
            kind: 'plan'),
        AxEvent(
            time: '09:40',
            title: 'Goal created',
            detail: 'Build a useful Syntila Ax UI',
            kind: 'goal'),
        AxEvent(
            time: '09:40',
            title: 'Worker selected',
            detail: 'Lead resolved with implementation capability',
            kind: 'worker'),
      ],
      artifacts: [
        AxArtifact(
            name: 'repository-map.md',
            type: 'Research report',
            size: '12 KB',
            source: 'Lead · Research'),
        AxArtifact(
            name: 'ax-preview.png',
            type: 'Screenshot',
            size: '184 KB',
            source: 'Local Runtime · Build'),
        AxArtifact(
            name: 'plan.json',
            type: 'Structured plan',
            size: '4 KB',
            source: 'Lead · Plan'),
      ],
      candidateOutputs: [
        AxCandidateOutput(
          worker: 'Lead',
          role: 'researcher',
          status: 'Complete',
          summary: 'Mapped repository boundaries and Flutter entry points.',
          artifactCount: 3,
        ),
        AxCandidateOutput(
          worker: 'Reviewer',
          role: 'architect',
          status: 'Complete',
          summary: 'Identified the API boundary and persistence handoff.',
          artifactCount: 2,
        ),
      ],
      synthesisDecision: AxSynthesisDecision(
        status: 'Accepted',
        summary: 'Both candidates agree on the next implementation boundary.',
        worker: 'Lead · Synthesizer',
        evidence: 'DecisionResult · 2 candidate outputs',
      ),
    );
