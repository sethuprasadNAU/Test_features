/// Which global rows one project may see (tasks 10.10, 10.20).
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';

/// The global-table rows one project may see, by id.
///
/// **It held tags as well until task 11.219.** Copy-on-add made `Tags` and
/// `Tag_Versions` project-scoped, so pull narrows them with
/// `WHERE project_id = ?` like the other nine tables and there is nothing to
/// reach for. What is left is people.
class ProjectReachability {
  const ProjectReachability({required this.users});

  final Set<String> users;

  /// The `Users` ids a project's rows actually reference.
  ///
  /// ## Why this exists
  ///
  /// `Users`, `User_Emails` and `Tags` have no `project_id` — they are global
  /// tables, collected by *reachability* rather than by scope (see
  /// [SyncTable.projectScopeColumn]). Before task 10.10, pull filtered them by
  /// `server_seq > cursor` and nothing else, which meant **a pull for any one
  /// project returned every user row on the server**: every registered
  /// person's name, and through `User_Emails`, their full address history.
  /// Any authenticated caller with one project of their own could read the
  /// server's entire user directory. That is squarely what "a sync request for
  /// project A returns no row belonging to project B" forbids, and it is the
  /// single largest hole task 10.10 closed.
  ///
  /// The rule applied here is the one the client already uses when it exports
  /// a project (`ProjectExporter.collect`): a project's reachable global rows
  /// are the tags its data references and the users its rows name — as author
  /// or owner — plus those users' address history. Reusing that definition
  /// rather than inventing a server-side one means a pulled project is exactly
  /// as self-contained as a backup of it, so the client merger receives no
  /// dangling foreign key.
  ///
  /// Reachability narrows *which* global rows may be delivered; the ordinary
  /// `server_seq > cursor` window still decides *when*. Global rows therefore
  /// stay part of the delta stream and page exactly as before, which matters:
  /// lifting them out of the cursor window — so that every page carried the
  /// project's whole reachable closure — makes a pull never return an empty
  /// page, and both this server's own paging test and the client's
  /// pull-until-exhausted loop spin forever on that.
  ///
  /// **This is also the read half of task 10.20's row-naming invariant.**
  /// [RowAuthorizer] asks the same question on the way *in* — "does this
  /// project already reach the person this row names?" — because a caller who
  /// may already see someone's global rows discloses nothing by naming them
  /// again. One implementation, because a write check and a read filter that
  /// disagreed about what a project reaches would be a hole shaped exactly
  /// like the one 10.10 closed.
  ///
  /// **Known gap, deliberately left for Phase 11.** A global row whose
  /// `server_seq` is below the caller's cursor but which only *becomes*
  /// reachable later is never delivered, which would surface client-side as a
  /// dangling foreign key. It needs another device to add a row referencing a
  /// user or tag this project had never referenced before, so it cannot arise
  /// in Phase 10 — one user's devices either already hold the row or are
  /// joining from cursor zero. Task 11.3 is where it becomes reachable; see
  /// the plan's Discovered Scope.
  static Future<ProjectReachability> resolve(
    Session session, {
    required String projectId,
  }) async {
    final users = <String>{};

    for (final table in syncTables) {
      final scope = table.projectScopeColumn;
      if (scope == null) continue;
      // `last_modified_by` is deliberately excluded — that is what
      // [SyncTable.identityUserColumns] means. It is an audit column the
      // client sets freely, it is a foreign key on neither side of the wire
      // (see `postgres_schema.dart`'s note), and it appears on *every* table —
      // so treating it as a reachability edge let a caller name any `user_id`
      // they liked in a row of their own project and have that person's
      // `Users` and `User_Emails` rows delivered on the next pull. Dropping it
      // cannot dangle a foreign key, because nothing references it.
      // Both column sets come from `reachColumnsFor`, the shared declaration
      // the client's push selection now narrows by as well (task 11.41). They
      // used to be chosen inline here, which made this the only place that
      // knew what a project reaches — so the client offered every global row
      // it held to every project, and every one the server would not take
      // became a permanently held record.
      final columns = reachColumnsFor(table, GlobalReachSet.users);
      if (columns.isEmpty) continue;
      // Column names come from the const `syncTables` descriptors, never from
      // a request; the project id is bound.
      final selected = columns.join(', ');
      final result = await session.execute(
        'SELECT $selected FROM ${quoted(table.name)} WHERE $scope = \$1',
        parameters: [projectId],
      );
      for (final row in result) {
        final map = row.toColumnMap();
        for (final column in columns) {
          final value = map[column];
          if (value is String && value.isNotEmpty) users.add(value);
        }
      }
    }

    return ProjectReachability(users: users);
  }
}
