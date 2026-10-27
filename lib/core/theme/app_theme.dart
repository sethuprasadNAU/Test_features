import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// Semantic color roles beyond what [ColorScheme] models directly, e.g. the
/// map-layer and bearing-quality colors that must stay distinct from the
/// brand palette (see the design doc's "functional colors, do not rebrand"
/// table). Access via `Theme.of(context).extension<TriTrackColors>()!`.
@immutable
class TriTrackColors extends ThemeExtension<TriTrackColors> {
  const TriTrackColors({
    required this.bearingRay,
    required this.estimatedPosition,
    required this.animalFix,
    required this.bounceRed,
    required this.fairAmber,
    required this.viewshedOverlay,
    required this.compassMagneticNeedle,
    required this.compassTrueNorth,
    required this.navigationLine,
  });

  final Color bearingRay;
  final Color estimatedPosition;
  final Color animalFix;
  final Color bounceRed;
  final Color fairAmber;
  final Color viewshedOverlay;
  final Color compassMagneticNeedle;
  final Color compassTrueNorth;
  final Color navigationLine;

  static const light = TriTrackColors(
    bearingRay: DesignTokens.bearingBlueLight,
    estimatedPosition: DesignTokens.estimatedPositionBlueLight,
    animalFix: DesignTokens.animalFixGreenLight,
    bounceRed: DesignTokens.bounceRedLight,
    fairAmber: DesignTokens.fairAmberLight,
    viewshedOverlay: DesignTokens.viewshedOverlayLight,
    compassMagneticNeedle: DesignTokens.compassNeedleRedLight,
    compassTrueNorth: DesignTokens.compassTrueNorthRedLight,
    navigationLine: DesignTokens.navigationLineLight,
  );

  static const dark = TriTrackColors(
    bearingRay: DesignTokens.bearingBlueDark,
    estimatedPosition: DesignTokens.estimatedPositionBlueDark,
    animalFix: DesignTokens.animalFixGreenDark,
    bounceRed: DesignTokens.bounceRedDark,
    fairAmber: DesignTokens.fairAmberDark,
    viewshedOverlay: DesignTokens.viewshedOverlayDark,
    compassMagneticNeedle: DesignTokens.compassNeedleRedDark,
    compassTrueNorth: DesignTokens.compassTrueNorthRedDark,
    navigationLine: DesignTokens.navigationLineDark,
  );

  @override
  TriTrackColors copyWith({
    Color? bearingRay,
    Color? estimatedPosition,
    Color? animalFix,
    Color? bounceRed,
    Color? fairAmber,
    Color? viewshedOverlay,
    Color? compassMagneticNeedle,
    Color? compassTrueNorth,
    Color? navigationLine,
  }) {
    return TriTrackColors(
      bearingRay: bearingRay ?? this.bearingRay,
      estimatedPosition: estimatedPosition ?? this.estimatedPosition,
      animalFix: animalFix ?? this.animalFix,
      bounceRed: bounceRed ?? this.bounceRed,
      fairAmber: fairAmber ?? this.fairAmber,
      viewshedOverlay: viewshedOverlay ?? this.viewshedOverlay,
      compassMagneticNeedle: compassMagneticNeedle ?? this.compassMagneticNeedle,
      compassTrueNorth: compassTrueNorth ?? this.compassTrueNorth,
      navigationLine: navigationLine ?? this.navigationLine,
    );
  }

