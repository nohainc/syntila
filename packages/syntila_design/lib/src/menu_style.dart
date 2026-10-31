import 'package:flutter/material.dart';

import 'colors.dart';
import 'radius.dart';

/// Shared surface and row styling for application and composer menus.
abstract final class SyntilaMenuStyle {
  static const padding = EdgeInsets.all(6);
  static const textStyle =
      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500);

  static Color background(bool isDark) =>
      SyntilaColors.navigationBackground(isDark);

  static Color shadow(bool isDark) =>
      Colors.black.withValues(alpha: isDark ? 0.7 : 0.18);

  static RoundedRectangleBorder shape(bool isDark) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: SyntilaColors.navigationBorder(isDark)),
      );

  static MenuStyle surface(bool isDark, {bool composer = false}) => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(composer
            ? SyntilaColors.composerBackground(isDark)
            : background(isDark)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(shadow(isDark)),
        shape: WidgetStatePropertyAll(shape(isDark)),
        padding: const WidgetStatePropertyAll(padding),
      );

  static ButtonStyle item(bool isDark, {bool isDestructive = false}) =>
      ButtonStyle(
        foregroundColor:
            WidgetStatePropertyAll(SyntilaColors.textPrimary(isDark)),
        iconColor: WidgetStatePropertyAll(SyntilaColors.textSecondary(isDark)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(196, 36)),
        shape: WidgetStatePropertyAll(
          SyntilaRadius.buttonShape,
        ),
        textStyle: const WidgetStatePropertyAll(textStyle),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return isDestructive
                ? SyntilaColors.error.withValues(alpha: 0.12)
                : SyntilaColors.navigationHover(isDark);
          }
          return null;
        }),
      );

  /// Text style for [PopupMenuItem] rows so popup-button menus match.
  static TextStyle popupTextStyle(bool isDark) =>
      textStyle.copyWith(color: SyntilaColors.textPrimary(isDark));
}

/// A popup route entry whose child owns focus, hover, and activation.
/// Avoid nesting PopupMenuItem's InkWell around a MenuItemButton.
class SyntilaMenuEntry<T> extends PopupMenuEntry<T> {
  const SyntilaMenuEntry({super.key, required this.value, required this.child});

  final T value;
  final Widget child;

  @override
  double get height => 36;

  @override
  bool represents(T? value) => this.value == value;

  @override
  State<SyntilaMenuEntry<T>> createState() => _SyntilaMenuEntryState<T>();
}

class _SyntilaMenuEntryState<T> extends State<SyntilaMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => widget.child;
}
