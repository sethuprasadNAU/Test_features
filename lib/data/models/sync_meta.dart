import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

part 'sync_meta.freezed.dart';

/// The six global sync/merge fields carried by every table (technical doc,
/// "Global Data Conventions"). Composed into every model as `sync` so the
/// column set stays identical everywhere and merge logic has one shape to
/// reason about.
///
/// - [createdAt]/[updatedAt] are UTC; [deletedAt] is the soft-delete tombstone
///   (UTC, null = live).
/// - [revision] increments on every edit; combined with [updatedAt] it drives
///   last-write-wins conflict resolution on merge (Phase 6).
/// - [lastModifiedBy] is a `user_id` and [originDeviceId] a device id; both are
///   nullable and intentionally *not* foreign-keyed (a merge may carry a row
///   whose author/device row hasn't synced yet).
///
/// Repositories own mutation of these fields (revision bump, timestamp touch,
/// tombstone) at the SQL level — models never hand-edit them.
@freezed
abstract class SyncMeta with _$SyncMeta {
  const SyncMeta._();

  const factory SyncMeta({
    required DateTime createdAt,
    required DateTime updatedAt,
    DateTime? deletedAt,
    @Default(0) int revision,
    String? lastModifiedBy,
    String? originDeviceId,
  }) = _SyncMeta;

  /// Sync metadata for a brand-new record: created == updated, revision 0,
  /// not deleted.
  factory SyncMeta.initial({
    required DateTime now,
    String? modifiedBy,
    String? originDeviceId,
  }) {
    final utc = now.toUtc();
    return SyncMeta(
      createdAt: utc,
      updatedAt: utc,
      revision: 0,
      lastModifiedBy: modifiedBy,
      originDeviceId: originDeviceId,
    );
  }

  bool get isDeleted => deletedAt != null;

  factory SyncMeta.fromRow(Map<String, Object?> row) => SyncMeta(
        createdAt: DbCodec.decodeUtc(row['created_at']),
        updatedAt: DbCodec.decodeUtc(row['updated_at']),
        deletedAt: DbCodec.decodeUtcOrNull(row['deleted_at']),
        revision: row['revision'] as int,
        lastModifiedBy: row['last_modified_by'] as String?,
        originDeviceId: row['origin_device_id'] as String?,
      );

  Map<String, Object?> toColumns() => {
        'created_at': DbCodec.encodeUtc(createdAt),
        'updated_at': DbCodec.encodeUtc(updatedAt),
        'deleted_at': DbCodec.encodeUtcOrNull(deletedAt),
        'revision': revision,
        'last_modified_by': lastModifiedBy,
        'origin_device_id': originDeviceId,
      };
}
