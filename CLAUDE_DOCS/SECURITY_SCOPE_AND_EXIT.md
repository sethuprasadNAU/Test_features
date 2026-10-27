# Security scope and exit criteria

**Written 2026-08-16, after Gate C failed for the seventh time.** This document
exists because the gate had no boundary. It defines what is in scope, what
counts as blocking, what happens to everything else, and what "done" means.

**Authoritative for scope.** `TriTrack_Security_Model.md` remains authoritative
for findings and decisions; `DEVELOPMENT_PLAN.md` for tasks. This file governs
*what the gate may look at and when it may stop.*

---

## 1. The premise

Nothing is infinitely secure, and no amount of review makes a system safe in the
absolute. Security review is risk management, and it terminates only when three
things are bounded:

1. **The surface** — an enumerated list of places untrusted data enters.
2. **The bar** — a written definition of what severity blocks.
3. **The disposition of everything below the bar** — an explicit, recorded
   acceptance rather than a task nobody scheduled.

**Seven gates have run and none of the three was bounded.** Each round the gate
chose its own surface, treated every finding as needing a task, and so generated
more work than it closed. The last round closed two blocking items and opened
three blocking plus thirteen non-blocking. That is not a failing codebase — no
previous fix regressed, and the sync interface has come back clean three rounds
running — it is an unbounded question being asked repeatedly.

**The planning failure was mine.** This document should have been the first
artifact of Phase 10, before task 10.0.

---

## 2. Two gates, not one

Gate C's stated condition has always been *"the server may not listen beyond
localhost."* Findings L-2 and L-3 need no server, no network and no account.
They are serious, and they were blocking a decision they have nothing to do
with.

| | **Gate C — network exposure** | **Gate D — app data integrity** |
| --- | --- | --- |
| **Question** | May the server listen beyond localhost? | May the app ship to a beta team? |
| **Surface** | Inventory items 14–20 **and 23–28** | Inventory items 1–13 **and 21–22** |
| **Blocks** | Deployment, Phase 11 | The March beta, any release |
| **Current blockers** | **The NAU review, and nothing else — and as of 2026-08-30 that sentence is finally true rather than true-sounding.** Every server inventory entry now carries a verdict **and** a failed live attack from the round that is happening (§21). What made the same claim wrong for the last two weeks was criterion 1's "from the current round": entries 14–20 were carrying 17 August and 23–26 were carrying 22 August, because the checks that produced them were never committed. They are committed now, so the evidence is reproducible rather than remembered. L-1 and M-11 both re-refused live this round | **none** |
| **Verdict prerequisite** | met — §16.1 | met — §16.1 |
| **Verdict (2026-08-17, §16)** | **FAILS on criterion 5 alone.** Criteria 1–4 all met for the first time | **PASSES.** All four criteria met; the default suite ran green four consecutive times |
| **Team-surface re-run (2026-08-22, task 11.9, §18)** | **Unchanged — still fails on criterion 5 alone.** Entries 23–26 added and all Hardened on failed live attacks | **Unchanged — still passes.** Entries 21–22 added and both Hardened. One open finding (N-1), below the bar, §18.3 |
| **The two reads (2026-08-29, task 11.49, §20)** | **Not a gate run — the two entries that had no verdict now have one.** Entries 27 and 28 Hardened on failed live attacks, every probe watched to fail against a deliberately broken server. **Criterion 1 now turns entirely on "from the current round"**, which §6.1 priced. Four findings, none at the bar (P-1…P-4) | Untouched — this task's surface is Gate C's |
| **The ninth run (2026-08-30, task 11.64, §21)** | **Still fails on criterion 5 alone — and criterion 1 is met for the first time.** Round 8's hand-written checks and its twelve-shape refusal matrix are now committed instruments, so entries 14, 15, 17 and 20 were re-attacked as part of a **3 min 45 s** run rather than a half-day one. Finding P-1 closed. One new finding, below the bar (Q-1) | **Unchanged — still passes.** 1520 passed, 12 skipped; no client entry re-opened |

A finding belongs to the gate whose surface it lives on. It does not block the
other one.

---

## 3. The surface — trust-boundary inventory

**This is the finite list.** Every place data crosses into TriTrack from
somewhere the app does not control. If a path is not here, it is out of scope.
If a new one is discovered, it is **added here first**, then attacked — it does
not block the run in progress unless it meets §4's bar.

Each entry carries a verdict: **Hardened** (a live attack was attempted and
failed), **Accepted** (in the register, with a reason), **Open** (has an owning
task), or **Unexamined**.

### Client — Gate D

| # | Path | Verdict |
| --- | --- | --- |
| 1 | `TT1:` share payload (clipboard/paste) | Hardened — J-1, §4.19. Re-attacked round 8: five clock forgeries and a foreign-author payload all refused, §16.2 |
| 2 | Project `.zip` import (file picker) | Hardened — K-1, §4.19.2; L-2 and L-12 closed by 10.93, §15.10. Re-attacked round 8: ceiling, freeze, NaN/Infinity coordinates, cross-project scope, tombstone and email rewrite all refused or consent-gated, §16.2. M-17 registers the freeze bound's measurement |
| 3 | Own backup restore (same codec as 2) | Hardened with 2 — including the ceiling round trip: an imported row at the ceiling plus one honest edit is refused by the holder's own export, which is L-2's harm, and the headroom is what prevents it (§16.2) |
| 4 | ~~Linked cloud backup folder (third party can write)~~ | **RETIRED 2026-08-29 — the surface no longer exists (task 11.30).** The automatic cloud backup is removed from the code and the interface: the settings model, its provider, the scheduler, the service, the iOS and Android platform channels that linked the folder, and the UI section are all deleted, and no code path in this app can now write to a third-party cloud folder. Server sync replaces it; the manual export paths are untouched and remain entries 2, 3 and 6. **Nothing here was hardened — it was removed**, which is why this row is struck through rather than re-verdicted. Consequences: task 10.84 (archive encryption / key custody) and task 10.85 (the folder as a write surface) both lose their subject, and §4.15.1's time-bounded acceptance of the unencrypted payload is closed as **overtaken** rather than renewed |
| 5 | CSV / tag import | Hardened on identity and clock — §14.8, §15.8. L-15 and M-2 closed by 10.94 and both re-measured live round 8: no header alias reaches any of nine identity/clock columns, and a NaN frequency rolled the whole commit back (0 of 3 written), §16.2. One bound open — 10.97 |
| 6 | CSV / text **export** — the recipient is the victim | Hardened — L-3 closed by 10.94, §4.19.4, §15.10. Re-measured in Excel again at round 8 against four leading-character bypass candidates (NBSP, vertical tab, BOM, RTL-override): all inert, §16.3 M-14 |
| 7 | Deep links, URL schemes, initial route | Hardened — K-3, 10.77. All five controls verified present in the real platform files round 8; no test asserts them — M-16, accepted |
| 8 | Server sync pull (rows authored elsewhere) | Hardened — C-1…C-5, D-1 |
| 9 | Server identity adoption (server-chosen `user_id`) | Hardened — K-4, 10.75. Re-attacked round 8: seven of eight hostile ids refused before any write, and a server naming an id held for a different person refused (M-15 is the eighth), §16.2 |
| 10 | Unknown-column store (values stashed from 1, 2, 8) | Hardened — K-5, 10.76. Re-attacked round 8 with five hostile columns: 2 refused at `hold`, 3 held, 0 promoted, database intact, §16.2 |
| 11 | Map tile and elevation tile downloads (third-party HTTP) | Accepted on disclosure — §5.8 names AWS and elevation. Open on ingestion — M-6, M-8, 10.107 |
| 12 | Local app-controlled state on disk — database, SharedPreferences, region/DEM/tile caches | Accepted — device disk encryption, §7.7. Widened: the prefs blob also selects the sync peer, but sandbox access already grants the database itself, so there is no escalation |
| 13 | Platform sensors and permissions | Accepted — no adversarial input path |
| 21 | **Teammates' rows arriving through pull** — since task 11.2 the rows a device merges are authored by *other people with different rights*, not by the same user on another device. Widens item 8, which assumed the latter | Hardened — task 11.9, §18.2. Four fresh attacks on a teammate's identity rows refused live. **One finding: N-1** — a contributor may name a teammate as the author of a record they never made (§18.3) |
| 22 | **`Observation_Exclusions`** — the table behind "exclude this observation from the analysis": the only write in this app where one person acts on somebody else's record, and the only one that names a row it does not own | Hardened — task 11.9, §18.2, §4.22. Seven attacks on the two rungs and the withdrawal rule refused live. The reference question is answered and **accepted** with its condition written down (N-2) |

