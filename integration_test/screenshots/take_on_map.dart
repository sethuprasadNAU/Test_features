// **Take on map, scripted** (`/w-32`) — shared by the capture run and the
// video pilot, so the two cannot disagree about what a sweep looks like.
//
// *Take on map* draws a range bearing over **today's earlier bearings on the
// same collar**, so a person sees the crossing while they sweep. Everything it
// needs is something a simulator does not have:
//
//  * **Earlier bearings dated today.** The seed's bearings are fixed in
//    February so the other pictures never move, and "today" for this screen is
//    the device's calendar date. So [addTodaysBearings] writes two directional
//    bearings on Sage stamped a few seconds ago, aimed from two different
//    places at one invented spot, and [removeTodaysBearings] **hard-deletes**
//    them again afterwards. Hard, not the app's soft delete: a tombstone is a
//    row the next sync round would push, and the sync-status pictures later in
//    the run count rows waiting to be sent.
//  * **A compass.** A simulator has none, and the button hides without one, so
//    the harness's faked heading (`setFakeHeading`) is moved on a script.
//  * **A finger held down.** `tester.startGesture` on the hold button, and the
//    heading stepped while it is down, is a person sweeping.
//
// Every number that sets the geometry is derived below from the seed's own
// position and the app's own declination, not typed: a sweep that crossed
// nothing would be a picture of the wrong thing under a name that says
// otherwise.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/localization/declination/record_declination.dart';
import 'package:tritrack/localization/declination/wmm_provider.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'harness.dart';
import 'seed.dart';

/// The two bearings written for the sweep to cross.
const List<String> todaysBearingIds = [
  'screenshot-today-bearing-1',
  'screenshot-today-bearing-2',
];

/// Where the phone points before anything is held, in magnetic degrees.
const double sweepStartDeg = 31;

/// Where the sweep ends. With [sweepStartDeg] this makes a 34-degree arc whose
/// middle is 48 — the compass picture's own 47, give or take a degree, so the
/// two pictures read as the same phone.
const double sweepEndDeg = 65;

/// The invented animal's spot, as the middle of the sweep points at it.
const double _targetMeters = 900;

/// Writes the two earlier bearings. Returns the declination used, for the log.
Future<double> addTodaysBearings(ProviderContainer container) async {
  const distance = ll.Distance();
  final wmm = await container.read(wmmServiceProvider.future);
  final declination = recordDeclinationDeg(
        manualOverrideDeg: null,
        wmm: wmm,
        latitude: seedLat,
        longitude: seedLon,
        date: DateTime.now(),
      ) ??
      0;
  final person = ll.LatLng(seedLat, seedLon);
  final middleTrue = (sweepStartDeg + sweepEndDeg) / 2 + declination;
  final target = distance.offset(person, _targetMeters, middleTrue);

  // Two observers, one either side and a little behind the person, each
  // pointing at the target. Their bearings are *computed* from where they
  // stand, so the two lines cross exactly where the sweep's middle points.
  final observers = <(String, ll.LatLng, String)>[
    (
      todaysBearingIds[0],
      distance.offset(person, 650, middleTrue - 115),
      ownerUserId,
    ),
    (
      todaysBearingIds[1],
      distance.offset(person, 480, middleTrue + 105),
      memberUserId,
    ),
  ];

  final db = await container.read(appDatabaseProvider.future);
  final versions = await db.raw.query(
    'Tag_Versions',
    columns: ['tag_version_id'],
    where: 'tag_id = ?',
    whereArgs: ['seed-tag-sage'],
    limit: 1,
  );
  final tagVersionId =
      versions.isEmpty ? null : versions.first['tag_version_id'] as String;
  final repo = await container.read(observationRepositoryProvider.future);
  final now = DateTime.now().toUtc();
  var seconds = 40;
  for (final (id, at, userId) in observers) {
    final trueBearing = (distance.bearing(at, target) + 360) % 360;
    final stamp = now.subtract(Duration(seconds: seconds));
    seconds -= 15;
    await repo.insert(Observation(
      observationId: id,
      projectId: seedProjectId,
      userId: userId,
      tagId: 'seed-tag-sage',
      tagVersionId: tagVersionId,
      timestampLocal: stamp.toLocal(),
      timestampUtc: stamp,
      timezoneOffset: seedOffset,
      latitude: at.latitude,
      longitude: at.longitude,
      positionAccuracyM: 6.0,
      positionSource: PositionSource.gpsFix,
      elevation: 1310.0,
      observationType: ObservationType.directional,
      magneticBearing: (trueBearing - declination + 360) % 360,
      trueNorthBearing: trueBearing,
      bearingUncertainty: 10.0,
      bearingCaptureMethod: BearingCaptureMethod.singlePoint,
      bearingMethod: BearingMethod.peak,
      magneticDeclination: declination,
      wmmModelVersion: 'WMM2025',
      antennaType: 'yagi_3el',
      signalType: SignalType.regularPulse,
      signalStrength: SignalStrength.medium,
      bearingQuality: BearingQuality.good,
      sync: SyncMeta.initial(
        now: stamp,
        modifiedBy: userId,
        originDeviceId: seedDeviceId,
      ),
    ));
  }
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: wrote ${observers.length} bearings dated today on '
      'Sage, aimed at a spot ${_targetMeters.round()} m away at '
      '${middleTrue.toStringAsFixed(1)} true (declination '
      '${declination.toStringAsFixed(1)})');
  return declination;
}

