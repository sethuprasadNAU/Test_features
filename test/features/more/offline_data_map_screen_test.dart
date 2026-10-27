import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/more/screens/offline_data_map_screen.dart';

import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

class _FakeOfflineRegions extends OfflineRegions {
  @override
  Future<List<OfflineRegion>> build() async => const [];
}

class _FixedDownloadManager extends DownloadManager {
  _FixedDownloadManager(this._fixed);
  final List<DownloadJob> _fixed;

  @override
  List<DownloadJob> build() {
    // Skip the real super.build() (which registers a WidgetsBindingObserver
    // and does real I/O on job completion) — this fake only needs to expose
    // a fixed job list for the progress-card UI to render.
    return _fixed;
  }
}

void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  const poly = [LatLng(35.0, -111.0), LatLng(35.0, -110.9), LatLng(35.1, -110.9)];

  Future<void> pumpScreen(WidgetTester tester, List<DownloadJob> jobs) async {
    final container = ProviderContainer(
      overrides: [
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(() => _FixedDownloadManager(jobs)),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: OfflineDataMapScreen()),
      ),
    );
    // Avoid pumpAndSettle: the basemap TileLayer issues real network image
    // requests that never resolve in a test environment, which would hang a
    // settle loop forever. A couple of plain pumps is enough for the
    // provider-driven overlay/progress widgets (no image decode required) to
    // build.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('shows Completed with a Retry when some tiles failed', (tester) async {
    await pumpScreen(tester, [
      const DownloadJob(
        id: 'tiles-1',
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.complete,
        total: 10,
        done: 8,
        failed: 2,
      ),
    ]);

    expect(find.textContaining('Completed'), findsOneWidget);
    // **Task 11.135 changed this line and the assertion follows the change.**
    // It used to read `(2 failed)` — the parenthesised count *replaced* the
    // done/total rather than joining it, so a run that fetched 8 of 10 said
    // nothing about the 8. Both facts now, and the "why" is the line below
    // the card's own, which `offline_data_map_overlap_test.dart` measures.
    expect(find.textContaining('6/10, 2 did not arrive'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('shows Failed state with error text and Retry', (tester) async {
    await pumpScreen(tester, [
      const DownloadJob(
        id: 'dem-1',
        kind: DownloadJobKind.dem,
        polygon: poly,
        status: DownloadJobStatus.failed,
        total: 5,
        done: 0,
        failed: 5,
        error: 'network unreachable',
      ),
    ]);

    expect(find.textContaining('Failed'), findsOneWidget);
    expect(find.textContaining('network unreachable'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });

  testWidgets('shows an honest running state with Cancel, not a perpetual dialog', (tester) async {
    await pumpScreen(tester, [
      const DownloadJob(
        id: 'tiles-2',
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.running,
        total: 20,
        done: 5,
      ),
    ]);

    expect(find.textContaining('downloading 5 / 20'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
  });

  testWidgets('shows a Paused state with Resume', (tester) async {
    await pumpScreen(tester, [
      const DownloadJob(
        id: 'tiles-3',
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.paused,
        total: 20,
        done: 5,
      ),
    ]);

    expect(find.textContaining('paused'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Resume'), findsOneWidget);
  });

  testWidgets('new selection starts a 4-vertex rectangle with midpoint handles', (tester) async {
    await pumpScreen(tester, const []);

    // flutter_map's `Marker` is a plain data object (not a Widget), so the
    // handle widgets themselves — private classes in the screen's library —
    // are located structurally: vertex handles set both onTap and
    // onPanUpdate, midpoint handles set only onPanStart.
    bool isVertexHandle(Widget w) =>
        w is GestureDetector && w.onTap != null && w.onPanUpdate != null;
    bool isMidpointHandle(Widget w) =>
        w is GestureDetector && w.onPanStart != null;

    expect(find.text('New selection'), findsOneWidget);
    await tester.tap(find.text('New selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byWidgetPredicate(isVertexHandle), findsNWidgets(4));
    final midpointFinder = find.byWidgetPredicate(isMidpointHandle);
    expect(midpointFinder, findsNWidgets(4));

    // Dragging a midpoint inserts a new vertex there, turning the rectangle
    // into a 5-gon — which then has 5 vertices and 5 midpoints. Invoke the
    // handle's onPanStart directly rather than simulating a raw pointer drag:
    // it sits inside flutter_map's own pan/zoom gesture arena, which makes a
    // synthetic drag an unreliable way to test app-level insert logic.
    final onPanStart = tester.widget<GestureDetector>(midpointFinder.first).onPanStart!;
    onPanStart(DragStartDetails());
    await tester.pump();

    expect(find.byWidgetPredicate(isVertexHandle), findsNWidgets(5));
    expect(find.byWidgetPredicate(isMidpointHandle), findsNWidgets(5));
  });

  testWidgets('selecting and deleting a vertex removes it, refusing below 3', (tester) async {
    await pumpScreen(tester, const []);

    bool isVertexHandle(Widget w) =>
        w is GestureDetector && w.onTap != null && w.onPanUpdate != null;

    // Hide the legend card first — at this default (near 0,0) camera
    // position it can overlap the selection rectangle's handles and steal
    // the tap.
    await tester.tap(find.byTooltip('Toggle legend'));
    await tester.pump();

    await tester.tap(find.text('New selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Select a vertex: its delete affordance (a close icon) appears.
    await tester.tap(find.byWidgetPredicate(isVertexHandle).first);
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);

    // Deleting it drops the rectangle to a 3-gon (still >= the minimum).
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byWidgetPredicate(isVertexHandle), findsNWidgets(3));

    // No vertex is selected after a delete, so the delete affordance is gone
    // until another vertex is tapped.
    expect(find.byIcon(Icons.close), findsNothing);

    // At the minimum of 3 vertices, the delete affordance itself is
    // withheld even for a selected vertex — the UI never offers a control
    // that would drop below a valid polygon.
    await tester.tap(find.byWidgetPredicate(isVertexHandle).first);
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byWidgetPredicate(isVertexHandle), findsNWidgets(3));
  });
}
