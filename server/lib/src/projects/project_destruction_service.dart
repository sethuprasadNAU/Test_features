/// Destroying a project on a schedule the server keeps (task 11.290).
///
/// See `project_destruction.dart` in the shared package for what this is for
/// and the design Michael specified. This file is the mechanism: the table
/// that holds a scheduled deletion, the write that destroys a project, and
/// the measurement that says whether the sweep is keeping up.
///
/// ## Three things this deliberately reuses rather than reinvents
///
/// - **The deletion order.** A project's rows live in the project-scoped
///   sync tables, and they reference each other with deferred foreign keys.
///   [TombstoneRetentionService.purgeableTables] already declares them
///   children-first for exactly this reason, so destruction walks that list
///   and adds the server's own per-project bookkeeping after it.
/// - **The resurrection guard.** A device that pushes rows for a project the
///   server no longer holds must be refused, not obeyed. The purge floor
///   already does that for a device behind a tombstone purge; this file's
///   [wasDestroyed] does it for a destroyed project, and `sync_routes.dart`
///   asks it before `ProjectAuthorizer`'s *absent* can be read as *publish*.
/// - **The scheduler's shape.** `bin/project_destruction.dart` is
///   `bin/audit_retention.dart` one table over: a compiled loop that decides
///   by the rows rather than by its own clock, and a `--check` that measures
///   what is still here past its date rather than whether the loop is up.
///
/// ## What "gone" reaches, stated once
///
/// Every row in every project-scoped sync table (`Projects` itself last),
/// the project's sync cursors, its purge floor, its join settings and join
/// requests, and any invitation rows from before task 11.81. **Not** the
/// audit log or the sync-traffic log — Michael, 2026-09-20: *the audit log is
/// out of scope of "gone"*; sign-in events keep a year and data-access rows
/// 180 days under §4.7, and both name the project id. Not `Users` or
/// `User_Emails`: they are people, not project data, and other projects
/// reach them. And not the `project_destruction` row itself, which is kept
/// with `executed_at` set so the id stays refused — see [wasDestroyed].
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart' show quoted;
import '../sync/tombstone_retention_service.dart';

/// A scheduled, or executed, destruction of one project.
///
/// **Server-only, like every table beside it, and for the same reason:** the
/// destroy date is the server's decision on the server's clock, and a column
/// on the synced `Projects` row would be one every device could write. No
/// foreign key to `Projects`, matching `project_join_settings`: the row has
/// to outlive the project it is about, because outliving it is its job.
const String createProjectDestruction = '''
CREATE TABLE IF NOT EXISTS project_destruction (
  project_id    TEXT PRIMARY KEY,
  scheduled_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  scheduled_by  TEXT NOT NULL,
  destroy_at    TIMESTAMPTZ NOT NULL,
  executed_at   TIMESTAMPTZ
)''';

List<String> projectDestructionStatements() => [createProjectDestruction];

/// How long a scheduled deletion waits before the server carries it out.
///
/// **Defaults to the backup retention window**, `TRITRACK_BACKUP_KEEP` (30
/// archives, one a day), because a shorter grace period would promise a
/// speed the backups do not deliver: a project "deleted" on day 3 is still in
/// 27 archives on disk. Overridable by `TRITRACK_PROJECT_DELETION_GRACE_DAYS`
/// for an institution whose rules differ, and every route and the sweep read
/// this one value so the number a person is shown is the number the server
/// applies.
class ProjectDeletionPolicy {
  const ProjectDeletionPolicy({
    required this.grace,
    this.backupRetentionDays = defaultGraceDays,
  });

  final Duration grace;

  /// `TRITRACK_BACKUP_KEEP`: how many daily archives the backup scheduler
  /// keeps, which is how long a destroyed project survives in a dump. Carried
  /// to the app so the *delete now* sentence names the real number.
  final int backupRetentionDays;

  int get graceDays => grace.inDays;

  static const int defaultGraceDays = 30;

  /// Reads the environment. A blank or unparseable value falls through to the
  /// next: the explicit grace, then the backup keep count, then 30.
  static ProjectDeletionPolicy fromEnvironment([
    Map<String, String>? environment,
  ]) {
    final env = environment ?? Platform.environment;
    final explicit = int.tryParse(
      env['TRITRACK_PROJECT_DELETION_GRACE_DAYS'] ?? '',
    );
    final fromBackups = int.tryParse(env['TRITRACK_BACKUP_KEEP'] ?? '');
    final keep = fromBackups != null && fromBackups > 0
        ? fromBackups
        : defaultGraceDays;
    final days = switch (explicit) {
      final int d when d >= 0 => d,
      _ => keep,
    };
    return ProjectDeletionPolicy(
      grace: Duration(days: days),
      backupRetentionDays: keep,
    );
  }
}

/// What one sweep did.
class ProjectDestructionSweep {
  const ProjectDestructionSweep({
    required this.destroyedProjectIds,
    required this.rowsDeleted,
  });

