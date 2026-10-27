import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart' as tritrack_sync;

import 'deployment_wipe_migration.dart';
import 'individual_backfill_migration.dart';
import 'non_detection_relink_migration.dart';
import 'project_time_zone_migration.dart';
import 'schema.dart';
import 'tag_scope_migration.dart';

export 'package:tritrack_sync/tritrack_sync.dart' show latestSchemaVersion;

/// One schema version's worth of forward-only DDL/DML.
///
/// Migrations are additive and ordered by [version]. To evolve the schema
/// (Phase 1+), append a new `Migration(N, [...])` — never edit a shipped one,
/// since devices in the field will already have run it. `PRAGMA user_version`
/// (managed by sqflite via the DB's `version`) records the last-applied
/// version so [runMigrations] knows where to resume.
///
/// ## [Migration.run] — a migration that has to decide something
///
/// Thirteen of the sixteen are a list of statements, and that is the shape
/// to prefer: a shipped migration should describe the change as it was made,
/// and a list of strings cannot quietly become a different migration.
///
/// Schema v14 (task 11.219) is the first that could not be one. It has to
/// **count** what it is about to move and print the four numbers, it has to
/// **fork** a tag that two projects hold — fresh ids, a copied version chain,
/// each project's own records re-pointed, and the counts printed (task
/// 11.224, after 11.219's refusal of that case fired on Michael's phone) —
/// and the project each tag ends up in is derived over five tables rather
/// than read off a column. None of that is expressible in DDL, and a migration that
/// moved this much data while printing nothing would be indistinguishable
/// from one that did nothing — which is this project's founding defect, met
/// in the worst possible place.
///
/// Schema v15 (task 11.225) is a run-bodied migration for the same reason:
/// it derives which `Non_Detections` rows the v14 fork left dangling from
/// `Tags.lineage_id`, rather than from anything a statement list could
/// express, and it too must count and print rather than move data silently.
/// See [NonDetectionRelinkMigration] for why it is a separate migration
/// rather than folded into v14's.
///
/// Schema v16 (task 11.240) is a statement list wrapped in a body that
/// counts: it creates one `Individuals` row per tag, and a migration that
/// creates a row per existing row and prints nothing cannot be told from one
/// that created none. See [IndividualBackfillMigration].
///
/// Schema v17 (task 11.243) is the same shape and the stakes are the
/// opposite: it **deletes** every collar, bearing and animal on the device,
/// by decision (`ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §9). A destructive step
/// that does not announce itself is the worst version of the defect the two
/// migrations above are wrapped against, so it counts first and prints what
/// it destroyed. See [DeploymentWipeMigration].
///
/// A run-bodied migration executes on whatever executor [runMigrations] is
/// given, inheriting its transaction: for the app that is sqflite's own
/// create/upgrade transaction, so it is atomic exactly as a batch is.
///
/// It is also told the version the database is coming *from*, which a
/// statement list has no use for and a body that reports does: `from == 0` is
/// a fresh create, where there is by definition nothing to migrate and a
/// census of zeroes is noise rather than a finding.
class Migration {
  const Migration(this.version, this.statements) : run = null;

  /// A migration whose body is Dart. See the note above for when that is the
  /// right shape — it is not the default and should stay rare.
  const Migration.run(this.version, this.run) : statements = const [];

  final int version;
  final List<String> statements;
  final Future<void> Function(DatabaseExecutor db, int fromVersion)? run;
}

