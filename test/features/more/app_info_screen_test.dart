import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';
import 'package:tritrack/features/more/screens/app_info_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/fake_url_launcher.dart';

/// Task 11.133 item 3 — the page a beta tester is sent to when a report needs
/// a build number, and the home for the full map attributions.
///
/// Pumped **inside the real app shell** rather than bare, which is the default
/// for a new screen test (task 11.111). It would have been defensible to
/// exempt this one — the screen is a plain `ListView` and every assertion
/// below is about what it contains rather than what fits — but the exemption
/// is a claim somebody has to re-check when the screen grows, and using the
/// harness is one line.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  setUp(() {
    // `package_info_plus` reads the platform; in a widget test there is no
    // platform, so this stands in for one. That it *can* be faked is the
    // whole reason the screen takes no version argument.
    PackageInfo.setMockInitialValues(
      appName: 'TriTrack',
      packageName: 'edu.nau.tritrack',
      version: '1.4.2',
      buildNumber: '87',
      buildSignature: '',
    );
  });

  // Several sources on this screen are `SelectableText`, and each one wraps
  // an `EditableText` that carries its own `Scrollable` (for scrolling its
  // cursor into view) — so `find.byType(Scrollable)`, `scrollUntilVisible`'s
  // default, matches more than one widget here. This picks out the one
  // `Scrollable` that is this screen's own `ListView`, by starting from a
  // widget known to be inside it.
  final listScrollable = find.ancestor(
    of: find.text('Version'),
    matching: find.byType(Scrollable),
  );

  Future<void> pumpAppInfo(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const AppInfoScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
  }

  testWidgets('shows the version and build number the build actually carries',
      (tester) async {
    await pumpAppInfo(tester);
    await tester.pumpAndSettle();
    expect(find.text('1.4.2 (build 87)'), findsOneWidget);
  });

  testWidgets(
      'guide link says the address instead of doing nothing when the '
      'browser cannot be reached',
      (tester) async {
    // Task 11.286. `AttributionLink`'s whole point is that a tap which can't
    // open a browser still gives somebody the address rather than silently
    // doing nothing — watched failing here before trusting it, per the
    // task's instruction, by leaving `succeeds` at its default of false.
    final launcher = installFakeUrlLauncher();
    await pumpAppInfo(tester);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Open the guide'),
      200,
      scrollable: listScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open the guide'));
    await tester.pumpAndSettle();

    expect(
      launcher.lastLaunchedUrl,
      'https://dynamic-and-active-systems-lab.github.io/tritrack-site/docs/',
    );
    expect(
      find.textContaining(
        'https://dynamic-and-active-systems-lab.github.io/tritrack-site/docs/',
      ),
      findsOneWidget,
      reason: 'the browser could not be reached, so the address itself must '
          'be shown — a tap that does nothing is a refusal with no way '
          'forward.',
    );
  });

  testWidgets('guide link opens the one guide address when the browser is '
      'reachable', (tester) async {
    final launcher = installFakeUrlLauncher(succeeds: true);
    await pumpAppInfo(tester);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Open the guide'),
      200,
      scrollable: listScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open the guide'));
    await tester.pumpAndSettle();

    expect(
      launcher.lastLaunchedUrl,
      'https://dynamic-and-active-systems-lab.github.io/tritrack-site/docs/',
    );
    expect(
      find.textContaining('Could not open'),
      findsNothing,
      reason: 'the browser opened successfully; nothing should say it did not.',
    );
  });

  testWidgets('says the guide link opens a web page', (tester) async {
    // The person tapping it may be about to lose signal; the row must not
    // read like in-app content that turns out to need a network.
    await pumpAppInfo(tester);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('web page'),
      200,
      scrollable: listScrollable,
    );
    expect(find.textContaining('web page'), findsOneWidget);
  });

  testWidgets('lists every basemap provider\'s full attribution',
      (tester) async {
    // **Not the shortened one.** The map may abbreviate a credit where that
    // provider's terms allow it; this page is where the rest lives, so a
    // short form appearing here would mean the full text is nowhere at all.
    await pumpAppInfo(tester);
    await tester.pumpAndSettle();
    for (final source in TileSources.all) {
      expect(
        find.text(source.attribution),
        findsOneWidget,
        reason: '${source.name}\'s full credit is not on App Info, and the '
            'map credit points here for it.',
      );
    }
  });

  test('the version is read from the build, never from a constant', () {
    // The rule this asserts is the project's oldest: a hand-maintained value
    // goes wrong the first time somebody forgets, and a version number is the
    // worst place for one because it is what a bug report is keyed on. A
    // literal that looks like a version number in this screen would be
    // exactly that mistake, and it would look completely correct on the day
    // it was written.
    //
    // Checked by reading the source rather than the rendered output, because
    // a hard-coded default is invisible at runtime — it renders as a version,
    // which is what makes it dangerous.
    final source = File('lib/features/more/screens/app_info_screen.dart')
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final versionLiterals = RegExp(r"'\d+\.\d+\.\d+").allMatches(source);
    expect(
      versionLiterals.map((m) => m.group(0)).toList(),
      isEmpty,
      reason: 'app_info_screen.dart contains something shaped like a hard-'
          'coded version number. The version must come from PackageInfo, '
          'which reads what the installer shipped — if the pubspec and the '
          'binary disagree, the tester is running the binary.',
    );
    expect(source, contains('PackageInfo.fromPlatform'));
  });
}
