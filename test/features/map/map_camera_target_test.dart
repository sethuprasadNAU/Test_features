import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:tritrack/features/map/map_camera_target.dart';

/// Task 11.103 — the fallback chain every map in the app opens with.
///
/// The defect this closes: with no position estimate the map centred on
/// `LatLng(0, 0)`, a real place in the Gulf of Guinea, at street zoom. Because
/// it is a *valid* coordinate nothing threw and nothing warned — "I do not
/// know where you are" was drawn as "you are here".
///
/// The chain is Michael's, 2026-08-31: the device's position, then the extent
/// of the most recently recorded data in the active project, then the
/// project's map extent, then nothing. The last step is the one worth having
/// tests for, because it is the one with no honest coordinate.
void main() {
  MapPointInTime at(double lat, double lon, DateTime when) =>
      MapPointInTime(lat, lon, when);

  final now = DateTime.utc(2026, 9, 1, 12);

  group('the chain runs in Michael\'s order', () {
    test('step 1 — a device position wins over everything else', () {
      final target = chooseMapCameraTarget(
        devicePosition: const ll.LatLng(35.19, -111.65),
        recorded: [at(10, 10, now)],
        projectExtent: const GeoExtent(
          minLat: 20,
          minLon: 20,
          maxLat: 21,
          maxLon: 21,
        ),
      );
      expect(target.source, MapCameraSource.devicePosition);
      expect(target.center, const ll.LatLng(35.19, -111.65));
    });

    test('step 2 — recent recordings beat the project extent', () {
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [at(35.0, -111.0, now), at(35.2, -111.4, now)],
        projectExtent: const GeoExtent(
          minLat: 20,
          minLon: 20,
          maxLat: 21,
          maxLon: 21,
        ),
      );
      expect(target.source, MapCameraSource.recentRecordedData);
      expect(target.center!.latitude, closeTo(35.1, 1e-9));
      expect(target.extent, isNotNull);
    });

    test('step 3 — the project extent when nothing has been recorded', () {
      final target = chooseMapCameraTarget(
        devicePosition: null,
        projectExtent: const GeoExtent(
          minLat: 35.1,
          minLon: -111.7,
          maxLat: 35.3,
          maxLon: -111.5,
        ),
      );
      expect(target.source, MapCameraSource.projectExtent);
      expect(target.center!.latitude, closeTo(35.2, 1e-9));
    });

    test('step 4 — nothing supplied carries no coordinate at all', () {
      final target = chooseMapCameraTarget(devicePosition: null);
      expect(target.source, MapCameraSource.nothingSupplied);
      expect(target.isSupplied, isFalse);
      expect(
        target.center,
        isNull,
        reason: 'a map with nothing to go on must not be handed a place. '
            'This is the whole defect: 0,0 is valid, so it passed silently.',
      );
      expect(target.zoom, MapCameraTarget.worldViewZoom);
    });
  });

  group('"the most recently recorded data" means the last day of work', () {
    test('a stale cluster does not drag the view away from today\'s', () {
      final lastWeek = now.subtract(const Duration(days: 7));
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [
          at(10.0, 10.0, lastWeek),
          at(10.1, 10.1, lastWeek),
          at(35.10, -111.60, now),
          at(35.12, -111.62, now.subtract(const Duration(hours: 3))),
        ],
      );
      expect(target.source, MapCameraSource.recentRecordedData);
      expect(target.center!.latitude, closeTo(35.11, 1e-9));
      expect(target.center!.longitude, closeTo(-111.61, 1e-9));
    });

    test('a session that runs through midnight stays one session', () {
      // The reason the window is measured back from the newest point rather
      // than being a calendar day: dusk-to-small-hours work straddles a
      // midnight, and a UTC midnight lands mid-evening across the Americas.
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [
          at(35.0, -111.0, DateTime.utc(2026, 9, 1, 2)),
          at(35.4, -111.4, DateTime.utc(2026, 8, 31, 22)),
        ],
      );
      expect(target.extent!.minLat, closeTo(35.0, 1e-9));
      expect(target.extent!.maxLat, closeTo(35.4, 1e-9));
    });

    test('one recording is a point, not a zero-area box to zoom into', () {
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [at(35.0, -111.0, now)],
      );
      expect(target.source, MapCameraSource.recentRecordedData);
      expect(target.extent, isNull);
      expect(target.center, const ll.LatLng(35.0, -111.0));
    });
  });

  group('nothing half-supplied is treated as supplied', () {
    test('a bbox missing one corner is not an extent', () {
      expect(
        GeoExtent.fromProjectBbox(minLat: 35.1, minLon: -111.7, maxLat: 35.3),
        isNull,
      );
    });

    test('a bbox stored with its corners swapped still frames the same box', () {
      final extent = GeoExtent.fromProjectBbox(
        minLat: 35.3,
        minLon: -111.5,
        maxLat: 35.1,
        maxLon: -111.7,
      )!;
      expect(extent.minLat, 35.1);
      expect(extent.maxLon, -111.5);
    });

    test('recordings with unusable coordinates are skipped, not centred on', () {
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [
          at(double.nan, 10, now),
          at(999, 10, now),
          at(35.0, -111.0, now),
        ],
      );
      expect(target.center, const ll.LatLng(35.0, -111.0));
    });

    test('recordings that are all unusable fall through to nothing supplied', () {
      final target = chooseMapCameraTarget(
        devicePosition: null,
        recorded: [at(double.infinity, 10, now)],
      );
      expect(target.source, MapCameraSource.nothingSupplied);
      expect(target.center, isNull);
    });
  });

  test('the whole-planet framing is world-scale, not a street-level place', () {
    // If this ever drifts up, the "nothing supplied" view starts reading as a
    // claim about somewhere again — which is the defect, wearing a different
    // coordinate.
    expect(MapCameraTarget.worldViewZoom, lessThanOrEqualTo(3));
    expect(
      MapCameraTarget.nothingSuppliedMessage,
      contains('does not know where you are'),
    );
  });
}