### Server — Gate C

| # | Path | Verdict |
| --- | --- | --- |
| 14 | Sync routes — push envelope, and `pull`/`ack` cursors | Hardened — J-4, J-5, 10.64, 10.67. **Round 9 (2026-08-30): 95 checks held**, and unlike round 8's forty they are **committed** — `scripts/verify_round8_server_surface.py`, watched to fail (16 of 16 required attacks flip against a server whose envelope stops telling a wrongly-typed integer from an absent one). Cursor and batch-size type confusion, `null` proved byte-identical to absent, row-container confusion at all three levels, nine invented table names, duplicate JSON keys in both orderings, 2000-deep nesting, 5000 undeclared columns, a body past the transport bound. No 500 anywhere, §21.2. One bound open (L-7, M-1) — 10.97; ack bound registered as M-13 |
| 15 | Auth routes (magic link, redeem, sessions) and `GET /projects/mine` | Hardened — Gate A, 10.56, and **task 11.64 (2026-08-30), which closed finding P-1**. **48 committed checks on the routes** (every field on `/auth/magic-link` and `/auth/redeem` wrong-typed, oversized, control-character-bearing and missing; eight bearer shapes on `/projects/mine`) plus **31 on `/projects/mine` as a *read*** — the questions it had never been asked. Eleven places a caller can put somebody else's `user_id` are all ignored; §4.28 now states the four fields a row may carry and why `owner_user_id` is kept; a `LIMIT`, a per-user rate limit and `cache-control: no-store` were added and each was watched refusing. The audit and traffic logs are this item's and 14's write sink, owned by 10.81/10.83. One below-bar finding: the project router writes no audit rows at all — Q-1, accepted at the time and **SUPERSEDED 2026-08-31 by task 11.81**. The acceptance was granted while that router only issued invitations; task 11.81 made it the place membership is *granted*, so it now writes audit rows for a join request made, approved, rejected and cleared, for a code rotated, for joining switched on or off, and for the team-size limit changed. §21.4 |
| 16 | Backup archive restore (server side) | Hardened — H-6, I-2, 10.43, 10.53. Drill and forged-archive refusal both green round 8. **Evidence restored 2026-08-30 (task 11.70):** task 11.69 had made the drills pass on Linux by overriding the container user, which left them green while the *shipped* procedure stayed broken — a control no longer measuring what it is cited for. Both overrides are removed; the drills now take the user from the same compose declaration an operator gets, and a new step 0 fails if it is not the invoking user (watched failing). **This entry's evidence measures the documented procedure again** |
| 17 | Deployment configuration and environment | **Hardened — the twelve-shape refusal matrix is now committed** (`scripts/verify_deployment_refusal_matrix.sh`, task 11.64) and was re-run 2026-08-30: **10 shapes refused with `EXIT 78`, 2 started.** L-1's `,` and `',, ,,'`, nothing declared, whitespace, `none` on a reachable deployment, an allowlist with no source-identity answer and one with a junk answer, and an unparseable publish address all refuse — and **M-11's `0.0.0.0/0` and `::/0` now refuse too**, where round 8 watched both start (closed by 10.108). Every refusal is additionally checked for naming the variable it refuses on, so a refusal for the wrong reason (§4.24) fails the matrix, and the matrix fails itself if no shape refuses or none starts. §21.2 **Updated 2026-09-21: "twelve-shape" is the size it was on 2026-08-30 and this row kept saying so while the script grew twice without it. Measured 2026-09-20 (task 11.287): 20 shapes, 16 refusing and 4 starting** — it stood at 17 before that task, which added the two SMTP refusals and their control. **The number is in the row because it is checkable; it went stale because nothing checks it**, and that is the same shape as the count findings in defect-vocabulary entry 27. Read it from `scripts/verify_deployment_refusal_matrix.sh` rather than from here. |
| 18 | Postgres role and privileges | Hardened — 10.63, 10.89, 10.83. Re-verified round 8 against real Postgres: `NOSUPERUSER`, and `DELETE`/`TRUNCATE` on both audit tables fail `42501` |
| 19 | Reverse proxy / TLS termination | Hardened — 10.49, 10.74; 7 checks green round 8. **Re-measured by Michael on 2026-08-30 on the Ubuntu VM, PASS on both shapes** — two real off-host callers (192.168.0.153 and 192.168.0.152, two phones) stayed distinct on the direct shape and on the TLS overlay; 13 checks; `PRESERVED` both. **This is the only server entry carrying evidence from the current round**, and task 11.64 should count it rather than re-running it. Host details to be recorded beside the declaration per §4.4.3. Previously **measured and licensed 2026-08-17** — both shapes PRESERVED with real off-host callers, 13 checks (10.88, §4.4.3). Qualifies that run, not the platform |
| 20 | Dev magic-link sender — an unauthenticated body names a file on disk, and it is the server's only subprocess call | Accepted — §15.3 M-9: refused under `TRITRACK_ENV=production`, no path separator survives the sanitiser, and the subprocess takes an argument list rather than a shell string. **Re-measured 2026-08-30 with committed checks** (task 11.64): five traversal addresses written, every separator became `_`, every file mode 600, and **`find / -xdev -name '*.link'` across the whole container filesystem found nothing outside the link directory** — asked of the container rather than of the host bind mount, and of everywhere rather than of the places somebody expected the attacker to go. **Corrected 2026-08-30 (task 11.71): the sentence that used to end this entry — "watched to fail: with the sanitiser deleted, the escape appears and the probe goes red" — was false when it was written.** The broken-control harness ran it for real that day and the escape check stayed `refused` against a server whose sanitiser had been deleted, so for two rounds it was reporting nothing. The check was looking in the right place; **round 8's attack corpus contained no address that could reach it** — on Linux four of the five cannot leave the directory at all, and the fifth (`/etc`) is refused by the filesystem because the container runs unprivileged, not by the sanitiser. **Now closed rather than excused:** the instrument asks the container which directories outside the link directory it can actually write to, aims an address at one, carries a new positive control that plants a `.link` where an escape would land and requires the same search to see it, and fails the run if no such directory exists. **Watched to fail for real on 2026-08-30**: with the sanitiser deleted the escape lands in `/tmp` and both that address and the filesystem-wide search flip to ADMITTED (9 of 9 required flips), while the same instrument returns 155 clean checks against the intact server. **The sanitiser is therefore load-bearing and is now known to be** — see §15.3 M-9 for what the unprivileged user does and does not cover |
| 23 | **Join-code and join-request administration** (`GET`/`POST /projects/<id>/join-settings`, `POST /projects/<id>/join-code/rotate`, `GET /projects/<id>/join-requests`, `POST /projects/<id>/join-requests/<requestId>/approve`, `POST /projects/<id>/join-requests/<requestId>/reject`, `POST /projects/<id>/members/readmit`) — an owner turns joining on or off, rotates the code, sets the team-size limit, and admits or refuses one person at a time. **Replaces the per-address invitation routes** (tasks 11.74, 11.81). Approval is the one place on this server where an owner’s action creates somebody else’s grant, and the role is chosen here rather than carried in the code | **Hardened — task 11.85, round 9, 2026-08-31.** All seven attacks re-landed live on the routes that replaced the invitation ones, plus the readmission bound. **The owner-only route set is derived from `project_routes.dart` rather than listed**, and the count is asserted, so a route added later is attacked or the instrument goes red — which is the defect that let this entry keep a verdict earned against routes that no longer existed. **63 refusals across the seven routes** (an outsider, a contributor and a viewer against each), and each route answers a fabricated project id **byte-identically** to a forbidden real one. Project Q's owner naming project P's request id was refused at both approve and reject, and the request stayed undecided. Ten role values outside the enum were refused at approval and at readmission; readmission refused a stranger and refused somebody whose only tie to the project was a pending request. **The team-size limit was watched refusing at the boundary and one past it, with pending requests counting toward it** — a third person refused while a request was pending, refused again once that person was a member, and admitted the moment the limit was raised by one. Rotation was measured both ways: without `clear_pending` the queue survived and the superseded code stopped working, with it two undecided requests became `cleared` and their owners were told rather than left reading "pending". A second approval at a higher role was refused, left no second membership row, and **the first run of the broken-control harness measured which control does that**: the `decided_at IS NULL` clause is belt-and-braces and `idx_memberships_one_open` is what actually refuses. **N-3's shape carries over and is now measured rather than argued**: nothing prunes decided requests — six rejections on a fresh project left six rows, and the only bound is the 200-row cap on what the two list routes *return*, which bounds the response and not the table. **Finding R-2** is the disclosure that keeps open because of it (see entry 29); task 11.79 is where the retention bound gets built. **Every probe watched to fail** against a build with `_requireOwner` bypassed and against one with the grant and decision controls removed (`scripts/verify_11_85_broken_control.py`) |
| 24 | **Join request creation** (`POST /projects/join-requests`) — the one route where an authenticated stranger asks to join a project they cannot otherwise see. **The code is now shared rather than bound to one address, which is a deliberate weakening of the credential and a deliberate strengthening of what it can do**: possessing it buys the right to ask, never membership (tasks 11.74, 11.81). **And it carries one caller-supplied string — the requester’s claimed name** (Michael’s decision 1, 2026-08-31), which is the untrusted-text path the design had removed and put back on purpose | **Hardened — task 11.85, round 9, 2026-08-31, with one registered finding (R-1).** A guessed code, a code for a project whose owner had switched joining off, one for a project since deleted, one a rotation had replaced, a malformed one, an over-length one and one of the right shape naming nothing **all drew a single byte-identical refusal** (`join_code_not_valid`, one distinct answer across all seven), and the `O`/`0` folding was checked not to be a second oracle. A pending requester could pull nothing of the project and could not write themselves the membership. A second pending request on the same project was refused; a member asking again was refused as a member. **A request carrying `role`, `project_id` and `user_id` was accepted and none of them reached anything** — the owner's screen showed only the seven documented fields with the server-authenticated address, and the role the owner chose (`viewer`) is the role that landed. **The claimed name was attacked as untrusted text, sixteen ways**: over-length by one, NUL, newline, carriage return, DEL, a C1 control, and ten bidirectional overrides, marks and isolates — all refused — while an ordinary name, a Hebrew name, an Arabic name, a name at the length bound and no name at all were all accepted and stored byte-for-byte. **Two got through, and that is finding R-1**: `U+2028 LINE SEPARATOR` and `U+2029 PARAGRAPH SEPARATOR` are line terminators rather than bidirectional controls, so a claimed name may carry a hard line break. **The rendering question was answered by measurement rather than by reading the string**: `test/features/more/join_request_name_rendering_test.dart` reads the break offsets off the tile's own render object and finds the line breaking exactly where the requester put it — and finds that the tile's **title**, the server-authenticated address, is untouched, that the claim is still prefixed "Says they are", and that six requester-chosen lines grow the tile rather than clipping its own text. Registered, not blocking; §5 carries the reasoning. **Rate limiting is measured, not assumed**: the per-account bucket admitted **10** guesses and refused the eleventh, in **40 ms of wall time** — it bounds the count per account and not the rate, there is no delay and no backoff, and the exhausted account could not slip a real code past the limit while a different account was unaffected. Against 40 bits of code entropy that is an adequate bound on guessing and an inadequate one on nuisance; both halves are now numbers. **Every probe watched to fail** against a build with the bidirectional class deleted from the validator and the owner's role choice ignored |
| 25 | **Membership and role mutation on the push path** — a device pushing `Project_Memberships` rows directly, where the row's existence *is* the grant | Hardened — task 11.9, §18.2. Six escalation attempts refused, including by the project's own owner; the last-owner guard refused all three removal shapes and the two-in-one-batch case |
| 26 | **Cross-project isolation and the role gradient across every Phase 11 endpoint** | Hardened — task 11.9, §18.2. A viewer's push into every project-scoped table drew nothing but refusals while a contributor's identical batch was accepted; a removed member's access closes from the next request; a refused row does not vouch for a later one in the same push |

