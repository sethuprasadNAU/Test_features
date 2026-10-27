import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/more/screens/project_extent_picker_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.135 — the extent picker's verdict, measured.**
///
/// This screen exists so somebody can look at the ground and say "the project
/// is this rectangle". With no tiles it is a crosshair over nothing, and the
/// person is being asked to draw a boundary they cannot see — on ground they
/// have very often never downloaded, which is exactly when tiles fail. So the
/// verdict is **show the band**, and this is what it costs: the map area
/// carries one other thing, a crosshair drawn dead centre, and the band is in
/// the top corner.
void main() {
  setUp(installFakeSharedPreferences);
  // The signal is process-wide — every live tile in the app is counted by one
  // provider — so a test that leaves it tripped puts a band on the next
  // test's screen.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  Future<void> pumpPicker(WidgetTester tester) async {
    // Tile fetches fail under `flutter test` and are reported as framework
    // errors; drop exactly that noise so a real layout overflow still shows.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    usePhoneGeometry(tester);
    final container = ProviderContainer(
      overrides: [
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ProjectExtentPickerScreen(),
        ),
      ),
    );
    // Plain pumps: the basemap's tile requests never resolve under
    // `flutter test`, so `pumpAndSettle` would spin forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  const bandKey = ValueKey('extent-picker-tiles-not-loading');

  testWidgets('says nothing while tiles are arriving', (tester) async {
    await pumpPicker(tester);
    expect(find.byKey(bandKey), findsNothing);
  });

  testWidgets('says so when tiles stop arriving, without covering the '
      'crosshair or the corner buttons', (tester) async {
    await pumpPicker(tester);
    for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
      TileFetchHealth.instance.recordNetworkFailure();
    }
    await tester.pump();

    final band = find.byKey(bandKey);
    expect(
      band,
      findsOneWidget,
      reason:
          'Drawing a project extent on a basemap that is not arriving is '
          'drawing a boundary you cannot see. Before task 11.135 this screen '
          'said nothing about it.',
    );

    // The crosshair is the subject: it marks the corner the buttons below
    // will record, and it is drawn at the centre of the map area.
    final crosshair = tester.getRect(find.byIcon(Icons.add));
    final bandRect = tester.getRect(band);
    printOnFailure('band: $bandRect\ncrosshair: $crosshair');
    expect(
      bandRect.overlaps(crosshair),
      isFalse,
      reason: 'the band must not cover the crosshair — that is the one thing '
          'on this map a person is aiming',
    );
    expect(
      bandRect.bottom,
      lessThan(crosshair.top),
      reason: 'it sits in the top corner, where this map has no furniture at '
          'all',
    );

    // And nothing overflows with it up — task 11.126's rule, at real phone
    // geometry rather than the 800x600 a bare pump gives.
    expect(tester.takeException(), isNull);
  });
}
