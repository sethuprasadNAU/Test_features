// Booting the real app for a screenshot run.
//
// **This reuses the app's own startup path and the test suite's own fakes.**
// It builds a `ProviderContainer`, overrides the same providers
// `test/features/observations/ground_truth_entry_test.dart` overrides for task
// 11.33's GPS prefill, and pumps `TriTrackApp` — the same widget `main()`
// runs. It deliberately does not reimplement any of it: a second way to start
// the app would drift from the real one, and the screenshots would then
// illustrate a startup nobody has.
//
// The four things faked, and why each has to be:
//
//  * **The database.** A fresh file, seeded from `seed.dart`, deleted before
//    every run. Screenshots of empty screens teach nothing, and a database
//    left over from a previous run would make the images depend on run order.
//  * **Position.** The simulator has no GPS. `xcrun simctl location set` moves
//    the *device*, which the OS location API honours, but the app's own
//    `gpsPositionProvider` is overridden here as well so the fix is exact and
//    identical on every run.
//  * **Heading.** The simulator has no magnetometer. See `README.md` — this is
//    the harness's one openly-invented sensor value, and it is invented rather
//    than photographed because a photograph cannot be regenerated.
//  * **Preferences.** The in-memory `SharedPreferences` the widget tests use,
//    so the simulator's saved state from a previous run cannot leak into the
//    images.
//
// The real `path_provider` is left alone — this runs on a real device, where
// it works, and the tile cache and database want somewhere real to live.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:tritrack/app.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/features/splash/splash_screen.dart';
import 'package:tritrack/routing/app_router.dart';

import '../../test/support/fake_session_store.dart';
import '../../test/support/fake_shared_preferences.dart';
import 'joined.dart';
import 'seed.dart';

/// The database file the screenshot run uses. Not `tri_track.db`: a harness
/// that opened the real one would be one careless `-d` flag away from seeding
/// invented foxes into somebody's actual field data.
const String screenshotDbFileName = 'tritrack_screenshots.db';

/// The heading the compass screens are drawn at.
///
/// **This number is invented and the site says so.** The simulator has no
/// magnetometer; see the compass section of `README.md` for why faking it was
/// chosen over a hand-taken photograph.
const double fakeMagneticHeadingDeg = 47.0;

/// The heading the faked compass reports *right now*.
///
/// **A variable rather than a constant since `/w-32`**, so a capture can script
/// a sweep: *Take on map* draws where the phone points and the arc it swept
/// while a button was held, and a compass stuck at one number can show neither.
/// It starts at [fakeMagneticHeadingDeg], every other screen sees exactly that,
/// and whatever scripts a sweep must put it back with
/// `setFakeHeading(fakeMagneticHeadingDeg)` afterwards, because the compass
/// picture is of 47 and the readiness check for it asks for the number.
double _fakeHeadingDeg = fakeMagneticHeadingDeg;

/// Points the faked compass at [degrees] (magnetic). The stream below re-reads
/// it every 100 ms, so the app sees the change within one sample.
void setFakeHeading(double degrees) => _fakeHeadingDeg = degrees;

/// A fix at the invented study area, with a plausible accuracy so the record
/// screen's prefilled precision reads like a real one.
Position seedFix() => Position(
      latitude: seedLat,
      longitude: seedLon,
      timestamp: seedUtc,
      accuracy: 6.0,
      altitude: 1312.0,
      altitudeAccuracy: 4.0,
      heading: fakeMagneticHeadingDeg,
      headingAccuracy: 5.0,
      speed: 0.0,
      speedAccuracy: 0.0,
    );

/// The position stream the app sees, fed on demand by [enableGpsFix].
///
/// **Fed rather than always-on, and the separation is kept on purpose.** It
/// was held back through `/w-02`, `/w-05` and `/w-03` because the map screen
/// started an automatic viewshed the moment a fix existed, and did it from
/// inside `build` — two debug assertions inside one drain window, which made
/// the test framework abandon the run and produce **no screenshots at all**.
/// Task 11.95 removed both. The fix is still delivered by an explicit call
/// rather than from the provider override, so that a future screen with the
/// same problem can be photographed before it is switched on instead of
/// costing the whole run.
final StreamController<Position> _positions =
    StreamController<Position>.broadcast();
Timer? _positionTimer;