| 27 | **`GET /auth/sessions`** — the caller's own signed-in devices. New in task 11.35, given a caller by task 11.36, and a **read**, unlike every other Phase 11 entry: the risk it carries is disclosure, not mutation | **Hardened — task 11.49, 2026-08-29, §20.2.** Fifty-eight attacks refused live. A victim's `user_id` was pushed at it through a query string, a `GET` body, five headers, a cookie, a repeat, an array, a `POST`, a path segment and a traversal; two session tokens were presented at once as genuinely duplicated headers; six malformed credentials and five malformed schemes were tried. The response was searched for a token, the SHA-256 the server stores, an email, a `user_id`, a real `session_id` read out of Postgres, and anything shaped like an address — **the no-source-address decision was attacked rather than read**, and the server does hold an address for the same caller elsewhere. The 100-row bound was watched refusing at 151 live sessions, the 60-per-15-minute limit was watched refusing on the 61st read, and a revoked device left the list on the very next request while its row stayed in the database. **Every probe was watched to fail** against two deliberately broken builds (`scripts/verify_11_49_broken_control.py`) |

| 28 | **`POST /sync/pull` answering a caller whose stint on the project has ended** — the **closed-membership disclosure exemption**. Every other project-scoped read on this server refuses a caller with no open membership; this one hands back exactly their own `Project_Memberships` rows whose stint is over, and refuses everything else about the project. New in task 11.60, and, like entry 27, a **read**: the risk it carries is disclosure and existence confirmation, not mutation | **Hardened — task 11.49, 2026-08-29, §20.3.** The existence-oracle property was demonstrated live, not asserted: a prober who *can* reach the disclosure on one project got **byte-identical** answers for a fictional project id and for a stranger's real one, and so did a caller who can never reach the branch. Attempts to manufacture the key it fires on — writing yourself a closed membership on somebody else's project, on a fictional one, and from a member of a different project — were all refused, and none changed what either id answers. The page was confirmed to carry one table, only the caller's own rows, no open stint, no `Projects` row, no `Users` row for the account that ended the stint, and none of the server's own bookkeeping columns; a huge `batch_size`, a cursor past the end, a negative cursor, and a `user_id` or foreign `device_id` in the body all returned the same one page. **The timing claim task 11.60 left unmeasured is now measured with numbers** (§20.3), and **every probe was watched to fail** against a build deliberately rebuilt into a `404`-versus-`403` oracle. The test file `closed_membership_disclosure_test.dart` is the in-process half; three documents and one comment used to cite an `existence_oracle_test.dart` that never existed, corrected by the same task (P-2). **Amended 2026-08-30 (task 11.72): the timing claim was measured on the wrong machine and was wrong.** The same probe on a clean Linux runner found the refusal for a project that really exists running **about 54 microseconds slower**, sign positive in 9 of 9 trials on each of three runs, with the null pair flipping every run. The cause was `ProjectAuthorizer.resolve` reading **every membership row of the project**, so the leak was a monotone reading of how many people are on a project the caller cannot see, not a single existence bit. **Closed by narrowing both statements to a result whose size does not depend on the project** (§4.13, "The clock is a channel too"), which takes both differences down by a factor of forty to a hundred — to +5.0 µs on the existence pair and +2.3 µs on the team-size pair, against a measured per-id noise floor of 4.1 µs on the same runner. **The few microseconds that remain are accepted in writing there, by Claude Code on 2026-08-30 and subject to Michael's review**, with the reason (an index probe that finds a row does a heap fetch and one that finds nothing does not) and a reopen condition that is a check rather than a promise; the byte-identical and key-manufacturing findings above are unaffected and still stand. The measurement now lives in `server/test/security/authorization_timing_test.dart`, which runs on every commit, carries a positive control that makes it fail rather than pass on a host that cannot resolve the effect, and has been watched to fail |

