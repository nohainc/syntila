import 'package:flutter/material.dart';
import 'package:syntila_protocol/syntila_protocol.dart' show WorkerInstance;

import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_session_catalogs.dart';

/// Read-only identity view during the Worker-first rollout. Management is P6.
class WorkerInstancesSection extends StatelessWidget {
  const WorkerInstancesSection({super.key, required this.catalogs});

  final AxSessionCatalogs catalogs;

  @override
  Widget build(BuildContext context) => AxQueryBuilder<bool>(
        engine: catalogs.engine,
        query: catalogs.workerIdentityEnabled,
        builder: (context, flag) {
          if (flag.data != true) return const SizedBox.shrink();
          return AxQueryBuilder<List<WorkerInstance>>(
            engine: catalogs.engine,
            query: catalogs.workerInstances,
            builder: (context, state) => WorkerInstancesList(
              workers: state.data,
              error: state.error,
              onRefresh: () =>
                  catalogs.engine.refresh(catalogs.workerInstances),
            ),
          );
        },
      );
}

class WorkerInstancesList extends StatelessWidget {
  const WorkerInstancesList({
    super.key,
    required this.workers,
    required this.error,
    required this.onRefresh,
  });

  final List<WorkerInstance>? workers;
  final Object? error;
  final Future<Object?> Function() onRefresh;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('Workers',
                    style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: 'Refresh Workers',
              onPressed: () {
                onRefresh().catchError((Object _) => null);
              },
              icon: const Icon(Icons.refresh),
            ),
          ]),
          if (error != null)
            const Text('Could not load Workers. Try refreshing.')
          else if (workers == null)
            const LinearProgressIndicator()
          else if (workers!.isEmpty)
            const Text('No Workers yet.')
          else
            for (final worker in workers!)
              ListTile(
                key: ValueKey('worker-instance-${worker.id}'),
                title: Text(worker.name),
                subtitle: Text([
                  worker.workerTypeName,
                  if (worker.description.isNotEmpty) worker.description,
                  worker.enabled ? 'Enabled' : 'Disabled',
                  worker.online ? 'Online' : 'Offline',
                  if (!worker.readinessKnown)
                    'Readiness unknown'
                  else if (worker.ready)
                    'Ready'
                  else
                    'Not ready',
                  worker.id.length > 8
                      ? worker.id.substring(worker.id.length - 8)
                      : worker.id,
                ].join(' · ')),
              ),
        ]),
      );
}
