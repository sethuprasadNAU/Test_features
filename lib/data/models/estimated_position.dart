import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'estimated_position.freezed.dart';

/// A computed tag-position estimate with its uncertainty ellipse, **or with
/// none**. Every contributing observation shares the same `tag_id` (enforced
/// by the tag-first Position Estimation flow). [observationIdsUsed] is stored
/// as a JSON array so an estimate can be recomputed/audited against its exact
/// inputs.
///
/// **No ellipse is three nulls** (task 11.323, schema v19): two bearings cross
/// exactly, so there is no scatter to measure. The fields stay `required` so
/// every writer has to say which it is; until v19 the app wrote 0 × 0 m, a
/// perfectly precise position that the sync rules then refused.
@freezed
abstract class EstimatedPosition with _$EstimatedPosition {
  const EstimatedPosition._();

  const factory EstimatedPosition({
    required String positionId,
    required String projectId,
    required String tagId,
    required DateTime timestampLocal,
    required DateTime timestampUtc,
    required String timezoneOffset,
    required double latitude,
    required double longitude,
    required double? semiMajorAxis,
    required double? semiMinorAxis,
    required double? rotationAngle,
    required EstimationMethod method,
    required List<String> observationIdsUsed,
    String? notes,
    required SyncMeta sync,
  }) = _EstimatedPosition;

  factory EstimatedPosition.fromRow(Map<String, Object?> row) =>
      EstimatedPosition(
        positionId: row['position_id'] as String,
        projectId: row['project_id'] as String,
        tagId: row['tag_id'] as String,
        timestampLocal: DbCodec.decodeLocal(row['timestamp_local']),
        timestampUtc: DbCodec.decodeUtc(row['timestamp_utc']),
        timezoneOffset: row['timezone_offset'] as String,
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
        semiMajorAxis: row['semi_major_axis'] as double?,
        semiMinorAxis: row['semi_minor_axis'] as double?,
        rotationAngle: row['rotation_angle'] as double?,
        method: EstimationMethod.fromDb(row['method'] as String),
        observationIdsUsed:
            DbCodec.decodeStringList(row['observation_ids_used']),
        notes: row['notes'] as String?,
        sync: SyncMeta.fromRow(row),
      );

  /// Whether this estimate has an ellipse at all — both axes measured.
  bool get hasEllipse => semiMajorAxis != null && semiMinorAxis != null;

  Map<String, Object?> toColumns() => {
        'position_id': positionId,
        'project_id': projectId,
        'tag_id': tagId,
        'timestamp_local': DbCodec.encodeLocal(timestampLocal),
        'timestamp_utc': DbCodec.encodeUtc(timestampUtc),
        'timezone_offset': timezoneOffset,
        'latitude': latitude,
        'longitude': longitude,
        'semi_major_axis': semiMajorAxis,
        'semi_minor_axis': semiMinorAxis,
        'rotation_angle': rotationAngle,
        'method': method.db,
        'observation_ids_used':
            DbCodec.encodeStringList(observationIdsUsed),
        'notes': notes,
        ...sync.toColumns(),
      };
}