/// Ordered migration set. Version 1 builds the full initial schema.
///
/// Must be contiguous from 1..[tritrack_sync.latestSchemaVersion] — that
/// constant, not this list, is the single authoritative "current version"
/// (shared with the future server so the two schemas can't silently drift on
/// what "latest" means). `assertMigrationsMatchLatestSchemaVersion` (asserted
/// in `test/data/migrations_test.dart`) keeps this list honest against it.
final List<Migration> migrations = [
  Migration(1, schemaV1Statements()),
  Migration(2, schemaV2Statements()),
  Migration(3, schemaV3Statements()),
  Migration(4, schemaV4Statements()),
  Migration(5, schemaV5Statements()),
  Migration(6, schemaV6Statements()),
  Migration(7, schemaV7Statements()),
  Migration(8, schemaV8Statements()),
  Migration(9, schemaV9Statements()),
  Migration(10, schemaV10Statements()),
  Migration(11, schemaV11Statements()),
  Migration(12, schemaV12Statements()),
  Migration(13, schemaV13Statements()),
  Migration.run(14, TagScopeMigration.apply),
  Migration.run(15, NonDetectionRelinkMigration.apply),
  Migration.run(16, IndividualBackfillMigration.apply),
  Migration.run(17, DeploymentWipeMigration.apply),
  Migration(18, schemaV18Statements()),
  Migration(19, schemaV19Statements()),
  Migration.run(20, ProjectTimeZoneMigration.apply),
];

/// Throws a [StateError] if [migrations]' highest version disagrees with the
/// shared [tritrack_sync.latestSchemaVersion] constant — the drift this whole
/// split is meant to make impossible to introduce silently.
void assertMigrationsMatchLatestSchemaVersion() {
  final maxVersion = migrations
      .map((m) => m.version)
      .fold(0, (a, b) => a > b ? a : b);
  if (maxVersion != tritrack_sync.latestSchemaVersion) {
    throw StateError(
      'migrations list (max v$maxVersion) is out of sync with '
      'tritrack_sync.latestSchemaVersion (v${tritrack_sync.latestSchemaVersion})',
    );
  }
}

/// Applies every migration with `version` in ($from, $to], each in its own
/// transaction/batch. Used for both fresh creates (from: 0) and upgrades.
///
/// Runs with foreign-key enforcement **off** — see `AppDatabase._openOptions`,
/// which moved `PRAGMA foreign_keys = ON` to `onOpen` for this reason. Schema
/// v6's table rebuilds require it, and SQLite prescribes it for any rebuild.
/// The cost is that a migration could leave a dangling reference without SQLite
/// objecting, so [_assertForeignKeysIntact] checks explicitly afterwards rather
/// than trusting that no migration ever will.
Future<void> runMigrations(
  Database db, {
  required int from,
  required int to,
}) async {
  final pending =
      migrations.where((m) => m.version > from && m.version <= to).toList()
        ..sort((a, b) => a.version.compareTo(b.version));
  if (pending.isEmpty) return;

  for (final migration in pending) {
    final run = migration.run;
    if (run != null) {
      await run(db, from);
      continue;
    }
    final batch = db.batch();
    for (final statement in migration.statements) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
  }

  await _assertForeignKeysIntact(db);
}

/// Throws a [StateError] if the freshly-migrated database contains a foreign
/// key violation or a foreign key that no longer names a valid key.
///
/// Only ever runs when a migration actually applied — `PRAGMA foreign_key_check`
/// scans every row of every table, which is far too expensive to pay on an
/// ordinary open, and pointless there anyway since enforcement is on.
///
/// This is the safety net for running migrations with enforcement off. It
/// catches both halves of what that allows: a row whose reference no longer
/// resolves, and (the v6-specific hazard) a single-column `REFERENCES` clause
/// left pointing at a table whose primary key has become composite, which
/// SQLite reports as a "foreign key mismatch" rather than silently tolerating.
Future<void> _assertForeignKeysIntact(Database db) async {
  final violations = await db.rawQuery('PRAGMA foreign_key_check');
  if (violations.isEmpty) return;
  final summary = violations
      .take(5)
      .map((v) => '${v['table']} row ${v['rowid']} -> ${v['parent']}')
      .join('; ');
  throw StateError(
    'Migration left ${violations.length} foreign key violation(s): $summary'
    '${violations.length > 5 ? ' …' : ''}',
  );
}
