import 'package:flutter/material.dart';

import 'colors.dart';
import 'dialog_style.dart';
import 'radius.dart';
import 'typography.dart';
import 'brand_assets.dart';

/// Shared Syntila theme system and brand container.
abstract final class SyntilaBrand {
  // Brand Accents
  static const accent = SyntilaColors.primary;
  static const accentDark = SyntilaColors.primaryPressed;
  static const accentWash = SyntilaColors.primarySoft;
  static const accentWashDark = SyntilaColors.primarySoftDark;

  // Light Palette
  static const lightInk = SyntilaColors.textPrimaryLight;
  static const lightInkMuted = SyntilaColors.textSecondaryLight;
  static const lightPaper = SyntilaColors.canvasLight;
  static const lightSurface = SyntilaColors.surfaceLight;
  static const lightSurfaceHover = SyntilaColors.surfaceHoverLight;
  static const lightLine = SyntilaColors.borderLight;
  static const lightCodeBackground = SyntilaColors.codeBackgroundLight;

  // Dark Palette
  static const darkInk = SyntilaColors.textPrimaryDark;
  static const darkInkMuted = SyntilaColors.textSecondaryDark;
  static const darkPaper = SyntilaColors.canvasDark;
  static const darkSurface = SyntilaColors.surfaceDark;
  static const darkSurfaceHover = SyntilaColors.surfaceHoverDark;
  static const darkLine = SyntilaColors.borderDark;
  static const darkCodeBackground = SyntilaColors.codeBackgroundDark;
  static const darkComposer = SyntilaColors.composerBackgroundDark;
  static const darkNavigation = SyntilaColors.navigationBackgroundDark;
  static const darkOwnMessage = SyntilaColors.ownMessageBackgroundDark;

  // Semantic Status Colors
  static const success = SyntilaColors.success;
  static const successWash = SyntilaColors.successSoftLight;
  static const successWashDark = SyntilaColors.successSoftDark;

  static const warning = SyntilaColors.warning;
  static const warningWash = SyntilaColors.warningSoftLight;
  static const warningWashDark = SyntilaColors.warningSoftDark;

  static const error = SyntilaColors.error;
  static const errorWash = SyntilaColors.errorSoftLight;
  static const errorWashDark = SyntilaColors.errorSoftDark;

  static const info = SyntilaColors.info;
  static const infoWash = SyntilaColors.infoSoftLight;
  static const infoWashDark = SyntilaColors.infoSoftDark;

