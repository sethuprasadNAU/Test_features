/// Postgres DDL for project invitations (task 11.2).
///
/// **RETIRED BY TASK 11.81 — this table is kept, and nothing writes to it any
/// more.** Per-address invitations were replaced by one shared join code per
/// project plus the owner's approval (`join_schema.dart`, `join_service.dart`).
/// `InviteService` is gone, and so is every invitation route —
/// `POST /projects/invites/redeem` was the last of them and task 11.84 deleted
/// it. **No code reads or writes this table.**
///
/// **Why the table stays rather than being dropped:** it is the record of who
/// was let into which project and by whom, and that is worth more than the few
/// kilobytes. Deleting an audit trail to tidy up a schema is the kind of
/// housekeeping that is only ever noticed once somebody needs it. Everything
/// below still describes what the rows in it mean — read it as history.
///
/// Server-only state, like `auth_schema.dart` and for the same reason: an
/// invitation is not project data. It never appears in `tableSpecs`, never
/// syncs to a device, and never lands in a backup archive a person can open.
/// That is deliberate — a synced invite row would put a grant-shaped record on
/// every member's phone, and the code's hash with it.
///
/// Being server-only also means this needs no schema-version bump: it is
/// created by `PostgresMigrations._ensureServerOnlyTables`, which runs every
/// `IF NOT EXISTS` statement on every start, and `ensureServerAppRole`'s
/// `ALTER DEFAULT PRIVILEGES` already covers a table created after the grant
/// (task 10.89).
library;

/// Live, redeemed and revoked invitations.
///
/// **Only the SHA-256 hash of the code is stored** (§4.2). A database read
/// must not yield working invitations, and this database holds the locations
/// of collared animals.
///
/// **`email` is the binding, and it is the whole security argument.** It holds
/// the normalized address the inviting owner typed. Redemption compares it
/// against the address the *server* authenticated for the calling session
/// (`auth_accounts.email`) — never against anything in the request. A code
/// read over somebody's shoulder, forwarded, or photographed off a whiteboard
/// is therefore worthless to anyone but its intended recipient, which is what
/// makes an 8-character code acceptable where §4.2 demands 256 bits of a
/// magic-link token. See `row_authorizer.dart`'s note that an invitation
/// record must carry a *server-authenticated* address, not one the inviter
/// typed: the typed address is a **constraint** here, and the grant is only
/// ever made out to an authenticated one.
///
/// `redeemed_at`/`revoked_at` make single-use and revocation enforceable in
/// one conditional `UPDATE`, the same shape `auth_magic_links.consumed_at`
/// uses — a `SELECT` then `UPDATE` is a race in which two concurrent
/// redemptions both succeed.
///
/// No foreign key to `Projects` or `Users`, matching the rest of the
/// server-only tables: those are synced tables whose rows arrive and are
/// tombstoned on the client's schedule, and an invitation must not be able to
/// block or be cascaded by that. The project's existence is checked at
/// redemption, where it matters.
const String createProjectInvites = '''
CREATE TABLE IF NOT EXISTS project_invites (
  invite_id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL,
  code_hash TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  role TEXT NOT NULL,
  created_by TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  redeemed_at TIMESTAMPTZ,
  redeemed_by TEXT,
  revoked_at TIMESTAMPTZ,
  revoked_by TEXT
)''';

const List<String> createProjectInviteIndexes = [
  // The owner's members screen lists a project's invitations.
  'CREATE INDEX IF NOT EXISTS idx_project_invites_project '
      'ON project_invites (project_id)',
];

/// Every statement needed to build the invitation schema, in order.
List<String> inviteSchemaStatements() => [
  createProjectInvites,
  ...createProjectInviteIndexes,
];
