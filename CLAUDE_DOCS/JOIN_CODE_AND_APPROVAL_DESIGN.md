# One join code and an owner's approval — measurement and design

**Task 11.74. Written 2026-08-30 by Claude Code. No production code was changed
by the task that produced this file.**

**What this is.** Michael decided on 2026-08-30 that per-address invitations do
not scale to a real team and that joining should work the way joining a group
chat works: one code per project, and the owner decides who actually gets in.
That decision is settled and this document does not re-open any of it. What this
document does is measure the code the change lands in, say what the change costs,
and write down the design in enough detail that building it is transcription
rather than invention.

**Nothing here is built. This is for Michael to read and approve first.**

---

## Summary for someone who reads only this section

Today, **holding an invite code is being a member.** You type it in, the server
writes you a membership row, and you are on the project. The code is tied to one
email address, which is the only thing that makes an 8-character code safe: a
code somebody photographs off a whiteboard is useless to them.

Under the new design, **holding the code buys only the right to ask.** The owner
sees a request, picks a role, and approves it. A code that leaks stops being a
key and becomes an address.

**The single most important finding is that this change needs no database
migration on anybody's phone.** The join code, the requests, and the team-size
limit are all records the server keeps for itself — the same category the
existing invitation table is already in — so the app's own database, the sync
protocol version, and every device in the field are untouched. That was not
guaranteed going in and it is the difference between a week of work and a day of
it.

**The second most important finding is that a pending request must not be a
membership row.** It cannot be one even if we wanted it to be: the app and the
server both refuse a membership row whose role is not one of `owner`,
`contributor` or `viewer`, and the route that lists your projects does not look
at the role at all — so a "pending" membership row would show the requester the
project's name and its owner before anybody approved anything. Keeping the
request in its own server-side table makes the question disappear rather than
answering it.

**One thing the planning session assumed turned out to be half wrong.** It
assumed the server already knows the requester's name. It knows their **email**
— that is confirmed and solid — but it does **not** reliably know their name,
because a name only reaches the server through a project you already belong to.
Section 1.1 says what to do about it, and the answer costs nothing.

---

## 1. The five questions, answered as measurements

Each answer below is marked **measured** (I read the code and can cite it),
**partly measured**, or **unknown** (I could not determine it and say so).

### 1.1 Does the requester type anything at all?

**Measured — the email half of the assumption is confirmed. The name half is
false, and this is the one place the plan needs correcting.**

**The email: confirmed, no typing, no new door.** The redemption route accepts a
body with exactly one field in it — `code` — and nothing else
(`server/lib/src/projects/project_routes.dart:215-222`). The address it matches
against comes from `auth_accounts`, keyed on the session's user id
(`InviteService.authenticatedEmailOf`, `server/lib/src/projects/invite_service.dart`, deleted by task 11.81 (`9361d76`)).
There is no path by which a caller can supply an address. A join-request route
built the same way inherits that property unchanged.

**The name: the server does not reliably have one.** Three measurements:

1. `auth_accounts` has three columns — `user_id`, `email`, `created_at` — and
   none of them is a name (`server/lib/src/auth/auth_schema.dart:28-32`).
2. The display name lives on the synced `Users` row. A device offers its own
   `Users` row **only inside a push**, and every push on this server names one
   project and is refused unless the caller may write that project
   (`server/lib/src/sync/sync_routes.dart:526-576`;
   `server/lib/src/authz/project_authorizer.dart:66`).
3. This server has **17 routes in total** and not one of them accepts a profile
   (`/health`, seven `auth`, three `sync`, five `projects`, enumerated from
   `router.dart`, `auth_routes.dart`, `sync_routes.dart`, `project_routes.dart`).

Put together: **a person who has never belonged to a project on this server has
no `Users` row on it at all, and therefore no name.** That is precisely the
commonest case for a join request — a new teammate joining their first project.

**But this is not a regression, and that is what makes it cheap to accept.** The
same thing already happens today, one step later. When somebody redeems an
invitation the server mints their `Users` row with `'first_name': ''` and
`'last_name': ''`, and it does so **deliberately** — the comment is explicit that
the server "does not know this person's name and must not invent one"
(`invite_service.dart`, deleted by task 11.81 (`9361d76`)). The members screen already falls back from name
to email to raw user id (`ProjectMember.displayName`,
`lib/core/providers/membership_provider.dart:43-51`). So an owner today already
sees a nameless new member until that person's device syncs for the first time.

**Recommendation: the request carries no text at all.** The pending list shows

- **the server-authenticated email, always** — which is the identifier the owner
  actually shared the code with, and the one thing the server can vouch for; and
- **the display name only when the server already holds a `Users` row** — which
  is true for anybody who has been on any project here before, and becomes true
  for everyone else on their first sync after approval.

This keeps *"there is no new untrusted-text path"* **literally true**, not
approximately true. The length, control-character and right-to-left-override
questions never arise, because there is no string to ask them of.