/// Starts delivering [seedFix] to the app.
///
/// **Called by `capture_test.dart` before the capture loop since `/w-06`**, so
/// every screenshot is of a device that knows where it is — which is the state
/// a person outdoors is in, and the state the guide has to illustrate.
///
/// The two defects that kept it switched off were both fixed by task 11.95:
/// the map no longer writes a provider during `build`, and the attribution
/// line no longer overflows. Turning it on was that task's outstanding
/// confirmation — its own evidence was a widget test, precisely because this
/// harness withheld the fix.
void enableGpsFix() {
  _positionTimer ??= Timer.periodic(
    const Duration(milliseconds: 200),
    (_) => _positions.add(seedFix()),
  );
  _positions.add(seedFix());
}

/// A phone held roughly level and pointing at [fakeMagneticHeadingDeg], with a
/// field magnitude in the ordinary range so the interference warning does not
/// fire. Repeating rather than single-shot: the compass controller recomputes
/// on each sample, and a stream that closes leaves the screen showing whatever
/// the last frame happened to catch.
Stream<T> _repeating<T>(T Function() build) =>
    Stream<T>.periodic(const Duration(milliseconds: 100), (_) => build())
        .asBroadcastStream();

// The return type is left to inference on purpose: Riverpod 3's `Override` is
// not exported under a name this file can write down.
// ignore: strict_top_level_inference
screenshotOverrides({required AppDatabase database}) => [
      splashDurationProvider.overrideWithValue(Duration.zero),
      appDatabaseProvider.overrideWith((ref) async => database),
      gpsPositionProvider.overrideWith((ref) => _positions.stream),
      compassHeadingProvider.overrideWith(
        (ref) => _repeating(
          () => CompassEvent.fromList(
            <double>[_fakeHeadingDeg, _fakeHeadingDeg, 3.0],
          ),
        ),
      ),
      accelerometerReadingProvider.overrideWith(
        (ref) => _repeating(
          () => AccelerometerEvent(0.1, 0.15, 9.79, seedUtc),
        ),
      ),
      magnetometerReadingProvider.overrideWith(
        (ref) => _repeating(
          () => MagnetometerEvent(21.4, -19.8, -41.2, seedUtc),
        ),
      ),
      // The signed-in, server-configured half (`/w-05`). **Inert until
      // `activateJoinedDevice` is called**, so the screens photographed before
      // that are of exactly the unconfigured device `/w-02` committed — see
      // `joined.dart` for why both states have to exist in one app session.
      //
      // **Spelled out here rather than spread in from a helper, and the
      // reason is the same one the missing return type above records.**
      // Riverpod 3 exports no name for an override, so a function that
      // returns a list of them has no writable return type — which under this
      // analyzer's rules means `dynamic`, which makes this literal a
      // `List<dynamic>`, which `ProviderContainer` rejects at run time. The
      // first run after that refactor booted no app and photographed nothing;
      // the only thing that noticed was the review refusing an empty
      // directory, again.
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(screenshotSession()),
      ),
      // **One transport override, and `/w-10` moved it up a level.**
      //
      // It used to be `membershipTransportProvider`, plus a subclass of
      // `ProjectLinkController` because that controller built its own
      // connection. Task 11.97 removed both facts: `membershipTransport`
      // now simply forwards to this provider, and `ProjectLinkController`
      // reads it through `requireServerTransport`. So the narrower override
      // and the subclass were a description of an app that no longer exists.
      //
      // **What changes by overriding here instead, stated rather than
      // implied.** This one reaches the sync engine as well, which the old
      // one could not. That is what makes the sync bar's failure states
      // photographable at all — and it is also why `joined.dart` can no
      // longer say the engine is never faked. See the table at the top of
      // that file for which captures actually run a round.
      serverTransportProvider.overrideWith(
        (ref) async => joinedTransportOrNull(),
      ),
    ];

/// Deletes the screenshot database so every run starts from the same state.
Future<void> _resetDatabaseFile() async {
  final directory = await getApplicationSupportDirectory();
  final file = File(p.join(directory.path, screenshotDbFileName));
  if (file.existsSync()) file.deleteSync();
}

/// Everything the app threw while a screen was being photographed, keyed by
/// the screen it happened on.
///
/// **Why a capture is allowed to continue past one.** A simulator can only run
/// a debug build — `flutter drive --profile` refuses outright, saying release
/// and profile builds are for physical devices only — so debug assertions are
/// live during every capture. Two fired on the map screen until task 11.95
/// closed them, and left to the ordinary test behaviour the first of them
/// aborted the whole run, producing **no images at all**. The map is quiet
/// now; this stays because the next screen to throw should cost one image's
/// honesty and not the whole set.
///
/// So `capture_test.dart` redirects the test framework's exception reporter
/// into this map. **Recorded, attributed to a screen, and printed at the end
/// of the run** — a harness that swallowed them without saying so would be
/// reporting a clean set of screenshots over a screen that is throwing, which
/// is exactly the kind of check this project keeps deleting.
final Map<String, List<String>> capturedErrors = {};