  static const neutral = SyntilaColors.neutral;
  static const neutralWash = SyntilaColors.neutralSoftLight;
  static const neutralWashDark = SyntilaColors.neutralSoftDark;

  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
    Brightness? brightness,
  }) =>
      SyntilaBrandAssets.logoMark(
        size: size,
        borderRadius: borderRadius,
        fit: fit,
        brightness: brightness,
      );

  // Responsive Breakpoints
  static const double desktopBreakpoint = 600.0;
  static const double tabletBreakpoint = 600.0;

  static bool isDesktop(double width) => width >= desktopBreakpoint;
  static bool isTablet(double width) => width < desktopBreakpoint;
  static bool isMobile(double width) => width < desktopBreakpoint;

  /// Builds the canonical light [ThemeData] for Syntila.
  static ThemeData lightTheme() {
    const colorScheme = ColorScheme.light(
      primary: SyntilaColors.primary,
      primaryContainer: SyntilaColors.primarySoft,
      secondary: SyntilaColors.primaryPressed,
      surface: SyntilaColors.surfaceLight,
      surfaceContainerLowest: SyntilaColors.canvasLight,
      surfaceContainerLow: SyntilaColors.surfaceLight,
      surfaceContainer: SyntilaColors.surfaceLight,
      surfaceContainerHigh: SyntilaColors.surfaceHoverLight,
      surfaceContainerHighest: SyntilaColors.codeBackgroundLight,
      error: SyntilaColors.error,
      onPrimary: Colors.white,
      onPrimaryContainer: SyntilaColors.primaryPressed,
      onSurface: SyntilaColors.textPrimaryLight,
      onSurfaceVariant: SyntilaColors.textSecondaryLight,
      onError: Colors.white,
      outline: SyntilaColors.borderLight,
      outlineVariant: SyntilaColors.borderLight,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: SyntilaColors.canvasLight,
      cardColor: SyntilaColors.surfaceLight,
      dividerColor: SyntilaColors.borderLight,
      fontFamily: SyntilaTypography.fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: SyntilaColors.surfaceLight,
        foregroundColor: SyntilaColors.textPrimaryLight,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: SyntilaColors.surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: SyntilaColors.borderLight),
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SyntilaColors.composerBackgroundLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide: const BorderSide(color: SyntilaColors.borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide: const BorderSide(color: SyntilaColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide:
              BorderSide(color: SyntilaColors.focusBorder(false), width: 1.5),
        ),
        labelStyle: TextStyle(color: SyntilaColors.textSecondary(false)),
        hintStyle: TextStyle(color: SyntilaColors.textSecondary(false)),
        floatingLabelStyle:
            WidgetStateTextStyle.resolveWith((states) => TextStyle(
                color: states.contains(WidgetState.error)
                    ? SyntilaColors.errorText(false)
                    : states.contains(WidgetState.focused)
                        ? SyntilaColors.focusLabel(false)
                        : SyntilaColors.textSecondary(false))),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(SyntilaColors.textPrimaryLight),
      iconButtonTheme: _iconButtonTheme(),
      segmentedButtonTheme: const SegmentedButtonThemeData(
        style: ButtonStyle(
            shape: WidgetStatePropertyAll(SyntilaRadius.buttonShape)),
      ),
      filledButtonTheme: _filledButtonTheme(false),
      outlinedButtonTheme: _outlinedButtonTheme(
          SyntilaColors.borderLight, SyntilaColors.primaryForegroundLight),
      textButtonTheme: _textButtonTheme(SyntilaColors.primaryForegroundLight),
      dialogTheme: SyntilaDialogStyle.theme(false),
      chipTheme: _chipTheme(
          SyntilaColors.surfaceHoverLight, SyntilaColors.textPrimaryLight),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SyntilaColors.textPrimaryLight,
        contentTextStyle: const TextStyle(
          color: SyntilaColors.textPrimaryDark,
          fontSize: 13,
          fontFamily: SyntilaTypography.fontFamily,
        ),
        actionTextColor: SyntilaColors.primaryForegroundDark,
        disabledActionTextColor: SyntilaColors.textSecondaryLight,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SyntilaRadius.md)),
      ),
    );
  }

  /// Builds the canonical dark [ThemeData] for Syntila.
  static ThemeData darkTheme() {
    const colorScheme = ColorScheme.dark(
      primary: SyntilaColors.primaryDark,
      primaryContainer: SyntilaColors.primarySoftDark,
      secondary: SyntilaColors.primaryPressedDark,
      surface: SyntilaColors.surfaceDark,
      surfaceContainerLowest: SyntilaColors.canvasDark,
      surfaceContainerLow: SyntilaColors.surfaceDark,
      surfaceContainer: SyntilaColors.surfaceDark,
      surfaceContainerHigh: SyntilaColors.surfaceHoverDark,
      surfaceContainerHighest: SyntilaColors.codeBackgroundDark,
      error: SyntilaColors.error,
      onPrimary: Colors.black,
      onPrimaryContainer: SyntilaColors.primaryForegroundDark,
      onSurface: SyntilaColors.textPrimaryDark,
      onSurfaceVariant: SyntilaColors.textSecondaryDark,
      onError: Colors.white,
      outline: SyntilaColors.borderDark,
      outlineVariant: SyntilaColors.borderDark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: SyntilaColors.canvasDark,
      cardColor: SyntilaColors.surfaceDark,
      dividerColor: SyntilaColors.borderDark,
      fontFamily: SyntilaTypography.fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: SyntilaColors.surfaceDark,
        foregroundColor: SyntilaColors.textPrimaryDark,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: SyntilaColors.surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: SyntilaColors.borderDark),
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: SyntilaColors.composerBackgroundDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide: const BorderSide(color: SyntilaColors.borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide: const BorderSide(color: SyntilaColors.borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
          borderSide:
              BorderSide(color: SyntilaColors.focusBorder(true), width: 1.5),
        ),
        labelStyle: TextStyle(color: SyntilaColors.textSecondary(true)),
        hintStyle: TextStyle(color: SyntilaColors.textSecondary(true)),
        floatingLabelStyle:
            WidgetStateTextStyle.resolveWith((states) => TextStyle(
                color: states.contains(WidgetState.error)
                    ? SyntilaColors.errorText(true)
                    : states.contains(WidgetState.focused)
                        ? SyntilaColors.focusLabel(true)
                        : SyntilaColors.textSecondary(true))),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(SyntilaColors.textPrimaryDark),
      iconButtonTheme: _iconButtonTheme(),
      segmentedButtonTheme: const SegmentedButtonThemeData(
        style: ButtonStyle(
            shape: WidgetStatePropertyAll(SyntilaRadius.buttonShape)),
      ),
      filledButtonTheme: _filledButtonTheme(true),
      outlinedButtonTheme: _outlinedButtonTheme(
          SyntilaColors.borderDark, SyntilaColors.primaryForegroundDark),
      textButtonTheme: _textButtonTheme(SyntilaColors.primaryForegroundDark),
      dialogTheme: SyntilaDialogStyle.theme(true),
      chipTheme: _chipTheme(
          SyntilaColors.surfaceHoverDark, SyntilaColors.textPrimaryDark),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: SyntilaColors.surfaceHoverDark,
        contentTextStyle: const TextStyle(
          color: SyntilaColors.textPrimaryDark,
          fontSize: 13,
          fontFamily: SyntilaTypography.fontFamily,
        ),
        actionTextColor: SyntilaColors.primaryForegroundDark,
        disabledActionTextColor: SyntilaColors.textSecondaryDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: SyntilaColors.borderDark),
          borderRadius: BorderRadius.circular(SyntilaRadius.md),
        ),
      ),
    );
  }

  static TextTheme _textTheme(Color foreground) => TextTheme(
        displayLarge: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w700,
          fontSize: 26,
          letterSpacing: -0.02,
          height: 1.25,
        ),
        headlineMedium: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w700,
          fontSize: 24,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
        titleSmall: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        bodyLarge: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 14,
          height: 1.45,
        ),
        bodyMedium: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 13.5,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 12,
          height: 1.35,
        ),
        labelLarge: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.005,
        ),
        labelSmall: TextStyle(
          color: foreground,
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
        ),
      );

  static IconButtonThemeData _iconButtonTheme() => IconButtonThemeData(
        style: IconButton.styleFrom(shape: SyntilaRadius.buttonShape),
      );

  static FilledButtonThemeData _filledButtonTheme(bool isDark) =>
      FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: SyntilaColors.primaryColor(isDark),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: SyntilaRadius.buttonShape,
        ).copyWith(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return null;
            return isDark && !states.contains(WidgetState.pressed)
                ? Colors.black
                : Colors.white;
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return null;
            return states.contains(WidgetState.pressed)
                ? SyntilaColors.primaryPressedColor(isDark)
                : SyntilaColors.primaryColor(isDark);
          }),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(Color border,
          [Color? foreground]) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground ?? SyntilaColors.primary,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: SyntilaRadius.buttonShape,
        ),
      );

  static TextButtonThemeData _textButtonTheme([Color? foreground]) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: foreground ?? SyntilaColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: SyntilaRadius.buttonShape,
        ),
      );

  static ChipThemeData _chipTheme(Color surface, Color foreground) =>
      ChipThemeData(
        backgroundColor: surface,
        labelStyle: TextStyle(color: foreground, fontSize: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(SyntilaRadius.pill)),
      );
}