**The alternative, stated so it is a decision rather than an omission.** We could
let the request carry the requester's own first and last name from their local
profile. It would not be a *new kind* of untrusted text — the `Users` table
already carries exactly that text and `RowValidator` already bounds it — but it
would be a **new door to it**, on a route reachable by anyone holding the code,
and it would have to be bounded identically or it becomes a way to write
attacker-chosen text onto a screen the owner reads. **My recommendation is not to
do it**, because the email already tells the owner who is asking and the name
arrives by itself a few seconds after approval. See §5, decision 1.

### 1.2 What enforces that a pending row is not a grant?

**Measured, and the answer is that there should be no pending row.**

**What the permission model currently rests on.** `SyncTable.insertIsAGrant` is a
per-table declaration with no default, so adding a table forces somebody to
decide (`packages/tritrack_sync/lib/src/sync_tables.dart:110-132`). It is true
for exactly three tables, and the comment on `Project_Memberships` is
one sentence: *"The row's existence **is** the permission"*
(`sync_tables.dart:366-379`).

**I enumerated every place that reads that table.** They fall into two groups.

**Group A — role-aware.** These go through the shared `resolveProjectRole` /
`resolveProjectOwners` in `packages/tritrack_sync/lib/src/project_roles.dart` and
`project_owners.dart`, which skip any row whose stint has ended, whose row is
tombstoned, or whose role string this build does not recognize:

| Where | File |
| --- | --- |
| The server's project-access gate | `server/lib/src/authz/project_authorizer.dart:227-243` |
| The server's per-row authorizer | `server/lib/src/authz/row_authorizer.dart:1553-1566` |
| The app's repository gate | `lib/data/repositories/base_repository.dart:349-373` |
| The app's shared role lookup | `lib/data/repositories/project_role_lookup.dart:26-56` |

**Group B — role-blind. These ask only "is the stint open".** They are the reason
a "pending membership row" is a bad idea:

| Where | What it would do wrong | File |
| --- | --- | --- |
| `GET /projects/mine` | **Would list the project — its name and its owner's user id — to the requester before approval.** The query filters on `end_date IS NULL AND deleted_at IS NULL` and never looks at `role`. | `server/lib/src/projects/project_directory_service.dart:70-76` |
| The already-a-member check on redemption | Would report a pending person as already a member | `server/lib/src/projects/invite_service.dart`, deleted by task 11.81 (`9361d76`) |
| The one-open-membership rule inside a push | Would treat a pending row as occupying the slot | `server/lib/src/authz/row_authorizer.dart:1567-1571` |
| `idx_memberships_one_open`, the database index behind that rule | Covers **every** role, by design | `server/lib/src/schema/postgres_schema.dart:446-450`, `lib/data/db/schema.dart:643-646` |
| The diagnostics console's member count | Would count people who are not members | `server/lib/src/diagnostics/diagnostics_repository.dart:86` |

**And two more things make a "pending role" impossible outright:**

- **Both sides of the wire refuse an unknown role.** `RowValidator` bounds
  `Project_Memberships.role` to the three values of `ProjectRole`
  (`packages/tritrack_sync/lib/src/row_validator.dart:275-276`). Adding a fourth
  means widening that enum, which then flows into the role gradient, the
  permissions matrix, `ProjectAccess`, and every screen that renders a role.
- **On the app side an unrecognized role silently *permits*.** `readProjectRole`
  returns null, and `assertRoleMayWrite` treats null as "this device cannot say,
  defer to the server" and lets the write through
  (`lib/data/repositories/base_repository.dart:184-185`). That is correct as an
  advisory check standing in front of an authoritative one — and it means a
  pending row would stop nothing locally.

**So the design is: a join request is not a membership-shaped row at all.**

It is a record in a **server-only table**, in exactly the category the invitation
table is already in. `invite_schema.dart:1-14` states the reason and it applies
here word for word: *"a synced invite row would put a grant-shaped record on
every member's phone."* The requests table is not in `tableSpecs`, not in
`syncTables`, never delivered by pull, never in a backup archive, never on
anybody's phone.

**The membership row is created only at approval, by the server**, from the
request's own `project_id` and the role the owner chose at that moment — the same
`SyncService.insertServerAuthoredRow` call redemption makes today
(`invite_service.dart`, deleted by task 11.81 (`9361d76`)). Nothing in any request body shapes it: not the
project, not the role, not the user. That is the property `_authorizeGrantingInsert`'s
long note says must be preserved and that redemption already has
(`row_authorizer.dart:893-900`).

**What this buys, and it is the whole argument for the shape:** not one of the
readers in Group A or Group B changes. `insertIsAGrant`'s sentence stays
literally true. There is no new predicate for a fourteenth reader to walk past —
which is this project's recurring defect class and the standing acceptance
criterion task 10.66 established.