  @override
  TriTrackColors lerp(ThemeExtension<TriTrackColors>? other, double t) {
    if (other is! TriTrackColors) return this;
    return TriTrackColors(
      bearingRay: Color.lerp(bearingRay, other.bearingRay, t)!,
      estimatedPosition: Color.lerp(estimatedPosition, other.estimatedPosition, t)!,
      animalFix: Color.lerp(animalFix, other.animalFix, t)!,
      bounceRed: Color.lerp(bounceRed, other.bounceRed, t)!,
      fairAmber: Color.lerp(fairAmber, other.fairAmber, t)!,
      viewshedOverlay: Color.lerp(viewshedOverlay, other.viewshedOverlay, t)!,
      compassMagneticNeedle: Color.lerp(compassMagneticNeedle, other.compassMagneticNeedle, t)!,
      compassTrueNorth: Color.lerp(compassTrueNorth, other.compassTrueNorth, t)!,
      navigationLine: Color.lerp(navigationLine, other.navigationLine, t)!,
    );
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(brightness: Brightness.light);
  static ThemeData dark() => _build(brightness: Brightness.dark);

  static ThemeData _build({required Brightness brightness}) {
    final isDark = brightness == Brightness.dark;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: isDark ? DesignTokens.brandGreenDark : DesignTokens.brandGreenLight,
      onPrimary: isDark ? DesignTokens.textOnBrandDark : DesignTokens.textOnBrandLight,
      secondary: isDark ? DesignTokens.brandGreenTextDark : DesignTokens.brandGreenTextLight,
      onSecondary: isDark ? DesignTokens.textOnBrandDark : DesignTokens.textOnBrandLight,
      error: isDark ? DesignTokens.bounceRedDark : DesignTokens.bounceRedLight,
      onError: DesignTokens.textOnBrandLight,
      surface: isDark ? DesignTokens.cardBackgroundDark : DesignTokens.cardBackgroundLight,
      onSurface: isDark ? DesignTokens.primaryTextDark : DesignTokens.primaryTextLight,
      // **Task 11.200: this was absent, and absent is not neutral.** Flutter's
      // `ColorScheme.onSurfaceVariant` getter falls back to `onSurface` when it
      // is not passed, so for as long as this line did not exist every one of
      // the 83 places in `lib/` asking for the *muted* colour was handed
      // full-strength body text — including the Record screen's
      // Irregular/Malfunctioning label, which Michael asked for in so many
      // words to be "light grey by default".
      //
      // The value is not invented here: `secondaryText*` has been in
      // `DesignTokens` since the design handoff and had no caller. Measured
      // against both backgrounds this theme uses, it clears WCAG AA (4.5:1)
      // for normal text in both modes: light `#6B6B68` is 5.35:1 on the card
      // and 4.60:1 on the app background; dark `#9C9C98` is 6.19:1 and 6.69:1.
      onSurfaceVariant: isDark
          ? DesignTokens.secondaryTextDark
          : DesignTokens.secondaryTextLight,
      surfaceContainerLowest: isDark
          ? DesignTokens.appBackgroundDark
          : DesignTokens.appBackgroundLight,
      outline: isDark ? DesignTokens.borderDark : DesignTokens.borderLight,
      // **Task 11.201 — the six that were left.** Same class as
      // `onSurfaceVariant` above and found by the same guard: a member the
      // theme did not pass, silently substituted by Flutter's getter.
      //
      // `outlineVariant` was the one above the line. It fell back to
      // `onBackground` -> `onSurface`, so the Position screen's *dimmed*
      // observer badge drew its circle in the app's darkest text colour and
      // its initials on it in `onSurfaceVariant`: 1.00:1 before task 11.200,
      // 3.26:1 light and 2.46:1 dark after it. Task 11.152 chose initials
      // over a colour swap precisely so that badge would not depend on colour
      // vision, and the state it failed in is the *excluded* one — exactly
      // when somebody is asking whose bearing they took out.
      outlineVariant: isDark
          ? DesignTokens.outlineVariantDark
          : DesignTokens.outlineVariantLight,
      // The container roles. Every one of these fell back to its saturated
      // sibling, which is why the app's "error tint" banners were solid
      // bounce red and the cloud-backup notice was a solid brand-green bar.
      // Measured pairings are on the tokens themselves.
      errorContainer: isDark
          ? DesignTokens.errorContainerDark
          : DesignTokens.errorContainerLight,
      onErrorContainer: isDark
          ? DesignTokens.onErrorContainerDark
          : DesignTokens.onErrorContainerLight,
      secondaryContainer: isDark
          ? DesignTokens.secondaryContainerDark
          : DesignTokens.secondaryContainerLight,
      onSecondaryContainer: isDark
          ? DesignTokens.onSecondaryContainerDark
          : DesignTokens.onSecondaryContainerLight,
      surfaceContainerHighest: isDark
          ? DesignTokens.surfaceContainerHighestDark
          : DesignTokens.surfaceContainerHighestLight,
    );

    final textTheme = _textTheme(colorScheme);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark
          ? DesignTokens.appBackgroundDark
          : DesignTokens.appBackgroundLight,
      textTheme: textTheme,
      extensions: [isDark ? TriTrackColors.dark : TriTrackColors.light],
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      // **Task 11.332.** A form field draws its error and helper text with an
      // ellipsis, and with these two left null that means one line. The
      // server address field's refusal is three sentences, and on the
      // 6.1-inch phone at the default text size it showed one line of them
      // ending in "…" (33% of it). Twenty is "as many as it needs": no
      // sentence this app writes under a field comes close.
      inputDecorationTheme: const InputDecorationTheme(
        errorMaxLines: formMessageMaxLines,
        helperMaxLines: formMessageMaxLines,
      ),
    );
  }

  /// How many lines a form field's error or helper text may take before it
  /// is cut — see the `inputDecorationTheme` above (task 11.332).
  static const int formMessageMaxLines = 20;

  // Type scale per the handoff: 8-10px micro-labels, 11-13px secondary/list,
  // 14-16px section headers/body, 18-20px screen titles, 24-30px key readouts.
  static TextTheme _textTheme(ColorScheme scheme) {
    final base = TextTheme(
      displaySmall: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: scheme.onSurface),
      headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: scheme.onSurface),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: scheme.onSurface),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: scheme.onSurface),
      bodyLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: scheme.onSurface),
      bodyMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: scheme.onSurface),
      labelLarge: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.04 * 12),
      labelSmall: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w400, color: scheme.onSurface),
    );
    return base;
  }
}