  final List<String> destroyedProjectIds;

  /// Rows deleted across every table, all projects — a count, so a test can
  /// assert the sweep did something rather than trust that it ran.
  final int rowsDeleted;

  int get projectsDestroyed => destroyedProjectIds.length;
}

/// The healthcheck's reading: how far past its date the most overdue
/// scheduled deletion is, or null when nothing is overdue.
///
/// **Measured from the rows, never from the loop.** A project whose
/// `destroy_at` is in the past and whose `executed_at` is null is a promise
/// the server has not kept, whatever the scheduler thinks it is doing.
class ProjectDestructionReading {
  const ProjectDestructionReading({
    required this.scheduled,
    required this.overdue,
    required this.mostOverdueBy,
  });

  /// Deletions waiting for their date.
  final int scheduled;

  /// Deletions whose date has passed and that are still here.
  final int overdue;

  /// How long past its date the most overdue one is; null when [overdue] is
  /// zero.
  final Duration? mostOverdueBy;
}

class ProjectDestructionService {
  ProjectDestructionService(
    this.session, {
    required this.policy,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Session session;
  final ProjectDeletionPolicy policy;
  final DateTime Function() _clock;

  DateTime get _now => _clock().toUtc();

  /// Where [projectId]'s deletion stands. Unscheduled projects answer with
  /// the grace period and nothing else, so the app can say what *would*
  /// happen before the owner commits to it.
  Future<ProjectDeletionStanding> standingFor(String projectId) async {
    final result = await session.execute(
      r'SELECT scheduled_at, destroy_at, executed_at FROM project_destruction '
      r'WHERE project_id = $1',
      parameters: [projectId],
    );
    if (result.isEmpty) {
      return ProjectDeletionStanding(
        graceDays: policy.graceDays,
        backupRetentionDays: policy.backupRetentionDays,
      );
    }
    final row = result.first;
    return ProjectDeletionStanding(
      graceDays: policy.graceDays,
      backupRetentionDays: policy.backupRetentionDays,
      scheduledAt: (row[0]! as DateTime).toUtc(),
      destroyAt: (row[1]! as DateTime).toUtc(),
      executedAt: (row[2] as DateTime?)?.toUtc(),
    );
  }

  /// Whether [projectId] has been destroyed — the guard `sync_routes.dart`
  /// asks before it lets an *absent* project be established by a push.
  ///
  /// Without this, an owner's device that was offline across the deletion
  /// and holds a pending change to the `Projects` row would re-create the
  /// project on its next round, as a publish, with nobody deciding to. The
  /// id is retired; the local copy on every device is the person's to export.
  Future<bool> wasDestroyed(String projectId) async {
    final result = await session.execute(
      r'SELECT 1 FROM project_destruction '
      r'WHERE project_id = $1 AND executed_at IS NOT NULL',
      parameters: [projectId],
    );
    return result.isNotEmpty;
  }

  /// The ids the destroyed-project guard would refuse, for the sweep's log.
  Future<int> countDestroyed() async {
    final result = await session.execute(
      'SELECT count(*) FROM project_destruction WHERE executed_at IS NOT NULL',
    );
    return result.first.first! as int;
  }

  /// Schedules [projectId] for destruction at the end of the grace period.
  ///
  /// **Idempotent, and it never moves an existing date.** A second tap on
  /// "delete" answers the standing already held; the only way to change the
  /// date is to cancel and schedule again, which is a deliberate pair of acts
  /// rather than a slip. The caller has already been checked as an owner by
  /// the route; this writes what it is told.
  Future<ProjectDeletionStanding> schedule({
    required String projectId,
    required String scheduledBy,
  }) async {
    final now = _now;
    await session.execute(
      r'INSERT INTO project_destruction '
      r'(project_id, scheduled_at, scheduled_by, destroy_at) '
      r'VALUES ($1, $2, $3, $4) '
      r'ON CONFLICT (project_id) DO NOTHING',
      parameters: [projectId, now, scheduledBy, now.add(policy.grace)],
    );
    return standingFor(projectId);
  }

  /// Withdraws a scheduled destruction. A row already executed is not
  /// withdrawn — there is nothing left to save — and the standing says so.
  Future<ProjectDeletionStanding> cancel(String projectId) async {
    await session.execute(
      r'DELETE FROM project_destruction '
      r'WHERE project_id = $1 AND executed_at IS NULL',
      parameters: [projectId],
    );
    return standingFor(projectId);
  }

  /// Destroys [projectId] now, inside the caller's transaction, and records
  /// that it did. Used by the route's *immediate* action and by the sweep.
  ///
  /// Returns the number of rows deleted. A project with no rows at all still
  /// gets its `executed_at`, because the promise being kept is about the id.
  Future<int> destroy({
    required String projectId,
    required String scheduledBy,
  }) async {
    final now = _now;
    var deleted = 0;
    // Children first, `Projects` last — the order the purge already uses,
    // for the same foreign keys.
    for (final table in TombstoneRetentionService.purgeableTables) {
      final scope = table.projectScopeColumn!;
      final result = await session.execute(
        'DELETE FROM ${quoted(table.name)} WHERE ${quoted(scope)} = \$1 '
        'RETURNING 1',
        parameters: [projectId],
      );
      deleted += result.length;
    }
    for (final table in _serverOnlyProjectTables) {
      final result = await session.execute(
        'DELETE FROM $table WHERE project_id = \$1 RETURNING 1',
        parameters: [projectId],
      );
      deleted += result.length;
    }
    // Deferred foreign keys: force the check here so a dangling reference
    // fails inside this call rather than at COMMIT, where the route's
    // savepoint discipline cannot see it.
    await session.execute('SET CONSTRAINTS ALL IMMEDIATE');
    await session.execute(
      r'INSERT INTO project_destruction '
      r'(project_id, scheduled_at, scheduled_by, destroy_at, executed_at) '
      r'VALUES ($1, $2, $3, $2, $2) '
      r'ON CONFLICT (project_id) DO UPDATE SET executed_at = EXCLUDED.executed_at',
      parameters: [projectId, now, scheduledBy],
    );
    return deleted;
  }

  /// Destroys every project whose date has passed. The loop's one call.
  ///
  /// Each project in its own transaction, so one that fails leaves the rest
  /// destroyed and is retried next cycle rather than holding them all.
  /// [session] must therefore be a connection, not a transaction.
  Future<ProjectDestructionSweep> destroyDue() async {
    final now = _now;
    final due = await session.execute(
      r'SELECT project_id, scheduled_by FROM project_destruction '
      r'WHERE executed_at IS NULL AND destroy_at <= $1 '
      r'ORDER BY destroy_at',
      parameters: [now],
    );
    final destroyed = <String>[];
    var rows = 0;
    for (final row in due) {
      final projectId = row[0]! as String;
      await session.execute('BEGIN');
      try {
        final deleted = await destroyIfStillDue(projectId, now: now);
        await session.execute('COMMIT');
        if (deleted != null) {
          rows += deleted;
          destroyed.add(projectId);
        }
      } catch (_) {
        await session.execute('ROLLBACK');
        rethrow;
      }
    }
    return ProjectDestructionSweep(
      destroyedProjectIds: destroyed,
      rowsDeleted: rows,
    );
  }

  /// Destroys [projectId] **only if it is still due**, re-reading its
  /// schedule under a row lock first; returns the rows deleted, or null when
  /// it was no longer due. The sweep's per-project step, inside the
  /// transaction [destroyDue] opens for it.
  ///
  /// **Why the sweep cannot trust its own list** (task 11.302). [destroyDue]
  /// reads every due project first and destroys them one by one, so an
  /// owner's *cancel* — or, since 11.302, a *restore*, which withdraws the
  /// schedule — can commit between the list and the destroy. Until this
  /// re-read the sweep then destroyed a project its owner had just been told
  /// was saved. Both of those write the same `project_destruction` row this
  /// locks, so the two orders are now both safe: if the owner's write
  /// commits first, this finds nothing and leaves the project; if this locks
  /// first, the owner's write waits, then finds the row executed, and the
  /// answer it returns says the project is gone rather than restored.
  Future<int?> destroyIfStillDue(String projectId, {DateTime? now}) async {
    final at = now ?? _now;
    final still = await session.execute(
      r'SELECT scheduled_by FROM project_destruction '
      r'WHERE project_id = $1 AND executed_at IS NULL AND destroy_at <= $2 '
      'FOR UPDATE',
      parameters: [projectId, at],
    );
    if (still.isEmpty) return null;
    return destroy(
      projectId: projectId,
      scheduledBy: still.first.first! as String,
    );
  }

  /// The healthcheck's measurement — see [ProjectDestructionReading].
  Future<ProjectDestructionReading> measure() async {
    final now = _now;
    final result = await session.execute(
      r'SELECT count(*) FILTER (WHERE destroy_at > $1), '
      r'count(*) FILTER (WHERE destroy_at <= $1), '
      r'min(destroy_at) FILTER (WHERE destroy_at <= $1) '
      r'FROM project_destruction WHERE executed_at IS NULL',
      parameters: [now],
    );
    final row = result.first;
    final oldest = row[2] as DateTime?;
    return ProjectDestructionReading(
      scheduled: row[0]! as int,
      overdue: row[1]! as int,
      mostOverdueBy: oldest == null ? null : now.difference(oldest.toUtc()),
    );
  }

  /// The server's own per-project bookkeeping, deleted after the synced rows.
  /// Every one of these is keyed by `project_id` and has no foreign key to
  /// anything, so the order among them does not matter.
  static const List<String> _serverOnlyProjectTables = [
    'sync_cursors',
    'tombstone_purge_floor',
    'project_join_requests',
    'project_join_settings',
    'project_invites',
  ];
}