**Enforced at the server, never by a screen.** Task 11.26's rule is satisfied
structurally rather than by a check: the owner's pending list and the members
list come from two different tables, one of which is not synced, so there is no
way for a screen to be showing a different list from the one the permission
model reads. There is no list to differ from.

### 1.3 The schema change, and what migration does to what exists

**Measured. The headline: no synced-schema change, and no client migration at
all.**

`latestSchemaVersion` stays **9** and `schemaMajorVersion` stays **2**
(`packages/tritrack_sync/lib/src/schema_constants.dart:105,133`). No
`Migration(10, …)`, no `schemaV10Statements()`, no new populated-upgrade test on
either side, and no device in the field has to chase a version.

That falls out of where the new tables live. Server-only tables are created by
`PostgresMigrations._ensureServerOnlyTables`, which runs every
`CREATE TABLE IF NOT EXISTS` on **every start**, before and independently of the
version check (`server/lib/src/db/postgres_database.dart:398-404, 462-473`), and
`ensureServerAppRole`'s `ALTER DEFAULT PRIVILEGES` already covers a table created
after the grant (task 10.89). Adding one costs a line in that list.

#### The two new tables

```sql
CREATE TABLE IF NOT EXISTS project_join_settings (
  project_id       TEXT PRIMARY KEY,
  code_hash        TEXT UNIQUE,          -- NULL when joining has never been turned on
  joining_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
  team_size_limit  INTEGER NOT NULL DEFAULT 50,
  rotated_at       TIMESTAMPTZ,
  rotated_by       TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by       TEXT
);

CREATE TABLE IF NOT EXISTS project_join_requests (
  request_id    TEXT PRIMARY KEY,
  project_id    TEXT NOT NULL,
  user_id       TEXT NOT NULL,
  email         TEXT NOT NULL,           -- the address the SERVER authenticated, copied at request time
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  device_id     TEXT,
  decided_at    TIMESTAMPTZ,
  decided_by    TEXT,
  decision      TEXT                     -- 'approved' | 'rejected' | 'cleared'
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_join_requests_one_pending
  ON project_join_requests (project_id, user_id) WHERE decided_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_join_requests_project
  ON project_join_requests (project_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_join_requests_user
  ON project_join_requests (user_id, requested_at DESC);
```

Four things in there are deliberate and each is copied from something that
already earned its place on this project:

- **Only the hash of the code is stored**, exactly as `project_invites` does, for
  the reason §4.2 gives: *a database read must not yield working codes.* **This
  is subject to decision 2 in §5** — there is a real argument for storing the
  code recoverably under this design, and Michael should make it rather than
  inherit it.
- **No foreign keys to `Projects` or `Users`**, matching every other server-only
  table, and for the reason `invite_schema.dart:39-43` states: those are synced
  tables whose rows arrive and are tombstoned on a client's schedule, and a join
  request must not be able to block or be cascaded by that.
- **The partial unique index mirrors `idx_memberships_one_open`.** One pending
  request per person per project, enforced by the database rather than by a read
  followed by a write — the same race, and the same fix, as task 11.10.
- **`email` is copied onto the request at the moment it is made**, from the
  session, so the owner's list needs no join against a `Users` row that may not
  exist.

#### What migration does to what exists

**Existing members: nothing at all.** Not one `Project_Memberships` row is read,
written, or reinterpreted. This is the direct payoff of §1.2's shape.

**A project with no code yet — which is every project that exists today.** There
is no `project_join_settings` row, and **no row means joining is off**. The
column default above is `FALSE` and the absent-row case must be read the same
way. The owner turns joining on, which is the action that mints the first code.

> **This is the single most dangerous line in the migration and it must be
> fail-closed.** A lazy "create the settings row on first read with joining
> enabled" would silently open every existing project to anyone holding a code
> nobody has issued yet. Do not write that. **The absence of a row means no, and
> a test should assert it.**

**Outstanding invitations.** How many live ones there are is **unknown — I could
not query the server from here.** Before migrating, run one statement against the
production database and record the number:

```sql
SELECT count(*) FROM project_invites
 WHERE redeemed_at IS NULL AND revoked_at IS NULL AND expires_at > now();
```

Given that the beta has not started and that the first backup that server ever
took was on 2026-08-31, the answer is very likely zero, in which case this whole
question is moot and should be recorded as moot rather than assumed away.

If it is not zero, the recommended handling is:

- **Keep the `project_invites` table. Do not drop it.** It is the record of who
  was let into which project and by whom, and that is worth more than the few
  kilobytes. Nothing new is ever written to it.
- **Stop issuing.** The two owner-side issue/revoke routes go.
- **Refuse redemption with a refusal that says what to do.** Keep
  `POST /projects/invites/redeem` mounted for one release, answering a new
  refusal code — `invite_flow_replaced` — which the app maps to its own copy:
  *"Invite codes have been replaced by a project join code. Ask the project owner
  for theirs."* Per §4.13 the server sends the code and the app writes the
  sentence; no server prose ever becomes user-facing copy.
