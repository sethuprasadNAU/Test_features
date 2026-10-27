/// The shared app-shell harness for space-budget tests (task 11.110).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/core/providers/cloud_backup_retirement_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/routing/app_router.dart';

/// Task 11.110 — the shell every space-budget test pumps a screen inside.
///
/// **Most of this project's widget tests pump a screen bare** — a
/// `MaterialApp(home: SomeScreen())`, usually at a generous surface size —
/// which hands the screen roughly a `NavigationBar`'s worth of height it
/// never has in the running app, and until 2026-09-07 the shell's two banner
/// slots on top of that. Task 11.109 found a screen with no usable content
/// left on a real phone while every test on it passed, and that gap is most
/// of the reason.
///
/// So this pumps the **real [TabShell]** — the same `Scaffold` /
/// `SafeArea(bottom: false)` / five-destination `NavigationBar` the app
/// builds — through a throwaway five-branch `GoRouter`, at real phone
/// geometry. It is the real widget rather than a copy of its shape on
/// purpose: a hand-written replica of the shell is a hand-maintained list,
/// and it would go stale the first time somebody changes the shell.
///
/// **Task 11.189 took the shell's two banners out**, so the height a screen
/// is given here is now the whole shell minus the navigation bar. That is
/// **109 more logical pixels at the default text size and 623 more at AX5**
/// than the same screen had before 2026-09-07, and
/// `test/routing/app_shell_space_budget_test.dart` is where those numbers are
/// measured rather than asserted from memory. The reason to keep pumping the
/// real shell is unchanged: the navigation bar is still 114 logical pixels a
/// bare pump does not take away, and the shell is still where a future
/// addition would land.

/// iPhone 14 Pro logical geometry — the 6.1-inch phone task 11.109's defect
/// was found on, and the smallest screen this app claims to support.
const phoneSize = Size(393, 852);
const phoneTopInset = 59.0; // status bar / Dynamic Island
const phoneBottomInset = 34.0; // home indicator

/// A device geometry a budget test can be pumped at. The default everywhere
/// is [phoneGeometry]; the others exist so a panel that is sized as a
/// *fraction* of the screen can be measured on a screen of a different size,
/// which is the question task 11.139 was asked about the bearings list.
class DeviceGeometry {
  const DeviceGeometry({
    required this.name,
    required this.size,
    required this.topInset,
    required this.bottomInset,
  });

  /// Named because a measurement that does not say which device it is about
  /// is the same measurement on two devices.
  final String name;
  final Size size;
  final double topInset;
  final double bottomInset;

  @override
  String toString() => name;
}

const phoneGeometry = DeviceGeometry(
  name: '6.1-inch phone',
  size: phoneSize,
  topInset: phoneTopInset,
  bottomInset: phoneBottomInset,
);

/// iPhone 17 Pro Max logical geometry — the **6.9-inch phone** the screenshot
/// harness photographs (`integration_test/screenshots/regenerate.sh`), whose
/// 1320 x 2868 native resolution is 440 x 956 at the 3x scale iOS renders it
/// at.
///
/// It exists because task 11.193's defect was found there and nowhere else:
/// `/w-14`'s published picture of the Record screen showed *Preview / set
/// position on map* sliced to a sliver at the bottom edge of the form. A
/// 6.9-inch phone is 104 logical pixels **taller** than the 6.1-inch one
/// [phoneGeometry] names, so this is not "the small screen" — it is the screen
/// the website's own picture is taken on, and a control that is cut off in
/// that picture is cut off for every reader of the guide.
const phone69Geometry = DeviceGeometry(
  name: '6.9-inch phone',
  size: Size(440, 956),
  topInset: 62.0,
  bottomInset: 34.0,
);

/// 12.9/13-inch iPad, portrait, in logical points. `/w-11` photographed the
/// Position screen here and found it showing the **same four bearing rows it
/// shows on a phone** — twice the height buying no extra rows — because the
/// panel is a fraction of the screen. Task 11.139 measures that rather than
/// leaving it a judgement.
const tabletGeometry = DeviceGeometry(
  name: '13-inch iPad (portrait)',
  size: Size(1024, 1366),
  topInset: 24.0,
  bottomInset: 20.0,
);

/// Points the test surface at [geometry] — a 6.1-inch phone unless told
/// otherwise — and puts it back afterwards.
void usePhoneGeometry(
  WidgetTester tester, {
  DeviceGeometry geometry = phoneGeometry,
}) {
  tester.view.physicalSize = geometry.size;
  tester.view.devicePixelRatio = 1.0;
  tester.view.padding = FakeViewPadding(
    top: geometry.topInset,
    bottom: geometry.bottomInset,
  );
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}

