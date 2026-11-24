import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/worker_usage.dart';
import '../spaces/spaces_pages.dart' show AxWorkerUsagePanel;

class WorkerUsageDialog extends StatefulWidget {
  const WorkerUsageDialog(
      {super.key, required this.source, required this.worker});
  final AxWorkerUsageDataSource source;
  final AxWorker worker;

  @override
  State<WorkerUsageDialog> createState() => _WorkerUsageDialogState();
}

class _WorkerUsageDialogState extends State<WorkerUsageDialog> {
  late final _controller = AxWorkerUsageController(widget.source);

  void _load() => _controller.load(
        workspaceId: widget.worker.workspaceId,
        workerId: widget.worker.id,
        workerName: widget.worker.displayName,
      );

  @override
  void initState() {
    super.initState();
    _load();
    _controller.addListener(_onChange);
  }

  void _onChange() {
    if (!_controller.visible && mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChange);
    _controller.dismiss();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child:
                AxWorkerUsagePanel(controller: _controller, onRefresh: _load),
          ),
        ),
      );
}
