/// Which database this server is — minted once, returned on every push and
/// pull (task 11.58).
///
/// ## The defect it closes
///
/// A device's pull bookmark is a number in *this database's* `server_seq`
/// line, and its row receipts say *this database* holds a row. Neither said
/// which database that was. Restore this server from a backup, or rebuild it,
/// and every device that had synced against the old one asks for "everything
/// after 4,812" from a line that now stops at a lower number — and is
/// correctly told there is nothing — while its receipts keep rows off the push
/// because a database that no longer exists once confirmed them. **Both halves
/// report a clean sync.** The value here is what lets the app notice.
///
/// ## A restore must not carry it across
///
/// **This is the half the task brief did not say, and it decides the design.**
/// "Minted once at schema creation" is not enough on its own: a backup is a
/// dump of every table, so a restored database would come back holding the
/// *old* identifier, and the one case this exists for — a restore — would be
/// the one case it could not see. So two things keep a restore from inheriting
/// it, and either is enough by itself:
///
/// - `server/backup/backup.sh` dumps this table's **definition but not its
///   row** (`--exclude-table-data`), so an archive written by this project's
///   own backup has nothing to restore;
/// - `server/backup/restore.sh` **empties the table** in the restored copy
///   before promoting it, which covers an archive taken any other way.
///
/// The server then mints a fresh one on its next start, in
/// [databaseIdentityStatements] — and a restore over a live database *has* to
/// be followed by a start, because Postgres will not rename a database
/// anything is connected to (`restore.sh` says so and stops).
///
/// **What it still cannot see: a restore that copies the whole disk** — a
/// virtual-machine snapshot rolled back, a volume restored by a hosting
/// provider. Those bring back this row with everything else, and nothing
/// inside the database can tell. Written down in `DEVELOPMENT_PLAN.md`'s
/// Discovered Scope for task 11.58 rather than assumed away.
///
/// ## Why it is read on every request rather than cached
///
/// A cached value would survive exactly the event it exists to report. The
/// read is a primary-key lookup on a one-row table, inside a transaction the
/// request already holds.
library;

import 'package:postgres/postgres.dart';

/// The table's name, as `backup.sh` and `restore.sh` spell it. A shell
/// script cannot import this constant, so
/// `server/test/sync/database_identity_test.dart` reads both scripts and fails
/// if either stops naming it.
const String databaseIdentityTable = 'server_database_identity';

/// DDL, and the mint.
///
/// Ensured on every start with the other server-only tables — not part of
/// `latestSchemaVersion`, because the client has no row of it — so an already
/// running server gains an identifier on its first start after upgrading, and
/// a freshly restored one gains a **new** one on its first start after the
/// restore.
///
/// `ON CONFLICT DO NOTHING` is what makes this "once": the row is only ever
/// written when there is none, so a restart never changes the answer.
/// `gen_random_uuid()` is built into Postgres 13 and later; this project runs
/// 16.
List<String> databaseIdentityStatements() => const [
  '''
CREATE TABLE IF NOT EXISTS $databaseIdentityTable (
  only_row BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (only_row),
  database_id TEXT NOT NULL,
  minted_at TIMESTAMPTZ NOT NULL DEFAULT now()
)''',
  'INSERT INTO $databaseIdentityTable (only_row, database_id) '
      'VALUES (TRUE, gen_random_uuid()::text) '
      'ON CONFLICT (only_row) DO NOTHING',
];

/// Reads this database's identifier, minting one if the row is missing.
///
/// Missing should not happen — every start ensures it — but the fallback is a
/// mint rather than a null, because a null on the wire means "this server
/// predates the field", and a device that reads that keeps trusting its old
/// bookmark. A database that lost its identifier is exactly the case where
/// that trust is wrong. The insert is safe under concurrency: two requests
/// that both find nothing both try, one wins, and both then read the winner.
Future<String> readDatabaseIdentity(Session session) async {
  final existing = await _select(session);
  if (existing != null) return existing;
  await session.execute(databaseIdentityStatements().last);
  final minted = await _select(session);
  if (minted == null) {
    throw StateError('$databaseIdentityTable holds no row after minting one');
  }
  return minted;
}

Future<String?> _select(Session session) async {
  final result = await session.execute(
    'SELECT database_id FROM $databaseIdentityTable WHERE only_row',
  );
  if (result.isEmpty) return null;
  return result.first.first as String;
}
