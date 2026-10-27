# TriTrack server — orientation primer

**Who this is for:** someone joining to help decide how and where the TriTrack
server gets deployed. It assumes web/hosting experience and no knowledge of this
project, wildlife telemetry, or Flutter.

**What it is:** enough context to have an opinion, plus the specific decisions
that are blocking progress. It is deliberately not a full technical
description — pointers to the deeper documents are at the end.

**Status as of 2026-08-21.** The server is written and works. It has never
listened on anything but localhost. **The engineering side of the security
review is finished** — the eighth round passed on every technical criterion, and
the one thing still blocking it is an institutional review that has to be
requested by a person, not built. Two of the decisions below have since been
answered by necessity rather than by choice; both are marked. The rest are still
open and still yours to weigh in on.

---

## 1. What the app does

TriTrack is a Flutter field app for wildlife biologists doing VHF radio
telemetry. A biologist walks a transect with a radio receiver and a handheld
antenna, takes compass bearings toward a radio-collared animal, and the app
triangulates the animal's position from multiple bearings.

It runs on iOS (the primary field device), Android and macOS. It is used in
places with no cell signal — that constraint drives the entire architecture.

Roughly 40,000 lines of Dart in the app, 6,800 in the server, 4,400 in a shared
package both sides use.

## 2. Why the data is sensitive

This matters more than the project's size suggests, and it is the reason the
security work has been as heavy as it has.

The database holds precise, timestamped locations of individual collared
animals. For endangered or commercially trafficked species, that dataset is
directly useful to poachers — targeting researchers' telemetry data is a
documented pattern in conservation, not a hypothetical. **A leaked coordinate
cannot be undone by rotating a credential.** It also holds researchers' names
and email addresses.

Assume the standard for this data is closer to "regulated health data" than to
"a hobby project's database."

## 3. The one constraint that cannot be traded away

**The app must remain fully usable with no server, forever.** Not degraded —
fully usable. A biologist in a canyon with no signal is the primary use case,
not an edge case.

Concretely, this has been enforced throughout as five rules, and any deployment
proposal has to respect them:

1. Signing in is never a gate to launching or using the app.
2. The server never assigns primary keys — the client generates all IDs.
3. No server-supplied column is required for the app to function.
4. No read path in the app goes through the network.
5. The test suite runs green with no server present.

The practical consequence: **the server is a sync convenience, not a
dependency.** If it is down for a week, fieldwork continues and syncs later.
That genuinely lowers the engineering bar for availability — nobody loses data
or loses a field season because the server is down.

It does not lower it as far as it first appears, though, once §4's scale is
taken into account. A single team that knows the developer will tolerate an
outage. Two hundred teams on three continents will not, and "your data is safe,
it just won't sync until Tuesday" is a different sentence when said to a
stranger who is depending on it.

## 4. Architecture, briefly

**Offline-first with last-write-wins sync.** Every device holds a complete local
database and works from it. When a device has connectivity it pushes its changes
and pulls others'. Conflicts resolve by last-write-wins over a small set of
sync columns; there is no locking and no server-side authority over content.

**Stack:** Dart server (shelf), PostgreSQL, Docker Compose. A shared Dart package holds
the merge logic so client and server run identical code.

**Seven long-running containers** (corrected three times now — **2026-09-10** from *"three
services: `postgres`, `server`, and a `backup` job"*, true before tasks 10.49, 11.78 and
11.79 each added one; **2026-09-21** from "five", true before task 11.290 added another;
and later the same day from "six", when task 11.291 added the seventh): `proxy` (Caddy,
terminates TLS and is the only container with host ports), `server`, `postgres`,
`backup-scheduler`, `audit-retention`, `project-destruction` and `tombstone-retention`. An
eighth, `backup`, is a one-shot job behind a Compose profile rather than a service.
**Derive this count from `docker-compose.yml` and `docker-compose.tls.yml` before quoting
it to anybody** — it has now gone stale twice by being carried rather than read, and a
count in a document for a system administrator is the sentence they will check against
`docker compose ps`.
**`CLAUDE_DOCS/TriTrack-server-architecture.html` is a one-page diagram of exactly this**,
written for a system administrator and derived from the compose files. **The PDF that used
to be named here was deleted by task 11.295** — nothing built it and nothing checked its
age, so it fell two rounds of edits behind. The HTML page carries print CSS sized for
letter paper; print it from a browser if somebody needs a PDF to attach.

