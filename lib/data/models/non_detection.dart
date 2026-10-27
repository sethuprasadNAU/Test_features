import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'non_detection.freezed.dart';

/// A "listened and heard nothing" record for a set of tags at a position/time.
/// Valuable negative evidence for occupancy modeling. [tagIdsListenedFor] is
/// stored as a JSON array of tag ids.
@freezed
abstract class NonDetection with _$NonDetection {
  const NonDetection._();

  const factory NonDetection({
    required String nonDetectionId,
    required String projectId,
    required String userId,
    required DateTime timestampLocal,
    required DateTime timestampUtc,
    required String timezoneOffset,
    required double latitude,
    required double longitude,
    double? positionAccuracyM,
    required PositionSource positionSource,
    required double elevation,
    @Default(0) double altitudeAgl,
    required List<String> tagIdsListenedFor,
    String? notes,
    required SyncMeta sync,
  }) = _NonDetection;

  factory NonDetection.fromRow(Map<String, Object?> row) => NonDetection(
        nonDetectionId: row['non_detection_id'] as String,
        projectId: row['project_id'] as String,
        userId: row['user_id'] as String,
        timestampLocal: DbCodec.decodeLocal(row['timestamp_local']),
        timestampUtc: DbCodec.decodeUtc(row['timestamp_utc']),
        timezoneOffset: row['timezone_offset'] as String,
        latitude: row['latitude'] as double,
        longitude: row['longitude'] as double,
        positionAccuracyM: row['position_accuracy_m'] as double?,
        positionSource: PositionSource.fromDb(row['position_source'] as String),
        elevation: row['elevation'] as double,
        altitudeAgl: (row['altitude_agl'] as num?)?.toDouble() ?? 0,
        tagIdsListenedFor:
            DbCodec.decodeStringList(row['tag_ids_listened_for']),
        notes: row['notes'] as String?,
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'non_detection_id': nonDetectionId,
        'project_id': projectId,
        'user_id': userId,
        'timestamp_local': DbCodec.encodeLocal(timestampLocal),
        'timestamp_utc': DbCodec.encodeUtc(timestampUtc),
        'timezone_offset': timezoneOffset,
        'latitude': latitude,
        'longitude': longitude,
        'position_accuracy_m': positionAccuracyM,
        'position_source': positionSource.db,
        'elevation': elevation,
        'altitude_agl': altitudeAgl,
        'tag_ids_listened_for': DbCodec.encodeStringList(tagIdsListenedFor),
        'notes': notes,
        ...sync.toColumns(),
      };
}