- **Remove that route in the release after.** A stale client then gets a plain
  404, by which time nobody is running one.

> **Superseded, and done, 2026-09-01 (task 11.84).** The route was not kept for a
> release. The planning session ruled that a compatibility shim is for a fleet on the
> old build and **there is no fleet** — nothing has shipped, and the only devices
> running any build are Michael's two. `POST /projects/invites/redeem`, its
> `invite_flow_replaced` refusal code and the app copy that mapped it are all deleted;
> a stale client now gets a plain 404, asserted. The `project_invites` table is
> untouched.

**Test work this creates.** No migration tests, because there is no migration.
What is needed instead is a server-side suite for the new tables and routes, of
the shape `server/test/projects/invite_service_test.dart` already has, plus a
replacement for `server/test/integration/membership_and_invites_test.dart`. For
scale: **20 test files mention invitations today**, the heaviest being
`test/data/sync/fake_sync_transport.dart` (58 references),
`server/test/integration/membership_and_invites_test.dart` (39),
`server/test/integration/member_authorization_test.dart` (27),
`server/test/projects/invite_service_test.dart` (26) and
`test/data/sync/invite_redemption_test.dart` (19). Most of the rest touch it once
or twice. **The test rewrite is the larger half of this task's cost, not the
production code.**

### 1.4 Which routes go, which arrive, and what the inventory becomes

**Measured for what goes; designed for what arrives.**

#### Going

| Route | Inventory entry today |
| --- | --- |
| `GET /projects/<id>/invites` | 23 |
| `POST /projects/<id>/invites` | 23 |
| `POST /projects/<id>/invites/<inviteId>/revoke` | 23 |
| `POST /projects/invites/redeem` | 24 (**deleted outright 2026-09-01, task 11.84** — not kept for a release; see the note in §1.3) |

#### Arriving

**Owner side — all seven refuse anything but an owner, through the existing
`_requireOwner`, which answers the same 403 for "not yours" and "no such
project" (`project_routes.dart:262-283`).**

| Route | What it does |
| --- | --- |
| `GET /projects/<id>/join-settings` | Is joining on; the team-size limit; how many members and how many pending; when the code was last rotated. Whether it returns the code itself is **decision 2**. |
| `POST /projects/<id>/join-settings` | Sets `joining_enabled` and `team_size_limit`. |
| `POST /projects/<id>/join-code/rotate` | Mints a new code and returns the plaintext once. Body `{"clear_pending": false}`. |
| `GET /projects/<id>/join-requests` | The pending list: request id, email, name if known, when asked. Bounded by a `LIMIT` and ordered, for the reason `/projects/mine` was given one under task 11.64. |
| `POST /projects/<id>/join-requests/<requestId>/approve` | Body `{"role": "contributor"}`. Writes the membership row server-side. **One request at a time.** |
| `POST /projects/<id>/join-requests/<requestId>/reject` | **One request at a time. There is deliberately no bulk reject** — see §2.5. |
| `POST /projects/<id>/members/readmit` | The new meaning of "re-invite a past member". See §1.5. |

**Requester side**

| Route | What it does |
| --- | --- |
| `POST /projects/join-requests` | Body `{"code": "…"}` and nothing else. **No project id in the path**, for exactly the reason the redeem route has none (`project_routes.dart:195-201`): a route that took one would let a caller ask "does this code work for project X" and read the answer off the difference. |
| `GET /projects/join-requests/mine` | The caller's own outstanding and recently-decided requests, keyed on the session and nothing else. Without it a rejected person waits forever with no signal, which is the defect task 11.60 exists to have fixed for removed members. **Since task 11.83 it also carries `project_id` on an approved request — and only on an approved one — so the requester's device can complete the join by itself; see §2.3.** |

#### The security inventory — entries drafted before anything is built

These are written for `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md` §3, "Server —
Gate C". They are drafted now, ahead of the code, because that is the discipline
that has worked twice and is the answer to four drift findings. **They carry the
verdict `Unexamined`, and they must carry it until somebody attacks them** — a
new entry arriving already marked Hardened is the drift these entries exist to
stop.

