/// Postgres DDL for the project join code and join requests (task 11.81, from
/// task 11.74's design §1.3).
///
/// **Server-only state, and that is the single most important fact about these
/// two tables.** They are not in `tableSpecs`, never sync to a device, never
/// land in a backup archive a person can open, and no client has any concept of
/// them. That is why this change needs **no schema migration on anybody's
/// phone**: `latestSchemaVersion` stays 9 and `schemaMajorVersion` stays 2.
///
/// Being server-only is also why adding them costs a line and not a release.
/// `PostgresMigrations._ensureServerOnlyTables` runs every
/// `CREATE TABLE IF NOT EXISTS` below on **every start**, before and
/// independently of the version check, and `ensureServerAppRole`'s
/// `ALTER DEFAULT PRIVILEGES` already covers a table created after the grant
/// (task 10.89).
///
/// **Why a pending request is not a membership row**, which is the design
/// decision everything here rests on. Nine places read `Project_Memberships`,
/// and five of them ask only "is the stint open" without looking at the role at
/// all — including `GET /projects/mine`, which would therefore have shown a
/// requester the project's name and its owner **before anybody approved
/// anything.** Both sides of the wire also refuse a role outside the three
/// `ProjectRole` values, so there is no "pending" role to invent. Keeping the
/// request in a table of its own makes the question disappear rather than
/// answering it, and means not one of those readers had to change.
library;

/// One project's join settings: whether joining is on, the code, and the
/// team-size limit.
///
/// **The absent row means joining is OFF, and this is the most dangerous line
/// in the whole change.** Every project that exists today has no row here. A
/// lazy "create the row on first read, with joining enabled" would silently
/// open every existing project to anyone holding a code nobody has issued yet.
/// The `DEFAULT FALSE` below is only half of it — the absent-row case is read
/// the same way in `JoinService`, and `join_service_test.dart` asserts it,
/// because a default in DDL says nothing about a row that was never inserted.
///
/// **`code` is stored readably, and that is a written exception to §4.2**, not
/// a slip. See Security Model **§4.2.1**, which names it, gives the reasoning
/// (a join code is no longer a credential — it buys the right to ask and the
/// owner is the gate), bounds what the exception covers, and states the
/// condition under which it lapses. Michael made that call on 2026-08-31. **If
/// you are here because storing this in plaintext looked wrong: read §4.2.1
/// before changing it, and if you make a join code sufficient to grant
/// membership on its own, the exception lapses and this goes back to a hash.**
///
/// No expiry column, deliberately (§2.1 of the design, confirmed by Michael out
/// loud). An invitation expires because it is handed to one person for one
/// purpose; a project's join code is infrastructure that lives on a whiteboard
/// for the season. A hidden expiry produces "the code stopped working and
/// nobody knows why", which is a failure this project has hit before. The owner
/// switches joining off; nothing else turns it off.
///
/// No foreign key to `Projects`, matching every other server-only table and for
/// the reason `invite_schema.dart` gives: those are synced tables whose rows
/// arrive and are tombstoned on a client's schedule, and join settings must not
/// be able to block or be cascaded by that.
const String createProjectJoinSettings = '''
CREATE TABLE IF NOT EXISTS project_join_settings (
  project_id       TEXT PRIMARY KEY,
  code             TEXT UNIQUE,
  joining_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
  team_size_limit  INTEGER NOT NULL DEFAULT 50,
  rotated_at       TIMESTAMPTZ,
  rotated_by       TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by       TEXT
)''';