/// Builds [screen] as tab [tabIndex] of a throwaway five-branch router, so
/// [TabShell] renders the same five-destination `NavigationBar` the app does.
/// The other four branches are empty `Scaffold`s — they are never displayed,
/// and standing up four more real screens would only slow the test down.
GoRouter throwawayShellRouter({required Widget screen, required int tabIndex}) {
  assert(tabIndex >= 0 && tabIndex < 5);
  return GoRouter(
    initialLocation: '/tab$tabIndex',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            TabShell(navigationShell: navigationShell),
        branches: [
          for (var i = 0; i < 5; i++)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/tab$i',
                  builder: (c, s) => i == tabIndex ? screen : const Scaffold(),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

/// Pumps [screen] inside the real app shell at 6.1-inch phone geometry and
/// waits for it to stop loading.
///
/// Runs inside [WidgetTester.runAsync] because these screens read SQLite and
/// `SharedPreferences`, neither of which completes under a fake clock.
///
/// [textScale] is the system text size, the thing a person changes in
/// Settings and **nothing in this app or its screenshot harness had ever
/// been rendered at anything but 1.0** before task 11.139. It is applied by
/// wrapping the router's own output in a [MediaQuery] rather than by setting
/// `tester.platformDispatcher.textScaleFactorTestValue`, so it survives the
/// `MediaQuery` `MaterialApp` inserts and so a caller can vary it without
/// touching global test state. Use the [iosTextScales] ladder — those are
/// the sizes a real iPhone can actually be set to.
Future<void> pumpInAppShell(
  WidgetTester tester, {
  required ProviderContainer container,
  required Widget screen,
  required int tabIndex,
  Duration timeout = const Duration(seconds: 15),
  DeviceGeometry geometry = phoneGeometry,
  double textScale = 1.0,
}) async {
  usePhoneGeometry(tester, geometry: geometry);
  final router = throwawayShellRouter(screen: screen, tabIndex: tabIndex);
  addTearDown(router.dispose);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
    final deadline = DateTime.now().add(timeout);
    while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        throw TestFailure(
          'pumpInAppShell: $screen was still showing a spinner after '
          '${timeout.inSeconds}s — a provider it watches never resolved, so '
          'nothing below was measured.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    }
  });
}

/// The height of the tallest **clear rectangle** inside [subject] — a
/// rectangle at least [kClearRegionMinWidth] wide with nothing from
/// [overlays] drawn over any part of it. The number that matters when the
/// subject is something you look *at* (a map) rather than something laid out
/// in a column.
///
/// ## What an overlay costs, and why this changed (task 11.204)
///
/// **An overlay blocks only the horizontal extent it actually covers.** Until
/// task 11.204 every overlay was charged the subject's full width whatever
/// its own width, and this comment said that was deliberate — a control
/// tucked into a corner still spoiled the band it sat in, and a budget that
/// let furniture accumulate along one edge "for free" is the budget that
/// produced the defect this measures.
///
/// **That reason was good and it contradicted rule 4 of the Position
/// screen's MAP SPACE BUDGET**, which said in as many words that a control
/// joining a corner cluster costs the clear band nothing extra. Both texts
/// were written on purpose, neither had gone stale, and nothing could tell
/// them apart until task 11.203 built the first overlay on any of these
/// screens that was not full width: two 48-pixel squares stacked in a
/// corner, charged as a full-width band of their combined height, which took
/// the Position map's band from 96 to **49.8**.
///
/// **The settlement satisfies both reasons instead of picking one.** Corners
/// are free *because the region is floored in both directions*: a caller
/// asserts a height floor (96 on all three maps today) and this measurement
/// enforces [kClearRegionMinWidth] as well. A 48-pixel square in a corner
/// leaves a rectangle nearly the subject's full width and full height, so it
/// costs nothing — which is rule 4. Furniture accumulating along one edge
/// eats the width until no rectangle [kClearRegionMinWidth] wide survives
/// and the answer collapses to whatever is left above or below it — which is
/// the old comment's reason, still enforced, now by a measurement rather
/// than by over-charging every overlay.
///
/// **It reproduces the old numbers on every layout that predates 11.203.**
/// Where every overlay really is full width, no slab that touches an overlay
/// leaves any horizontal gap at all, so the answer is exactly the old
/// largest vertical gap. That equivalence is asserted directly, over random
/// inputs, in `test/support/clear_band_measurement_test.dart` — a
/// measurement that cannot reproduce what the old one said about the old
/// inputs would be a different instrument rather than a better one.
double clearBandHeight(
  WidgetTester tester,
  Finder subject,
  List<Finder> overlays,
) {
  final area = tester.getRect(subject);
  final rects = <Rect>[];
  for (final overlay in overlays) {
    for (final element in overlay.evaluate()) {
      rects.add(tester.getRect(find.byWidget(element.widget)));
    }
  }
  return clearBandFromRects(area, rects);
}

/// Whether [target] is fully inside [viewport], with no scrolling — the
/// question that matters on a scrolling form: "can they reach the control
/// they came here to use without hunting for it?"
bool isFullyVisibleIn(WidgetTester tester, Finder target, Finder viewport) {
  final v = tester.getRect(viewport);
  final t = tester.getRect(target);
  return t.top >= v.top - 0.5 && t.bottom <= v.bottom + 0.5;
}

/// Gives the app a live sync status, so a budget test measures the screen in
/// the state a real device is usually in rather than in its calm one. Use as
/// `syncControllerProvider.overrideWith(LiveSyncStatusController.new)`.
///
/// **What this makes appear changed on 2026-09-07 and the reason to use it
/// did not.** It used to make the shell's sync bar render — one of two
/// ~38-pixel bands above every tab that no bare pump could see. Task 11.189
/// replaced that with `SyncStatusIcon` on the Main Map and a dot on the More
/// tab, so what this now switches on is **a 28-pixel overlay on the map**,
/// which the map's clear-band measurement counts like any other overlay, and
/// a badge on a navigation icon, which changes no height at all.
///
/// **This is still the variable to expect.** Task 11.109's finding was that
/// the bearings list showed the same single row at 2 bearings and at 200, and
/// what actually flipped it to zero was a conditional band appearing.
class LiveSyncStatusController extends SyncController {
  @override
  Future<SyncStatus> build() async => SyncStatus(
        schedule: const SyncSchedule(),
        // Relative to now, not a fixed calendar date (task 11.114 fixed a
        // real instance of this bug in this exact fixture): a fixed past
        // date only drifts one way, and it would have made every
        // space-budget test using this class permanently trip the 24-hour
        // staleness threshold from the day this literal turned a day old.
        lastSuccessAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 1),
        ),
      );
}