> **Replace entry 23 with:**
>
> | 23 | **Join-code and join-request administration** (`GET`/`POST /projects/<id>/join-settings`, `POST /projects/<id>/join-code/rotate`, `GET /projects/<id>/join-requests`, `POST /projects/<id>/join-requests/<requestId>/approve`, `POST /projects/<id>/join-requests/<requestId>/reject`, `POST /projects/<id>/members/readmit`) — an owner turns joining on or off, rotates the code, sets the team-size limit, and admits or refuses one person at a time. **Replaces the per-address invitation routes** (task 11.74). Approval is the one place on this server where an owner's action creates somebody else's grant, and the role is chosen here rather than carried in the code | **Unexamined.** The seven attacks task 11.9 landed on the routes this replaces must be re-landed: a fictional project reading byte-identical to a forbidden one; an owner of A naming B's request id; a non-owner reaching every route; a role value outside the enum at approval; approval of an already-decided request; the team-size limit refused at the boundary and one past it; and rotation with `clear_pending` both ways. N-3 (issuance unbounded, nothing prunes) **does not carry over** — there is one code per project — but its shape does: nothing prunes decided requests, and that needs a bound before it is accepted |
>
> **Replace entry 24 with:**
>
> | 24 | **Join request creation** (`POST /projects/join-requests`) — the one route where an authenticated stranger asks to join a project they cannot otherwise see. **The code is now shared rather than bound to one address, which is a deliberate weakening of the credential and a deliberate strengthening of what it can do**: possessing it buys the right to ask, never membership (task 11.74) | **Unexamined.** The property to attack is that a correct code, a wrong code, a revoked code and a code for a project with joining switched off all fail to produce any access; that a request is refused when the team is full, counting pending; and that one caller cannot hold two pending requests on one project. **Two disclosures are inherent to the design and must be written down rather than discovered**: a correct guess reveals that a project exists and, if the response carries it, its name; and the requester's email reaches the owner's screen. Rate limiting is the only bound on guessing and must be measured, not assumed — the existing per-user redemption bucket (10 per 15 minutes, 40 per day) is the starting point and may need tightening now that a guess is worth something |
>
> **Add entry 29:**
>
> | 29 | **`GET /projects/join-requests/mine`** — the caller's own outstanding and recently-decided join requests. A **read**, like entries 27 and 28, and it exists so that a rejected requester is told rather than left waiting, which is the class task 11.60 found for removed members | **Unexamined.** Same questions entry 27 was asked and passed: that a caller-supplied `user_id` anywhere in the request is ignored; that the row set is bounded and rate-limited; that `cache-control: no-store` is set; and that a decided request discloses the decision and nothing else about the project or about who made it |

**One below-bar item carries straight over and should be named now rather than
rediscovered:** finding Q-1 — the project router writes **no audit rows at all**.
That was accepted while the router only issued invitations. Under this design the
router is where memberships are granted, so `AuthAuditEvent` should probably gain
entries for a request made, approved, rejected and cleared, and the code rotated.
That is the planning session's call and it is named in §5, decision 4.

### 1.5 What happens to "re-invite a past member"

**Measured for what it is today; designed for what it becomes.**

**What it is today.** An icon button — `Icons.person_add_alt_1`, no text label,
tooltip only — on each row of the Past members list, owner-only
(`lib/features/more/screens/project_members_screen.dart:180-207`, rendered at
:107-118). It opens the ordinary invite sheet pre-filled with that person's
address and their previous role (:128-148), retitled *"Invite them back"* with
the line *"This sends a new invitation for them to accept. Their previous time on
the project stays on the record."* (:492-496). It needs a local `Users` row
carrying their address, and is disabled with an explanatory tooltip when the
device does not have one.

**Why it cannot just be deleted.** It is the answer to a real and ordinary
situation: a field tech who was on last season's project is coming back. Under
the new flow, deleting it would mean the owner has to send that person the join
code and wait for them to ask — for somebody the owner already trusts, already
has on the roster, and already removed themselves.

**What it becomes: the owner re-admits them directly.** No code, no request, no
round trip. `POST /projects/<id>/members/readmit`, body `{"user_id": …, "role": …}`,
owner-only, and bounded by one condition that is what makes it safe:

> **The named person must already hold a closed membership row on this project —
> ended or tombstoned — and no open one.**

That condition does three things at once. It **discloses nothing**, because the
owner can already see that person on their own members screen. It **grants
nothing new**, because they were already in. And it means the route **cannot be
used to add a stranger** — it can only reverse a removal the owner themselves
made. It is the one membership insert an owner may make, and its bound comes from
the project's own history rather than from a list somebody maintains.

Two details:

- It **counts toward the team-size limit** like everything else, and is refused
  at the boundary with the same message.
- It writes a **new** membership row and never nulls `end_date` on the old one,
  which is already the rule redemption follows and the reason it follows it: the
  record of the prior stint is the point of keeping it
  (`invite_service.dart`, deleted by task 11.81 (`9361d76`)).

**This is better than what it replaces**, and worth saying so plainly: today
re-inviting somebody the owner already trusts makes them go and redeem a code.
Under this route the owner puts them back with one tap and their next sync picks
it up.

**The copy has to move with it.** The removal disclosure —

> *"Removing someone later stops their app syncing and blocks their access to the
> server — but it cannot delete the project data already downloaded to their
> device. Anything they have already synced, including exact locations, stays in
> their copy. Only invite people you are willing to trust with that."*

— currently gates the invite sheet with an unticked checkbox
(`project_members_screen.dart:22-27`, gate at :433-434). **Its new home is the
approval action**, because approval is now the moment an owner lets somebody in.
Re-admission should show it too. Nothing should let a person onto a project
without the owner having read that paragraph at least once.

