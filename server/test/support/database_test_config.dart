import 'package:tritrack_server/tritrack_server.dart';

/// Shared by every Postgres-backed test file in this suite.
///
/// This used to be a `_config`/`_skipReason` block copy-pasted into each
/// file. `test/sync/tombstone_retention_test.dart` picked up the copy but
/// never wired it into a `skip:` — its 11 tests errored instead of skipping
/// (task 10.31). Route every Postgres-backed group through this file instead
/// of writing a new copy: a single definition is a single place to get
/// right, and `database_coverage_guard_test.dart` fails loudly if a run has
/// no database at all, so a future omission like that one can't hide behind
/// a quiet "all green" result again.
final DatabaseConfig? testDatabaseConfig = () {
  try {
    return DatabaseConfig.fromEnvironment();
  } on StateError {
    return null;
  }
}();

/// Pass to `group(..., skip: databaseSkipReason)` on every group that needs
/// Postgres. Also guard `setUpAll`/`setUp`/`tearDownAll` bodies with
/// `if (testDatabaseConfig == null) return;` — `setUpAll` itself can't take
/// a `skip:` argument, so the group-level skip is what actually keeps a
/// no-database run from touching a null connection.
String? get databaseSkipReason => testDatabaseConfig != null
    ? null
    : 'no Postgres configured; set POSTGRES_* to run';
