import 'csv_writer.dart';

import '../models/observation.dart';
import '../models/tag.dart';
import '../models/tag_version.dart';
import '../models/user.dart';

/// CSV export of observations (design doc §11: "Export CSV: all observation
/// fields, filterable by tag or date range"). Filtering by tag/date range is
/// the caller's job — pass an already-filtered [observations] list — this
/// module is a pure formatter, matching how [ProjectExporter] stays a pure
/// collector.
///
/// Tag/observer names are resolved alongside the raw ids so the CSV is
/// directly useful in a spreadsheet without a join; a tag/user absent from
/// the lookup maps (should not happen for a project's own data, but is
/// possible for a hand-edited export) falls back to just the id.
///
/// ## What the tag columns mean, since this is where it is most visible
///
/// **`tag_name` and `tag_frequency_mhz` are what the bearing was recorded
/// against, not what the tag reads today** (task 11.32). A spreadsheet made
/// this morning and one made after somebody renames or re-tunes the tag agree
/// about the same bearing, which is the whole point — before this, every
/// exported row silently adopted the tag's current values, so an export could
/// not be matched against an earlier one or against a field notebook.
///
/// The two `tag_current_*` columns beside them carry today's values, so the
/// spreadsheet can show drift rather than hide it. They are separate columns
/// rather than a reconciliation: **a tag reading 148.520 for six weeks and
/// 148.535 afterwards is a drift record**, and collapsing the two into one
/// number is exactly what this task exists to stop.
///
/// `tag_values_recorded` says whether the bearing knows. Rows recorded before
/// schema v9, pasted from a share payload, or whose version row has not reached
/// this device read **`no`**, and their `tag_name`/`tag_frequency_mhz` cells
/// are **empty** rather than filled in from the tag row. An empty cell is the
/// honest answer; a filled one would be a measurement nobody took.
///
/// `color_hex` is deliberately absent from this export and always was. It is a
/// display key, not a measurement — see `tagColumnKinds`.
abstract final class ObservationCsv {
  static const _header = [
    'observation_id',
    // As recorded — see the class doc.
    'tag_name',
    'tag_frequency_mhz',
    'tag_pulse_rate',
    // Whether the two above are known at all: `yes` or `no`, never blank.
    'tag_values_recorded',
    // What the tag reads now, so drift is visible instead of invisible.
    'tag_current_name',
    'tag_current_frequency_mhz',
    'observer_name',
    'timestamp_local',
    'timestamp_utc',
    'timezone_offset',
    'latitude',
    'longitude',
    'elevation_m',
    // **Back since task 11.67, which made it settable.** Task 11.30 took it
    // out because nothing in the app could set it and every row said `0`,
    // which a person post-processing the file in R would read as a measured
    // height. It is now the receiver's height above ground as set on the
    // Record screen — non-zero for a receiver in an aircraft, and `0`
    // everywhere else, **which is still what every record on foot says and
    // has always said.** A zero here means "on the ground", not "not
    // recorded"; there is no separate aerial flag, by Michael's decision
    // (*"altitude should say it all"*). Metres, like `elevation_m`.
    'altitude_agl_m',
    'position_source',
    'position_accuracy_m',
    'observation_type',
    'magnetic_bearing',
    'true_north_bearing',
    'bearing_uncertainty',
    'bearing_capture_method',
    'bearing_method',
    'magnetic_declination',
    'wmm_model_version',
    'antenna_type',
    'receiver_gain',
    // Task 11.187. `pulse_mode` is the slot the bearing was heard on;
    // `pulse_mode_name` is what that mode was **called at the time**, read off
    // the tag version like every other recorded value and left **empty** when
    // this device has no version row rather than filled in from today's tag.
    //
    // `signal_type` stays, unchanged, because a column that has been in every
    // export since v1 should not vanish from somebody's analysis script — and
    // because it is still the mode of every row recorded before schema v12.
    // It is the two-valued projection of `pulse_mode`; where the two seem to
    // disagree, `pulse_mode` is the one that knows. See `SignalType`.
    'pulse_mode',
    'pulse_mode_name',
    'signal_type',
    'signal_strength',
    // Task 11.193. **`yes`, `no`, or empty, and empty is not `no`.** Empty
    // means nobody was asked — a bearing recorded before the control existed,
    // or a record type with no signal in it — and a person analysing a season
    // for failing collars must be able to tell that apart from an observer who
    // listened and heard nothing wrong. Exporting an empty cell as `no` is the
    // same falsehood `altitude_agl` was left out over until task 11.67.
    'signal_irregular',
    'bearing_quality',
    'notes',
  ];

  /// [recordedStates] maps `observation_id` to what that bearing was recorded
  /// against — build it with `TagVersionRepository.recordedStatesFor`. An
  /// observation missing from the map exports its recorded tag columns empty
  /// and `tag_values_recorded` as `no`, which is the same answer as a bearing
  /// that genuinely has no version: **the export never falls back to the tag's
  /// current values**, because a caller who forgot to pass this would otherwise
  /// silently reintroduce the entire defect.
  static String export(
    List<Observation> observations, {
    required Map<String, Tag> tagsById,
    required Map<String, User> usersById,
    Map<String, RecordedTagState> recordedStates = const {},
  }) {
    final rows = <List<dynamic>>[_header];
    for (final o in observations) {
      final tag = tagsById[o.tagId];
      final user = usersById[o.userId];
      final recorded = recordedStates[o.observationId];
      rows.add([
        o.observationId,
        recorded?.recordedTagName,
        recorded?.recordedFrequencyMhz,
        recorded?.recordedPulseRate,
        recorded?.isRecorded ?? false ? 'yes' : 'no',
        tag?.tagName ?? o.tagId,
        tag?.frequencyMhz,
        user == null ? o.userId : '${user.firstName} ${user.lastName}',
        o.timestampLocal.toIso8601String(),
        o.timestampUtc.toIso8601String(),
        o.timezoneOffset,
        o.latitude,
        o.longitude,
        o.elevation,
        o.altitudeAgl,
        o.positionSource.db,
        o.positionAccuracyM,
        o.observationType.db,
        o.magneticBearing,
        o.trueNorthBearing,
        o.bearingUncertainty,
        o.bearingCaptureMethod?.db,
        o.bearingMethod?.db,
        o.magneticDeclination,
        o.wmmModelVersion,
        o.antennaType,
        o.receiverGain,
        o.pulseModeSlot,
        recorded == null || !recorded.isRecorded
            ? null
            : recorded.recordedPulseModeName(
                storedSlot: o.pulseMode,
                legacy: o.signalType,
              ),
        o.signalType.db,
        o.signalStrength.db,
        switch (o.signalIrregular) {
          null => null,
          final bool flagged => flagged ? 'yes' : 'no',
        },
        o.bearingQuality?.db,
        o.notes,
      ]);
    }
    return SpreadsheetSafeCsv.encode(rows);
  }
}
