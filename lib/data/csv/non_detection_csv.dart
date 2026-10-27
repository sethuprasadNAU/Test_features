import 'csv_writer.dart';

import '../models/non_detection.dart';
import '../models/tag.dart';
import '../models/user.dart';

/// CSV export of non-detections (multi-tag "no signal" records) — the
/// negative-evidence counterpart to [ObservationCsv]. Mirrors its structure:
/// a pure formatter, tag/observer names resolved alongside raw ids so the
/// CSV is directly useful without a join, falling back to the id when a
/// tag/user is absent from the lookup maps.
///
/// Since a single non-detection can list multiple tags in
/// [NonDetection.tagIdsListenedFor], the tag columns are semicolon-joined
/// lists rather than a single tag per row.
abstract final class NonDetectionCsv {
  static const _header = [
    'non_detection_id',
    'observer_name',
    'timestamp_local',
    'timestamp_utc',
    'timezone_offset',
    'latitude',
    'longitude',
    'position_accuracy_m',
    'position_source',
    'elevation',
    // **Back since task 11.67** — see `ObservationCsv` for the history. The
    // receiver's height above ground in metres, as set on the Record screen;
    // `0` is on the ground, which is what every no-signal sweep on foot says.
    // It is the same value the flight's bearings carry, so a flight's
    // no-signal records do not claim ground level while its detections do
    // not.
    'altitude_agl_m',
    'tag_count',
    'tag_frequencies_mhz',
    'tag_names',
    'notes',
  ];

  static String export(
    List<NonDetection> records, {
    required Map<String, Tag> tagsById,
    required Map<String, User> usersById,
  }) {
    final rows = <List<dynamic>>[_header];
    for (final r in records) {
      final user = usersById[r.userId];
      final tags = r.tagIdsListenedFor.map((id) => tagsById[id]).toList();
      final frequencies = [
        for (var i = 0; i < tags.length; i++)
          tags[i]?.frequencyMhz.toString() ?? r.tagIdsListenedFor[i],
      ].join(';');
      final names = [
        for (var i = 0; i < tags.length; i++) tags[i]?.tagName ?? r.tagIdsListenedFor[i],
      ].join(';');
      rows.add([
        r.nonDetectionId,
        user == null ? r.userId : '${user.firstName} ${user.lastName}',
        r.timestampLocal.toIso8601String(),
        r.timestampUtc.toIso8601String(),
        r.timezoneOffset,
        r.latitude,
        r.longitude,
        r.positionAccuracyM,
        r.positionSource.db,
        r.elevation,
        r.altitudeAgl,
        r.tagIdsListenedFor.length,
        frequencies,
        names,
        r.notes,
      ]);
    }
    return SpreadsheetSafeCsv.encode(rows);
  }
}
