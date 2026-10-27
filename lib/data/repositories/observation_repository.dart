import '../db/schema.dart';
import '../models/observation.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class ObservationRepository extends BaseRepository {
  ObservationRepository(super.db)
    : super(
        table: Tables.observations,
        pk: const ['observation_id', 'project_id'],
        rule: MutationRule.author,
      );

  Future<void> insert(Observation observation) =>
      insertRow(observation.toColumns());

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<Observation?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'observation_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : Observation.fromRow(row);
  }

  Future<List<Observation>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc DESC',
    );
    return rows.map(Observation.fromRow).toList();
  }

  /// All observations for one tag in a project, oldest first — the input set
  /// for the Position Estimation flow (which is strictly tag-scoped so
  /// bearings from different tags are never mixed).
  Future<List<Observation>> findByProjectAndTag(
    String projectId,
    String tagId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ? AND tag_id = ?',
      whereArgs: [projectId, tagId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc',
    );
    return rows.map(Observation.fromRow).toList();
  }

  /// Observations belonging to one triangulation session.
  ///
  /// [projectId] is required for the same reason it is on [findById]: since
  /// task 10.35 a `session_id` identifies a session only within its project,
  /// so matching on it alone could pull in another project's observations.
  ///
  /// **Nothing calls this, and since task 11.197 nothing writes a session
  /// either.** Michael, 2026-09-07: *"I don't think this is needed since we
  /// would select bearings from the list in the position menu."* Position
  /// estimation groups bearings by tag and time; it has never grouped by
  /// session. The Record screen's *Attach to triangulation session* checkbox
  /// was the only thing that ever created a `Triangulation_Sessions` row, and
  /// it is gone — so that table is **write-nothing**: it keeps every row any
  /// device has already made, syncs them, and will not gain another.
  ///
  /// **The column and the table stay.** `Observations.session_id` still holds
  /// whatever was written to it, and a column holding real data is not
  /// dropped to tidy a screen. This method is kept for the same reason: it is
  /// the only way to read that data back if anybody ever wants to.
  Future<List<Observation>> findBySession(
    String sessionId, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'session_id = ? AND project_id = ?',
      whereArgs: [sessionId, projectId],
      includeDeleted: includeDeleted,
      orderBy: 'timestamp_utc',
    );
    return rows.map(Observation.fromRow).toList();
  }

  Future<int> update(
    Observation observation, {
    required MutationActor actor,
    String? deviceId,
  }) => updateByKey(
    {
      'observation_id': observation.observationId,
      'project_id': observation.projectId,
    },
    observation.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );

  /// Tombstones [observation]. Takes the model rather than an id because the
  /// key is `(observation_id, project_id)` and the model already carries both
  /// — which makes a mismatched pair unrepresentable at the call site.
  Future<int> softDelete(
    Observation observation, {
    required MutationActor actor,
    String? deviceId,
  }) => softDeleteByKey(
    {
      'observation_id': observation.observationId,
      'project_id': observation.projectId,
    },
    actor: actor,
    deviceId: deviceId,
  );

  /// Undo of [softDelete].
  Future<int> restore(
    Observation observation, {
    required MutationActor actor,
    String? deviceId,
  }) => restoreByKey(
    {
      'observation_id': observation.observationId,
      'project_id': observation.projectId,
    },
    actor: actor,
    deviceId: deviceId,
  );
}