/// Records [summary] against whichever screen is being photographed.
void recordCaptureError(String summary) {
  capturedErrors.putIfAbsent(currentScreen, () => <String>[]).add(summary);
  // Printed as it happens as well as summarised at the end: the order matters
  // when something goes wrong mid-run, and a summary alone cannot show it.
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: $currentScreen threw — $summary');
}

/// The screen currently being photographed, for attributing the above.
String currentScreen = 'startup';

/// One line of an exception — **except for the one class where one line is
/// useless.**
///
/// Everywhere in this harness an error is filed by its first line, and that is
/// the right trade for a screen that overflowed: the first line names the
/// widget and the amount. A build-phase assertion is the exception. Its first
/// line is *"setState() or markNeedsBuild() called during build."* — the rule,
/// with nothing about who broke it — and the widget's name is several lines
/// down. `/w-10` filed that error against the code lane twice before noticing
/// it had reported a rule rather than a finding.
String _summarise(Object error) {
  final text = error.toString();
  final lines = text.split('\n').where((l) => l.trim().isNotEmpty);
  if (!text.contains('markNeedsBuild') && !text.contains('setState')) {
    return lines.first;
  }
  return lines.take(12).map((l) => l.trim()).join(' | ');
}

/// Boots the app with the seed loaded and a project open.
///
/// [seeded] false gives the other case the guide needs a picture of: a device
/// with nothing on it, which is what a first launch actually looks like and
/// which routes to the identity gate instead of the map.
Future<ProviderContainer> bootApp(
  WidgetTester tester, {
  bool seeded = true,
}) async {
  installFakeSharedPreferences();
  late ProviderContainer container;

  // **No `tester.runAsync` anywhere in this file, and that is deliberate.**
  // `integration_test` runs against a live binding on a real device, so plain
  // `await` and a plain `Future.delayed` already work — and an exception
  // raised by a frame *inside* a `runAsync` leaves the binding believing an
  // async block is still open, after which every later call fails with
  // "Reentrant call to runAsync() denied". This app raises exactly such an
  // exception on the map screen, so the run silently captured nothing until
  // the `runAsync` wrappers came out.
  {
    await _resetDatabaseFile();
    final database = await AppDatabase.open(fileName: screenshotDbFileName);
    // **`retry:` is not optional here, and leaving it off made this harness
    // measure a different app** (task 11.142, `/w-10` item 0).
    //
    // A `ProviderContainer` with no `retry:` runs Riverpod's default — ten
    // attempts over 38.2 seconds. `main.dart` runs `appRetryPolicy`, which is
    // three attempts and under two seconds. So the Members screen, whose two
    // server-backed sections fail immediately with `not_configured` on a
    // device with no server, rendered its error text in 1.6 s in the app and
    // spun for twenty in here — and `project-members.png` was published
    // showing a state nobody on a phone sees for more than about two seconds.
    //
    // The general form, which is why it is written here rather than in a
    // commit message: **a harness that assembles the app's environment itself
    // must assemble it from the app's configuration**, or everything it
    // observes is evidence about the harness. `retry_policy_applied_test.dart`
    // cannot see this line — it scans `lib/` for `ProviderScope(` — so the
    // guard for it lives beside the harness, in
    // `harness_matches_the_app_test.dart`.
    container = ProviderContainer(
      retry: appRetryPolicy,
      overrides: screenshotOverrides(database: database),
    );

    if (seeded) {
      await seedDatabase(container);
      await container.read(activeUserIdProvider.notifier).set(ownerUserId);
      await container.read(activeProjectIdProvider.notifier).set(seedProjectId);
    }
    // Resolving the identity before the first frame is what the app's own
    // widget-test helper does (`test/support/app_boot_helper.dart`) — the
    // splash screen reads it on frame one and will not navigate until it
    // completes.
    await container.read(currentUserProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TriTrackApp(),
      ),
    );
  }

  await settle(tester);
  return container;
}

