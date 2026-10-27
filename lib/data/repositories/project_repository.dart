import '../db/schema.dart';
import '../models/project.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class ProjectRepository extends BaseRepository {
  ProjectRepository(super.db)
    : super(
        table: Tables.projects,
        pk: const ['project_id'],
        rule: MutationRule.owner,
      );

  Future<void> insert(Project project) => insertRow(project.toColumns());

  Future<Project?> findById(String id, {bool includeDeleted = false}) async {
    final row = await findRowById(id, includeDeleted: includeDeleted);
    return row == null ? null : Project.fromRow(row);
  }

  Future<List<Project>> findAll({bool includeDeleted = false}) async {
    final rows = await findRows(
      includeDeleted: includeDeleted,
      orderBy: 'project_name',
    );
    return rows.map(Project.fromRow).toList();
  }

  Future<int> update(
    Project project, {
    required MutationActor actor,
    String? deviceId,
  }) => updateById(
    project.projectId,
    project.toColumns(),
    actor: actor,
    deviceId: deviceId,
  );
}
