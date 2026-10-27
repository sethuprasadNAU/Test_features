import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/app_boot_helper.dart';
import '../support/complete_identity_setup.dart';
import '../support/dart_source.dart';
import '../support/fake_shared_preferences.dart';

/// **Task 11.161 — what a tab you are not looking at is still doing.**
///
/// Task 11.160 stopped the tab shell ticker-muting its hidden branches,
/// because riverpod reads that same `TickerMode` and the silent pause it
/// produced was the cause of that task's crash. **It wrote the cost down and
/// could not measure it**: a hidden tab keeps its provider subscriptions and
/// its animations. It named three examples — the compass stream, the compass
/// dial, and a progress spinner — and said in as many words that three things
/// somebody noticed is not the set.
///
/// **This file derives the set.** It boots the real app once, against a real
/// (in-memory) database with a project on the device, and takes two
/// snapshots of what is alive: one **on the Map tab before anything else has
/// been opened**, and one **back on the Map tab after every tab has been
/// visited**. Everything in the second and not the first is there **because a
/// tab nobody is looking at is still holding it**. The baseline is taken in
/// the same run rather than from a second boot, so nothing about the two
/// differs except which tabs have been opened — and one boot instead of two
/// is the difference between a test that runs in seconds and one nobody
/// wants in the suite.
///
/// A `ProviderObserver` on a fresh container reports what was created
/// and what was unmounted (see `TriTrack_Technical_Context.md`, *A Provider's
/// Read-Set Can Be Derived at Run Time*), and
/// `SchedulerBinding.transientCallbackCount` reports how many tickers are
/// asking for frames — one number per tab, so a ticker that starts and never
/// stops is visible as a step that never comes back down.
///
/// **What the derivation found, and where it disagrees with 11.160's three
/// examples.** The compass stream was right. The dial was right — but it is
/// *one* ticker and it only runs while headings are arriving, so pausing the
/// stream stops it as a consequence rather than needing a fix of its own.
/// **The spinner was an artifact of measuring under a fake clock**: with real
/// time available every screen's loading state resolves and no spinner is
/// left anywhere. And one thing nobody had named turned up — the compass
/// controller listens to GPS for declination, so the Compass tab holds the
/// GPS stream too. See [notPaused] for why that one is deliberately left
/// running.
///
/// ## Two things this cannot see, stated rather than assumed away
///
/// It drives the five tab branches and no sub-route, so a sensor first
/// reached from a screen under More — the pre-trip checklist reads the
/// compass, for instance — is outside it. And the sensor streams are
/// overridden with fakes, because a real `EventChannel` neither exists nor
/// emits under `flutter test`, so this measures **whether a subscription is
/// held** and never what holding it costs a battery. That number needs a
/// field day and is release-checklist item F1.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets(
    'a tab nobody is looking at holds nothing that was not decided on',
    (tester) async {
      // The Map tab fetches basemap tiles, and every fetch under
      // `TestWidgetsFlutterBinding` comes back 400. Drop exactly that noise, the
      // same way the map's own tests do.
      final originalOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception is NetworkImageLoadException) return;
        originalOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = originalOnError);

      final run = await _sweepEveryTab(tester);

      final heldByHiddenTabs = run.aliveAfterSweep
          .difference(run.aliveBeforeSweep)
          .map(_Liveness.nameOf)
          .toSet();

      // Printed every run, so what a five-line CI tail carries is the finding
      // rather than the name of the check.
      debugPrint(
        'hidden-tab liveness: ${heldByHiddenTabs.length} providers held by a '
        'hidden tab — ${(heldByHiddenTabs.toList()..sort()).join(', ')}; '
        'tickers per tab ${run.tickersPerTab}',
      );

      // **Refuse an empty result.** A derivation that finds nothing and a
      // subject that contains nothing are indistinguishable from the inside,
      // and only one of them is true here: opening four more tabs cannot leave
      // the app in exactly the state it was in before.
      expect(
        heldByHiddenTabs,
        isNotEmpty,
        reason:
            'Opening every tab left the app holding exactly what it held '
            'before, which means this test is no longer measuring anything — '
            'most likely the sweep did not actually change tab.',
      );

      final undeclared = heldByHiddenTabs.difference(notPaused.keys.toSet());
      expect(
        undeclared,
        isEmpty,
        reason:
            'A hidden tab is holding something nobody has decided about: '
            '${undeclared.join(', ')}. Either pause it — see '
            'lib/routing/tab_visibility.dart — or say in `notPaused` why it '
            'costs nothing to leave running.',
      );

      // Derived rather than named: every `@riverpod` function under `lib/` that
      // returns a `Stream` is a subscription to something outside the app.
      // There is no other kind in this codebase, and one added tomorrow is
      // caught here rather than by somebody remembering.
      final streamProviders = _streamBackedProviderNames();
      expect(
        streamProviders,
        isNotEmpty,
        reason:
            'Found no stream-backed providers under lib/ at all, which cannot '
            'be right — the source scan has stopped matching.',
      );

      final stillSubscribed = run.aliveAfterSweep
          .map(_Liveness.nameOf)
          .toSet()
          .intersection(streamProviders);
      expect(
        stillSubscribed,
        // The GPS fix is the one declared exception, and the reason is in
        // `notPaused`: its resume cost is a person standing still.
        {'gpsPositionProvider'},
        reason:
            'A sensor stream is still subscribed after its tab went off screen. '
            'Subscribed at the end of the sweep: '
            '${(stillSubscribed.toList()..sort()).join(', ')}.',
      );

      // One number per tab. A ticker that starts on one tab and never stops
      // shows up as a step that never comes back down — which is what this
      // measured before the compass was paused: 0 on Map, 1 from the moment the
      // Compass tab was first shown, and 1 for the rest of the run.
      expect(
        run.tickersPerTab['Map (after the sweep)'],
        0,
        reason:
            'Something is still animating for a tab nobody is looking at. The '
            'count per tab was ${run.tickersPerTab}.',
      );
    },
  );

  test('every compass watch in lib/ goes through the tab gate', () {
    // The liveness test above can only see a screen it actually opens: five
    // tab branches, no sub-routes. This is the other half — a source
    // derivation over the whole corpus, so a compass watch added tomorrow on
    // a screen the sweep never reaches still has to say what it does while
    // its tab is off screen.
    //
    // Aimed at the indirection rather than at the files it lives in: it asks
    // each `watch` call which form it used. `ref.read` is deliberately not
    // matched — a read holds no subscription, which is why
    // `bearing_capture_provider.dart` needs no gate.
    const gated = ['compassControllerProvider', 'compassAvailableProvider'];
    final ungated = <String>[];
    var callSites = 0;

    for (final file in dartFilesUnder('lib')) {
      final source = stripComments(file.readAsStringSync());
      for (final provider in gated) {
        for (final match in RegExp(
          r'(\w+)\s*\(\s*(?:context\s*,\s*)?' + provider,
        ).allMatches(source)) {
          final method = match.group(1)!;
          if (method == 'read' || method == 'listen') continue;
          callSites++;
          if (method != 'watchWhileTabVisible') {
            ungated.add('${file.path}: $method($provider)');
          }
        }
      }
    }

    // Refuse an empty result: finding no call sites and there being none are
    // indistinguishable from the inside, and only one of them is true.
    expect(
      callSites,
      greaterThan(0),
      reason:
          'Found no compass watch call sites under lib/ at all. Either the '
          'compass has been removed from the app or this scan has stopped '
          'matching; it is much more likely to be the second.',
    );
    expect(
      ungated,
      isEmpty,
      reason:
          'A compass watch that is not gated on tab visibility keeps the '
          'sensor stream subscribed for the rest of the run once its screen '
          'has been opened: ${ungated.join('; ')}. Use '
          'ref.watchWhileTabVisible (lib/routing/tab_visibility.dart), or say '
          'here why this one should not be gated.',
    );
  });
}

