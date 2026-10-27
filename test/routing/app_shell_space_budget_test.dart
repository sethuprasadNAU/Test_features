import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';

import '../support/app_shell_harness.dart';
import '../support/fake_shared_preferences.dart';
import '../support/text_scale_probe.dart';

/// **How much of the phone the app shell keeps for itself** — task 11.149's
/// instrument, rewritten by task 11.189 when the answer became "nothing but
/// the navigation bar."
///
/// Every other space-budget file in this suite measures one screen. This one
/// measures what is left for a screen *before any screen has been built*.
///
/// ## What it measured before, and what it measures now
///
/// The shell carried two coloured strips above every tab: the sync bar and a
/// one-time notice about a removed cloud-backup feature. Task 11.149 measured
/// what they cost the tab under them on a 6.1-inch phone and bounded them to
/// a quarter of the shell. Michael asked on 2026-09-07 for the strip to go
/// altogether and for sync to be one small icon, and task 11.189 did that.
///
/// **The body left to whichever tab is showing, measured here, before and
/// after:**
///
/// | text size | before 11.149 | after 11.149 | after 11.189 | recovered |
/// |---|---|---|---|---|
/// | Large (default) | 570 | 570 | **679** | **+109** |
/// | xxxLarge | 501 | 524 | **679** | +178 |
/// | AX1 | 471 | 527 | **679** | **+208** |
/// | AX2 | 408 | 540 | **679** | +271 |
/// | AX3 | 239 | 519 | **679** | **+440** |
/// | AX4 | 169 | 545 | **679** | +510 |
/// | AX5 | 56 | 533 | **679** | **+623** |
///
/// 679 is the whole shell: 852 logical pixels of phone, less the 59-pixel
/// status inset, less the 114-pixel navigation bar. **It does not change with
/// the text size, because nothing in the shell wraps any more** — which is
/// the property this file now asserts, and it is a stronger statement than
/// the share it replaced. The last column is what every screen in the app was
/// handed back.
///
/// **The columns for "before" are quoted from task 11.149's own header**, not
/// re-measured: the widget they describe no longer exists, so the honest
/// thing to do with them is cite them. The "after 11.189" column is measured
/// by this file on every run.
///
/// ## What this deliberately does not do
///
/// It does not decide how much of the body each *screen* keeps for what. A
/// screen that cannot meet its own floor inside 679 pixels is that screen's
/// finding, and the Position, Record, Main Map and Offline Data Map budgets
/// say where theirs stop. **Their floors were not relaxed when this space
/// arrived** — the squeeze is gone and the floors have headroom, which is not
/// the same as not needing them.
///
/// **Measured in the test font, about twice Roboto's width** (task 11.133).
/// Nobody has looked at a phone.
void main() {
  setUp(installFakeSharedPreferences);

  const bodyKey = Key('shell-body-probe');

  ({double body, double nav, double shell}) measure(WidgetTester tester) {
    double heightOf(Finder f) =>
        f.evaluate().isEmpty ? 0.0 : tester.getRect(f).height;
    final nav = heightOf(find.byType(NavigationBar));
    return (
      body: heightOf(find.byKey(bodyKey)),
      nav: nav,
      // The shell is everything below the status bar: the screen and the
      // navigation bar, and since task 11.189 nothing else.
      shell: phoneSize.height - phoneTopInset - nav,
    );
  }

  Future<ProviderContainer> pumpShell(
    WidgetTester tester, {
    required double textScale,
    bool syncLive = true,
    SyncStatus? syncStatus,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        if (syncStatus != null)
          syncControllerProvider.overrideWith(() => _FixedSync(syncStatus))
        else if (syncLive)
          syncControllerProvider.overrideWith(LiveSyncStatusController.new),
      ],
    );
    addTearDown(container.dispose);
    // **Seeded on purpose**, even though the cloud-backup retirement notice
    // is no longer in the shell: this file's whole job is to prove that the
    // shell costs a screen nothing, and the strongest form of that is to
    // switch on everything that used to make it cost something.
    await tester.runAsync(seedCloudBackupRetiredNotice);
    await pumpInAppShell(
      tester,
      container: container,
      // A screen that asks for everything and holds nothing, so what is
      // measured is the shell rather than somebody's layout.
      screen: const Scaffold(body: SizedBox.expand(key: bodyKey)),
      tabIndex: 0,
      textScale: textScale,
    );
    return container;
  }

  /// **The screen gets the whole shell, at every text size.**
  ///
  /// Task 11.149's version of this asserted a *share* — the banners may take
  /// a quarter, the screen keeps three. That was the right assertion while
  /// there were banners. With none, the honest assertion is the stronger one:
  /// **the shell hands over everything between the status bar and the
  /// navigation bar, and the number does not move when the text does.**
  ///
  /// This is what goes red the day somebody puts a third piece of furniture
  /// above every tab, which is exactly what the two banners were.
  group('the screen gets the whole shell', () {
    for (final scale in iosTextScalesUpward) {
      testWidgets(textScaleName(scale), (tester) async {
        final overflows = collectLayoutOverflows();
        await pumpShell(tester, textScale: scale);
        final m = measure(tester);
        printOnFailure(
          '${textScaleName(scale)}: shell ${m.shell} = body ${m.body} '
          '(nav ${m.nav})',
        );
        expect(
          m.body,
          closeTo(m.shell, 0.5),
          reason: 'At ${textScaleName(scale)} the screen was left ${m.body} '
              'logical pixels of a ${m.shell}-pixel shell, so something in '
              'the app shell is taking ${m.shell - m.body} of them.\n'
              'Task 11.189 removed the two banners that used to sit here and '
              'gave every tab that space back — 109 logical pixels at the '
              'default text size and 623 at AX5. If this has failed, a new '
              'piece of shell furniture was added above the tab, and it costs '
              'every screen in the app at once. Read this file\'s header '
              'before deciding it is worth it: the Record screen\'s scrolling '
              'form was once handed a viewport of zero pixels this way.',
        );
        expect(
          overflows,
          isEmpty,
          reason: 'The shell itself striped at ${textScaleName(scale)}: '
              '$overflows',
        );
      });
    }
  });

  /// **The recovered space is stated as a number, not only as an equality.**
  ///
  /// The assertion above would still pass on a shell that had shrunk for some
  /// other reason, so this one names the figure task 11.189 reported to
  /// Michael and fails if it stops being true. 679 is arithmetic on the phone
  /// geometry this file already declares, not a constant somebody chose.
  testWidgets('the body is the phone less the status inset and the nav bar',
      (tester) async {
    await pumpShell(tester, textScale: 1.0);
    final m = measure(tester);
    printOnFailure('default text size: body ${m.body}, nav ${m.nav}');
    expect(m.nav, closeTo(114, 0.5));
    expect(
      m.body,
      closeTo(phoneSize.height - phoneTopInset - 114, 0.5),
      reason: 'Task 11.189 reported 679 logical pixels of body on a '
          '6.1-inch phone at the default text size, against 570 before it. '
          'That is the number in its report and in the plan; this is where '
          'it is measured.',
    );
  });

  /// **Nothing above the tab reacts to the text size any more, in the worst
  /// state the sync surface has.**
  ///
  /// The old shell's worst case was the longest sync sentence at the largest
  /// text size: two sentences wrapping in a strip that grew to hold them.
  /// That state still exists — it is what `SyncStatusIcon` draws in red — and
  /// the point of the redesign is that it now costs the screen nothing at
  /// all, on any tab, because it is not on the tab.
  testWidgets('the longest sync state at AX5 takes nothing from the screen',
      (tester) async {
    await pumpShell(
      tester,
      textScale: iosTextScales.last,
      // Reached the way the app reaches it — an address this build refuses —
      // rather than by naming the health enum, so this keeps exercising the
      // real mapping.
      syncStatus: const SyncStatus(
        schedule: SyncSchedule(),
        unavailable: SyncUnavailable.serverAddressRefused,
      ),
    );
    final m = measure(tester);
    printOnFailure('AX5, refused address: body ${m.body} of ${m.shell}');
    expect(
      m.body,
      closeTo(m.shell, 0.5),
      reason: 'Before task 11.189 this exact state was the shell\'s worst '
          'case: the sync bar\'s longest sentence, wrapping at the largest '
          'text size. It is now a 28-pixel icon over the map and a dot on a '
          'navigation icon, and neither takes a pixel from any screen.',
    );
  });

  /// **Rule 5 of task 11.149's decision, and it outlived the rest of them.**
  ///
  /// The navigation bar was the other candidate for shedding — labels off, or
  /// a shorter bar — and it turns out there is nothing there to reclaim. It
  /// is still the only thing the shell keeps, so it is still the only thing
  /// worth measuring, and the badge task 11.189 put on the More icon must not
  /// have changed it.
  testWidgets('the navigation bar is the same height at every text size',
      (tester) async {
    final heights = <double, double>{};
    final clipped = <double, List<ClippedText>>{};
    for (final scale in iosTextScalesUpward) {
      await pumpShell(tester, textScale: scale);
      heights[scale] = measure(tester).nav;
      clipped[scale] = clippedTexts(tester)
          .where((c) => const ['Map', 'Record', 'Compass', 'Position', 'More']
              .contains(c.text.trim()))
          .toList();
    }
    printOnFailure('navigation bar heights: $heights');
    expect(
      heights.values.toSet(),
      hasLength(1),
      reason: 'Flutter\'s NavigationBar deliberately does not scale with '
          'textScaler (its own class documentation says so), which is why the '
          'navigation bar was never a candidate for shedding: there is '
          'nothing there to reclaim. If this has more than one value, that '
          'stopped being true — or the sync badge task 11.189 added to the '
          'More destination grew the bar, which it must not. '
          'Heights: $heights',
    );
    for (final entry in clipped.entries) {
      expect(
        entry.value,
        isEmpty,
        reason: 'A navigation bar label is being cut off at '
            '${textScaleName(entry.key)} with nothing to say so: '
            '${entry.value}. The bar not growing is only acceptable while its '
            'labels are still readable; if they are not, taking them off '
            'deliberately is better than losing them silently.',
      );
    }
  });
}

class _FixedSync extends SyncController {
  _FixedSync(this._status);
  final SyncStatus _status;

  @override
  Future<SyncStatus> build() async => _status;
}
