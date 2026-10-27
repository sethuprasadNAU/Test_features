import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'actual_tag_location.freezed.dart';

/// A ground-truthed tag location (e.g. found by walking in), with an
/// [uncertaintyRadius] in meters. Useful for validating estimates against
/// reality.
///
/// **This is the yardstick, not another measurement.** A truth point is
/// deliberately not an `Observation`, so no position-estimate query has to
/// remember to exclude it — see `RecordType.groundTruth` and
/// `test/data/analysis/ground_truth_not_in_solver_test.dart`.
@freezed
abstract class ActualTagLocation with _$ActualTagLocation {
  const ActualTagLocation._();

  const factory ActualTagLocation({
    required String locationId,
    required String projectId,
    required String tagId,
    required DateTime timestampLocal,
    required DateTime timestampUtc,
    required String timezoneOffset,
    required double latitude,
    required double longitude,
    required double uncertaintyRadius,
    String? notes,

    /// Whether the animal, the collar, or both were found here (task 11.33).
    ///
    /// Null only on a row written before schema v10, where it reads as "not
    /// recorded" — every point this app writes sets it. Anything computing
    /// accuracy statistics must read it: only [GroundTruthKind.animalAndCollar]
    /// validates the triangulation of a live collared animal.
    GroundTruthKind? foundKind,

    /// The `Tag_Versions` row the tag read when this point was taken — what the
    /// receiver was tuned to and what the collar was called at the time (task
    /// 11.32's rule, applied here by task 11.33).
    ///
    /// Null is an ordinary answer: a tag with no version history yet, or a row
    /// written before schema v10. Editing the tag afterwards cannot change it,
    /// which is what lets an export made after a rename still be matched to the
    /// animal it describes.
    String? tagVersionId,

    /// **Who walked in and found it** (task 11.93).
    ///
    /// Null only on a row written before schema v11, where it reads as "not
    /// recorded" — every point this app writes sets it to the person who
    /// saved it. It is deliberately not [SyncMeta.lastModifiedBy], which names
    /// whoever last *touched* the row: a colleague who corrects the precision
    /// figure has not become the person who found the collar.
    ///
    /// **A fact about the record, not a permission.** Any contributor may
    /// still edit or delete the point — `truthPointEditVerdict` does not read
    /// this column and must not start to. Michael settled that on 2026-08-31:
    /// the person who saw the pride and the person driving the truck may not
    /// be the same person.
    String? userId,

    /// How the coordinate was got: a GPS fix, a hand-placed pin, or a fix
    /// somebody later nudged by hand (task 11.93).
    ///
    /// Null only on a row written before schema v11, where it reads as "not
    /// recorded". [PositionSource.gpsFixAdjusted] exists because the position
    /// became editable in the same task: a point that began as a measurement
    /// and was moved by hand is neither of the other two, and the precision
    /// radius alone cannot say which it is.
    PositionSource? positionSource,
    required SyncMeta sync,
  }) = _ActualTagLocation;

  factory ActualTagLocation.fromRow(Map<String, Object?> row) =>
      ActualTagLocation(
        locationId: row['location_id'] as String,
        projectId: row['project_id'] as String,
        tagId: row['tag_id'] as String,
        timestampLocal: DbCodec.decodeLocal(row['timestamp_local']),
        timestampUtc: DbCodec.decodeUtc(row['timestamp_utc']),
        timezoneOffset: row['timezone_offset'] as String,
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
        uncertaintyRadius: row['uncertainty_radius'] as double,
        notes: row['notes'] as String?,
        foundKind: row['found_kind'] == null
            ? null
            : GroundTruthKind.fromDb(row['found_kind'] as String),
        tagVersionId: row['tag_version_id'] as String?,
        userId: row['user_id'] as String?,
        positionSource: row['position_source'] == null
            ? null
            : PositionSource.fromDb(row['position_source'] as String),
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'location_id': locationId,
        'project_id': projectId,
        'tag_id': tagId,
        'timestamp_local': DbCodec.encodeLocal(timestampLocal),
        'timestamp_utc': DbCodec.encodeUtc(timestampUtc),
        'timezone_offset': timezoneOffset,
        'latitude': latitude,
        'longitude': longitude,
        'uncertainty_radius': uncertaintyRadius,
        'notes': notes,
        'found_kind': foundKind?.db,
        'tag_version_id': tagVersionId,
        'user_id': userId,
        'position_source': positionSource?.db,
        ...sync.toColumns(),
      };
}
