import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// The first visual foundation; no remote fonts or runtime assets are required.
abstract final class CosmicPalette {
  static const deep = Color(0xff050507);
  static const night = Color(0xff090e20);
  static const violet = Color(0xff302447);
  static const silver = Color(0xffc5cad3);
  static const white = Color(0xfff2f3f5);
}

ThemeData get cosmicTheme {
  // Flutter's platform typography uses the system Cupertino faces on iOS.
  final base = ThemeData(
    brightness: Brightness.dark,
    typography: Typography.material2021(platform: defaultTargetPlatform),
  );
  final text = base.textTheme.apply(
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
      displaySmall: text.displaySmall?.copyWith(
        fontSize: 36,
        height: 1.16,
        letterSpacing: -0.8,
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
      titleLarge: text.titleLarge?.copyWith(fontSize: 21, height: 1.3),
      titleMedium: text.titleMedium?.copyWith(fontSize: 17, height: 1.4),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: 17, height: 1.5),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 15, height: 1.5),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 13,
        height: 1.45,
        color: CosmicPalette.silver,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 15,
        height: 1.2,
        letterSpacing: 0.15,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: CosmicPalette.white,
      elevation: 0,
      scrolledUnderElevation: 0,
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
        backgroundColor: CosmicPalette.white,
        foregroundColor: CosmicPalette.deep,
        minimumSize: const Size(48, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        shape: const StadiumBorder(),
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
  );
}