**Auth:** email magic links. No passwords. Sessions are opaque database rows,
not JWTs — deliberately, so that removing a team member revokes access
immediately rather than whenever a token expires.

**Scale — read this carefully, because it is the thing most likely to be
assumed wrong.** Any individual team is small: a handful of people per project,
syncing in intermittent bursts when devices come back into signal. But the
intended reach is **hundreds of independent research teams worldwide, plausibly
a few thousand users**, and those teams are unrelated to each other — different
institutions, different countries, different species, no reason to trust one
another.

So this is a *low-traffic, high-tenancy* system. The distinction matters:

- **Compute stays modest.** Thousands of users syncing occasionally is not heavy
  load. A single well-chosen VM plausibly serves the whole thing for a long
  time. Nobody needs to reach for autoscaling or Kubernetes here.
- **Everything around the compute changes.** Strict isolation between unrelated
  tenants, self-service onboarding, account recovery for people you have never
  met, support, abuse handling, and the legal position of holding protected-
  species coordinates for teams in jurisdictions you do not operate in.

If a proposal is sized for the traffic, it will be right. If it is sized for the
tenancy and the obligations, it will be right for a different and harder reason.
**Both need to be true.**

**Team collaboration is now built** (corrected 2026-08-21; this section
previously said it was not). Multiple co-equal project owners, invitations by a
short code bound to the invitee's address, a three-rung role gradient — viewer,
contributor, owner — enforced server-side with the client agreeing, a team view
of everyone's observations, and owner data-quality actions that supersede rather
than overwrite a colleague's record. **Its own security pass has not run yet**
and is the last task in that phase.

At this project's intended scale that feature is also what turns "a project"
into "a tenant", so the decisions below constrain how it *scales*, not whether
it exists. Worth knowing which way round that is before costing anything.

## 5. Where the security work stands

A review gate must pass before the server listens on any non-localhost
interface. **It ran eight times and failed seven.** That sounds worse than it
is: every round found real problems, they were fixed, and the following round
re-verified them as fixed rather than taking the fix on trust. No fix has ever
regressed.

**Where it landed.** The eighth round passed every technical criterion for the
first time, and passed a second gate covering the app itself outright. The one
remaining blocker is an institutional security review that has not been
requested yet — a person has to send an email; no amount of engineering moves
it.

**What the rounds actually found, because the shape is more useful than the
count.** The network-facing sync interface came back clean for the last three
rounds running — that is the part an attacker on a network would reach, and it
is the result that matters most here. The serious findings were elsewhere, and
each time in a place nobody had looked yet: first the backup path, then the
*fit* between a correct control and the configuration it actually ran in, then
project files. Two examples worth carrying into a hosting conversation:

- **Backups.** They are encrypted to a public key, and the design correctly
  noted a public key need not be secret. But the restore procedure verified only
  that an archive was *intact*, never that it came from *us* — so anyone who
  could write a file into the backup directory could have their SQL executed
  with database superuser rights. Integrity is not authenticity. Archives are
  signed now.
- **Rate limiting.** The limit on sign-in attempts counted requests per source
  address, in a deployment where every request arrives wearing the same address.
  The fix is why decision B below is already answered: the server now **refuses
  to start** anywhere it cannot tell one caller from another.

**What remains open is almost entirely deployment and operations.** That is why
you are here.

## 6. The decisions

Roughly in dependency order. A is the one that unlocks the rest.

### A. Lab tool or service? — **decided: staged**

**A single-team closed beta in March 2027, then broad release.**

This is the answer to what was the primer's central open question, and it makes
everything below tractable. Read the rest of §6 as *the destination*, not as the
March scope — the point of listing them is that beta decisions should not
foreclose them, not that they must all be solved first.

**In scope for the beta:** one known research team, invite-only, no public
signup, no strangers. The obligations that make the service version hard —
tenant isolation against hostile signups, GDPR, support at volume, uptime for
people you have never met — are all deferred, legitimately.

