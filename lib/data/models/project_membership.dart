import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'project_membership.freezed.dart';

/// Links a user to a project with a role and active span.
///
/// Schema decision: the spec lists no primary key for this junction, but a
/// person can leave and rejoin (multiple `join_date`/`end_date` spans), so a
/// composite (project_id, user_id) key would not be unique over time. We add
/// a surrogate [membershipId] UUID PK to give each span a stable identity for
/// last-write-wins merge.
///
/// Lifecycle: membership records are "never deleted, only deactivated" — set
/// [endDate] (and/or role) rather than the soft-delete tombstone.
@freezed
abstract class ProjectMembership with _$ProjectMembership {
  const ProjectMembership._();

  const factory ProjectMembership({
    required String membershipId,
    required String projectId,
    required String userId,
    required DateTime joinDate,
    DateTime? endDate,
    required ProjectRole role,
    required SyncMeta sync,
  }) = _ProjectMembership;

  factory ProjectMembership.fromRow(Map<String, Object?> row) =>
      ProjectMembership(
        membershipId: row['membership_id'] as String,
        projectId: row['project_id'] as String,
        userId: row['user_id'] as String,
        joinDate: DbCodec.decodeUtc(row['join_date']),
        endDate: DbCodec.decodeUtcOrNull(row['end_date']),
        role: ProjectRole.fromDb(row['role'] as String),
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'membership_id': membershipId,
        'project_id': projectId,
        'user_id': userId,
        'join_date': DbCodec.encodeUtc(joinDate),
        'end_date': DbCodec.encodeUtcOrNull(endDate),
        'role': role.db,
        ...sync.toColumns(),
      };
}
