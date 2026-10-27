import 'package:flutter/material.dart';

/// Raw color/spacing/radius values from the hi-fi design handoff
/// (`CLAUDE_DOCS/design_handoff_tritrack`). Do not use these directly in
/// widgets — go through [AppTheme]'s `ColorScheme`/`TextTheme` so light/dark
/// switches automatically.
abstract final class DesignTokens {
  // --- Brand ---
  static const brandGreenLight = Color(0xFF3E7A4C);
  static const brandGreenDark = Color(0xFF5FAE71);
  static const brandGreenTextLight = Color(0xFF3E7A4C);
  static const brandGreenTextDark = Color(0xFF6FBF82);
  static const textOnBrandLight = Color(0xFFFFFFFF);
  static const textOnBrandDark = Color(0xFF0D1A10);
  static const brandGreenShadowLight = Color(0x663E7A4C); // rgba(62,122,76,0.4)
  static const brandGreenShadowDark = Color(0x805FAE71); // rgba(95,174,113,0.5)
  static const wordmarkTriLight = Color(0xFF1A1A1A);
  static const wordmarkTriDark = Color(0xFFF3EFE4);

  // --- Functional (semantic; never rebrand) ---
  static const bearingBlueLight = Color(0xFF3B82F6);
  static const bearingBlueDark = Color(0xFF60A5FA);
  static const estimatedPositionBlueLight = Color(0xFF2563EB);
  static const estimatedPositionBlueDark = Color(0xFF3B82F6);
  static const animalFixGreenLight = Color(0xFF16A34A);
  static const animalFixGreenDark = Color(0xFF22C55E);
  static const bounceRedLight = Color(0xFFDC2626);
  static const bounceRedDark = Color(0xFFF87171);
  static const fairAmberLight = Color(0xFFD97706);
  static const fairAmberDark = Color(0xFFF59E0B);
  static const viewshedOverlayLight = Color(0x4D966EDC); // rgba(150,110,220,0.30)
  static const viewshedOverlayDark = Color(0x38966EDC); // rgba(150,110,220,0.22)

  /// The "navigate to a point" line/indicator (Main Map + Compass) — a
  /// distinct blue from [bearingBlueLight]/[bearingBlueDark] so a live nav
  /// line never reads as just another bearing ray.
  static const navigationLineLight = Color(0xFF0EA5E9);
  static const navigationLineDark = Color(0xFF38BDF8);

  /// Compass magnetic needle color.
  static const compassNeedleRedLight = bounceRedLight;
  static const compassNeedleRedDark = bounceRedDark;

  /// Compass true-north marker color. Superseded the 2026-07-16 "same red
  /// family, distinguish by shape only" decision on 2026-07-17 — the user
  /// asked explicitly for a visibly lighter red so magnetic vs. true is
  /// distinguishable by color at a glance, iPhone-Compass-style.
  static const compassTrueNorthRedLight = Color(0xFFF29999);
  static const compassTrueNorthRedDark = Color(0xFFFCA5A5);

  // --- Neutrals ---
  static const appBackgroundLight = Color(0xFFEEEEEC);
  static const appBackgroundDark = Color(0xFF141414);
  static const cardBackgroundLight = Color(0xFFFFFFFF);
  static const cardBackgroundDark = Color(0xFF1C1C1C);
  static const primaryTextLight = Color(0xFF1A1A1A);
  static const primaryTextDark = Color(0xFFF2F2F0);
  static const secondaryTextLight = Color(0xFF6B6B68);
  static const secondaryTextDark = Color(0xFF9C9C98);
  static const borderLight = Color(0xFFE2E2DF);
  static const borderDark = Color(0xFF2A2A2A);
  static const borderHeavyLight = Color(0xFF1A1A1A);
  static const borderHeavyDark = Color(0xFFF2F2F0);

  /// The low-emphasis neutral: decorative boundaries, and the *filled*
  /// decorative shapes this app draws with the same role (a bottom-sheet drag
  /// handle, the dimmed observer badge on the Position screen). Task 11.201.
  ///
  /// **Deliberately more present than [borderLight]/[borderDark], which is
  /// the opposite of Material 3's baseline ordering** — there, `outlineVariant`
  /// is fainter than `outline`. This app's `outline` is already a hairline
  /// (#E2E2DF on white is 1.14:1), so a fainter still value would be a shape
  /// nobody can see. The two things drawn in this role here are objects rather
  /// than rules, so the value is a mid neutral: 2.44:1 against the card in
  /// light and 1.92:1 in dark, with the meaning-bearing text on top of it at
  /// 7.12:1 and 7.93:1 (see `AppTheme`).
  static const outlineVariantLight = Color(0xFFA6A6A1);
  static const outlineVariantDark = Color(0xFF4A4A47);

  // --- Container roles (Material 3 "container" pairs) ---
  // Each is a tint to sit a label on, never the saturated functional colour.
  // Task 11.201 defined all six; before that every one of them fell back to
  // its non-container sibling, so an error *tint* rendered as full-strength
  // bounce red and its label rendered white.

  /// Pale red tint behind an error message. Pairs with
  /// [onErrorContainerLight] at 8.21:1, and with the theme's ordinary body
  /// text at 14.25:1 — which matters, because the held-record card on the
  /// Sync Status screen puts default-coloured text on it.
  static const errorContainerLight = Color(0xFFFBE3E3);
  static const errorContainerDark = Color(0xFF3B1A1A);
  static const onErrorContainerLight = Color(0xFF7F1D1D);
  static const onErrorContainerDark = Color(0xFFFCCFCF);

  /// Pale green tint, the quiet sibling of the brand green. One caller: the
  /// cloud-backup retirement notice. Pairs at 7.84:1 light, 10.31:1 dark.
  static const secondaryContainerLight = Color(0xFFE3EFE6);
  static const secondaryContainerDark = Color(0xFF1F2E23);
  static const onSecondaryContainerLight = Color(0xFF24502F);
  static const onSecondaryContainerDark = Color(0xFFC4E3CB);

  /// The neutral panel three "here is a fact about your setup" boxes are
  /// drawn in. Subtle on purpose — 1.18:1 against the card in light, 1.13:1
  /// in dark — but no longer *identical* to it, which is what falling back to
  /// `surface` made it. The muted label on it clears 4.5:1 in both modes.
  static const surfaceContainerHighestLight = Color(0xFFECECE9);
  static const surfaceContainerHighestDark = Color(0xFF262626);

  // --- Spacing & radius ---
  static const spacingScreenHorizontal = 20.0;
  static const spacingSectionGap = 12.0;
  static const radiusSmall = 10.0;
  static const radiusCard = 12.0;
  static const radiusPill = 20.0;

  // --- Touch targets ---
  static const minTouchTarget = 44.0;
  static const tabBarHeight = 88.0;
  static const brandHeaderHeight = 44.0;
}