/// What is still alive because a hidden tab is holding it and is
/// **deliberately not paused**.
///
/// The inverted declaration: anything the derivation finds that is not here
/// has to be argued for, so a *new* unpaused sensor fails the run instead of
/// joining a list nobody reads. Keyed by the provider's own `name`, which
/// riverpod's code generator sets — not by a string anybody typed twice.
///
/// **Checked in one direction only, and that is where this stops.** An entry
/// here whose provider no longer survives a tab change is dead text and
/// nothing notices; what cannot happen is a survivor with no entry. The
/// asymmetry is deliberate — which providers a screen reaches depends on what
/// is on the device, and failing a run because something was *not* held would
/// make this test a weather report.
const notPaused = <String, String>{
  'gpsPositionProvider':
      'The GPS fix, and the one stream whose resume cost is a person standing '
      'still. Re-acquiring under canopy is seconds at best and can be a '
      'minute, so a tab change must never drop it — and it would be dropped '
      'constantly, because four of the five tabs and half the More screens '
      'read it. It is paused when the whole app is backgrounded, which is '
      'where that cost is worth paying and where the Performance & Battery '
      'rule already puts it.',
  'compassEverHeardProvider':
      'One bool saying this device has produced a real heading at least once. '
      'Deliberately keepAlive, so that pausing the compass does not put a '
      'working compass back on probation. It holds no subscription and never '
      'changes again once set.',
  'declinationOverrideProvider':
      'A manually entered magnetic declination, read from preferences. A '
      'stored answer, not a subscription.',
  'wmmServiceProvider':
      'The World Magnetic Model, loaded once from an asset. Holding it is '
      'holding a parsed table in memory; dropping it would mean re-parsing it '
      'on the next tab change for no saving at all.',
  'observationFormProvider':
      'The draft observation on the Record tab. Dropping it while the tab is '
      'hidden is exactly the loss the autosaved draft exists to prevent.',
  'projectActiveTagsProvider':
      'The tags in the active project, a database query result. It costs '
      'nothing while nothing is asking it anything.',
  'projectDeploymentsProvider':
      'Which collar is on which animal in the active project, the same shape '
      'as the tags — one query result, held so the Record tab can decide '
      'which collars to offer (task 11.249). It holds no subscription and '
      'asks nothing of anything while the tab is hidden.',
  'cloudBackupRetirementNoticeProvider':
      'Whether this device still has a leftover cloud-backup folder token in '
      'preferences, which decides whether the More screen shows the one-time '
      'notice about that feature being removed. A single stored answer, read '
      'once and then unchanged until somebody dismisses it — it holds no '
      'subscription and asks nothing of anything. '
      '**It arrived in this list on 2026-09-07 and is not a regression:** '
      'task 11.189 moved the notice out of the app shell, where it was built '
      'above every tab and so was never held by a *hidden* one, onto the More '
      'screen, where it is. Nothing about what it costs changed; what changed '
      'is which side of this measurement it sits on.',
  'deviceLockWarningNoticeProvider':
      'Whether this device has no passcode/biometric lock configured, which '
      'decides whether the More screen shows the one-time warning (Security '
      'Model §4.8 control 2, task 10.79). Same shape as '
      '`cloudBackupRetirementNoticeProvider` just above: a single answer read '
      'once from a platform check and a stored dismissal flag, then unchanged '
      'until dismissed. It holds no subscription and asks nothing of anything '
      'while hidden.',
};

