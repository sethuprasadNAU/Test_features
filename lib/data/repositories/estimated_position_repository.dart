import '../db/schema.dart';
import '../models/estimated_position.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class EstimatedPositionRepository extends BaseRepository {
  EstimatedPositionRepository(super.db)
    : super(
        table: Tables.estimatedPositions,
        pk: const ['position_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  Future<void> insert(EstimatedPosition position) =>
      insertRow(position.toColumns());

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<EstimatedPosition?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'position_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : EstimatedPosition.fromRow(row);
  }

  /// All estimates for a project (any tag) — the Main Map's project-wide
  /// layer, as opposed to [findByProjectAndTag]'s tag-scoped Position
  /// Estimation flow.
  Future<List<EstimatedPosition>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc DESC',
    );
    return rows.map(EstimatedPosition.fromRow).toList();
  }

  Future<List<EstimatedPosition>> findByProjectAndTag(
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
    return rows.map(EstimatedPosition.fromRow).toList();
  }

  Future<int> update(
    EstimatedPosition position, {
    required MutationActor actor,
    String? deviceId,
  }) => updateByKey(
    {'position_id': position.positionId, 'project_id': position.projectId},
    position.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );

  /// Tombstones [position]. Takes the model rather than an id — see
  /// `ObservationRepository.softDelete` for why.
  Future<int> softDelete(
    EstimatedPosition position, {
    required MutationActor actor,
    String? deviceId,
  }) => softDeleteByKey(
    {'position_id': position.positionId, 'project_id': position.projectId},
    actor: actor,
    deviceId: deviceId,
  );

  /// Undo of [softDelete].
  Future<int> restore(
    EstimatedPosition position, {
    required MutationActor actor,
    String? deviceId,
  }) => restoreByKey(
    {'position_id': position.positionId, 'project_id': position.projectId},
    actor: actor,
    deviceId: deviceId,
  );
}
