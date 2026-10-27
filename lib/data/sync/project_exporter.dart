import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

import 'unknown_columns.dart';

/// Reads one project's complete state out of the live database into an
/// in-memory [ProjectBackup], ready for [BackupArchive.encode].
///
/// "Complete" means:
/// - every project-scoped row (WHERE the project-scope column matches),
///   **including tombstoned rows** — a backup that dropped soft-deletes would
///   resurrect them on the next merge, so deletes must travel too;
/// - the reachable global rows: the [Tables.users] any collected row
///   references (owner, observer, `last_modified_by`), so the archive is
///   self-contained and mergeable on a device that has never seen these
///   people.
///
/// **[Tables.tags] and [Tables.tagVersions] used to need a second pass and no
/// longer do (task 11.219).** They were global, so an archive had to collect
/// the tags a project's rows referenced *by reachability* and then their whole
/// version history. Copy-on-add made both project-scoped, so they come out of
/// the ordinary `WHERE project_id = ?` loop above like the other nine tables,
/// and the archive carries a project's tags because they **are** the
/// project's — not because something worked out that it could see them.
///
/// "Complete" stops where [SyncTable.archiveDisclosure] says it does (task
/// 11.30). The archive is deliberately **narrower than the database**: a table
/// declared [ArchiveDisclosure.withheld] is not collected, however reachable
/// its rows are. Today that is [Tables.userEmails] — everyone's prior email
/// addresses, which no screen in this app has ever displayed. The reason lives
/// at the declaration, not here, so that adding a table is the moment somebody
/// decides whether it may leave the device.
abstract final class ProjectExporter {
  /// Collects [projectId] from [db]. [now] stamps the manifest (injectable for
  /// deterministic tests). [schemaVersion] defaults to the app's current schema
  /// and should only be overridden in tests.
  static Future<ProjectBackup> collect(
    DatabaseExecutor db,
    String projectId, {
    required DateTime now,
    int? schemaVersion,
  }) async {
    final tables = <String, List<Map<String, Object?>>>{};

    // 1. Project-scoped tables (project row + all its children), tombstones
    //    included.
    for (final t in syncTables) {
      if (t.archiveDisclosure == ArchiveDisclosure.withheld) continue;
      final scope = t.projectScopeColumn;
      if (scope == null) continue;
      final rows = await db.query(
        t.name,
        where: '$scope = ?',
        whereArgs: [projectId],
      );
      tables[t.name] = rows.map(_copyRow).toList();
    }

    // 2. Reachable Users: every user_id referenced by everything collected so
    //    far — including the tags', which step 1 already gathered.
    final userIds = _collectIds(tables, (t) => t.userColumns);
    tables[Tables.users] =
        await _rowsByIdIn(db, Tables.users, 'user_id', userIds);

    // 4. Address history for those same users is **deliberately not collected**
    //    (task 11.30). It used to be, for `ProjectMerger`'s prior-email
    //    fallback; see `Tables.userEmails`'s `archiveDisclosure` declaration
    //    for what that fallback loses and why the trade goes this way.

    // 5. Put back any values held for these rows by a newer schema minor
    //    (task 10.18). A backup that dropped them would be the same silent
    //    destruction the sync path exists to avoid, one file removed.
    final store = UnknownColumnStore(db);
    for (final t in syncTables) {
      if (t.archiveDisclosure == ArchiveDisclosure.withheld) continue;
      final rows = tables[t.name];
      if (rows != null) await store.attach(projectId, t, rows);
    }

    final manifest = BackupManifest(
      formatId: kBackupFormatId,
      formatVersion: kBackupFormatVersion,
      schemaVersion: schemaVersion ?? latestSchemaVersion,
      createdAtUtc: now.toUtc(),
      projectId: projectId,
      projectName: _projectName(tables, projectId),
      rowCounts: rowCountsOf(tables),
    );

    return ProjectBackup(manifest: manifest, tables: tables);
  }

  /// Gathers the distinct non-null ids found in the given columns across all
  /// already-collected tables. [columnsOf] picks which columns of each table
  /// hold the id kind we're gathering.
  static Set<String> _collectIds(
    Map<String, List<Map<String, Object?>>> tables,
    List<String> Function(SyncTable) columnsOf,
  ) {
    final ids = <String>{};
    for (final t in syncTables) {
      final rows = tables[t.name];
      if (rows == null) continue;
      for (final col in columnsOf(t)) {
        for (final row in rows) {
          final value = row[col];
          if (value is String && value.isNotEmpty) ids.add(value);
        }
      }
    }
    return ids;
  }

  /// `SELECT * FROM <table> WHERE <idColumn> IN (...)` including tombstoned
  /// rows. Chunks the IN list to stay under SQLite's variable limit.
  static Future<List<Map<String, Object?>>> _rowsByIdIn(
    DatabaseExecutor db,
    String table,
    String idColumn,
    Set<String> ids,
  ) async {
    if (ids.isEmpty) return [];
    const chunkSize = 500; // well under SQLite's default 999-variable limit.
    final idList = ids.toList();
    final out = <Map<String, Object?>>[];
    for (var i = 0; i < idList.length; i += chunkSize) {
      final chunk = idList.sublist(
        i,
        i + chunkSize > idList.length ? idList.length : i + chunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await db.query(
        table,
        where: '$idColumn IN ($placeholders)',
        whereArgs: chunk,
      );
      out.addAll(rows.map(_copyRow));
    }
    return out;
  }

  /// sqflite returns read-only row maps; copy to a mutable map the merger/
  /// migrator can rewrite (id remap, forward migration) without surprises.
  static Map<String, Object?> _copyRow(Map<String, Object?> row) =>
      Map<String, Object?>.of(row);

  static String _projectName(
    Map<String, List<Map<String, Object?>>> tables,
    String projectId,
  ) {
    for (final row in tables[Tables.projects] ?? const []) {
      if (row['project_id'] == projectId) {
        return (row['project_name'] as String?) ?? 'Project';
      }
    }
    return 'Project';
  }
}