/// Boots the real app with a project on the device, snapshots what is alive
/// on the Map tab, then walks Record → Compass → Position → More and back to
/// Map and snapshots again.
Future<_Liveness> _sweepEveryTab(WidgetTester tester) async {
  final observer = _Liveness();
  final container = await pumpAppForTest(
    tester,
    observers: [observer],
    overrides: [
      // Live samples, not a fixed reading: the dial animates on *change*, so
      // a stream that emits once and stops would hide the ticker this is here
      // to count. There is no real sensor under `flutter test` — see the note
      // at the top of the file about what that does and does not let this
      // measure.
      compassHeadingProvider.overrideWith(
        (ref) => Stream<CompassEvent>.periodic(
          const Duration(milliseconds: 100),
          (i) => CompassEvent.fromList([12.0 + i, 12.0 + i, 1.0]),
        ),
      ),
      magnetometerReadingProvider.overrideWith(
        (ref) => Stream<MagnetometerEvent>.periodic(
          const Duration(milliseconds: 100),
          (i) => MagnetometerEvent(20 + i * 0.1, 5, 40, DateTime.now()),
        ),
      ),
      accelerometerReadingProvider.overrideWith(
        (ref) => Stream<AccelerometerEvent>.periodic(
          const Duration(milliseconds: 100),
          (i) => AccelerometerEvent(0, i * 0.01, 9.8, DateTime.now()),
        ),
      ),
    ],
  );
  await completeIdentitySetup(tester);

  // A project on the device, so the five tabs render the screens a person on
  // a field day sees rather than five "no active project" empty states — on
  // which the Record tab never reaches its compass at all.
  await tester.runAsync(() async {
    final me = container.read(currentUserProvider).value!;
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(
      Tables.projects,
      sampleProject(id: 'project-1', ownerUserId: me.userId).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-me',
        projectId: 'project-1',
        userId: me.userId,
      ).toColumns(),
    );
    await container.read(activeProjectIdProvider.notifier).set('project-1');
  });
  await _settle(tester);

  observer.aliveBeforeSweep = {...observer.alive};
  observer.tickersPerTab['Map (before the sweep)'] =
      SchedulerBinding.instance.transientCallbackCount;

  for (final tab in ['Record', 'Compass', 'Position', 'More', 'Map']) {
    observer.currentTab = tab;
    await tester.tap(find.text(tab));
    await _settle(tester);
    observer.tickersPerTab[tab] =
        SchedulerBinding.instance.transientCallbackCount;
  }

  observer.aliveAfterSweep = {...observer.alive};
  observer.tickersPerTab['Map (after the sweep)'] =
      SchedulerBinding.instance.transientCallbackCount;

  // Disposed here rather than through `addTearDown`, which only runs after
  // `flutter_test`'s own end-of-test invariant check: the compass leaves
  // `CompassAvailable`'s availability `Timer` pending, and
  // `UncontrolledProviderScope`'s container is not tied to the widget tree's
  // disposal. Same reason as `compass_screen_test.dart`.
  container.dispose();
  return observer;
}

