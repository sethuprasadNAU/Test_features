import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../sync/row_key_migration.dart';
import '../sync/sync_conflicts.dart';
import '../sync/unknown_columns.dart';
import 'migrations.dart';
import 'pre_migration_backup.dart';

/// Owns opening the project's SQLite connection correctly on every platform.
///
/// Responsibilities:
/// - Force `PRAGMA foreign_keys = ON` on every connection (SQLite defaults it
///   OFF, so referential integrity would otherwise be silently unenforced) —
///   but only *after* migrations have run, which is a rebuild requirement
///   rather than a relaxation; see the note on `onOpen` below.
/// - Wire `PRAGMA user_version` to the migration set via sqflite's `version`
///   and run [runMigrations] on create/upgrade.
/// - Select the right factory: the native plugin on iOS/Android, FFI on
///   desktop (macOS secondary target + test host).
///
/// The table schema itself lives in `schema.dart`; migration ordering in
/// `migrations.dart`.
class AppDatabase {
  AppDatabase._(this.raw);

  final Database raw;

  /// Schema version the code expects; drives `PRAGMA user_version`.
  static int get schemaVersion => latestSchemaVersion;

  /// Opens (creating/migrating as needed) the on-device project database.
  ///
  /// Not renamed alongside the Dart package rename: changing this filename
  /// would orphan every existing install's database, since the app would
  /// silently open a new empty DB at the new path.
  static Future<AppDatabase> open({String fileName = 'tri_track.db'}) async {
    final factory = _resolveDatabaseFactory();
    final directory = await getApplicationSupportDirectory();
    final path = p.join(directory.path, fileName);
    // Before anything touches the file: if a migration is about to run, copy
    // it first. This is the one place the app itself could destroy data, so
    // it is the one place a guaranteed backup matters most (task 10.19).
    await PreMigrationBackup.ensureBackedUpBeforeMigration(
      factory: factory,
      path: path,
      targetVersion: schemaVersion,
      backupDir: Directory(p.join(directory.path, 'pre_migration_backups')),
    );
    final db = await factory.openDatabase(path, options: _openOptions());
    return AppDatabase._(db);
  }

  /// Opens a throwaway in-memory database (FFI). For tests and previews — no
  /// `path_provider`/plugin dependency, so it runs on the plain Dart VM.
  ///
  /// `singleInstance: false` so each call yields an *independent* in-memory
  /// database. sqflite caches `:memory:` by path with `singleInstance: true`
  /// (the default), which would make two `openInMemory()` calls alias the same
  /// database — silently breaking any test that needs two separate DBs (e.g. a
  /// merge from one project database into another).
  static Future<AppDatabase> openInMemory() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: _openOptions(singleInstance: false),
    );
    return AppDatabase._(db);
  }

  static OpenDatabaseOptions _openOptions({bool singleInstance = true}) =>
      OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: singleInstance,
        // Deliberately NOT `onConfigure`, which runs *before* create/upgrade.
        // Foreign keys must be off while migrations run: schema v6 rebuilds six
        // tables to re-key them (task 10.35), and SQLite's own prescribed
        // procedure for a table rebuild is to disable FK enforcement for the
        // duration — during it, a table briefly references one whose key shape
        // has already changed. [runMigrations] runs `PRAGMA foreign_key_check`
        // before returning, so the window cannot hide a real violation.
        //
        // Enforcement itself is unchanged: this is per-connection and `onOpen`
        // also runs on every open, before any repository can read or write.
        onCreate: (db, version) => runMigrations(db, from: 0, to: version),
        onUpgrade: (db, oldVersion, newVersion) =>
            runMigrations(db, from: oldVersion, to: newVersion),
        // Runs after create/upgrade on every open. The holding table is
        // client-only, so it is ensured here rather than by a migration — see
        // [UnknownColumnStore]. Promotion follows immediately: an upgrade that
        // added a column must move any value held for it into place before any
        // screen reads that column, or the app would show a blank field it is
        // in fact holding the value for.
        onOpen: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await UnknownColumnStore.ensureTable(db);
          // Before promotion, and before anything reads a held or refused row:
          // the client-only stores key rows by primary key, and schema v6
          // changed what that is. See [RowKeyMigration] — it is idempotent, so
          // running it on every open costs a no-op scan of small tables.
          await RowKeyMigration.run(db);
          await UnknownColumnStore(db).promote();
          // Client-only, like the holding table above — see
          // [SyncConflictStore] (task 10.12).
          await SyncConflictStore.ensureTable(db);
        },
      );

  static DatabaseFactory _resolveDatabaseFactory() {
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return databaseFactory;
  }

  Future<void> close() => raw.close();
}
