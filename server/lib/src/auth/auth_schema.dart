/// Postgres DDL for authentication state (task 10.6).
///
/// Separate from `postgres_schema.dart` because none of this is synced data —
/// it is server-only state that no client ever receives, and it deliberately
/// does not appear in `tableSpecs`.
library;

/// Accounts, anchored on normalized email.
///
/// **This is the server's answer to "which `user_id` belongs to this email",
/// and it is authoritative.** A device adopts the id recorded here on sign-in
/// and remaps its local rows onto it; devices never negotiate identity with
/// each other (see the plan's "One user, many devices"). The value is a UUID
/// string, shape-identical to the client-generated ids everywhere else — Phase
/// 10 invariant 2 forbids server-assigned primary keys for *data*, and this is
/// not data, it is the identity anchor.
///
/// Typed `TEXT`, not Postgres `UUID`, deliberately: the synced `Users.user_id`
/// is `TEXT` (the shared column set says so), and task 10.10 will join a
/// session's user against row authorship constantly. Matching types means no
/// cast at any of those call sites, and a cast that is right almost everywhere
/// is precisely the shape of an authorization bug.
///
/// `email` holds the **normalized** address (trimmed, lower-cased) and is
/// UNIQUE — that uniqueness is the entire mechanism by which two devices
/// converge on one id.
const String createAuthAccounts = '''
CREATE TABLE IF NOT EXISTS auth_accounts (
  user_id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
)''';

/// Unconsumed and consumed magic-link tokens.
///
/// Only the SHA-256 hash is stored — a database read must not yield usable
/// tokens (§4.2). `email` rather than `user_id` because an account is created
/// on *redemption*, not on request: an unauthenticated endpoint that writes
/// account rows is both a pollution vector and an enumeration oracle (§4.5).
///
/// `consumed_at` makes single-use enforceable in one atomic statement; see
/// `AuthService.redeem`.
const String createAuthMagicLinks = '''
CREATE TABLE IF NOT EXISTS auth_magic_links (
  token_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ
)''';

const List<String> createAuthMagicLinkIndexes = [
  // Supports "invalidate any prior unconsumed link for this address" so a user
  // who taps resend three times holds one live token, not three.
  'CREATE INDEX IF NOT EXISTS idx_auth_magic_links_email ON auth_magic_links (email)',
];

/// Live and revoked sessions.
///
/// **Opaque, database-backed rows — not JWTs, and this is load-bearing**
/// (§4.3). Immediate revocation is a hard requirement here: task 11.2's member
/// removal is cosmetic without it, and a removed team member whose device keeps
/// syncing is the same as not having revoked at all. A JWT is valid until it
/// expires by construction, so revoking one needs a server-side blocklist —
/// which is a database read per request, which is the thing JWTs were chosen to
/// avoid. The stateless option collapses into the stateful one with extra steps
/// and a footgun, so: the row *is* the session.
///
/// Keyed on `(user_id, device_id)` with **no uniqueness across the user**:
/// concurrent sessions per user are the normal case, not an edge case. Signing
/// in on a phone must not sign out a laptop.
///
/// `device_id` is the client's install id. It is stored so a session can be
/// revoked per-device (10.14) and so the device registry (10.13) can answer
/// "why is my phone behind" — but it is **never trusted for authorization**:
/// it is a plaintext, forgeable value on the device (see the security model
/// §3.7). The session row is the authority for who is calling; the device id
/// is a label on it.
const String createAuthSessions = '''
CREATE TABLE IF NOT EXISTS auth_sessions (
  session_id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL REFERENCES auth_accounts(user_id) ON DELETE CASCADE,
  device_id TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ,
  revoked_reason TEXT
)''';

const List<String> createAuthSessionIndexes = [
  // All-devices revocation (10.14) and the device registry (10.13).
  'CREATE INDEX IF NOT EXISTS idx_auth_sessions_user ON auth_sessions (user_id)',
  'CREATE INDEX IF NOT EXISTS idx_auth_sessions_user_device ON auth_sessions (user_id, device_id)',
];

/// Records the outcome of a magic-link request so the *requesting* device can
/// find out what happened to a link that was opened somewhere else.
///
/// **Why this table exists.** A link requested on a laptop and opened on a
/// phone signs in the phone — the session belongs to the redeeming device,
/// never the requesting one (§4.2), and that must stay true. But the plan also
/// requires that the requesting device "must not wait silently forever". This
/// gives the laptop something truthful to poll: not a session (it has not
/// earned one) but the *fact* that its link was consumed elsewhere, so it can
/// stop spinning and say so.
///
/// `request_id` is handed to the requesting device at request time and is not
/// a secret in the token sense — it reveals only the state of a request the
/// caller already made. It deliberately carries **no email and no user_id**,
/// so polling it tells an attacker who guesses a request id nothing about who
/// it belonged to.
const String createAuthLinkRequests = '''
CREATE TABLE IF NOT EXISTS auth_link_requests (
  request_id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL,
  outcome TEXT
)''';

/// Every statement needed to build the auth schema, in order.
List<String> authSchemaStatements() => [
  createAuthAccounts,
  createAuthMagicLinks,
  ...createAuthMagicLinkIndexes,
  createAuthSessions,
  ...createAuthSessionIndexes,
  createAuthLinkRequests,
];
