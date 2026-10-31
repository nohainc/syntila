import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_design/syntila_design.dart';

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  test('button shapes use the same rounded rectangle in both themes', () {
    for (final theme in [SyntilaBrand.lightTheme(), SyntilaBrand.darkTheme()]) {
      final styles = [
        theme.iconButtonTheme.style!,
        theme.segmentedButtonTheme.style!,
        theme.filledButtonTheme.style!,
        theme.outlinedButtonTheme.style!,
        theme.textButtonTheme.style!,
        SyntilaMenuStyle.item(theme.brightness == Brightness.dark),
      ];
      for (final style in styles) {
        for (final states in [
          <WidgetState>{},
          {WidgetState.hovered},
          {WidgetState.focused},
          {WidgetState.pressed},
          {WidgetState.disabled}
        ]) {
          expect(style.shape!.resolve(states), SyntilaRadius.buttonShape);
        }
      }
    }
  });

  test('Primary buttons follow theme and pressed state', () {
    for (final isDark in [false, true]) {
      final theme =
          isDark ? SyntilaBrand.darkTheme() : SyntilaBrand.lightTheme();
      final background = theme.filledButtonTheme.style!.backgroundColor!;
      expect(theme.colorScheme.primary, SyntilaColors.primaryColor(isDark));
      expect(background.resolve({}), theme.colorScheme.primary);
      expect(background.resolve({WidgetState.pressed}),
          SyntilaColors.primaryPressedColor(isDark));
      expect(background.resolve({WidgetState.disabled}), isNull);
      final foreground = theme.filledButtonTheme.style!.foregroundColor!;
      for (final states in [
        <WidgetState>{},
        {WidgetState.pressed}
      ]) {
        expect(
            _contrastRatio(
                foreground.resolve(states)!, background.resolve(states)!),
            greaterThanOrEqualTo(4.5));
      }
      expect(
          _contrastRatio(
              theme.colorScheme.onPrimary, theme.colorScheme.primary),
          greaterThanOrEqualTo(4.5));
    }
  });
  group('Surface Hierarchy & Theme Tokens', () {
    test('Light mode surface hierarchy is defined deterministically', () {
      expect(SyntilaColors.canvasLight, const Color(0xfff1f2f4));
      expect(SyntilaColors.surfaceLight, const Color(0xfffbfcfd));
      expect(SyntilaColors.surfaceHoverLight, const Color(0xffe7e8ea));
      expect(SyntilaColors.borderLight, const Color(0xffd3d5d7));
      expect(SyntilaColors.codeBackgroundLight, const Color(0xffe7e8ea));
    });

    test('Dark mode surface hierarchy is defined deterministically', () {
      expect(SyntilaColors.canvasDark, const Color(0xff17181a));
      expect(SyntilaColors.surfaceDark, const Color(0xff1e2021));
      expect(SyntilaColors.surfaceHoverDark, const Color(0xff252628));
      expect(SyntilaColors.borderDark, const Color(0xff2d2e30));
      expect(SyntilaColors.codeBackgroundDark, const Color(0xff111213));
    });

    test('Material 3 ColorScheme maps surface containers properly', () {
      final lightTheme = SyntilaBrand.lightTheme();
      expect(lightTheme.scaffoldBackgroundColor, SyntilaColors.canvasLight);
      expect(lightTheme.colorScheme.surface, SyntilaColors.surfaceLight);
      expect(lightTheme.colorScheme.surfaceContainerLowest,
          SyntilaColors.canvasLight);
      expect(
          lightTheme.colorScheme.surfaceContainer, SyntilaColors.surfaceLight);
      expect(lightTheme.colorScheme.surfaceContainerHigh,
          SyntilaColors.surfaceHoverLight);
      expect(lightTheme.colorScheme.surfaceContainerHighest,
          SyntilaColors.codeBackgroundLight);
      expect(lightTheme.colorScheme.outline, SyntilaColors.borderLight);

      final darkTheme = SyntilaBrand.darkTheme();
      expect(darkTheme.scaffoldBackgroundColor, SyntilaColors.canvasDark);
      expect(darkTheme.colorScheme.surface, SyntilaColors.surfaceDark);
      expect(darkTheme.colorScheme.surfaceContainerLowest,
          SyntilaColors.canvasDark);
      expect(darkTheme.colorScheme.surfaceContainer, SyntilaColors.surfaceDark);
      expect(darkTheme.colorScheme.surfaceContainerHigh,
          SyntilaColors.surfaceHoverDark);
      expect(darkTheme.colorScheme.surfaceContainerHighest,
          SyntilaColors.codeBackgroundDark);
      expect(darkTheme.colorScheme.outline, SyntilaColors.borderDark);
    });

    test('Typography tokens and scale are valid and deterministic', () {
      expect(SyntilaTypography.fontFamily, 'Inter');
      expect(SyntilaTypography.fontFamilyMono, 'JetBrains Mono');
      expect(SyntilaTypography.display.fontSize, 26);
      expect(SyntilaTypography.displayLarge.fontSize, 26);
      expect(SyntilaTypography.pageTitle.fontSize, 22);
      expect(SyntilaTypography.titleLarge.fontSize, 22);
      expect(SyntilaTypography.sectionTitle.fontSize, 17);
      expect(SyntilaTypography.titleMedium.fontSize, 17);
      expect(SyntilaTypography.cardTitle.fontSize, 15);
      expect(SyntilaTypography.titleSmall.fontSize, 15);
      expect(SyntilaTypography.bodyLarge.fontSize, 14);
      expect(SyntilaTypography.body.fontSize, 13.5);
      expect(SyntilaTypography.bodyMedium.fontSize, 13.5);
      expect(SyntilaTypography.bodySmall.fontSize, 12.5);
      expect(SyntilaTypography.caption.fontSize, 11.5);
      expect(SyntilaTypography.button.fontSize, 13);
      expect(SyntilaTypography.mono.fontSize, 12);
      expect(SyntilaTypography.codeSmall.fontSize, 12);
      expect(SyntilaTypography.codeBlock.fontSize, 13);
      expect(SyntilaTypography.monoSmall.fontSize, 11);
      expect(SyntilaTypography.wordmark.fontSize, 16);
      expect(SyntilaTypography.wordmark.fontWeight, FontWeight.w700);
      expect(SyntilaTypography.wordmark.letterSpacing, -0.32);

      // Verify no typography scale item is below 11px
      expect(SyntilaTypography.caption.fontSize!, greaterThanOrEqualTo(11.0));
      expect(SyntilaTypography.monoSmall.fontSize!, greaterThanOrEqualTo(11.0));
    });

    test('ThemeData TextTheme includes all core typographic levels', () {
      final theme = SyntilaBrand.darkTheme();
      expect(theme.textTheme.displayLarge?.fontSize, 26);
      expect(theme.textTheme.headlineMedium?.fontSize, 24);
      expect(theme.textTheme.titleLarge?.fontSize, 20);
      expect(theme.textTheme.titleMedium?.fontSize, 16);
      expect(theme.textTheme.titleSmall?.fontSize, 14);
      expect(theme.textTheme.bodyLarge?.fontSize, 14);
      expect(theme.textTheme.bodyMedium?.fontSize, 13.5);
      expect(theme.textTheme.bodySmall?.fontSize, 12);
      expect(theme.textTheme.labelLarge?.fontSize, 13);
      expect(theme.textTheme.labelSmall?.fontSize, 11.5);
      expect(theme.textTheme.labelSmall?.fontSize!, greaterThanOrEqualTo(11.0));
    });

    test('Contrast ratios meet WCAG AA standards', () {
      // 1. Normal text in Light mode
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryLight, SyntilaColors.surfaceLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryLight, SyntilaColors.canvasLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryLight, SyntilaColors.surfaceHoverLight),
          greaterThanOrEqualTo(4.5));

      // 2. Muted text in Light mode
      expect(
          _contrastRatio(
              SyntilaColors.textSecondaryLight, SyntilaColors.surfaceLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textSecondaryLight, SyntilaColors.canvasLight),
          greaterThanOrEqualTo(4.5));

      // 3. Normal text in Dark mode
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryDark, SyntilaColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryDark, SyntilaColors.canvasDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryDark, SyntilaColors.surfaceHoverDark),
          greaterThanOrEqualTo(4.5));

      // 4. Muted text in Dark mode
      expect(
          _contrastRatio(
              SyntilaColors.textSecondaryDark, SyntilaColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textSecondaryDark, SyntilaColors.canvasDark),
          greaterThanOrEqualTo(4.5));

      // 5. Accent foreground in dark mode (#B8A9FE) vs dark backgrounds
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundDark, SyntilaColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundDark, SyntilaColors.canvasDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(SyntilaColors.primaryForegroundDark,
              SyntilaColors.navigationBackgroundDark),
          greaterThanOrEqualTo(4.5));

      // 6. Button text on primary & pressed backgrounds
      expect(_contrastRatio(Colors.white, SyntilaColors.primary),
          greaterThanOrEqualTo(4.5));
      expect(_contrastRatio(Colors.white, SyntilaColors.primaryPressed),
          greaterThanOrEqualTo(4.5));

      // 7. Selected sidebar item
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryDark, SyntilaColors.navigationSelected),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(SyntilaColors.primaryForegroundDark,
              SyntilaColors.navigationSelected),
          greaterThanOrEqualTo(4.5));

      // 8. Links and Markdown links
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundLight, SyntilaColors.surfaceLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundLight, SyntilaColors.canvasLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundDark, SyntilaColors.surfaceDark),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.primaryForegroundDark, SyntilaColors.canvasDark),
          greaterThanOrEqualTo(4.5));

      // 9. Code blocks and terminal surfaces
      expect(
          _contrastRatio(SyntilaColors.textPrimaryLight,
              SyntilaColors.codeBackgroundLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              SyntilaColors.textPrimaryDark, SyntilaColors.codeBackgroundDark),
          greaterThanOrEqualTo(4.5));

      // 10. Status badge foreground & wash pairings
      expect(
          _contrastRatio(
              const Color(0xff14532d), SyntilaColors.successSoftLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(
              const Color(0xff78350f), SyntilaColors.warningSoftLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(const Color(0xff7f1d1d), SyntilaColors.errorSoftLight),
          greaterThanOrEqualTo(4.5));
      expect(
          _contrastRatio(const Color(0xff1e3a8a), SyntilaColors.infoSoftLight),
          greaterThanOrEqualTo(4.5));

      // 11. Disabled control indicators
      expect(
          _contrastRatio(SyntilaColors.textSecondaryLight,
              SyntilaColors.surfaceHoverLight),
          greaterThanOrEqualTo(3.0));
      expect(
          _contrastRatio(
              SyntilaColors.textSecondaryDark, SyntilaColors.surfaceHoverDark),
          greaterThanOrEqualTo(3.0));
    });

    test(
        'Component theme data (Buttons, Cards, Inputs, Dialogs) is configured with theme tokens',
        () {
      for (final theme in [
        SyntilaBrand.lightTheme(),
        SyntilaBrand.darkTheme()
      ]) {
        final isDark = theme.brightness == Brightness.dark;

        // Component Theme Properties
        expect(theme.cardTheme.elevation, 0);
        expect(theme.cardTheme.color,
            isDark ? SyntilaColors.surfaceDark : SyntilaColors.surfaceLight);

        // Input Decoration Theme
        expect(theme.inputDecorationTheme.filled, isTrue);
        expect(
            theme.inputDecorationTheme.fillColor,
            isDark
                ? SyntilaColors.composerBackgroundDark
                : SyntilaColors.composerBackgroundLight);

        // Button Themes
        expect(theme.filledButtonTheme.style?.shape?.resolve({}),
            isA<OutlinedBorder>());
        expect(theme.outlinedButtonTheme.style?.shape?.resolve({}),
            isA<OutlinedBorder>());

        // AppBar Theme
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.backgroundColor,
            isDark ? SyntilaColors.surfaceDark : SyntilaColors.surfaceLight);

        // SnackBar Theme
        expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
      }
    });

    test(
        'Geometry tokens (Radius, Spacing, Assets) are deterministic and immutable',
        () {
      expect(SyntilaRadius.xs, 4.0);
      expect(SyntilaRadius.sm, 6.0);
      expect(SyntilaRadius.md, 10.0);
      expect(SyntilaRadius.lg, 14.0);
      expect(SyntilaRadius.xl, 20.0);
      expect(SyntilaRadius.pill, 999.0);

      expect(SyntilaSpacing.xxs, 2.0);
      expect(SyntilaSpacing.xs, 4.0);
      expect(SyntilaSpacing.sm, 8.0);
      expect(SyntilaSpacing.md, 12.0);
      expect(SyntilaSpacing.lg, 16.0);
      expect(SyntilaSpacing.xl, 24.0);
      expect(SyntilaSpacing.xxl, 32.0);
      expect(SyntilaSpacing.xxxl, 48.0);

      expect(SyntilaBrandAssets.logoMasterSvg, contains('logo.svg'));
      expect(SyntilaBrandAssets.logoDarkMasterSvg, contains('logo_dark.svg'));
      expect(SyntilaBrandAssets.logoPng32, contains('32.png'));
      expect(SyntilaBrandAssets.logoPng64, contains('64.png'));
      expect(SyntilaBrandAssets.logoPng128, contains('128.png'));
      expect(SyntilaBrandAssets.logoPng192, contains('192.png'));
      expect(SyntilaBrandAssets.logoPng512, contains('512.png'));
      expect(SyntilaBrandAssets.logoPng1024, contains('logo.png'));
      expect(SyntilaBrandAssets.logoDarkPng32, contains('logo_dark_32.png'));
      expect(SyntilaBrandAssets.logoDarkPng64, contains('logo_dark_64.png'));
      expect(SyntilaBrandAssets.logoDarkPng128, contains('logo_dark_128.png'));
      expect(SyntilaBrandAssets.logoDarkPng192, contains('logo_dark_192.png'));
      expect(SyntilaBrandAssets.logoDarkPng512, contains('logo_dark_512.png'));
      expect(SyntilaBrandAssets.logoDarkPng1024, contains('logo_dark.png'));
      expect(SyntilaBrandAssets.logoPng1024For(false),
          SyntilaBrandAssets.logoPng1024);
      expect(SyntilaBrandAssets.logoPng1024For(true),
          SyntilaBrandAssets.logoDarkPng1024);
      expect(
          SyntilaBrandAssets.logoPng32For(false), SyntilaBrandAssets.logoPng32);
      expect(SyntilaBrandAssets.logoPng32For(true),
          SyntilaBrandAssets.logoDarkPng32);
    });

    testWidgets(
        'SyntilaBrand.logoMark selects light vs dark logo asset by theme',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.lightTheme(),
          home: Scaffold(body: SyntilaBrand.logoMark(size: 32)),
        ),
      );
      final lightImage = tester.widget<Image>(find.byType(Image));
      expect((lightImage.image as AssetImage).assetName,
          SyntilaBrandAssets.logoPng1024);

      await tester.pumpWidget(
        MaterialApp(
          theme: SyntilaBrand.darkTheme(),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(body: SyntilaBrand.logoMark(size: 32)),
        ),
      );
      await tester.pumpAndSettle();
      final darkImage = tester.widget<Image>(find.byType(Image));
      expect((darkImage.image as AssetImage).assetName,
          SyntilaBrandAssets.logoDarkPng1024);
    });
  });
}