| 29 | **`GET /projects/join-requests/mine`** — the caller’s own outstanding and recently-decided join requests. A **read**, like entries 27 and 28, and it exists so that a rejected requester is told rather than left waiting, which is the class task 11.60 found for removed members | **Hardened — task 11.85, round 9, 2026-08-31, with one registered finding (R-2).** Asked every question entry 27 was asked and passed. A caller-supplied `user_id` was pushed at it **ten ways** — query string, `GET` body, `X-User-Id`, `X-Forwarded-User`, a bare `user-id` header, `On-Behalf-Of`, a cookie, a repeat, an array, and a `request_id` — and every one returned exactly the caller's own single request; an unrecognized bearer draws `401`, so the route is authenticated at all. `cache-control: no-store` is set. **The 200-row bound was watched refusing** against a database-seeded account holding 225 requests, and a `limit=` in the query string did not raise it; the 60-per-15-minute limit was watched refusing on the 61st read, the refusal carried no list, and a second caller was not locked out. **The `project_id` argument was attacked rather than inherited, and it holds**: on all four decision states the field set is exactly the six the design names, `project_id` is present **only** on the approved request, and that requester reads the same id from `GET /projects/mine` — while the rejected requester's directory names nothing. **What the entry's wording got wrong is finding R-2**: `project_name` comes from a join against the **live** `Projects` row and nothing prunes a decided request, so a person the owner refused goes on reading whatever the project is called — watched changing from one name to another after a rename. A project that is *deleted* does drop out, which is the one place this route closes behind itself. Registered, not blocking; §5 carries the reasoning. **Watched to fail** against a build whose query is unscoped and which returns `project_id` on every decision — and **the first run of that harness caught this instrument being blind**: the ten redirection probes took their reference from the route under test, so they reported `refused` against a server with no scoping at all. The reference is now the request id the fixture created |

