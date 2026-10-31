import 'package:flutter_test/flutter_test.dart';
import 'package:gui_manifest_flutter/gui_manifest_flutter.dart';
import 'package:syntila_design/syntila_design.dart';
import 'package:syntila_workspace_gui/src/syntila_themes.dart';

void main() {
  test('light and dark themes carry the Syntila navigation colors', () {
    for (final (theme, isDark) in [
      (syntilaLightTheme(), false),
      (syntilaDarkTheme(), true),
    ]) {
      final sidebar = theme.extension<GuiSidebarTheme>()!;
      expect(
        sidebar.backgroundColor,
        SyntilaColors.navigationBackground(isDark),
      );
      expect(
        sidebar.selectedColor,
        SyntilaColors.navigationSelectedColor(isDark),
      );
      expect(sidebar.textColor, SyntilaColors.navigationTextMuted(isDark));
      expect(sidebar.borderColor, SyntilaColors.navigationBorder(isDark));
    }
  });
}
