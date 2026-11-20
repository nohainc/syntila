import 'package:flutter/material.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';

/// The Syntila web app's themes, with its navigation colors for the sidebar.
ThemeData syntilaLightTheme() => _withSidebar(SyntilaBrand.lightTheme(), false);

ThemeData syntilaDarkTheme() => _withSidebar(SyntilaBrand.darkTheme(), true);

/// The sidebar colors the Syntila app uses (navigation background, selected
/// row, muted text and borders).
GuiSidebarTheme syntilaSidebarTheme(bool isDark) => GuiSidebarTheme(
  backgroundColor: SyntilaColors.navigationBackground(isDark),
  selectedColor: SyntilaColors.navigationSelectedColor(isDark),
  textColor: SyntilaColors.navigationTextMuted(isDark),
  labelColor: SyntilaColors.neutralText(isDark),
  borderColor: SyntilaColors.navigationBorder(isDark),
);

ThemeData _withSidebar(ThemeData base, bool isDark) => base.copyWith(
  extensions: [...base.extensions.values, syntilaSidebarTheme(isDark)],
);
