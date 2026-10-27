import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../core/providers/recordings_revision_provider.dart';
import '../../../data/models/observation.dart';
import '../../../data/repositories/repository_providers.dart';

/// **Which way *Take on map* holds the map** — task 11.315, Michael's two
/// orientations behind one button.
enum BearingMapOrientation {
  /// The map stays still with north at the top; the wedge turns.
  northUp,

  /// The map turns so the direction the phone points is always at the top.
  facingUp;

  /// Reads a stored value back, falling back to [northUp] for nothing or for
  /// a value this build does not know. North up is where the screen starts
  /// the first time (Michael, 2026-09-28).
  static BearingMapOrientation parse(String? raw) =>
      raw == facingUp.name ? facingUp : northUp;
}

/// The orientation *Take on map* opens in, remembered **on this device**.
///
/// A view preference, not field data, so it is kept in the device's own
/// preferences and never synced — the same place and the same reasoning as
/// the tag wheel's sort switch (`TagWheelSortSetting`). A person who turns
/// facing up on wants it that way on the next bearing.
class BearingMapOrientationSetting
    extends AsyncNotifier<BearingMapOrientation> {
  static const prefsKey = 'bearing_map_orientation';
  final _prefs = SharedPreferencesAsync();

  @override
  Future<BearingMapOrientation> build() async =>
      BearingMapOrientation.parse(await _prefs.getString(prefsKey));

  Future<void> set(BearingMapOrientation orientation) async {
    state = AsyncData(orientation);
    await _prefs.setString(prefsKey, orientation.name);
  }
}

final bearingMapOrientationProvider =
    AsyncNotifierProvider.autoDispose<
      BearingMapOrientationSetting,
      BearingMapOrientation
    >(BearingMapOrientationSetting.new, name: 'bearingMapOrientationProvider');

/// **Today's earlier bearings on one collar** — what *Take on map* draws
/// faintly under the sweep (task 11.315).
///
/// Exactly this, and nothing else, decides it:
///
/// - **Same tag means the same `tag_id`** — the collar the Record screen's
///   wheel has selected. Not the same animal: the question on a trail is
///   where *this transmitter's* lines cross, and the collar is what the
///   receiver is tuned to. Bearings from every member of the project count,
///   not only this phone's, because a teammate's bearing on the same collar
///   crosses the same way.
/// - **Today means the device's local calendar date**, read from each
///   bearing's UTC timestamp converted to this device's zone — never from
///   `timestamp_local`, which is the wall clock *of whoever took it* and can
///   be a different zone's day.
/// - **A bearing is a directional record with a true-north bearing.** A note,
///   an omnidirectional detection or a no-signal sweep has no line to draw.
/// - **Deleted records are not here**; the repository leaves them out.
///
/// Every bearing it returns is drawn from its own stored true-north value,
/// the way the Map tab draws it — no second conversion.
List<Observation> earlierBearingsToday(
  Iterable<Observation> observations, {
  required String tagId,
  required DateTime now,
}) {
  final today = now.toLocal();
  bool isToday(DateTime utc) {
    final local = utc.toLocal();
    return local.year == today.year &&
        local.month == today.month &&
        local.day == today.day;
  }

  return [
    for (final o in observations)
      if (o.tagId == tagId &&
          o.observationType == ObservationType.directional &&
          o.trueNorthBearing != null &&
          !o.sync.isDeleted &&
          isToday(o.timestampUtc))
        o,
  ];
}

/// [earlierBearingsToday] over the project's stored bearings on [tagId],
/// refreshed whenever a record is saved, edited or arrives by sync (the same
/// revision counter the Map tab watches).
final todaysBearingsOnTagProvider = FutureProvider.autoDispose
    .family<List<Observation>, ({String projectId, String tagId})>((
      ref,
      key,
    ) async {
      ref.watch(recordingsRevisionProvider);
      final repo = await ref.watch(observationRepositoryProvider.future);
      final rows = await repo.findByProjectAndTag(key.projectId, key.tagId);
      return earlierBearingsToday(rows, tagId: key.tagId, now: DateTime.now());
    }, name: 'todaysBearingsOnTagProvider');
