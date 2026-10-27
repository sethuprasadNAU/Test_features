import '../db/schema.dart';
import '../models/actual_tag_location.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class ActualTagLocationRepository extends BaseRepository {
  ActualTagLocationRepository(super.db)
    : super(
        table: Tables.actualTagLocations,
        pk: const ['location_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  Future<void> insert(ActualTagLocation location) =>
      insertRow(location.toColumns());

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<ActualTagLocation?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'location_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : ActualTagLocation.fromRow(row);
  }

  /// All ground-truthed locations for a project (any tag) — the Main Map's
  /// project-wide layer.
  Future<List<ActualTagLocation>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc DESC',
    );
    return rows.map(ActualTagLocation.fromRow).toList();
  }

  Future<List<ActualTagLocation>> findByProjectAndTag(
    String projectId,
    String tagId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ? AND tag_id = ?',
      whereArgs: [projectId, tagId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc DESC',
    );
    return rows.map(ActualTagLocation.fromRow).toList();
  }

  Future<int> update(
    ActualTagLocation location, {
    required MutationActor actor,
    String? deviceId,
  }) => updateByKey(
    {'location_id': location.locationId, 'project_id': location.projectId},
    location.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );

  /// Tombstones a truth point. **Soft, like every other delete in this app** —
  /// the row stays with `is_deleted = 1` and a bumped revision, so the delete
  /// merges rather than resurrecting on the next sync, and [restore] can undo
  /// it from the snackbar the screens show.
  Future<int> softDelete(
    ActualTagLocation location, {
    required MutationActor actor,
    String? deviceId,
  }) => softDeleteByKey(
    {'location_id': location.locationId, 'project_id': location.projectId},
    actor: actor,
    deviceId: deviceId,
  );

  /// Undo of [softDelete].
  Future<int> restore(
    ActualTagLocation location, {
    required MutationActor actor,
    String? deviceId,
  }) => restoreByKey(
    {'location_id': location.locationId, 'project_id': location.projectId},
    actor: actor,
    deviceId: deviceId,
  );
}