---

## 2. The design, stated once

### 2.1 The code

One code per project, 8 characters of Crockford Base32, the existing format and
the existing `canonicalizeInviteCode` tolerance for case, hyphens and the
confusable glyphs (`packages/tritrack_sync/lib/src/invite_code.dart`). It is
meant to be emailed, sent over WhatsApp, or written on a whiteboard at a field
site, and that constraint is why it is 8 characters rather than a UUID.

**The entropy argument in that file's header is now false as written and must be
rewritten as part of this change.** It says 40 bits is acceptable *because* a
code redeems only for the address it names — *"An attacker who guesses a code
belonging to somebody else cannot use it."* Under a shared code that sentence is
no longer true. The replacement argument is Michael's own and it is a better one:
**a guessed code buys the right to ask, and the owner is the gate.** What 40 bits
now bounds is nuisance — a stranger appearing in an owner's pending list — rather
than access. **Leaving the old sentence in place would be exactly the defect task
11.54 was created to fix: copy describing a mechanism the code does not have.**

Whether 8 characters is still the right number is **decision 3** in §5.

**No expiry.** Invitations expire in 14 days because they are handed to one
person for one purpose. A project's join code is infrastructure — it is on the
whiteboard for the season. A hidden expiry would produce the *"the code stopped
working and nobody knows why"* failure this project keeps finding. The owner
switches joining off; nothing else turns it off.

### 2.2 Requesting

Signed in, one field on the wire (`code`), everything else from the session.
Refusals are uniform in the same way redemption's are today — wrong code,
unknown code, joining switched off, and project tombstoned all answer the same
thing — with two deliberate exceptions that carry real information to the person
and disclose nothing they do not already know about themselves:

- **already a member** — they hold an open membership; and
- **already asked** — they hold a pending request; and
- **the team is full** — which must say so plainly, and must say that pending
  requests count, because otherwise the owner and the requester will read a
  member count of 40 and a limit of 50 and neither will understand the refusal.

### 2.3 Approving

The owner sees the pending list, picks a role, approves. **Default contributor
unless changed.** The role is never in the code and never in the request — it is
chosen at approval and nowhere else, which is what makes a leaked code
uninteresting: it cannot be a leaked *owner* code because there is no such thing.

Approval writes the membership row the way redemption does today — server-side,
inside the transaction, from the request's own `project_id`, and it calls the
same `_makeIdentityReachable` step so the new member's `Users` and `User_Emails`
rows actually reach the other members' devices (`invite_service.dart`, deleted by task 11.81 (`9361d76`)).
That step is not optional: without it the owner's next pull carries a membership
row naming somebody whose `Users` row is missing and the app's own foreign key
refuses the whole page.

**How the requester finds out they are in.** ~~Nothing new is needed.~~
**Corrected 2026-08-31 by task 11.83, after Michael ran the flow on two real
devices: the Mac approved and the project never appeared on the iPhone, and
nothing errored.** The struck-out sentence was this document's defect, not the
build's — task 11.81 built exactly what was written here.

Both halves of the original claim were true and the conclusion drawn from them
was false. After approval the project *does* appear in `GET /projects/mine`, and
the "Join a project" screen *does* render it with a Join button
(`ProjectDirectoryClient.listAvailableToJoin`,
`lib/data/sync/project_joiner.dart`). **But the person has no reason to go back
to that screen and nothing tells them to** — and the one element that was
tracking their request, the "Your requests" card, filtered approvals out of its
own list, so at the exact moment the news arrived it went blank. That is task
11.60's class, *a person is not told the thing that happened to them*, on the
other side of the same door.

**What is actually needed, and is what task 11.83 built:**

1. **The device completes the approval by itself.** `JoinRequestWatcher` links
   and syncs the project the moment it sees one of this person's requests come
   back approved. A device that knows it has been let in and waits to be told
   again is the same silence in a new place. It reuses
   `MembershipController.joinApprovedProject` and `SyncEngine` — a first pull
   of a season's data is resumable and a second copy of that paging loop would
   be its own defect.
2. **`GET /projects/join-requests/mine` returns `project_id` on an approved
   request**, and on nothing else. The device cannot pull a project it cannot
   name. Approved-only is the whole disclosure argument: an approved requester
   is a member and `GET /projects/mine` hands them the same id, so nobody the
   owner has not admitted learns a project identifier from this route.
3. **The card narrates rather than vanishing.** Approval and rejection are told
   through one element in one place, on the projects screen as well as the join
   screen — the whole defect was that the truth was one screen away from where
   the person was looking.
4. **The device polls `GET /projects/join-requests/mine` every 60 seconds,
   foreground only, and only while a request is outstanding**, plus once on app
   resume, plus pull-to-refresh on the projects screen. It is **not** the sync
   tick and could not be: automatic sync runs against the *active, linked*
   project, and somebody joining their **first** project has no linked project,
   so there is no loop to piggyback on. 60 seconds is a quarter of
   `joinRequestListPerUser`'s 60-per-15-minutes, the bucket written for exactly
   this poll.

