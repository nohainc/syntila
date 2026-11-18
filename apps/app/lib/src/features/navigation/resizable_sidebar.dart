import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import '../../platform/view_preferences.dart';

/// Sidebar with an inset resize grip; width belongs to the shell so
/// collapsing the sidebar or navigating does not reset it.
class ResizableSidebar extends StatefulWidget {
  const ResizableSidebar({
    super.key,
    required this.width,
    required this.onWidthChanged,
    required this.child,
  });

  static const minWidth = ViewPreferences.minSidebarWidth;
  static const maxWidth = ViewPreferences.maxSidebarWidth;
  final double width;
  final ValueChanged<double> onWidthChanged;
  final Widget child;

  @override
  State<ResizableSidebar> createState() => _ResizableSidebarState();
}

class _ResizableSidebarState extends State<ResizableSidebar> {
  double _dragStartX = 0;
  double _dragStartWidth = 0;
  double get width => widget.width.clamp(minWidth, maxWidth).toDouble();
  static const minWidth = ResizableSidebar.minWidth;
  static const maxWidth = ResizableSidebar.maxWidth;

  void _resize(double value) =>
      widget.onWidthChanged(value.clamp(minWidth, maxWidth).toDouble());

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: Stack(
          children: [
            Positioned.fill(child: widget.child),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: 8,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                      _resize(width - 10),
                  const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                      _resize(width + 10),
                  const SingleActivator(LogicalKeyboardKey.home): () =>
                      _resize(minWidth),
                  const SingleActivator(LogicalKeyboardKey.end): () =>
                      _resize(maxWidth),
                },
                child: Focus(
                  child: Builder(builder: (context) {
                    return Semantics(
                      label: 'Sidebar width',
                      value: '${width.round()} pixels',
                      increasedValue:
                          '${(width + 10).clamp(minWidth, maxWidth).round()} pixels',
                      decreasedValue:
                          '${(width - 10).clamp(minWidth, maxWidth).round()} pixels',
                      onIncrease:
                          width < maxWidth ? () => _resize(width + 10) : null,
                      onDecrease:
                          width > minWidth ? () => _resize(width - 10) : null,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeColumn,
                        child: GestureDetector(
                          key: const ValueKey('sidebar-resize-handle'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Focus.of(context).requestFocus(),
                          dragStartBehavior: DragStartBehavior.down,
                          onHorizontalDragStart: (details) {
                            Focus.of(context).requestFocus();
                            _dragStartX = details.globalPosition.dx;
                            _dragStartWidth = width;
                          },
                          onHorizontalDragUpdate: (details) => _resize(
                              _dragStartWidth +
                                  details.globalPosition.dx -
                                  _dragStartX),
                          child: Center(
                            child: Container(
                              key: const ValueKey('sidebar-resize-line'),
                              width: 1,
                              color: Colors.transparent,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ],
        ),
      );
}