/// Makes the cloud-backup retirement notice live by writing the leftover
/// preference it reads. Drives the real provider rather than overriding it,
/// so this cannot go on passing after the notice is retired.
///
/// **It is no longer a shell banner** (task 11.189): it is an entry at the
/// top of the More screen, so it costs no other screen anything and a budget
/// test for a screen that is not More has no reason to seed it. Kept here
/// because `more_screen_test.dart` needs exactly this seeding.
///
/// Call after `installFakeSharedPreferences`.
Future<void> seedCloudBackupRetiredNotice() =>
    SharedPreferencesAsync().setString(
      CloudBackupRetirementNotice.prefsKey,
      jsonEncode({'folderToken': 'a-folder-this-device-once-linked'}),
    );

/// The same measurement as [clearBandHeight], with the overlay set **derived
/// from the `Stack`'s own children** instead of listed by hand (task 11.166).
///
/// ## Why this exists
///
/// [clearBandHeight] takes a list of finders, and both map screens supplied
/// one written out by hand, under a comment asking the next person to add
/// their new overlay to it. **That is a hand-maintained list acting as the
/// control**, which this project's oldest rule says is the wrong place for
/// one: an overlay missing from the list is not measured, and the band reads
/// as *larger* than it is — so the check fails in the silent direction.
///
/// It was already wrong. The Main Map's legend card
/// (`map_screen.dart`, the `Positioned` under `_showLegend`) is a `Stack`
/// child with no key at all and was in neither list, so the floor was being
/// asserted only for the state where somebody has the legend switched off.
///
/// Here the subject is the `Stack`'s **first** child — the map fills it — and
/// every later child is an overlay, whether or not it is keyed, whether or
/// not anybody remembered it. **A new overlay is measured the moment it is
/// added.**
///
/// It refuses a scope it cannot have derived: a `Stack` with no overlays at
/// all would measure a perfect band and agree with itself, which is the
/// failure a derivation has to be unable to report as success.
double clearBandOverStack(WidgetTester tester, Key stackKey) {
  final (area, overlays) = stackSubjectAndOverlays(tester, stackKey);
  return clearBandFromRects(area, overlays);
}