| 30 | **`POST /projects/<projectId>/deletion` and `GET /projects/<projectId>/deletion`** — an owner schedules, cancels or immediately carries out the destruction of a project **and every member's records in it**. New in task 11.290 (2026-09-20) | **Answered live, 2026-09-24: nothing admitted, and the probe can fail.** The full gate at `fe9cfbbe` passed 25 of 25 on the gate VM with probes 8 and 8a clean, and the 11.85 drill's `owner` and `deletion-scope` variants then flipped every attack they were required to (task 11.311's report, commits `17d6fde`, `9489d0e`). **Answered again live, 2026-09-28, with task 11.312's additions:** the gate at `3c08c39` passed 25 of 25 with `verify_11_9_team_surface.py` clean (373 checks, none admitted), and the 11.85 drill then flipped every required attack in all five variants — including the new two: `owner` flipped *DV's owner removed by a co-owner reaching 'schedule'*, and `restore-any-owner` flipped *DR's co-owner who did not delete it restoring project DR* (task 11.312's comms entry). The round was written 2026-09-23. These routes were live from 2026-09-20 and not inventoried until 2026-09-21 (found by task 11.292), and **no instrument attacked them until `verify_11_9_team_surface.py` found the gap on its own** on Michael's 2026-09-23 VM run: its route set, derived from `project_routes.dart`, came up two short. **What was already true and was watched when this entry was written:** both sit behind `_requireOwner`; the body carries an `action` and nothing else, so **no device clock can move anybody's deadline**; `schedule` never moves an existing date; the destruction's every `DELETE` is `WHERE project_id = $1`. **What the round asks** — probe 8 (the owner-route sweep, now compared against the router as a set of method-and-path pairs rather than a count, so the next owner route fails it again) and probe 8a, which is new: (1) **who may reach them** — a contributor, a viewer, an owner whose membership has ended, a stranger and nobody signed in, for every action (read, `schedule`, `cancel`, `immediate`), each answer required to be **byte-identical** to the same caller's answer for an id nothing has ever named; the consequence is then read back by the real owner (still scheduled, not canceled, rows still pullable), because a `403` is the server's account of what it did and the account is the thing under test. *Both ways a membership ends are attacked: the ended owner is tested by leaving (`ex_owner`), and, since task 11.312 item 5, by removal — a co-owner ends the row instead (`removed_owner`). `isSelfDeparture` (`packages/tritrack_sync/lib/src/membership_departure.dart`) only matches when the caller and the row's `user_id` are the same person, so removal takes the ordinary `MutationRule.projectOwner` path rather than the self-departure exception; the resulting row is in the same state either way (`end_date` set, nothing else about the row's shape distinguishing the two), so it is asked the same questions as the ended owner.* *A fourth action, `restore` (task 11.302), was added to `ProjectDeletionAction` after this round was written and, since task 11.312 item 7, is attacked too — the list of actions is now read from `ProjectDeletionAction` itself rather than typed, the way the answer's field set already is. `restore` is gated narrower than every other action here: `_restore` requires not just `_requireOwner` but `ProjectDirectoryService.isDeletedBy` — the same owner who performed the delete, read from `Projects.last_modified_by` at the moment `deleted_at` was set. So it is attacked with a co-owner who did not delete it (the caller that actually reaches `_restore`'s own refusal, the other four being caught by `_requireOwner` already), a contributor, a viewer, an ended owner and a stranger, each byte-identical to a never-named project; a body `project_id` naming a different deleted project changes neither project's standing; and the real, deleting owner's restore is read back as succeeding, with the redirected project confirmed untouched throughout.* (2) **a caller-supplied project id** — the owner of project A asks for A's deletion and names project B in the body three ways, the query string three ways, two headers, a cookie, `X-Original-URL`/`X-Rewrite-URL`, and an `On-Behalf-Of` naming B's owner, plus a traversal segment and its percent-encoded form in the path. B's standing is read by B's owner after each one — **a reference known from the fixture, never the answer of the route under test**, which is entry 29's lesson. `immediate` is then sent with every redirection at once, and B's rows are pulled. (3) **the path id malformed** — the nil UUID, a traversal prefix, a trailing space, an encoded space, 300 characters, an encoded NUL, `*`, a SQL fragment — each as `immediate`, by the owner of the real id, so an id the server trimmed back to a real project would destroy it and fail loudly. (4) **a destroyed id** — its former owner and a stranger, every action, byte-identical to a never-named id. `/sync/*` names a destroyed id (Security Model §4.13's one written exception), and that exception's reopen trigger is a route answering one differently; **these two must not.** (5) **the body** — twelve malformed actions, no action, a bare string; and a `schedule` carrying its own `destroy_at`, `scheduled_at` and a zero grace period, which must come back with the server's arithmetic. (6) **the answer** — its field set, read from `ProjectDeletionStanding.toJson` rather than written into the probe; every answer searched for any identifier or email address; `cache-control: no-store` on both routes. **What the code answers to the two questions entry 27 asks that the probe cannot:** *the bound* — there is none to hold, because the answer is one fixed-size object and never a list; *the rate limit* — **neither route has one, and neither does any owner route on this router** (the limiter guards only `/projects/mine`, `/projects/deleted/mine` and the requester's two join routes). Left so deliberately by this task, subject to the planning session: only an owner reaches either route, `immediate` can happen once, `schedule` is idempotent and `cancel` of nothing changes nothing, so what an owner can multiply is audit rows about their own project. The probe **measures** it rather than asserting it (70 reads, counted, reported as a note). **Watched to fail, offline only:** probe 8a was run on the Mac against an in-process model of the two routes in three modes — correct, owner gate removed, body id trusted after the gate — and came back clean, then flipped every attack the two broken modes are certain to flip. That checks the probe's logic, not the server. **The live proof is `verify_11_85_broken_control.py`**, whose `owner` variant now requires the deletion attacks to flip (including the co-owner-removal one, task 11.312 item 5), whose `deletion-scope` variant makes the route trust a body `project_id` after the gate, and whose new `restore-any-owner` variant (task 11.312 item 7) removes `_restore`'s narrowing down to `_requireOwner` alone and requires the co-owner attack on `restore` to flip. **The rate limit's absence was confirmed by the planning session, 2026-09-24** (reasoning above; a limit added later shows up as a changed note). |
| 31 | **`GET /projects/deleted/mine`** — the projects *this caller* deleted that the server still holds as tombstones. New in task 11.292 (2026-09-21). A **read**, like entries 27, 28 and 29 | **Derived rather than gated so far, and the derivation is unusually strong for a new route.** It **takes no identifier at all**, so entry 29's ten redirection probes have nothing to push at — which is a property of the route rather than a claim about it. Three conditions decide a row (an open owner membership, a tombstoned row, and **the caller sent the tombstone**, verified from `last_modified_by` under §4.17), and **each was watched red by removing its clause**: the author clause on the co-owner who did not delete, the role clause on the owner demoted after deleting. Its four fields are defended one at a time in §4.28.1, which also **refuses the general "show me deleted projects" listing in writing** as a question about the server's history rather than the caller's projects — §4.13's reopen trigger by name. **What it still owes a gate:** the bound and the rate limit (neither stated), `cache-control: no-store` (unverified), and the response searched for anything about a project the caller neither owns nor deleted. **Its readiness rests on tests nobody has attacked**, which is entry 29's own lesson about a harness taking its reference from the route under test. |

## 3a. Dormant controls — present, deliberate, and currently unreachable

**A gate must not file one of these as a finding, and must not mistake one for live
protection.** Both failures have happened on this project: a control assumed live
that was not, and a correct control re-reported as new. The register below exists so
neither happens again.

**The rule for a gate:** a dormant control is in scope for the question *"does the
test that would wake it still exist?"* and out of scope as a finding. If a gate finds
one has become reachable, that is a real finding and belongs in §3.

| Control | Why it is dormant | What would wake it | Test that fires then |
| --- | --- | --- | --- |
| **§4.17 clause 2** — "this project already reaches the named person" | Task 11.47 (2026-08-28) narrowed what an edited-by column may claim, and **no row can reach clause 2 any more.** Kept deliberately: it is the right answer if a shared-vocabulary table ever gains a real author column. | A shared-vocabulary table gaining an author column | Yes — a test fires on the day that happens. Both the code and the security model state that nothing currently depends on it. |

