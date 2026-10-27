import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'triangulation_session.freezed.dart';

/// Groups observations intended as one near-simultaneous fix on a single
/// stationary tag. Makes the "these bearings belong together" intent explicit
/// and enables the temporal-spread warning (Lenth assumes one stationary
/// source).
///
/// Schema decision: the spec lists `started_at_local`/`started_at_utc` but no
/// offset. To honor the global "every recorded time stores local + utc +
/// offset" rule, we add [startedAtOffset] (column `started_at_offset`).
@freezed
abstract class TriangulationSession with _$TriangulationSession {
  const TriangulationSession._();

  const factory TriangulationSession({
    required String sessionId,
    required String projectId,
    required String tagId,
    String? label,
    required DateTime startedAtLocal,
    required DateTime startedAtUtc,
    required String startedAtOffset,
    String? notes,
    required SyncMeta sync,
  }) = _TriangulationSession;

  factory TriangulationSession.fromRow(Map<String, Object?> row) =>
      TriangulationSession(
        sessionId: row['session_id'] as String,
        projectId: row['project_id'] as String,
        tagId: row['tag_id'] as String,
        label: row['label'] as String?,
        startedAtLocal: DbCodec.decodeLocal(row['started_at_local']),
        startedAtUtc: DbCodec.decodeUtc(row['started_at_utc']),
        startedAtOffset: row['started_at_offset'] as String,
        notes: row['notes'] as String?,
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'session_id': sessionId,
        'project_id': projectId,
        'tag_id': tagId,
        'label': label,
        'started_at_local': DbCodec.encodeLocal(startedAtLocal),
        'started_at_utc': DbCodec.encodeUtc(startedAtUtc),
        'started_at_offset': startedAtOffset,
        'notes': notes,
        ...sync.toColumns(),
      };
}