/// Pumps real frames for [wait], draining anything they throw.
///
/// `pumpAndSettle` alone is not enough here. Map tiles arrive over the network
/// and images decode on a real clock, so the wait has to be a real one, in
/// short slices with a pump and a drain between them. `pumpAndSettle` is then
/// allowed to give up: some screens hold a legitimately endless animation (a
/// progress indicator while a tile loads), and a harness that threw there
/// would refuse to photograph exactly the states worth photographing.
///
/// **This is not what decides that a screen is finished, and until `/w-11` it
/// was.** A duration is a guess about how long a machine takes; the run
/// photographed a half-downloaded map and reported itself green because the
/// guess had gone stale. What a shutter now waits on is [awaitReady] and the
/// per-screen conditions in `readiness.dart`. This is the frame pump those
/// conditions are polled between, and the short settle after a navigation or
/// a tap that gives the next frame somewhere to happen.
Future<void> settle(
  WidgetTester tester, {
  Duration wait = const Duration(seconds: 3),
}) async {
  const slice = Duration(milliseconds: 120);
  final slices = (wait.inMilliseconds / slice.inMilliseconds).ceil();
  for (var i = 0; i < slices; i++) {
    await Future<void>.delayed(slice);
    // **Drained before the pump as well as after.** An exception reported by a
    // frame that the platform drew during the delay is left pending, and the
    // next `pump` throws it back at the caller — which aborts the test body
    // mid-run while the framework records the test as passed. That is how an
    // earlier version of this harness reported "All tests passed" over an
    // empty output directory.
    _drain(tester);
    try {
      await tester.pump();
    } catch (error) {
      recordCaptureError(_summarise(error));
    }
    _drain(tester);
  }
  // **No `pumpAndSettle` here, and its absence is the point.** Under the live
  // binding it opens an async guard that a thrown frame leaves standing, and
  // the test body is then quietly detached: an earlier version of this file
  // reported "All tests passed" at eight seconds while its capture loop
  // carried on afterwards against a disposed provider container. Real frames
  // are already being drawn during the slices above, so waiting in real time
  // and pumping is both sufficient and the only thing that survives a screen
  // that throws.
  _drain(tester);
}

/// Takes any error the frame just reported, and files it against the screen.
///
/// **Draining every quarter-second is not tidiness, it is the only thing that
/// makes the run finish.** The test framework tolerates one un-taken exception
/// at a time; when a second arrives first it collapses both into a "multiple
/// exceptions" message and abandons the test — which on this app means the map
/// screen's two debug assertions between them produce **no screenshots at
/// all**. Draining between frames keeps them separate, so each is recorded
/// against the screen it came from and the run continues.
void _drain(WidgetTester tester) {
  for (var error = tester.takeException();
      error != null;
      error = tester.takeException()) {
    recordCaptureError(_summarise(error));
  }
}

/// Navigates by route rather than by tapping through the interface.
///
/// Tapping would be a more faithful imitation of a person, and it would also
/// make every screenshot depend on every screen between it and the tab bar —
/// so one changed label could fail the capture of fifteen unrelated images.
/// The routes are the app's own, out of `lib/routing/app_router.dart`.
///
/// **The `wait` here is a nudge, not a settle** (`/w-11`). It exists to give
/// the route change a frame or two to happen; whether the screen has
/// *finished* is [awaitReady]'s question, asked immediately afterwards by the
/// shutter itself. Before `/w-11` this argument carried each shot's tuned
/// sleep and was the only thing standing between a navigation and a
/// photograph.
Future<void> goTo(
  WidgetTester tester,
  ProviderContainer container,
  String route, {
  Duration wait = const Duration(seconds: 1),
}) async {
  currentScreen = route;
  container.read(appRouterProvider).go(route);
  await settle(tester, wait: wait);
}

/// Whether [finder]'s first match is wholly inside the visible window.
///
/// Not "is it in the widget tree": a `ListView` builds children that are off
/// the bottom of the screen, so existence is not visibility, and a shot named
/// for something below the fold would be a picture of the wrong thing under a
/// name that says otherwise.
bool isOnScreen(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return false;
  final view = tester.view;
  final height = view.physicalSize.height / view.devicePixelRatio;
  final rect = tester.getRect(finder.first);
  return rect.height > 0 && rect.top >= 0 && rect.bottom <= height;
}