**What it promises, as numbers.** App open: at most 60 seconds from approval to
the project appearing, plus the download. App backgrounded: the moment it is
opened. **App closed: nothing arrives until it is opened**, and nothing here
changes that — delivering to a closed app means push notifications, which need
an Apple developer account this project does not have.

The screen also says *"waiting for approval"* while the request is pending, from
the same route.

### 2.4 Rotating and switching off

Rotation mints a new code and shows it once. **Pending requests survive by
default.** The rotation sequence — and only the rotation sequence — offers *"also
clear pending requests"*, defaulted off. It is not reachable by mis-tapping a
list, which is the whole point of putting it there.

Switching joining off leaves pending requests alone; they can still be approved.
Switching it off is not a way to clear the queue and should not be described as
one.

Cleared requests are marked `decision = 'cleared'` rather than deleted, so the
person's own status read tells them their request is gone rather than leaving
them staring at "pending" forever.

### 2.5 The team-size limit, and no bulk reject

**One limit per project, owner-changeable, default 50, and pending requests count
toward it.** The count is *open memberships of every role, including the owner,
plus undecided requests.* It is checked at the request route and at re-admission.
It is **not** checked at approval, because approving converts a pending request
into a member and leaves the total unchanged — which is the tidy consequence of
counting pending in the first place.

The owner may lower the limit below the current head count. Nobody is removed;
new requests are refused. The screen should say that plainly rather than making
it look like an error.

**There is no bulk reject, and this is Michael's reasoning rather than the
planning session's:** an accidental "reject all" forces every legitimate
requester to ask again and be contacted individually, and that accident is far
likelier than the flood it would defend against. **The more probable failure
wins.** The only bulk operation anywhere in this design is "also clear pending",
and it exists only behind a deliberate rotation.

---

## 3. What changes on the app side

No database migration. What changes is screens and one API client.

| File | Change |
| --- | --- |
| `lib/features/more/screens/project_members_screen.dart` | The Invitations section becomes a **Join code** section (on/off, the code, rotate, team-size limit, "48 of 50") and a **Pending requests** section (approve with a role, reject, one at a time). The re-invite button keeps its place and calls the re-admit route. The removal disclosure moves to approval and re-admission. |
| `lib/features/more/screens/join_project_screen.dart` | "Have an invite code?" becomes "Have a join code?"; the copy **"only work for the email address they were sent to" becomes false and must go**; a new "waiting for approval" state. |
| `lib/data/sync/sync_transport.dart` | The three invite methods go; eight new ones arrive; the refusal-code-to-copy map is rewritten (it currently lives at :182-204). |
| `lib/core/providers/membership_provider.dart` | `invite`, `redeemAndJoin` replaced by request / approve / reject / rotate / readmit. |
| `packages/tritrack_sync/lib/src/project_invites.dart` | Becomes the join-code wire contract. `RedeemInviteResponse` becomes a request response. The **refusal codes are the contract** and every new one needs app copy written for it, because no server prose is ever shown to a user (§4.13). |
| `packages/tritrack_sync/lib/src/invite_code.dart` | Format unchanged; **the entropy argument in the header must be rewritten** — see §2.1. |

**The copy that is about to become false, listed so none of it ships:**

- *"Codes expire, can only be used once, and only work for the email address they
  were sent to."* — `sync_transport.dart:182-204`
- *"It only works for the address above, expires in 14 days, and can be used
  once."* — `project_members_screen.dart:578-631`
- *"You will stop syncing it, and you will need a new invitation to rejoin."* —
  the Leave dialog, `projects_screen.dart:706-735`. It becomes *"you will need to
  ask to join again, or the owner can put you back."*
- *"…if you are ever invited back the project reappears with them."* — the
  departed-member delete warning, `projects_screen.dart:194-245`.

---

## 4. Why this is safer than what it replaces

Stated so nobody argues it the wrong way round.

**Today, possessing an invite code *is* membership.** The code is bound to an
address, which is the only thing holding that up: redemption matches the code
against the address the server authenticated for the calling session, so a code
that reaches the wrong hands is worthless. That binding is genuinely good and
it is doing real work.

**What it costs is that it does not scale**, and the cost is not theoretical: one
code per person, typed by the owner, one at a time, each expiring in 14 days,
each needing the owner to be online at the moment they issue it.

**Under this design, possessing the code buys only the right to ask, and the
owner is the gate.** A leaked code stops being a credential and becomes an
address. The things that could go wrong with a leak change from *a stranger is on
your project and can read every collar location* to *a stranger appears in your
pending list and you tap reject*.

