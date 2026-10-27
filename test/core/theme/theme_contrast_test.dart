// **Task 11.201 — assert the contrast, never the token.**
//
// The lesson task 11.200 asked to be carried forward, now in `CLAUDE.md`: a
// check that compares a widget's colour to a theme token is keyed on that
// token's *name*, and passes whatever the name resolves to. That is how the
// Record screen's "light grey by default" label went unmet under a green
// suite — the test compared the label to `onSurfaceVariant`, and
// `onSurfaceVariant` was not passed to this app's `ColorScheme`, so it
// resolved to full-strength body text and the comparison held.
//
// So nothing here names a token on both sides of an `expect`. Every assertion
// is a **measured WCAG 2.1 contrast ratio** between two concrete `Color`
// values pulled out of the real themes, or out of a real widget the app
// builds. A theme that redefines a role cannot satisfy these by redefining it
// consistently; only an actually readable pairing can.
//
// ## Which floor, and why
//
// **WCAG 2.1 SC 1.4.3 (AA), 4.5:1, for text.** The relaxed 3:1 "large text"
// allowance starts at 18pt regular or 14pt bold; nothing checked here is
// remotely that size — the observer badge's initials are 9px bold — so the
// normal-text floor is the one that applies everywhere below.
//
// **WCAG 2.1 SC 1.4.11 (AA), 3:1, for non-text.** Used for the one graphical
// element asserted here, the retirement notice's chevron.
//
// The badge additionally clears **SC 1.4.6 (AAA), 7:1**, which is asserted
// rather than merely noted: it is the item this task existed for, it is read
// in sunlight on a phone in a field, and the headroom is free.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/position_estimation/screens/position_estimation_screen.dart';

/// WCAG 2.1 relative luminance of an opaque colour.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2.1 contrast ratio between two opaque colours, 1.0 to 21.0.
double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [foreground] composited over [background] at its own alpha — what the eye
/// actually receives where the app draws a translucent colour.
Color flatten(Color foreground, Color background) {
  final a = foreground.a;
  return Color.from(
    alpha: 1,
    red: foreground.r * a + background.r * (1 - a),
    green: foreground.g * a + background.g * (1 - a),
    blue: foreground.b * a + background.b * (1 - a),
  );
}

/// The two backgrounds this app ever puts content on: a card and the page.
/// `surfaceContainerLowest` is what `AppTheme` uses for the scaffold.
({Color card, Color page}) _grounds(ColorScheme s) =>
    (card: s.surface, page: s.surfaceContainerLowest);