/// Removes them again, completely. See the header for why it is a hard delete.
Future<void> removeTodaysBearings(ProviderContainer container) async {
  final db = await container.read(appDatabaseProvider.future);
  final removed = await db.raw.delete(
    Tables.observations,
    where: 'observation_id IN (${todaysBearingIds.map((_) => '?').join(',')})',
    whereArgs: todaysBearingIds,
  );
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: removed $removed of ${todaysBearingIds.length} '
      "bearings written for Take on map; the rest of the run sees the seed's "
      'own data');
}

/// Selects Sage on the Record screen's draft and returns the tag that was
/// selected, so the caller can put it back.
Future<String?> selectSageOnRecord(ProviderContainer container) async {
  final draft = await container.read(observationFormProvider.future);
  final before = draft.tagId;
  container.read(observationFormProvider.notifier).setTag('seed-tag-sage');
  return before;
}

/// Puts the Record draft's tag back, and clears any bearing a Confirm wrote.
void restoreRecordDraft(ProviderContainer container, String? tagId) {
  final notifier = container.read(observationFormProvider.notifier);
  notifier.clearBearing();
  if (tagId == null) {
    notifier.clearTag();
  } else {
    notifier.setTag(tagId);
  }
}

/// Taps the Record screen's round map button and waits for the screen to open.
Future<bool> openTakeOnMap(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('record-take-on-map'));
  if (button.evaluate().isEmpty) {
    recordCaptureError('there is no Take on map button on the Record screen; '
        'the faked compass should have made it appear');
    return false;
  }
  await tester.tap(button.first);
  await settle(tester, wait: const Duration(seconds: 2));
  return true;
}

/// Where the hold button is, or null with a capture error.
Offset? holdButtonCenter(WidgetTester tester) {
  final hold = find.byKey(const ValueKey('bearing-map-hold'));
  if (hold.evaluate().isEmpty) {
    recordCaptureError('the HOLD TO SWEEP button is not on screen');
    return null;
  }
  return tester.getCenter(hold.first);
}

/// Presses the hold button and turns the faked phone from [sweepStartDeg] to
/// [sweepEndDeg] in [steps] steps, [stepPause] apart. Returns the gesture,
/// still down, or null with a capture error. The caller releases it.
///
/// The heading is set *before* the press and given time to arrive: the app
/// marks where the sweep started from the heading it has at the instant of the
/// press, so a press before the first sample arrived would start the arc at 47.
Future<TestGesture?> startSweep(
  WidgetTester tester, {
  int steps = 9,
  Duration stepPause = const Duration(milliseconds: 350),
}) async {
  final at = holdButtonCenter(tester);
  if (at == null) return null;
  setFakeHeading(sweepStartDeg);
  await settle(tester, wait: const Duration(milliseconds: 600));
  final gesture = await tester.startGesture(at);
  await settle(tester, wait: const Duration(milliseconds: 500));
  for (var i = 1; i <= steps; i++) {
    setFakeHeading(sweepStartDeg + (sweepEndDeg - sweepStartDeg) * i / steps);
    await settle(tester, wait: stepPause);
  }
  return gesture;
}

/// Everything a scripted sweep leaves behind that a later picture would
/// inherit: the compass goes back to its one fixed number.
void restoreHeading() => setFakeHeading(fakeMagneticHeadingDeg);

/// The number of polylines on the Take on map layer, or -1 with no layer.
int takeOnMapLineCount() {
  final layer = find.byKey(const ValueKey('bearing-map-lines'));
  if (layer.evaluate().isEmpty) return -1;
  final widget = layer.evaluate().first.widget;
  // `PolylineLayer.polylines`, read dynamically so this file needs no import
  // of flutter_map's layer types.
  return ((widget as dynamic).polylines as List).length;
}