**What genuinely gets weaker, said plainly:** a correct guess of the code now
confirms that a project exists, and — if the response carries it — its name. Under
the old design a guess confirmed nothing. That is inherent: you cannot tell
somebody "your request to join Project X has been sent" without confirming X
exists. The bound on it is the rate limit and the fact that a project id is not
being enumerated, only a code. **It should be written into the inventory entry
rather than discovered later**, which is what the entry 24 draft above does.

---

## 5. Decisions only Michael can make

> **ALL FIVE ANSWERED BY MICHAEL, 2026-08-31. They are settled — the build task
> transcribes them and does not re-open them.**
>
> **1. The name comes with the request — recommendation overruled, and his reason is
> better than the recommendation.** *"What if someone has a nonrecognizable email? The
> owner might not know the email addresses of the people. Names would be an important
> part of the verification for approval."* That is correct and it is the point of the
> screen: an owner deciding whether to admit somebody needs something they can
> recognize, and `f.lastname@nau.edu` is not it. **Consequence, to be designed rather
> than discovered:** this reintroduces the untrusted-text path the design had removed,
> so the name **must carry exactly the bounds `Users.first_name` already has** —
> length, control characters, and **bidirectional-override characters**, which matter
> more here than anywhere else in the app because **this is the one screen where a
> person decides whether to trust somebody by reading a string.** A name that displays
> as a colleague's is the attack this screen is uniquely exposed to.
> **And present the two differently, because they are not equally trustworthy:** the
> email is **server-authenticated**, the name is **what the requester says they are
> called.** Pre-fill it from their profile so most people type nothing, but it is
> caller-supplied and the screen should not imply otherwise.
>
> **2. Store the join code readably — recommendation accepted.** §4.2 gains a **named,
> written exception** rather than a quiet one, with the reasoning: §4.2 governs
> credentials, and a join code is no longer one.
>
> **3. Eight characters stays — fresh yes given.**
>
> **4. Approvals, rejections and rotations are recorded — recommendation accepted.**
> **This supersedes finding Q-1's acceptance**, which was granted while that router
> only issued invitations. It is now where membership is granted, and it will write
> audit rows. No separate task; it belongs to the build.
>
> **5. No expiry on a join code — confirmed out loud**, as asked.


**1. Does the request carry the requester's name?**
My recommendation: **no.** The email is server-authenticated, is what he shared
the code with, and is what the members screen already falls back to today. The
name arrives by itself on their first sync after approval. Saying no keeps "no
new untrusted text" literally true. Saying yes means the pending screen renders a
string a stranger chose, and it must be bounded exactly as `Users.first_name`
already is.

**2. Can the owner read the join code again after they close the screen?**
Today an invite code exists in plaintext exactly once and is stored only as a
hash, per §4.2's rule that a database read must not yield working tokens.

- **Keep it that way.** Losing the code means rotating. **But rotation is not
  free under a shared code the way it was under a per-person one** — it kills the
  copy on the whiteboard, in the WhatsApp thread, and in everyone's notes, and
  the owner has to re-broadcast.
- **Store it readably**, so the owner can look it up. This is an exception to
  §4.2 and must be **written into §4.2 as a named exception**, not slipped in.
  The argument for it is Michael's own: §4.2 is about *credentials*, and a join
  code is no longer one. Somebody holding a database dump already has the field
  data; the marginal harm of them also being able to ask to join is close to
  zero.

**My recommendation is to store it readably and write the exception down**,
because the failure mode of the alternative — a field team's whiteboard code goes
dead because the owner lost their phone — is an operational failure, and the
failure mode of this one is an exposure Michael has already accepted by design.
**But this is his call, because it is a written security rule and I am proposing
an exception to it.**

**3. Is 8 characters still enough?** The old justification (a guess is useless to
anyone but the invited address) is gone. The new one is that a guess buys only
the right to ask. 8 characters is about a thousand billion possibilities, and the
rate limit is 10 attempts per 15 minutes per signed-in account. I think 8 is
still right and the code's readability in the field matters more, but the number
was chosen under an argument that no longer holds, so it deserves a fresh yes.

**4. Should granting membership be audited?** The project router writes no audit
rows today — that is finding Q-1, accepted while the router only issued
invitations. It is now where memberships are granted. I think approvals,
rejections and rotations should be recorded, but that is a plan decision and I
have not built it.

**5. Confirm there is no expiry on a join code** (§2.1). I have designed it with
none. Say so out loud, because "the code stopped working and nobody knows why" is
a failure this project has hit before.

---

## 6. What this design deliberately does not do

- **It does not touch the app's database, the sync protocol, or any device in the
  field.** No version moves.
- **It does not add a fourth role.** `ProjectRole` stays `owner`, `contributor`,
  `viewer`.
- **It does not put a pending person anywhere the permission model looks.**
- **It does not add bulk reject**, and the reason is written down in §2.5 so
  nobody adds it later as an obvious convenience.
- **It does not carry the role in the code**, and there are no per-role codes.
- **It does not delete the invitation history.** `project_invites` stays as the
  record of who was let in and by whom.