**Why keep a control nothing reaches?** Because deleting it would delete the reasoning
too, and the next person to add an author column to a shared table would re-derive it
from scratch — or not. The cost of keeping it is exactly one row in this table plus a
test, and the cost of the alternative was measured twice this month in comments that
claimed properties which were not the ones holding.

---

## 4. The bar — what blocks

A finding **blocks** if and only if it meets one of these. Everything else goes
to the register.

- **B1 — Silent or unrecoverable loss or corruption of field observation data.**
  Irreplaceable data, and the user is not told.
- **B2 — Disclosure of animal coordinates or observer identity to a party not
  authorized to have them.**
- **B3 — Unauthenticated remote access, privilege escalation, or bypass of
  authentication or authorization on the server.**
- **B4 — A control the security model asserts exists that does not exist, or
  does not fire.** Includes a check that cannot fail.

**Sanity check against the existing record**, which is how we know the bar is
calibrated rather than convenient: L-1 is B4. L-2 is B1. L-3 is B2. K-1 was B1.
J-1 was B1. C-3 was B2. `Ce2`, `Dc`, `Dh`, `Eb` meet none — which is exactly how
four consecutive gates already treated them. **The bar reproduces every judgment
already made.**

**How B4 is read — settled by the triage, and not to be re-derived.** B4 is not
a harm, and read literally it makes every documentation drift blocking, which is
the treadmill this document exists to stop. It is also falsified by the record:
§4.7's unimplemented retention sweep has been named at six consecutive gates and
rated blocking by none. **B4 is a route to B1–B3, not an independent bar** — a
missing or vacuous control blocks when what it leaves undefended is one of B1,
B2 or B3. That is how L-1 blocks (the refusal that does not fire leaves the
source-identity collapse live) and how §4.7's gap does not (what it leaves
undefended is audit rows kept too long). Full reasoning: §15.0.

---

## 4.1 One finding fixed before it was ever registered — S-1, 2026-08-31

**Recorded here because it is above the bar and therefore does not belong in §5's
register, and because the next round has a job because of it.**

Task 11.93's own new tests found that the server's row-naming check asked *"does this row
name the caller?"* **before** it asked the update rules — so a caller could write **their
own** name over an identity column on **somebody else's** row. In plain terms: a colleague
could have taken credit for finding another person's lion.

**It was unreachable until that task existed.** Every table that named a person also refused
the write itself; `Actual_Tag_Locations` is the first table **writable by anyone on the
project *and* carrying a statement about who a record is about.** The defect was created by
the combination, not by either half — **which is the shape worth remembering: a new table
can reactivate a dormant hole in a check that was correct for every table before it.**

**Fixed for every table in the same commit, with a server test confirmed to fail
beforehand.** Same family as N-1 (task 11.24).

> **The next gate round must attack the generalised fix, not the table it was found on.**
> One edit now governs every table, and 11.93's test covers the case 11.93 knew about. **A
> fix applied everywhere by a single change is precisely the kind that needs its own
> probe** — the failure mode is not that it does not work, but that it works for a reason
> narrower than "everywhere".

## 5. The register — everything below the bar

Below-bar findings go to a register in `TriTrack_Security_Model.md` with an ID,
one line of description, and one disposition:

- **accepted** — with a reason. Not scheduled, not revisited.
- **scheduled** — with a task number.
- **deferred** — to a named phase, with the dependency stated.

**Rules that make this terminate:**

1. A registered finding is triaged **once**. A later gate confirms it is still
   below the bar and moves on. It does not get re-argued each round.
2. A registered finding does **not** require a task. "Accepted" is a complete
   and honest disposition.
3. A registered finding **blocks nothing**.
4. Adding to the register requires the reason to be written. Silence is not a
   disposition — that rule (task 10.72) stays, and this is what satisfies it.

The thirteen findings L-4 through L-16, and the reserved numbers 10.92–10.105,
are the first input to this register. Most should end as **accepted**.

**The register is written: `TriTrack_Security_Model.md` §15** (task 10.106,
2026-08-16). It disposes of every open finding, triages the whole `Not started`
Phase 10 queue, and records what became of each reserved number. §15.0 settles
how B4 is read — **as a route to B1–B3, not an independent bar** — which is what
keeps a documentation gap from blocking a gate, and it reproduces every judgment
the seven gates already made.

---

## 6. Exit criteria — what "done" means

### Gate C passes when all of:

1. Every server inventory entry (14–20 and 23–29) has a verdict, **no entry on that
   surface reads `Unexamined`**, and every one marked Hardened has a **failed live
   attack** on record from the current round.

   > **The clause in bold was added 2026-08-31, and the criterion was failing to do its
   > job without it.** As written before, `Unexamined` counted as "has a verdict", so this
   > criterion would have reported **Met** over a server whose newest routes — the ones
   > that grant membership — had never been attacked. **A control whose only job is to
   > pass is not doing a job**, and this one would have passed for a reason other than the
   > documented one. It stayed harmless only while `Unexamined` was a state that never
   > survived to a gate run; task 11.81 ended that.

   **MET again, 2026-08-31, under the corrected wording (§22).** Task 11.85 gave
   entries 23, 24 and 29 verdicts earned by failed live attacks in that round, and
   no entry on this surface reads `Unexamined`. **The record of it having been NOT
   MET for one day is kept rather than overwritten, because the day is the
   finding:** entries 23 and 24 read `Hardened` on 2026-08-30, read `Unexamined`
   on 2026-08-31 because task 11.81 replaced the routes their verdict was earned
   against, and read `Hardened` again the same day against the routes that
   replaced them. **A verdict does not transfer to a replacement because it kept
   the row number**, and the criterion now says so in a way that cannot be read
   the other way. Two findings came out of that round — R-1 and R-2 — and neither
   meets the bar; both are in the register (§22.4).

   > **The re-establishment cost 2.5 seconds of instrument time and about half a
   > day of everything else**, and the split is worth recording. The probes are
   > committed and run in seconds, exactly as task 11.64 intended. What was
   > expensive was that **four instruments could no longer reach the surface at
   > all**: they built their fixtures by inviting somebody, and 11.81 deleted that
   > route. Rewriting a fixture is not the same work as writing a check, and 11.64
   > bought the second without buying the first. The join-code flow now lives once
   > in `gate_wire.py` rather than four times, which is what makes the *next*
   > protocol change a one-file repair.

   **Met, 2026-08-30, for the first time (§21)** — and the record of that is kept below
   rather than overwritten, because what it bought (committed instruments, a four-minute
   round) is why re-establishing it is now cheap: Every entry was re-attacked
   live in one pass: 14, 15 and 20 by `verify_round8_server_surface.py`, 17 by
   `verify_deployment_refusal_matrix.sh`, 16 by the backup drill and the
   archive-forgery test, 18 by the server suite's role tests against real
   Postgres, 19 by `verify_tls_termination.sh` plus Michael's assisted
   source-identity run on the Ubuntu VM, 23–26 by
   `verify_11_9_team_surface.py` and `verify_11_24_attribution.py`, and 27–28
   by `verify_11_49_server_reads.py`.
   **What changed is not the server — it is that the checks now survive the
   round.** Entries 14, 15, 17 and 20 spent two weeks failing this criterion
   for one reason: round 8 wrote their checks by hand and committed none of
   them, so "from the current round" could only be re-established by writing
   them again. §6.1 priced that at half a day of Opus time per round, forever.
   Task 11.64 spent it once.
