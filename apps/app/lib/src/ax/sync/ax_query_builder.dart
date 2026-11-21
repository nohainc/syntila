import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'ax_sync_engine.dart';

/// Rebuilds only the resource consumer; cached data renders on the first frame.
class AxQueryBuilder<T> extends StatefulWidget {
  const AxQueryBuilder(
      {super.key,
      required this.engine,
      required this.query,
      required this.builder,
      this.ensure = true});
  final bool ensure;
  final AxSyncEngine engine;
  final AxQuery<T> query;
  final Widget Function(BuildContext, AxQueryState<T>) builder;
  @override
  State<AxQueryBuilder<T>> createState() => _AxQueryBuilderState<T>();
}

class _AxQueryBuilderState<T> extends State<AxQueryBuilder<T>> {
  late AxQueryState<T> state;
  void Function()? cancel;
  int _subscriptionGeneration = 0;
  AxQueryState<T>? _pendingState;
  bool _stateUpdateScheduled = false;
  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    final generation = ++_subscriptionGeneration;
    state = widget.engine.peek(widget.query);
    cancel = widget.engine.watch(widget.query, (value) {
      if (!mounted) return;
      _pendingState = value;
      if (!_isBuildActive) {
        _pendingState = null;
        setState(() => state = value);
        return;
      }
      if (_stateUpdateScheduled) return;
      _stateUpdateScheduled = true;
      // Query notifications may be synchronous with a parent rebuild. Cross
      // the current build stack before marking this consumer dirty.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _stateUpdateScheduled = false;
        final next = _pendingState;
        _pendingState = null;
        if (mounted && next != null) setState(() => state = next);
      });
      // A post-frame callback does not request a frame by itself; without
      // this an idle window shows the new data only at its next repaint.
      WidgetsBinding.instance.ensureVisualUpdate();
    }, fireImmediately: false);
    // Attach query state/error handling locally, never to the complete shell.
    if (widget.ensure) {
      final engine = widget.engine;
      final query = widget.query;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _subscriptionGeneration) return;
        unawaited(engine
            .ensure(query)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      });
    }
  }

  bool get _isBuildActive =>
      WidgetsBinding.instance.buildOwner?.debugBuilding == true ||
      SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle;

  @override
  void didUpdateWidget(covariant AxQueryBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.engine != widget.engine ||
        oldWidget.query.key != widget.query.key ||
        oldWidget.ensure != widget.ensure) {
      cancel?.call();
      _subscribe();
    }
  }

  @override
  void dispose() {
    cancel?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, state);
}
