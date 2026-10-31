import 'package:syntila_design/syntila_design.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

/// Keeps the latest-content action above the timeline without reserving space.
class TimelineScrollOverlay extends StatefulWidget {
  const TimelineScrollOverlay({
    super.key,
    required this.controller,
    required this.onFollowLatest,
    required this.child,
  });

  final ScrollController controller;
  final VoidCallback onFollowLatest;
  final Widget child;

  @override
  State<TimelineScrollOverlay> createState() => _TimelineScrollOverlayState();
}

class _TimelineScrollOverlayState extends State<TimelineScrollOverlay> {
  bool _visible = false;
  bool _scrollingToLatest = false;
  int _scrollGeneration = 0;

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _scrollGeneration++;
    }
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      _scrollGeneration++;
    }
    var visible = _visible;
    if (notification.metrics.extentAfter <= 24) {
      visible = false;
    } else if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.forward) {
        visible = false;
      } else if (notification.direction == ScrollDirection.reverse) {
        visible = true;
      }
    }
    if (visible != _visible) setState(() => _visible = visible);
    return false;
  }

  Future<void> _scrollToLatest() async {
    if (!widget.controller.hasClients || _scrollingToLatest) return;
    widget.onFollowLatest();
    final generation = ++_scrollGeneration;
    _scrollingToLatest = true;
    setState(() => _visible = false);
    try {
      // SliverList estimates the extent from mounted rows. Its estimate can
      // shrink while scrolling through shorter rows, leaving pixels beyond the
      // real bottom. Re-read after layout instead of retaining that estimate.
      for (var attempt = 0; attempt < 4; attempt++) {
        if (!mounted ||
            generation != _scrollGeneration ||
            !widget.controller.hasClients) {
          return;
        }
        final position = widget.controller.position;
        if ((position.pixels - position.maxScrollExtent).abs() <= 1) break;
        await widget.controller.animateTo(
          position.maxScrollExtent,
          duration: Duration(milliseconds: attempt == 0 ? 300 : 120),
          curve: Curves.easeOutCubic,
        );
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      _scrollingToLatest = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (_visible)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: Center(
                  child: Material(
                    elevation: 4,
                    color: Theme.of(context).colorScheme.surface,
                    shape: SyntilaRadius.buttonShape,
                    child: IconButton(
                      key: const ValueKey('scroll-to-latest'),
                      // No hover hint; the label keeps it accessible.
                      onPressed: _scrollToLatest,
                      // Same color as message timestamps.
                      color: SyntilaColors.neutral,
                      icon: const Icon(Icons.arrow_downward_rounded,
                          semanticLabel: 'Scroll to latest'),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}