/// Somebody's request to join a project, and what the owner decided.
///
/// **`email` is copied onto the row at the moment the request is made**, from
/// the session's `auth_accounts` row — so the owner's list needs no join
/// against a `Users` row that may not exist. It is the address the *server*
/// authenticated and there is no path by which a caller supplies it.
///
/// **`claimed_name` is the one caller-supplied string in this design**
/// (Michael's decision 1, 2026-08-31). He overruled the recommendation to carry
/// no name, and his reason is the better one: an owner may not recognise
/// `f.lastname@nau.edu`, and a name is what makes approval a judgement rather
/// than a guess. It is bounded by `RowValidator.isWellFormedPersonName` and
/// `TextBound.personName.maxLength` — the **same** declaration `Users.first_name`
/// carries, not a second copy of it — because this is the one screen in the app
/// where a person decides whether to trust somebody by reading a string, and a
/// name that renders as a colleague's is the attack it is uniquely exposed to.
///
/// **`project_name` is frozen onto the row at the moment the request is made**
/// (Michael's decision, 2026-08-31, built by task 11.79). It used to be joined
/// live from the `Projects` row every time `GET /projects/join-requests/mine`
/// answered — so a project renamed after a refusal handed the new name to the
/// person who had been turned down. Renaming "Field season" to something
/// specific is exactly when that matters. **This is the pattern the row
/// already uses one column over:** `email` is copied here at request time
/// rather than joined from `auth_accounts`, for the same reason.
///
/// **A decided request is kept, never deleted — but not for ever** (task
/// 11.79). `decision` is `approved`, `rejected` or `cleared`; a cleared one was
/// removed by a code rotation. Keeping it is what lets
/// `GET /projects/join-requests/mine` tell somebody their request is gone
/// instead of leaving them on "pending" forever — the class task 11.60 found
/// for removed members. Thirty days after the decision the row is swept by
/// `AuditRetentionService` (`decidedJoinRequestRetention`), because a person
/// who was turned down has no reason to be a row on this server a year later,
/// and a rejection has no reason to sit on their screen for ever. **The card
/// is then simply absent, not an error** — the news has already been given;
/// this is the notice being taken down.
const String createProjectJoinRequests = '''
CREATE TABLE IF NOT EXISTS project_join_requests (
  request_id    TEXT PRIMARY KEY,
  project_id    TEXT NOT NULL,
  user_id       TEXT NOT NULL,
  email         TEXT NOT NULL,
  claimed_name  TEXT,
  project_name  TEXT,
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  device_id     TEXT,
  decided_at    TIMESTAMPTZ,
  decided_by    TEXT,
  decision      TEXT
)''';

/// Bring a database created before task 11.79 up to the table above.
///
/// `CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists,
/// so a new column needs its own statement — and this one runs on every start
/// beside the creates, for the same reason they do.
///
/// The backfill is a one-time repair with a `WHERE project_name IS NULL` guard,
/// so it costs an index-less scan of a small table once and nothing thereafter.
/// It copies the project's name **as it is now**, which is the best any
/// backfill can do: the name at request time was not recorded, which is the
/// defect being closed.
const List<String> alterProjectJoinRequests = [
  'ALTER TABLE project_join_requests '
      'ADD COLUMN IF NOT EXISTS project_name TEXT',
  'UPDATE project_join_requests r SET project_name = p.project_name '
      'FROM "Projects" p WHERE p.project_id = r.project_id '
      'AND r.project_name IS NULL',
];

const List<String> createProjectJoinIndexes = [
  // **One pending request per person per project, enforced by the database
  // rather than by a read followed by a write.** Exactly the race, and exactly
  // the fix, that task 11.10 applied to `idx_memberships_one_open`: two taps
  // arriving at once both pass a `SELECT` before either writes. A partial index
  // is what makes it expressible — a plain unique key on the pair would forbid
  // the ordinary case of asking again after being rejected.
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_join_requests_one_pending '
      'ON project_join_requests (project_id, user_id) '
      'WHERE decided_at IS NULL',
  // The owner's pending list, newest first.
  'CREATE INDEX IF NOT EXISTS idx_join_requests_project '
      'ON project_join_requests (project_id, requested_at DESC)',
  // `GET /projects/join-requests/mine`.
  'CREATE INDEX IF NOT EXISTS idx_join_requests_user '
      'ON project_join_requests (user_id, requested_at DESC)',
];

/// Every statement needed to build the join schema, in order.
///
/// The alters come last, and they read `"Projects"` — which exists by then on
/// both paths through `PostgresMigrations.run`: the bootstrap path runs
/// `schemaStatements()` first, and every other path is a database that already
/// has it.
List<String> joinSchemaStatements() => [
  createProjectJoinSettings,
  createProjectJoinRequests,
  ...createProjectJoinIndexes,
  ...alterProjectJoinRequests,
];