/// Scrolls until [finder] is on screen, and **says so when it never gets
/// there**.
///
/// A silent failure here is the worst kind this harness can have: the shutter
/// still fires, an image still lands, and it is a picture of the top of a
/// screen filed under the name of something further down. So a scroll that
/// does not arrive is recorded against the screen like any other capture
/// error, and the run's closing summary prints it.
Future<void> scrollTo(
  WidgetTester tester,
  Finder finder, {
  String? describedAs,
}) async {
  final what = describedAs ?? finder.describeMatch(Plurality.one);
  if (finder.evaluate().isEmpty) {
    // **"Not in the widget tree" is not "not on this screen"** (`/w-08`).
    //
    // A `ListView` builds only the children near the viewport, so something
    // far enough below the fold has no element at all — and `ensureVisible`
    // needs one, because it works by asking a built widget's own scrollable to
    // reveal it. This branch used to call that absence and stop.
    //
    // It was right the day it was written and became wrong the moment task
    // 11.99 put a "Your role" card at the top of the members screen: on the
    // phone that pushed the pending-request section past the build window, so
    // the shot named for it and the Approve tap below it both failed, on a
    // screen that had lost nothing at all. **The assertion was doing its job
    // — it is what caught this** — so it keeps its job and gains the one thing
    // it was missing: drag the list looking for the target before concluding
    // the app no longer has it.
    if (!await _dragUntilBuilt(tester, finder, what)) return;
  }
  try {
    // **Flutter's own `ensureVisible`, not a hand-rolled drag loop.** The
    // first version of this dragged a fixed distance and checked the result
    // against the window's own bounds, and it reported everything as already
    // visible and scrolled nothing — one wrong rectangle, and every image it
    // guarded was silently of the top of the screen. Asking the framework to
    // scroll its own scrollable has no rectangle to get wrong.
    await tester.ensureVisible(finder);
  } catch (error) {
    recordCaptureError('could not scroll to $what — '
        '${error.toString().split('\n').first}');
    return;
  }
  await settle(tester, wait: const Duration(seconds: 1));
  // **Says where it ended up, every time, not only when it fails.** A scroll
  // that silently did nothing produces a picture of the top of a screen filed
  // under the name of something further down, and that is indistinguishable
  // from a correct capture unless the instrument says which it was.
  final rect = tester.getRect(finder.first);
  final view = tester.view;
  final height = view.physicalSize.height / view.devicePixelRatio;
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: scrollTo($what): now at '
      '${rect.top.round()}..${rect.bottom.round()} of $height');
  if (rect.height <= 0 || rect.top < 0 || rect.bottom > height) {
    recordCaptureError('$what is at ${rect.top.round()}..${rect.bottom.round()} '
        'in a window $height tall, so the next image is not of what its name '
        'says');
  }
}

/// Drags the screen's scrollable until [finder] builds, or reports that it
/// never did.
///
/// Bounded and loud in both directions: a target that arrives is announced
/// with the number of drags it took, because "it needed eleven drags" is how
/// somebody finds out a screen has grown a section since the last run; a
/// target that never arrives is a capture error, so the shutter that fires
/// afterwards is filed under a name the run has already contradicted.
Future<bool> _dragUntilBuilt(
  WidgetTester tester,
  Finder finder,
  String what,
) async {
  // **Which list to drag, and why the obvious answer is wrong in this app.**
  //
  // `scrollUntilVisible` defaults to `find.byType(Scrollable).first`, and
  // `app_router.dart` is a `StatefulShellRoute.indexedStack`: **all five tabs
  // stay mounted at once**, each with a scrollable of its own, underneath
  // whatever route is pushed on top of them. The first in the tree is the
  // map's, so the default drags a screen nobody is looking at, the target
  // never builds, and the run concludes the app no longer has it.
  //
  // That is not a guess — it is what the first attempt at this repair did, on
  // a real run, and **the assertion below reported it** rather than letting a
  // picture of the wrong screen through. `hitTestable()` keeps only the
  // scrollables a tap could actually reach, which on a stack of routes is the
  // one on screen.
  final all = find.byType(Scrollable);
  final onScreen = all.hitTestable();
  final Finder list;
  if (onScreen.evaluate().isNotEmpty) {
    list = onScreen.first;
  } else {
    // Never the framework's `.first`: the wrong end of this tree is the map,
    // and the right end is whatever was pushed last.
    list = all.last;
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: scrollTo($what): no scrollable is hit-testable, '
        'so the last of ${all.evaluate().length} is being dragged on the '
        'assumption it belongs to the topmost route');
  }
  try {
    await tester.scrollUntilVisible(finder, 200, scrollable: list);
  } catch (error) {
    recordCaptureError('$what is not on this screen at all, and dragging the '
        'on-screen list from top to bottom never built it; the next image is '
        'not of what its name says');
    return false;
  }
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: scrollTo($what): was not built yet; dragged the '
      'on-screen list (1 of ${all.evaluate().length} scrollables in the tree) '
      'until it was');
  return true;
}

/// True when the app is showing [text] somewhere on screen right now.
///
/// Used by the capture run to check a state is the one it is about to file
/// under a name, rather than trusting that navigating there was enough.
bool showsText(WidgetTester tester, String text) =>
    isOnScreen(tester, find.text(text));