2. No open finding on that surface meets §4's bar.
   **Met, re-checked 2026-08-31 (§22.4).** Round 9 added two: **R-1**, a claimed
   name may carry a hard line break, so a stranger asking to join writes the
   second line of the owner's tile — below the bar because the tile's *title* is
   the server-authenticated address and is untouched, which was measured on
   screen rather than argued; and **R-2**, a refused requester keeps a live read
   on the project's current name — below the bar because a project name is
   neither coordinates nor observer identity. Round 8's Q-1 is unchanged in
   substance and **narrower in fact**: the project router does have an audit hook
   now (task 11.81), and what is still missing is a rate-limit refusal event.
3. Every below-bar finding on that surface is in the register with a disposition.
   **Met.** R-1 is **scheduled** and needs a task number from the planning
   session — it is in Phase 11's Discovered Scope, not left as an "Open" with
   nobody named. R-2 is **scheduled**, with its durability half belonging to task
   11.79 (whose scope must be widened to `project_join_requests`) and its
   live-name half needing Michael's decision. Q-1 stays accepted; P-1 is closed
   rather than registered.
4. Four suites green in one pass; instruments operable and self-tested; the
   adversarial pass matches its recorded baseline exactly.

   **Met, 2026-09-06 — and the unwritten "on a quiet machine" is gone, which is
   the only thing that changed.** Task 11.90 rewrote the drift guard inside
   `gate_c_adversarial_pass`'s `Cg` timing check so that it compares the effect
   against **the resolution the run itself demonstrated** — the largest gap that
   run opened between two project ids that are identical in truth — instead of
   against the sign of that gap. An effect the run cannot resolve is now
   INCONCLUSIVE and the run survives it; an effect it can resolve is still a
   failure, however loaded the host, because the bar is a measurement of the
   host rather than a constant. **This criterion no longer has a precondition
   nobody wrote down.**

   **Watched, not assumed.** The rule lives in `scripts/gate_timing_guard.py`
   with a `--selftest` that breaks it on purpose in a second — including on
   R-3's own numbers, where it asserts that the *previous* rule called that
   shape a Gate C blocker — and `gate_smoke_test.sh` runs that self-test on
   every gate. On a live stack under deliberate load (load average above 200,
   eight copies of the pass sharing one stack, which is R-3's condition) the
   check declared INCONCLUSIVE through **all three of its doors**, including the
   one the repair adds: an effect of 2.439 ms with the same sign in every trial,
   against a resolution of 4.548 ms — **a run the old rule would have reported as
   a Gate C blocker.** Every inconclusive run exited 0 with its baseline intact.
   §22.4.1 records the one qualification: at the shipped seven trials a unanimous
   sign is 1 in 64 and did not occur in 46 loaded runs, so that door was reached
   by cutting the trial count to three in a throwaway copy against the same live
   stack — real measurements, real load, fewer trials.
   **17 of 18 instruments PASS as of 2026-08-31, and the eighteenth is finding
   R-3 rather than a server defect.** `gate_c_adversarial_pass`'s `Cg` timing
   check failed inside the full run and **held on three consecutive re-runs on
   the same host with nothing else running** — sign flipping, magnitude at the
   noise floor. It is a false blocker produced by machine load slipping past a
   drift guard that tests the null's *sign* and not its *magnitude*; §22.4.1
   has the mechanism and the repair. **Recorded here rather than re-run until
   green**, because "matches its baseline exactly" quietly means "on a quiet
   machine" until that check is fixed, and this criterion should say so. The
   four repaired instruments and both round-9 probe sets pass.

   **Verdict, 2026-08-31 — the planning session's: MET, with the caveat stated
   rather than absorbed, and task 11.90 removes the caveat.** The one failure is
   in the instrument and not on the server, and it fails safe — a false blocker,
   not a missed one. **But a criterion with an unwritten precondition is a
   criterion that will be met on paper on the day it matters**, so "on a quiet
   machine" stays visible here until 11.90 makes the guard test magnitude rather
   than sign. **Round 9 could have re-run until green and reported a clean pass;
   that it did not is why this criterion is still worth something.**

   **Met, 2026-08-30.** 18/18 instruments PASS in 3 min 45 s; all 11
   wire-speaking instruments abort on a forced-stale constant under
   `GATE_SMOKE_SELFTEST=1`; the adversarial pass reports 36 held and 4 failed,
   exactly the four baselined ones; the server suite is 724 passed with zero
   skips, the offline suite 1520 passed with 12 skipped, the e2e suite 60
   passed.
5. **The NAU information-security review has happened.**
   **RE-SCOPED 2026-08-31, and the criterion is unchanged while the letter is not.**
   Michael read the request and judged that **most of it asked NAU ITS to review a threat
   model they do not own** — how a member of a research team could enter a misleading record
   is a research-integrity question, not a campus-network one. **He is right, and the letter
   was 278 lines aimed largely at the wrong reader.** It is now a two-paragraph hosting
   request about what the server exposes, what sits in front of it, and where backups may
   live; the application-security material moved whole to
   `CLAUDE_DOCS/DEVELOPER_REVIEW_BRIEF.md`, for a developer joining the project.

   > **This does not weaken the criterion. It aims it.** Gate C asks whether the server may
   > listen beyond localhost, and the risk that question is about is the risk to the network
   > it would listen on. **A review nobody was qualified to give would have satisfied the
   > criterion on paper** — which is the failure mode this document exists to prevent.

   **And the errand shrank rather than the standard: hosting on a NAU machine almost
   certainly requires ITS sign-off anyway**, so the letter asks for hosting and gets the
   review as a consequence.

   **NOT MET.** It was the only thing left on 2026-08-30; criterion 1 re-opened on
   2026-08-31 when task 11.81 replaced two attacked surfaces with three unattacked
   ones, and **task 11.85 closed it again the same day**. So this is once more the
   only blocker — with the date attached, because that sentence has now been true,
   false, and true again inside forty-eight hours. The recipient address is still
   blank and only Michael can fill it in.

### 6.1 What a full Gate C re-run cost, priced 2026-08-29 and paid 2026-08-30

**Kept, rather than replaced, because the comparison is the finding.** Task
11.49 priced the re-run at roughly half a day of Opus time plus one to two
hours for entry 17's matrix, and named exactly one cause: *round 8's server
checks and the deployment refusal matrix exist only in a transcript.* It
recommended committing them. Task 11.64 did, and then ran the round from them.

| | Before (priced 2026-08-29) | After (measured 2026-08-30) |
| --- | --- | --- |
| Entries 14, 15 — the sync envelope and the auth routes | **half a day**, an Opus session writing ~66 checks again | inside `gate_smoke_test.sh` — **143 checks**, no attention |
| Entry 17 — the twelve-shape refusal matrix | **1–2 hours**, an Opus session plus Docker | inside `gate_smoke_test.sh` — **12 shapes**, no attention |
| Entry 20 — traversal addresses | **15 minutes** | inside `gate_smoke_test.sh` — **11 checks** (task 11.71), and now `find`s the whole container filesystem rather than the places somebody guessed — and aims one address somewhere the write can actually land, which is what made that `find` able to fail |
| `scripts/gate_smoke_test.sh` | 3 min 21 s, 16 instruments | **3 min 45 s, 18 instruments** |

**So the cost of the *next* round, stated plainly:**

| What | Command | Cost |
| --- | --- | --- |
| Every instrument, including everything above | `scripts/gate_smoke_test.sh` | **3 min 45 s**, Docker only, unattended |
| The instruments' own self-test | `GATE_SMOKE_SELFTEST=1 scripts/gate_smoke_test.sh` | about the same again |
| Server suite | `scripts/run_server_tests_docker.sh` | ~40 s, 724 tests, zero skips |
| App suite, offline | `scripts/run_offline_suite.sh` | ~1 min 30 s — **bring any stack down first**, or it aborts by design |
| End-to-end suite | `scripts/run_e2e_tests.sh` | ~1 min, 60 tests. **Use the script.** The bare `flutter test test/e2e --tags e2e --run-skipped` this table used to quote silently runs against nothing and reports sixty failures; it did so once during this very round |
| TLS termination | `scripts/verify_tls_termination.sh` | ~1 min, 7 checks |
| Watching the newest instruments fail | `scripts/verify_round8_broken_control.py`, `scripts/verify_11_49_broken_control.py` | **10 and 13 minutes** — evidence that the probes *can* fail, not something each round must repeat |

**The whole automated round is now well under fifteen minutes of wall clock,
almost none of it attended, and one Opus session to read the output and write
the verdict.** Two things still are not scriptable and both are named rather
than assumed:

| What | Why it is not scriptable | Who it needs |
| --- | --- | --- |
| **Entry 19's host license** — `scripts/verify_source_identity.sh --assisted` | It measures whether an **off-host** caller reaches this machine with its own address attached. Two containers on the host are not two off-host callers (task 10.110) | **Michael, plus two real devices that are not the host.** Last run 2026-08-30 on the Ubuntu VM: both shapes `PRESERVED`. It licenses **that host**, not the platform — a different beta host means measuring again, and §4.4.3 requires the host, OS, virtualisation and Docker flavour recorded beside the declaration |
| **Criterion 5** | The NAU information-security review | NAU. Unknown, and not ours |

**The rule this round establishes, and it is the one worth carrying:** a check
that is not committed is a check the next round will not run. Round 8's
seventy checks were correct, thorough, and worth nothing to round 9.

---

### What `TRITRACK_TRUSTED_PROXIES` / `TRITRACK_PROXY_SOURCE_IDENTITY` mean (task 11.65)

**This is the one file that owns the full explanation.** Every other site that
sets or documents these two variables (`README.md`, `server/README.md`,
`.env.example`, `docker-compose.tls.yml`, `SERVER_DEPLOYMENT_PRIMER.md`) keeps
only a one-line claim next to the variable, because a person editing `.env`
who is sent elsewhere to learn what the value means is a person who will set
it without reading. This section is where "elsewhere" points to.

**The question behind both variables.** Rate limits and the audit log key on
each request's source address. Behind a reverse proxy, or behind whatever
forwards a host's published port, the address the server actually sees may not
be the caller's — and if it is not, §4.4's per-source rate limit collapses
into one bucket shared by every user (finding I-1: ten unauthenticated
requests then deny magic-link sign-in to the whole deployment), and every
audit row records the wrong actor. The server refuses to start on a reachable
deployment until an operator answers both questions below; that refusal is the
control.

- **`TRITRACK_TRUSTED_PROXIES`** answers "who may speak for a client?" It is
  either an allowlist of proxy sockets (`X-Forwarded-For` is read from those
  peers and no others), or the literal `peer-verified` — nothing is in front
  of this server, the TCP peer *is* the client, **and an operator measured
  that on this deployment**, with
  `scripts/verify_source_identity.sh --assisted`, from two real off-host
  devices, and read `PRESERVED` on the `direct` shape.
- **`TRITRACK_PROXY_SOURCE_IDENTITY`** answers the same question one hop
  upstream: does the address a declared proxy forwards survive the host's own
  publish path in front of it (finding K-2)? `probe-verified` means the same
  probe, run **on that host**, read `PRESERVED` on the `proxied` shape.
  `on-network-only` means nothing off that host reaches the proxy at all
  (true of this repository's own drills; not true the moment a phone on the
  Wi-Fi can reach it).

**Why neither value is ever generated or defaulted.** Both are an operator's
own claim about a network the repository cannot see and has never measured on
the operator's behalf — no Docker Desktop host can make either claim
truthfully, because its VM boundary rewrites every inbound connection's source
address before any container sees it (task 10.110). A tool that filled either
value in automatically would be vouching for a machine it has never watched
traffic cross, which is exactly the assumption findings I-1, J-2 and K-2 were
each a version of. The awkward, hand-typed spelling is part of the control,
not an oversight in the UX.

**What to do:** run `./scripts/verify_source_identity.sh --assisted` (see
`server/README.md`'s "Does your host even have a source address?" for what it
needs) against the actual deployment host, from two real off-host devices, and
transcribe only the verdicts it prints — `PRESERVED` on `direct` licenses
`peer-verified`; `PRESERVED` on `proxied` licenses `probe-verified`. Anything
else means the deployment is not exposable yet.

---

### Gate D passes when all of:

1. Every client inventory entry (1–13 and 21–22) has a verdict, and every one marked
   Hardened has a failed live attack on record.
2. No open finding on that surface meets §4's bar.
3. Every below-bar finding is in the register with a disposition.
4. The default suite is green **deterministically** — three consecutive full
   runs, not one.

### The stopping rule, which is the part that matters

**A gate attacks the inventory. It does not free-range.** Its job is to attempt
to falsify each entry's stated verdict.

If it discovers a path not on the inventory, it **adds the path to §3 and
reports it** — and that finding blocks the run **only if it meets §4's bar.**
Otherwise it is registered and the gate continues to its verdict.

This is what stops the treadmill. Without it, any sufficiently thorough reviewer
can keep a gate open forever, because there is always one more place to look.

---

## 7. What this does not claim

It does not claim TriTrack is secure. It claims the surface has been enumerated,
the serious harms on it have been attacked and refused, and the remainder has
been written down and accepted by a named person on a stated date.

That is what a security review is. The alternative — waiting for a review that
finds nothing — has no end state, and seven rounds of evidence say so.
