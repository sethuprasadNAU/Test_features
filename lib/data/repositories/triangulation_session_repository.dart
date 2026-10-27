import '../db/schema.dart';
import '../models/triangulation_session.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// **A write-nothing table since task 11.197.**
///
/// The Record screen's *Attach to triangulation session* checkbox was the
/// only thing in the app that ever inserted a row here, and Michael had it
/// removed on 2026-09-07: *"I don't think this is needed since we would
/// select bearings from the list in the position menu."* He was right and it
/// was checkable — `ObservationRepository.findBySession` had no callers, so a
/// person who ticked that box got a row written here and an id stamped onto
/// their observation, and nothing ever read either one back.
///
/// **The rows that exist are kept and still sync.** This class is not dead
/// code: it is what reads and merges them. It simply has no caller that
/// inserts, and that is deliberate rather than an oversight — if a future
/// feature means sessions, it adds the writer back.
class TriangulationSessionRepository extends BaseRepository {
  TriangulationSessionRepository(super.db)
    : super(
        table: Tables.triangulationSessions,
        pk: const ['session_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  Future<void> insert(TriangulationSession session) =>
      insertRow(session.toColumns());

  /// A row is identified by its id *within a project* since task 10.35 — the
  /// same id may legitimately exist in another project, so [projectId] is not
  /// a filter but half the key.
  Future<TriangulationSession?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final row = await findRowByKey({
      'session_id': id,
      'project_id': projectId,
    }, includeDeleted: includeDeleted);
    return row == null ? null : TriangulationSession.fromRow(row);
  }

  Future<List<TriangulationSession>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await findRows(
      where: 'project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 'started_at_utc DESC',
    );
    return rows.map(TriangulationSession.fromRow).toList();
  }

  Future<int> update(
    TriangulationSession session, {
    required MutationActor actor,
    String? deviceId,
  }) => updateByKey(
    {'session_id': session.sessionId, 'project_id': session.projectId},
    session.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );
}
