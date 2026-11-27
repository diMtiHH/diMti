import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// AURA 13 uses bundled OFL Manrope fonts; no runtime font download occurs.
abstract final class CosmicPalette {
  static const deep = Color(0xff050507);
  static const night = Color(0xff090e20);
  static const violet = Color(0xff302447);
  static const silver = Color(0xffc5cad3);
  static const white = Color(0xfff2f3f5);
  static const stars = Color(0xffbad2f8);
  static const galaxy = Color(0xff96aaf9);
  static const aurora = Color(0xff71dcc5);
  static const gravity = Color(0xffedb584);
}

ThemeData get cosmicTheme {
  final base = ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'Manrope',
    typography: Typography.material2021(platform: defaultTargetPlatform),
  );
  final text = base.textTheme.apply(
    fontFamily: 'Manrope',
    bodyColor: CosmicPalette.white,
    displayColor: CosmicPalette.white,
  );
  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary: CosmicPalette.white,
      onPrimary: CosmicPalette.deep,
      secondary: CosmicPalette.silver,
      onSecondary: CosmicPalette.deep,
      surface: CosmicPalette.night,
      onSurface: CosmicPalette.white,
      surfaceContainer: CosmicPalette.night,
      surfaceContainerHigh: CosmicPalette.violet,
      outline: CosmicPalette.silver,
    ),
    scaffoldBackgroundColor: CosmicPalette.deep,
    canvasColor: CosmicPalette.deep,
    textTheme: text.copyWith(
      displayLarge: text.displayLarge?.copyWith(
        fontSize: 84,
        height: 1.1,
        letterSpacing: -1,
        fontWeight: FontWeight.w300,
      ),
      displaySmall: text.displaySmall?.copyWith(
        fontSize: 32,
        height: 1.16,
        letterSpacing: -0.55,
        fontWeight: FontWeight.w400,
      ),
      headlineLarge: text.headlineLarge?.copyWith(
        fontSize: 30,
        height: 1.2,
        letterSpacing: -0.55,
        fontWeight: FontWeight.w400,
      ),
      headlineMedium: text.headlineMedium?.copyWith(
        fontSize: 26,
        height: 1.25,
        letterSpacing: -0.3,
        fontWeight: FontWeight.w400,
      ),
      titleLarge: text.titleLarge?.copyWith(fontSize: 22, height: 1.3),
      titleMedium: text.titleMedium?.copyWith(fontSize: 17, height: 1.4),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.5),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.45,
        color: CosmicPalette.silver,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 15,
        height: 1.2,
        letterSpacing: 0,
        fontWeight: FontWeight.w500,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: CosmicPalette.white,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    dividerTheme: DividerThemeData(
      color: CosmicPalette.silver.withValues(alpha: 0.16),
      thickness: 0.5,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      filled: false,
      hintStyle: text.bodyLarge?.copyWith(color: CosmicPalette.silver),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: CosmicPalette.silver.withValues(alpha: 0.10),
        foregroundColor: CosmicPalette.white,
        disabledBackgroundColor: CosmicPalette.silver.withValues(alpha: 0.04),
        disabledForegroundColor: CosmicPalette.silver.withValues(alpha: 0.45),
        minimumSize: const Size(48, 56),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        side: BorderSide(
          color: CosmicPalette.silver.withValues(alpha: 0.28),
          width: 0.8,
        ),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: CosmicPalette.white,
        backgroundColor: Colors.transparent,
        minimumSize: const Size(48, 52),
        side: BorderSide(
          color: CosmicPalette.silver.withValues(alpha: 0.24),
          width: 0.8,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: CosmicPalette.silver,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    iconTheme: const IconThemeData(color: CosmicPalette.silver, size: 22),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: CosmicPalette.silver.withValues(alpha: 0.08),
    ),
  );
}
