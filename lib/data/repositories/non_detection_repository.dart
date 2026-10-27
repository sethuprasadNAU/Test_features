import '../db/schema.dart';
import '../models/non_detection.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class NonDetectionRepository extends BaseRepository {
  NonDetectionRepository(super.db)
    : super(
        table: Tables.nonDetections,
        pk: const ['non_detection_id', 'project_id'],
        rule: MutationRule.author,
      );

  Future<void> insert(NonDetection nonDetection) =>
      insertRow(nonDetection.toColumns());

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<NonDetection?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'non_detection_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : NonDetection.fromRow(row);
  }

  Future<List<NonDetection>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc DESC',
    );
    return rows.map(NonDetection.fromRow).toList();
  }

  Future<int> update(
    NonDetection nonDetection, {
    required MutationActor actor,
    String? deviceId,
  }) => updateByKey(
    {
      'non_detection_id': nonDetection.nonDetectionId,
      'project_id': nonDetection.projectId,
    },
    nonDetection.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );

  /// Tombstones [nonDetection]. Takes the model rather than an id for the
  /// same reason as [ObservationRepository.softDelete] — the key is
  /// `(non_detection_id, project_id)` and the model already carries both.
  Future<int> softDelete(
    NonDetection nonDetection, {
    required MutationActor actor,
    String? deviceId,
  }) => softDeleteByKey(
    {
      'non_detection_id': nonDetection.nonDetectionId,
      'project_id': nonDetection.projectId,
    },
    actor: actor,
    deviceId: deviceId,
  );

  /// Undo of [softDelete].
  Future<int> restore(
    NonDetection nonDetection, {
    required MutationActor actor,
    String? deviceId,
  }) => restoreByKey(
    {
      'non_detection_id': nonDetection.nonDetectionId,
      'project_id': nonDetection.projectId,
    },
    actor: actor,
    deviceId: deviceId,
  );
}