/// The subject rectangle and the overlay rectangles [clearBandOverStack]
/// derives — exposed so a test can assert that a particular overlay is in the
/// set, which is the only way to tell "the legend does not shrink the band"
/// apart from "the derivation never saw the legend."
(Rect, List<Rect>) stackSubjectAndOverlays(WidgetTester tester, Key stackKey) {
  final stack = tester.renderObject<RenderStack>(find.byKey(stackKey));
  final children = <RenderBox>[];
  for (RenderBox? c = stack.firstChild; c != null; c = stack.childAfter(c)) {
    children.add(c);
  }
  if (children.length < 2) {
    throw TestFailure(
      'clearBandOverStack: the Stack keyed $stackKey has '
      '${children.length} child(ren), so this measurement derived no '
      'overlays at all and would have reported a perfect clear band. A map '
      'with nothing over it and a scan that found nothing are '
      'indistinguishable from in here, and only one of them is true.',
    );
  }
  Rect rectOf(RenderBox b) => b.localToGlobal(Offset.zero) & b.size;
  return (rectOf(children.first), children.skip(1).map(rectOf).toList());
}

/// The narrowest a clear region may be and still count as clear.
///
/// **Stated here with its reason, beside the thing it constrains, because
/// its absence is what made "corners are free" unsafe to write down** (task
/// 11.204).
///
/// It is the height floor's own argument turned through ninety degrees. The
/// height floor on all three maps is 96 logical pixels — three 32pt marker
/// heights: the marker at each observer, the crossing, and room to see they
/// are not the same point. **A crossing needs that neighbourhood in both
/// directions.** Two rays arriving from different bearings cross at an angle,
/// so a region 96 tall and 20 wide contains no more of a crossing than a
/// region 20 tall does; it is a slot, not a view. The same three marker
/// widths give the same number, and using one number for both axes is also
/// the honest statement of what is known: nobody has measured a real
/// crossing on a real phone, and inventing a second, different constant
/// would imply somebody had.
///
/// **What it is not.** It is not a claim that a 96×96 square is a comfortable
/// place to judge a position estimate. It is the point below which the
/// measurement stops calling a region clear at all, so that furniture
/// creeping along an edge is charged for the width it takes.
const double kClearRegionMinWidth = 96.0;

/// The measurement shared by [clearBandHeight] and [clearBandOverStack]: the
/// height of the tallest rectangle inside [area] that is at least [minWidth]
/// wide and has no [overlays] over it.
///
/// See [clearBandHeight] for why an overlay is charged its own width rather
/// than [area]'s, and for the equivalence with the pre-task-11.204
/// computation on full-width overlay sets.
///
/// The candidate horizontal slabs are the ones bounded by overlay edges:
/// every maximal clear rectangle has its top and bottom on an overlay edge or
/// on [area]'s own edge, so the pairs of those y values are an exhaustive
/// candidate set. For each slab, the overlays crossing it are projected onto
/// the x axis and the widest surviving gap decides whether that slab counts.
double clearBandFromRects(
  Rect area,
  List<Rect> overlays, {
  double minWidth = kClearRegionMinWidth,
}) {
  if (area.height <= 0 || area.width <= 0) return 0.0;

  // Overlays clipped to [area], dropping the ones that cannot block anything
  // inside it. A zero-height or zero-width overlay covers no pixels of the
  // subject and is charged for none.
  final blockers = <Rect>[];
  final edges = <double>{area.top, area.bottom};
  for (final r in overlays) {
    if (r.height <= 0 || r.width <= 0) continue;
    final clipped = Rect.fromLTRB(
      r.left.clamp(area.left, area.right),
      r.top.clamp(area.top, area.bottom),
      r.right.clamp(area.left, area.right),
      r.bottom.clamp(area.top, area.bottom),
    );
    if (clipped.height <= 0 || clipped.width <= 0) continue;
    blockers.add(clipped);
    edges.add(clipped.top);
    edges.add(clipped.bottom);
  }

  final ys = edges.toList()..sort();
  var best = 0.0;
  for (var i = 0; i < ys.length; i++) {
    for (var j = i + 1; j < ys.length; j++) {
      final top = ys[i];
      final bottom = ys[j];
      final height = bottom - top;
      if (height <= best) continue; // cannot improve on what we have
      if (_widestGapAcross(area, blockers, top, bottom) >= minWidth) {
        best = height;
      }
    }
  }
  return best;
}

/// The widest run of [area]'s width, between [top] and [bottom], that no
/// blocker touches.
double _widestGapAcross(
  Rect area,
  List<Rect> blockers,
  double top,
  double bottom,
) {
  final spans = <(double, double)>[];
  for (final b in blockers) {
    // Strict, so a blocker that merely abuts this slab does not cross it.
    if (b.bottom <= top || b.top >= bottom) continue;
    spans.add((b.left, b.right));
  }
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  var best = 0.0;
  var cursor = area.left;
  for (final (left, right) in spans) {
    if (left > cursor) best = best > left - cursor ? best : left - cursor;
    if (right > cursor) cursor = right;
  }
  if (area.right > cursor) {
    best = best > area.right - cursor ? best : area.right - cursor;
  }
  return best;
}
