import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

import 'project_standing.dart';

export 'project_standing.dart';

/// The role [userId] currently holds in [projectId], read from **this device's
/// own** `Projects` and `Project_Memberships` rows.
///
/// Extracted from `BaseRepository.projectRoleFor` by task 11.19, which needed
/// the same answer somewhere a repository does not reach:
/// `SharedObservationImporter` writes raw statements inside its own
/// transaction, so it has a [DatabaseExecutor] and no repository instance, and
/// building a repository purely to borrow one method would have been a second
/// place this query lives. The provider layer already states the property this
/// protects — *"a screen asking 'may I offer this control' and a repository
/// asking 'may this write proceed' must get the same answer from the same
/// membership rows"* ([projectRoleForUser]'s note) — and the importer is a
/// third asker of the same question. There is one implementation of it.
///
/// Returns null when no role is held — **and since task 11.237 that null is
/// two different answers**, which [readProjectStanding] tells apart: *this
/// device cannot say* (no such project here, or a `role` string this build
/// does not recognise) and *this device can say, and the person is not on the
/// project*. Callers that permit on null — `ProjectMerger`'s restore gate,
/// [UntrustedImportRules.receiverMayImport] — are the ones for which the two
/// really are the same answer; a write gate is not one of them, and reads the
/// standing instead.
Future<ProjectRole?> readProjectRole(
  DatabaseExecutor db, {
  required String projectId,
  required String? userId,
}) async =>
    (await readProjectStanding(db, projectId: projectId, userId: userId)).role;

/// [readProjectRole] with the `null` split in two (task 11.237): the standing
/// [userId] holds in [projectId], read from **this device's own** `Projects`
/// and `Project_Memberships` rows.
///
/// **[ProjectStanding.unknown]** wherever the device has nothing to answer
/// with — no signed-in user, no `Projects` row here (including the moment a
/// project is being created), or a membership row naming this person whose
/// `role` this build does not recognise. Every caller reads it as *defer to the
/// server*, which is the permissive direction and the right one for an
/// advisory check standing in front of an authoritative one.
///
/// **[ProjectStanding.notAMember]** where the device *can* answer and the
/// answer is no: the project's row is here, and after the same resolution
/// `resolveProjectRole` does for the server — open rows only, creator fallback
/// included — nothing names this person. That is a colleague's archive
/// imported by somebody who is not on the team, or a member who has since
/// left; both are read-only here until a real membership arrives.
///
/// **Derived per read, never stored.** See [ProjectStanding] for why.
Future<ProjectStanding> readProjectStanding(
  DatabaseExecutor db, {
  required String projectId,
  required String? userId,
}) async {
  if (userId == null || userId.isEmpty) return ProjectStanding.unknown;
  final projectRows = await db.query(
    Tables.projects,
    columns: ['owner_user_id'],
    where: 'project_id = ?',
    whereArgs: [projectId],
    limit: 1,
  );
  if (projectRows.isEmpty) return ProjectStanding.unknown;
  final memberships = await db.query(
    Tables.projectMemberships,
    columns: ['user_id', 'role', 'end_date', 'deleted_at'],
    where: 'project_id = ?',
    whereArgs: [projectId],
  );
  final role = resolveProjectRole(
    membershipRows: memberships,
    creatorUserId: governingUserId(
      projectRows.first,
      'owner_user_id',
      table: Tables.projects,
    ),
    userId: userId,
  );
  if (role != null) return ProjectStanding.member(role);
  // `resolveProjectRole` answers null both for "no open row names them" and
  // for "an open row names them with a role this build cannot read". Only the
  // first is a snapshot; the second is a build behind its server, and the
  // server is the one to refuse it.
  final namedByAnOpenRow = memberships.any(
    (row) =>
        row['user_id'] == userId &&
        row['end_date'] == null &&
        row['deleted_at'] == null,
  );
  return namedByAnOpenRow ? ProjectStanding.unknown : ProjectStanding.notAMember;
}

/// [row]'s [column] as a user id, or null if the column is null.
///
/// **Throws [StateError] on any other type rather than reading it as null**,
/// and that is the point of the function: every caller is deciding a permission
/// off this value, and a value the code cannot interpret must not be allowed to
/// resolve to the permissive answer by accident. A non-string here means the
/// row is malformed, not that nobody owns it.
///
/// Lives beside [readProjectRole] rather than on `BaseRepository` (where task
/// 8.1 wrote it) because task 11.19 needed the same guard off a bare
/// [DatabaseExecutor]; `BaseRepository._governingValue` delegates here so there
/// is one answer.
String? governingUserId(
  Map<String, Object?> row,
  String column, {
  required String table,
}) {
  final value = row[column];
  if (value == null) return null;
  if (value is String) return value;
  throw StateError(
    'Malformed governing column: $table.$column holds a '
    '${value.runtimeType}, not a String or null. Refusing to guess '
    'whether this row is owned by the acting user.',
  );
}