**Two traps worth naming now, because they are cheap to avoid and expensive to
fix:**

1. **Beta drift.** "One team in March" becomes "five teams by summer" with no
   decision ever taken, and then the deferred obligations arrive without the
   design that was supposed to precede them. **Write down what must be true
   before team #2, and before open signup.** That is the guardrail, and it costs
   an afternoon.
2. **Data migration.** Whatever the beta stores has to survive into production,
   or has to be knowingly discarded. There is schema versioning already, which
   helps, but "the beta team's real field season" is not data anyone will be
   relaxed about throwing away. **What the beta database actually holds, measured
   2026-09-11 (Michael's census on the Ubuntu VM, task 11.222): five collars on
   schema version 11, one of them linked to no project.** Whether that is a field
   season or seeded rows is Michael's to say; it is not nothing, and task 11.227
   is what makes the upgrade from v11 go through with it in place.

**One consequence worth flagging to whoever takes decision D:** at one known
team, a private overlay network (Tailscale, WireGuard) is back on the table and
is substantially simpler than public TLS with DNS and certificate renewal. It
does not scale to the service version — but it may be exactly right for March,
with the public path built later against real operational experience.

### B. Where does it run?

At the scale in §4, some options fall away on their own.

Self-hosting on a machine at Michael's house is workable for (1) and not for
(2): a residential connection, a changing IP address, one disk, and no
redundancy is not a foundation for teams in other countries depending on it.
A cloud VM is the obvious default. Managed database hosting is worth pricing
against the operational burden it removes.

University hosting was assumed until recently and is now unlikely.

Also bearing on it, and easy to defer until it is painful: **who pays, and who
operates it in year three.** Research software has an uncertain funding horizon,
and a service with hundreds of dependent teams is harder to switch off than a
lab tool.

### C. Tenant isolation

**New in importance at this scale, and the security property that matters most.**

Hundreds of unrelated teams share one database. A team in one country must never
be able to see, infer, or damage another's data — and the data in question is
poaching-relevant coordinates for protected species.

This has had real attention already: the review rounds found and closed several
cases where the server would reveal whether another team's record existed, and a
schema change moved primary keys to being project-scoped. **But all of that was
designed against a threat model of a small number of mutually-known teams.** It
should be re-examined against "an adversary can trivially sign up as a tenant,"
which is a different and much cheaper attack position.

Concretely worth someone's fresh eyes: whether signup is open or invite-only,
what a hostile tenant can learn or do, and whether isolation is enforced by a
single well-tested layer or by rules repeated in many places.

### C2. A hard constraint arrived on 2026-08-16: read this before costing anything

**There is currently no machine on which this can be exposed.** Not "it is
untested" — the server deliberately refuses to start in the only configuration
that is permitted to be reachable, unless the host it runs on has been measured.

The cause is narrow and worth understanding, because it will shape the hosting
choice more than any preference:

- Rate limits and the audit log both key on the caller's source address.
- On Docker Desktop, the publish path **destroys that address one hop upstream**
  of anything the application can see. Every caller arrives looking identical.
- Measured, not assumed: both `direct` and `proxied` publish paths collapse, with
  the probe's negative control passing in the same run.
- The consequence of accepting that would be a repeatable remote
  denial-of-service on sign-in — ten unauthenticated requests lock out the whole
  team for fifteen minutes — with audit rows that can never attribute it.

So the exposable deployment is now gated on a **passing
`scripts/verify_source_identity.sh --assisted` run against the actual host**,
from two real off-host devices, enforced at startup rather than documented.
(Task 10.110: the probe's automatic mode returns `COLLAPSED` or `NO VERDICT`
and never `PRESERVED` — it holds only containers, and a container on the host
is not an off-host caller. Its first version answered automatically and
consequently failed *every* Linux host. §4.4.4.) `TRITRACK_TRUSTED_PROXIES` additionally requires
`TRITRACK_PROXY_SOURCE_IDENTITY` to read `probe-verified` or `on-network-only`;
anything else exits 78. There is no default, deliberately — a shipped default
would be the repository vouching for a machine it has never seen. Both
variables are an operator's own measured claim about their own network. Full
reasoning: `SECURITY_SCOPE_AND_EXIT.md`, "What `TRITRACK_TRUSTED_PROXIES` /
`TRITRACK_PROXY_SOURCE_IDENTITY` mean".

**What this means for the decisions below.** Docker Desktop on a Mac is out for
anything exposed. A Linux host is the obvious candidate and **nobody has
measured one** — the repo is careful to say so rather than assume it. Whatever
host is chosen, running that probe on it is the first thing to do, before
committing money or a migration. It takes minutes and it is the difference
between a deployment and a procedure.

Task 10.88 exists to do exactly that against a candidate host.

**Update, 2026-08-17 — measured, and the news is good.** A native Linux host
*does* preserve the caller's address. Measured on Ubuntu 24.04 ARM64 under
Parallels (bridged networking) with Docker installed natively: two off-host
callers, a phone and a Mac, arrived as `192.168.0.153` and `192.168.0.88` —
distinct and real.

Two caveats that matter for costing a host:

- **The repo's own probe reported the opposite**, because it has no genuine
  off-host caller and its container-to-container hairpin path gets masqueraded
  on Linux. That is a defect in the probe, now task 10.110, and until it is
  fixed **nothing can be formally licensed for exposure** even though the
  underlying host is fine.
- The measurement is recorded for that named configuration, not for "Linux."
  A cloud host is the same arrangement with a different NIC and very likely
  behaves the same way, but that is an expectation and not yet a measurement.

**Update, later the same day — a host is now formally licensed.** The probe was
fixed (task 10.110) and re-run in assisted mode with two real off-host callers.
**Both deployment shapes PRESERVED**, 13 checks. Configuration: Ubuntu 24.04.3 ARM64 under Parallels Desktop on an Apple Silicon Mac, bridged networking, Docker installed natively from get.docker.com (not Docker Desktop). Off-host callers: iPhone `192.168.0.153` and Mac `192.168.0.88` on a home LAN.

So the position is now: **a native Linux host with Docker is a viable place to
run this, demonstrated rather than assumed.** Docker Desktop on macOS remains
unusable for anything exposed. A cloud VM is the same arrangement with a
different NIC and will almost certainly behave the same — but the probe should
be re-run on whichever host is actually chosen, and it takes ten minutes plus
two devices on the same network. Note that campus and corporate Wi-Fi often
isolate clients from one another, which makes the measurement impossible on
those networks rather than merely inconvenient.

### D. TLS termination and certificates — **partly answered, and not by choice**

**Correction, 2026-08-21: a terminating reverse proxy with automatic certificate
handling is built and committed**, and this section previously said it was not.
It was built without knowing NAU's requirements, which was the wrong order and
is called out as such in the review letter — if NAU would host this, rebuilding
to their requirements beats retrofitting. **What has never been exercised is a
real certificate on a real hostname**, because no such host exists yet. That is
the gap, not the proxy.

The rest of this section still stands as the open question.

### D (original text)

At this scale, public exposure is effectively decided — you cannot enrol
hundreds of independent teams onto a private overlay network you administer.
(For a lab-tool-first deployment, Tailscale or WireGuard would be a strong and
much simpler option, which is worth knowing if A lands on a staged rollout.)

So: TLS is required. Nothing is committed today — no reverse proxy, no
certificate handling — and the security review has flagged this at three
consecutive rounds as "there is nothing here to evaluate."

Open: who terminates TLS, what issues the certificates and how they renew, and
how the app is configured to trust them. Note the app currently takes a server
URL the user types in, which fits a self-hosted lab tool and fits a hosted
service badly — worth revisiting under A.

### E. Backups — where do the copies go, and who holds the keys?

**Correction, 2026-08-21: the server-side half is decided and built.** Archives
are encrypted to a public key and **signed**, and the restore procedure refuses
an archive it cannot attribute rather than promoting it over a live database.
What is still open is what this section says it is — *where the off-site copy
lives, and where the keys live* — plus one client-side item that is scheduled
and not built: the app's own cloud auto-backup is still unencrypted and on by
default, which needs client key custody and is required before a real field
season.

Backups are encrypted and now signed. Undecided: where the off-site copy lives,
and where the signing and decryption keys live.

The constraint that catches people: **if the archives and the key to verify them
sit in the same place, an attacker who can reach one can reach both, and the
signature proves nothing.** Same logic geographically — server and backups in
one building means one fire takes both.

At service scale this also acquires a restore-time question: how long may a
full restore take, and does anyone find out before the teams do?

### F. Operations and support

Unglamorous, usually decided by accident, and the section that changes most if A
lands on "service":

- Who applies security updates to the host and the containers?
- Who notices it is down — and how, before a user emails?
- Who restores it if the database is lost, and have they rehearsed it? (There is
  a restore drill script; it works. Nobody outside the project has run it.)
- **Who answers a stranger who cannot sign in?** Magic-link auth means email
  delivery problems become support tickets. At hundreds of teams this is a
  recurring job, not an occasional favour.
- What happens when the person maintaining it moves on?

### G. Legal position and data governance

**Newly relevant, and currently unaddressed.**

Hundreds of teams worldwide means users in jurisdictions with their own rules —
GDPR most obviously, since the system stores names and email addresses. It also
means holding location data for protected species across borders, where the data
itself may be subject to permit conditions or wildlife-authority restrictions
that vary by country.

Questions nobody has answered: who is the data controller, what the terms of
service and privacy policy say, whether data residency is constrained, what
happens to a team's data when they leave, and whether NAU's name being attached
creates institutional obligations.

This is not a reason to stop. It is a reason to know the answer before the
hundredth team signs up rather than after.

### H. Does this still need an institutional review?

A review request to NAU's information security office is drafted and unsent
(`NAU_infosec_review_request.md`). It was written assuming university hosting
and a small user base — both now doubtful, so it needs revising before it goes.

Moving off university hardware does not remove the need. This is university
research data on protected species, likely to be named in grants,
data-management plans, or IRB submissions — and if it becomes a service used by
teams worldwide under NAU's name, that is a larger institutional question, not a
smaller one. Worth an outside opinion, and G probably needs a lawyer rather than
a security office.

## 7. What to read next

In this order. Stop when you have what you need — the later ones are reference,
not reading.

1. **`README.md`** (repo root) — build and run instructions, architecture
   overview. Start here if you want to get it running locally; Docker Compose
   brings up the whole stack.
2. **`CLAUDE_DOCS/TriTrack_Security_Model.md` §7.7** — a deliberately
   plain-language summary of the risk picture: assets, threat actors, what
   holds, what doesn't, what is out of scope. A few pages, assumes no knowledge
   of the codebase. **If you read only one thing beyond this primer, read this.**
3. **`CLAUDE_DOCS/DEVELOPMENT_PLAN.md`**, Phase 10 — the task-by-task record of
   what has been built and what is left. Long. Skim it; don't read it.
4. **`CLAUDE_DOCS/TriTrack_Security_Model.md` §10** — the most recent review
   round in full, if you want to judge how seriously this has been taken.

## 8. What you do not need to worry about

Named explicitly so you can set it aside:

- The app itself — the telemetry maths, maps, compass work. Done and working.
- The sync and merge engine. Extensively tested, including adversarially.
- Whether the app works offline. That is settled and defended by tests.
- Authentication mechanics — magic links, session handling, revocation.
  Reviewed four times.

One caveat on that last item, and it is decision C's point: the authorization
design has been reviewed thoroughly, but **against a threat model assuming a
small number of mutually-known teams.** If this becomes an open-signup service,
that assumption needs re-testing rather than inheriting. The code is likely
fine; the assumption behind the review is what changed.

The open questions are product shape, hosting, tenant isolation, TLS, backup
custody, operations, and legal governance.

## 9. A note on how this project works

Development is done with AI assistance, in a two-tier setup: architecture and
planning in one session, implementation in another, with a written plan as the
contract between them. The security reviews are structured self-assessments
with live reproductions against a running instance — **not a third-party
penetration test.** That distinction is stated in the review documents too, and
it is part of why an outside opinion is wanted.

Michael's background is research scripting rather than networking or
application security. He has said as much plainly; treat the hosting and
transport decisions as genuinely open, and push back where the reasoning above
is wrong.
