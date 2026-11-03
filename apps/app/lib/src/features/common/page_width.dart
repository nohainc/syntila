import 'package:flutter/widgets.dart';

import '../../platform/view_preferences.dart';

/// The app's selected text size, independent of the operating system scale.
class PageWidth extends InheritedWidget {
  const PageWidth({super.key, required this.textSize, required super.child});

  final TextSizeOption textSize;

  static TextSizeOption of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageWidth>()?.textSize ??
      TextSizeOption.standard;

  @override
  bool updateShouldNotify(PageWidth oldWidget) =>
      textSize != oldWidget.textSize;
}