void main() {
  final themes = <String, ThemeData>{
    'light': AppTheme.light(),
    'dark': AppTheme.dark(),
  };

  group('the observer badge, excluded — the state it was invisible in', () {
    // Rendered, not reasoned about. The colours asserted are the ones the
    // widget actually hands to `CircleAvatar` and to its `Text`, so a later
    // edit that swaps either role is measured rather than re-approved.
    ({Color fill, Color initials}) badgeColors(WidgetTester tester) {
      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      final text = tester.widget<Text>(find.text('AV'));
      final fill = avatar.backgroundColor;
      final initials = text.style?.color;
      expect(
        fill,
        isNotNull,
        reason: 'the badge drew no fill at all, so nothing below measured the '
            'thing this test is about',
      );
      expect(initials, isNotNull, reason: 'the badge drew initials with no colour');
      return (fill: fill!, initials: initials!);
    }

    for (final entry in themes.entries) {
      final name = entry.key;
      final theme = entry.value;

      testWidgets('$name: initials clear AA (4.5:1) and AAA (7:1) on the badge',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(child: ObserverBadge(initials: 'AV', dimmed: true)),
          ),
        ));
        final c = badgeColors(tester);
        final ratio = contrast(c.initials, c.fill);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: 'An excluded observer\'s initials measure '
              '${ratio.toStringAsFixed(2)}:1 against their own badge in the '
              '$name theme. They were 1.00:1 before task 11.200 and 3.26:1 '
              '(light) / 2.46:1 (dark) after it. 9px bold is normal text '
              'under WCAG 2.1, so the floor is SC 1.4.3\'s 4.5:1.',
        );
        expect(
          ratio,
          greaterThanOrEqualTo(7.0),
          reason: 'The excluded badge is the one control this task existed '
              'for and it is read outdoors, so it holds SC 1.4.6 (AAA, 7:1) '
              'and not only AA. Measured ${ratio.toStringAsFixed(2)}:1 in the '
              '$name theme.',
        );
      });

      testWidgets('$name: an excluded badge does not read as an included one',
          (tester) async {
        // The non-colour cue is the initials (task 11.152); the colour is the
        // accelerator, and it still has to change. This asserts the two
        // states differ as *values*, which is not something a theme can
        // satisfy by resolving two names to one colour.
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(child: ObserverBadge(initials: 'AV', dimmed: true)),
          ),
        ));
        final excluded = badgeColors(tester);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Center(child: ObserverBadge(initials: 'AV', dimmed: false)),
          ),
        ));
        final included = badgeColors(tester);
        expect(
          contrast(excluded.fill, included.fill),
          greaterThanOrEqualTo(1.5),
          reason: 'The excluded and included badges are nearly the same '
              'colour in the $name theme, so the dimming carries no signal.',
        );
      });
    }
  });

  group('container roles pair with the colours drawn on them', () {
    // Each row is a pairing the app actually draws, named by what a person
    // sees rather than by the token. Failures print the measured ratio, so
    // the last line of a CI tail is a finding.
    for (final entry in themes.entries) {
      final name = entry.key;
      final s = entry.value.colorScheme;
      final grounds = _grounds(s);

      test('$name: the error banners\' own label', () {
        final ratio = contrast(s.onErrorContainer, s.errorContainer);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'Error-tint banners (Sync Status held record, Main Map '
                'computation failure, Server settings, Project setup) measure '
                '${ratio.toStringAsFixed(2)}:1 in $name.');
      });

      test('$name: default body text on an error banner', () {
        // The held-record card on Sync Status puts *unstyled* text on this
        // fill, so the pairing that matters there is not the "on" role.
        final ratio = contrast(s.onSurface, s.errorContainer);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'The Sync Status held-record card writes "Why it is '
                'waiting" and "What you can do" in ordinary body text on the '
                'error tint: ${ratio.toStringAsFixed(2)}:1 in $name.');
      });

      test('$name: the error tint at the 40% the project-setup screen uses',
          () {
        // Project setup draws `errorContainer.withValues(alpha: 0.4)` over
        // the page, so the real background is the composite.
        for (final ground in [grounds.card, grounds.page]) {
          final fill = flatten(s.errorContainer.withValues(alpha: 0.4), ground);
          final ratio = contrast(s.onErrorContainer, fill);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: 'Project setup\'s 40% error tint measures '
                  '${ratio.toStringAsFixed(2)}:1 in $name.');
        }
      });

      test('$name: the viewer notice on the Record screen, which has no tint',
          () {
        // The one place an "on-container" colour is drawn with no container:
        // the sentence telling a viewer why they cannot record. It was white
        // on white in light mode until this token was defined.
        for (final ground in [grounds.card, grounds.page]) {
          final ratio = contrast(s.onErrorContainer, ground);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: '"Viewers cannot record observations" measures '
                  '${ratio.toStringAsFixed(2)}:1 in $name.');
        }
      });

      test('$name: the cloud-backup retirement notice', () {
        final ratio = contrast(s.onSecondaryContainer, s.secondaryContainer);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'The retirement notice\'s title and subtitle measure '
                '${ratio.toStringAsFixed(2)}:1 in $name.');
        // Its chevron is drawn at 70% — a graphical element, SC 1.4.11.
        final chevron = flatten(
          s.onSecondaryContainer.withValues(alpha: 0.7),
          s.secondaryContainer,
        );
        final chevronRatio = contrast(chevron, s.secondaryContainer);
        expect(chevronRatio, greaterThanOrEqualTo(3.0),
            reason: 'The retirement notice\'s chevron measures '
                '${chevronRatio.toStringAsFixed(2)}:1 in $name; non-text '
                'needs 3:1.');
      });

      test('$name: the three neutral setup panels', () {
        // Profile, Server settings and the Tag database all draw a muted
        // label inside a `surfaceContainerHighest` box.
        final ratio = contrast(s.onSurfaceVariant, s.surfaceContainerHighest);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'The muted text inside the setup panels measures '
                '${ratio.toStringAsFixed(2)}:1 in $name.');
      });

      test('$name: the setup panel is distinguishable from what it sits on',
          () {
        // Not a WCAG floor — a panel is not a control and its border and icon
        // carry it. The assertion is only that it is no longer *identical* to
        // the card, which is what falling back to `surface` made it: 1.00.
        final ratio = contrast(s.surfaceContainerHighest, grounds.card);
        expect(ratio, greaterThan(1.05),
            reason: 'The setup panels measure ${ratio.toStringAsFixed(2)}:1 '
                'against the card in $name — indistinguishable, which is what '
                'this token falling back to `surface` used to produce.');
      });

      test('$name: muted text stays readable on both grounds', () {
        for (final ground in [grounds.card, grounds.page]) {
          final ratio = contrast(s.onSurfaceVariant, ground);
          expect(ratio, greaterThanOrEqualTo(4.5),
              reason: 'Muted labels measure ${ratio.toStringAsFixed(2)}:1 in '
                  '$name.');
        }
      });
    }
  });

  test('the two themes are actually different themes', () {
    // A guard against this whole file passing by measuring one theme twice —
    // a mistake that would leave the dark half, which was the harder one at
    // 2.46:1, unmeasured while every assertion above stayed green.
    expect(
      AppTheme.light().colorScheme.surface,
      isNot(AppTheme.dark().colorScheme.surface),
      reason: 'AppTheme.light() and AppTheme.dark() returned the same surface '
          'colour, so every "dark" assertion in this file measured the light '
          'theme.',
    );
  });
}