/// Lets the app get on with it for a bounded stretch of **real** time.
///
/// Not `pumpAndSettle`, for two separate reasons and both matter. The sensor
/// streams above never stop emitting, so nothing ever settles. And the
/// database answers on real time: pumping on the fake clock alone leaves every
/// screen stuck in its loading state, which is how an earlier version of this
/// file "found" three progress spinners running on hidden tabs that do not
/// exist in the running app.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}

/// Every `@riverpod` function under `lib/` whose return type is a `Stream`,
/// by generated provider name.
Set<String> _streamBackedProviderNames() {
  final names = <String>{};
  final declaration = RegExp(
    r'@riverpod\s*\n\s*Stream<[^>]*>\s+(\w+)\s*\(',
    multiLine: true,
  );
  for (final file in dartFilesUnder('lib')) {
    for (final match in declaration.allMatches(
      stripComments(file.readAsStringSync()),
    )) {
      names.add('${match.group(1)}Provider');
    }
  }
  return names;
}

/// Which providers are alive, and which tab was on screen when each was born.
final class _Liveness extends ProviderObserver {
  _Liveness();

  String currentTab = 'boot';
  final Map<ProviderBase<Object?>, String> bornOn = {};
  final Set<ProviderBase<Object?>> alive = {};
  Set<ProviderBase<Object?>> aliveBeforeSweep = {};
  Set<ProviderBase<Object?>> aliveAfterSweep = {};
  final Map<String, int> tickersPerTab = {};

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    bornOn.putIfAbsent(context.provider, () => currentTab);
    alive.add(context.provider);
  }

  @override
  void didUnmountProvider(ProviderObserverContext context) {
    alive.remove(context.provider);
  }

  /// A family instance carries its family's name; a hand-written provider has
  /// none and prints as its type.
  static String nameOf(ProviderBase<Object?> provider) {
    final key = provider is Family ? provider : (provider.from ?? provider);
    return key.name ?? provider.runtimeType.toString();
  }
}
