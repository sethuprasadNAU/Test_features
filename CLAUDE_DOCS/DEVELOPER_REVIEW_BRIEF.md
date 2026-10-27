# Application security review brief — for the developer joining the project

**Created 2026-08-31 by splitting `NAU_infosec_review_request.md` in two, on Michael's
instruction.** That document had grown to 278 lines and was aimed at NAU's Information
Security Office. **Most of it was aimed at the wrong reader.**

> **Michael's reasoning, and it is right: NAU ITS cares about risk to NAU's
> infrastructure — where this is hosted, what it exposes, whether somebody could reach
> their network through it. It does not care how one member of a research team could put a
> fake bearing into somebody's dataset.** That second question is real, and it matters more
> to this project than the first, but **it is a question for this project's own developer,
> not for a university's network security team.**

**So this file is the application-security half**, kept whole rather than summarized,
and addressed to the developer Michael is onboarding. **The short hosting letter is what
remains in `NAU_infosec_review_request.md`.**

**Where to start reading.** `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md` is the trust-boundary
inventory and the bar; `TriTrack_Security_Model.md` is the long form with every round's
findings; this file is the invitation to attack them. **The most useful thing a second pair
of eyes can do is disagree with a verdict that says Hardened.**

---

## Original content, preserved


**Status: CLEARED TO SEND, 2026-08-22.** Drafted 2026-08-07; revised 2026-08-14,
08-15, 08-16, 08-21; rewritten 2026-08-22 after task 11.9. **The condition set on
2026-08-21 was that task 11.9 had to have *run*, whatever it found. It has run.
There is nothing left to wait for.** Recipient address still deliberately blank —
fill in the correct address for NAU's Information Security Office rather than
guessing.

The substance being reviewed is `TriTrack_Security_Model.md` **§14.12** (the
plain-language residual-risk summary) read alongside **§18** (the team-feature
review). This file is only the cover note. Gate C does not pass until the review
has actually happened.

**This is the longest-standing blocking item on the project and the only one
engineering cannot close.** It has been rated blocking at eight consecutive
gates. Five of those gates revised this letter and none could send it.

**Two failure modes this letter has already been caught in, recorded so they are
not repeated.** The seventh gate found the body two rounds out of date, still
saying the assessment had failed five times and describing the fourth round's
findings as the most recent — the two most serious findings in the whole record
were not in it at all. A reviewer would have been asked to have an opinion about
the wrong system. Then task 11.17 found the same thing again from the other
direction: the letter described a single-user app after the team feature had
shipped. **Both are the same failure the assessment keeps finding in the code — a
document that was accurate when written and was not re-read when the thing it
described changed.**

**Why it is being sent now rather than after a clean verdict.** Waiting for a
pass is how this letter reached nine rounds unsent. The most recent round met
every technical criterion for the first time, and the only item keeping the gate
shut is this review — so the letter is now the blocker, and waiting on it is
circular. It goes out describing one open finding honestly, because "here is what
the latest round found and here is what I am doing about it" is this letter's
most credible paragraph, not its weakest.

---

**Subject:** Request for security review — research app holding protected-species location data (pre-deployment)

Hello,

I'm writing to request a security review before I expose a small research
application to any network beyond my own machine. I'd rather ask now than after
it's running.

Background: I've built an app called TriTrack for wildlife telemetry field work
— a biologist walks a transect with a radio receiver, records bearings to a
radio-collared animal, and the app triangulates the animal's position. It has
worked entirely offline on the phone until now, and it will keep working that
way; the app is releasable with no server at all. I've since built a server
component so a research team can sync one project across several devices, and
that server has never listened on anything but localhost.

The reason I'm asking for your time rather than just deploying it: the data is
more sensitive than the app's size suggests. It holds precise, timestamped
locations of individual collared animals. For endangered or commercially
trafficked species that dataset is directly useful to poachers — targeting
researchers' telemetry data is a documented pattern in conservation, not a
hypothetical — and a leaked coordinate can't be undone by rotating a
credential. It also holds researchers' names and email addresses.

## Where things stand

Before deciding whether to expose it, I set a rule for myself that the server
does not leave localhost until it passes a structured security assessment. It has
now run **eight** full rounds, plus a ninth narrower one covering only the team
feature described below. I've been fixing what each round found and re-running
it. I should be clear about what this is and isn't: it's a disciplined
self-assessment with reproductions run against a live instance, not a third-party
penetration test. That's part of why I'm writing.

The eighth round was the first to meet every technical criterion I'd set. The
only item still holding the gate shut is this review — which is why you're
hearing from me now rather than after another round.

What the rounds have found, in summary:

- The first round found five blocking problems, four reproduced against a
  running server — among them that any registered user could attach a
  colleague's name to a scientific observation, and that the bundled
  configuration served unencrypted traffic on every network interface by
  default. All five are fixed and have been re-verified in every subsequent
  round.
- **The sync interface — the part an attacker on the network would actually
  reach — came back clean four rounds running.** That's the result I care most
  about, and it's why most of this letter is about everything else. **Then the
  round after that found one gap in it, and I'd rather correct myself here than
  have you find it:** the app says only a project owner may take a radio tag out
  of a project, and the server was never told that rule, so a contributor's
  device can push that change and have it accepted — and the tag disappears for
  the whole team. I found it by reading the code rather than by attacking it, so
  it isn't yet reproduced against a running server; reproducing it, deciding how
  serious it is, and closing it are scheduled as one piece of work. It doesn't
  change what I'm asking you, because the server is staying on localhost either
  way.
- The middle rounds found problems in the **backup** path and in the **fit
  between a correct control and the configuration it runs in** — a backup file
  anyone could forge because I'd documented that the verifying key needn't be
  secret (true for reading, false for writing); a retention rule that deleted by
  filename rather than by signature; a sign-in rate limit that counted requests
  per source address in a deployment where every request arrives wearing the same
  address. All are fixed. The last one is fixed in a way worth mentioning: the
  server now **refuses to start** in any deployment where it can't tell one
  caller from another. I'd rather have that than a running server and an
  assumption.
- The later rounds found the serious problems somewhere I hadn't been looking:
  **in project files.** The app can export a whole project as a small `.zip` and
  import one. I had reasoned that a file the user deliberately chose was less
  dangerous than something pasted from a clipboard. That was wrong — choosing a
  file tells you where the bytes came from, not who wrote them. A crafted project
  file could move an animal's recorded location, erase the magnetic declination
  that makes the bearing reconstructible, reassign who recorded it, and report
  the result to the user as "Updated: 3." Worse, a crafted file could change only
  an internal version counter — leaving every visible field alone, so the
  confirmation dialog showed nothing wrong — and thereby make a record
  impossible to restore from the user's own backup ever again. Both are fixed and
  both were re-attacked in the most recent round to confirm.
- A related one worth stating because the victim isn't the user: every spreadsheet
  the app exports writes tag names and observer names in as stored, and
  spreadsheets execute formulas. A tag name planted by an imported file could
  read the latitude and longitude cells beside it and send them to a stranger
  when a colleague opened the export. Fixed, and re-tested in Excel against four
  further bypass attempts.

Two general lessons I've drawn, and they're the two I'd most like challenged:
**a control is only as good as the configuration it was measured in**, and
**wherever a control deliberately ignores something, that exemption is where the
next problem is.** Nearly every finding above is one or the other.

## The part I most want reviewed: the team feature

Since the last version of this letter I've built the feature that makes this a
multi-user system, and it's the part where an outside opinion is worth most to
me. A project now has members with roles — read-only, contributor, and owner —
people join by redeeming a single-use invitation tied to their email address, and
one person can now correct or set aside a bearing that a colleague recorded.

A few design choices I made deliberately and would like challenged:

- **Sign-in is by emailed magic link. Sessions are opaque records in the
  database, not self-contained tokens.** I chose that specifically so that
  removing somebody takes effect on their next request rather than whenever a
  token would have expired. It costs a database lookup per request.
- **Invitations are single-use, expire in 14 days, are stored only as hashes, can
  be revoked, and are bound to the address they were sent to** — so a forwarded
  invitation is useless to whoever it's forwarded to.
- **The app's own permission checks are courtesy; the server is the
  enforcement.** Someone who edits their own phone's database directly can change
  anything locally, and it's refused on their next sync. I'd rather state that
  plainly than imply the phone is a security boundary.
- **Corrections don't overwrite.** When one person corrects another's
  measurement, the new record supersedes the old one, the original survives for
  provenance, and only the superseding record counts toward the position
  estimate.

I then ran a round against that feature specifically, building a real team over
real HTTP — an owner, two contributors, a read-only member who each joined by
actually redeeming an invitation, and an unrelated stranger with their own
project — and attacking it. What held: read-only members can't write anything;
contributors can't promote themselves, add outsiders, or remove anybody; a
project can't be left with no owner; a removed member loses read, write and
directory access on their very next request; an invitation is useless to anyone
but the invited address and can't be reused or used after revocation; and one
project's owner naming another project's invitation changed nothing.

**One thing did not hold, and it's the finding I'd most value your view on.** A
contributor can record a bearing — or a mark setting a colleague's bearing
aside — and put a *teammate's* name on it as the person who did it. The server
accepts it, and that teammate's next sync delivers a bearing they never took,
under their name.

I've rated it as not blocking deployment, and I want to be transparent about that
reasoning so you can disagree with it. The person doing this has to already be a
contributor the project owner deliberately invited — someone who could already
record deliberately bad bearings under their own name and pull the estimated
position just as far off. Nothing is destroyed, altering an already-stored
record's author is still refused, and the fabricated record shows up in the
project's activity log with the name on it.

But I don't want to simply accept it, for a reason that's specific to research
rather than to software: **a bearing credited to the wrong observer is a record I
couldn't defend in a permit file, a data-management plan, or a paper.** It's not
a data-loss problem, it's a scientific-record problem, and the two features whose
entire purpose is recording who observed what are the two this makes say
something false. I have work scheduled on it and two candidate designs written
down. If you think the severity rating is wrong, I'd rather hear it now.

The cause is worth mentioning because it's the same shape as most of the rest:
the rule against putting someone else's name on a record has an exemption for
people your project can already see. That exemption was correct when a project
meant one person's own phone and laptop. It became "any teammate may be named"
the moment team membership joined the query, and **nothing was written down when
that took effect.** No individual change was wrong; the combination was. I'm now
building a single table of who may do what, precisely so the next combination is
visible before somebody attacks it.

## What I'd value from you

These are the parts I can't check myself:

1. **Whether one project is really isolated from another.** This is now a
   multi-tenant system in miniature, and I tested it as one — a stranger with
   their own project couldn't read, write, or affect anything in a project they
   weren't a member of, on any endpoint I could find. But "on any endpoint I
   could find" is doing a lot of work in that sentence, and it's exactly the kind
   of claim I'd rather have someone else try to break.
2. **The severity call on the attribution finding above.** Not blocking, in my
   judgement. Please tell me if that's wrong.
3. **Backup authenticity, key custody, and retention.** Archives are signed now,
   with the verifying key kept alongside the restore procedure rather than beside
   the archives. Is that the right shape, and is there an NAU practice or service
   I should use instead of rolling my own? Related: what's the standard answer to
   "prove this backup is both genuine *and* the one you think it is" — I clearly
   got the second half wrong on my first attempt.
4. **TLS and hosting.** I now have a reverse proxy with automatic certificate
   handling committed, but I built it without knowing your requirements, which
   was the wrong order — and it has never been exercised with a real certificate
   on a real hostname. If NAU would host this, I'd rather rebuild to your
   requirements than retrofit. This also bears on the rate-limiting problem
   above: the standard fix is a trusted-proxy header, and how far to trust it
   depends entirely on what sits in front.
5. **Whether the risks I've decided to accept are reasonable ones** for research
   data of this sensitivity. I've documented them explicitly rather than leaving
   them implicit. They include: not defending against a departing team member's
   existing local copy of data they legitimately had; not encrypting the app's
   local database, relying on device disk encryption instead; and **retaining
   invitation records indefinitely, which means a project keeps a permanent list
   of every address anyone was ever invited with, including people who never
   replied.** That last one is a retention question rather than a security one,
   and it's the sort of thing I'd expect you to have a policy on.
6. **One default I've now decided to remove, and I'd like the interim
   challenged.** The app backs up project data to the user's own cloud storage
   (iCloud/Google Drive), unencrypted, and this is currently **on by default**. I
   decided that when the app was single-user and the data never left one person's
   phone, and that reasoning stopped being true when I added project sharing. **My
   decision is to retire the feature outright** — once the server exists it's
   redundant, and a project owner who wants raw data for analysis is better served
   by an explicit export than by an unattended copy to consumer cloud storage. I
   can't remove it the day I decide to, because until a server is actually
   deployed that copy is some users' only backup, so the interim step is to turn
   the default off. **The question for you is whether that interim is acceptable,
   or whether unencrypted animal coordinates in consumer cloud storage is
   something that should be off — or encrypted — before anything else happens.**
7. **Mobile platform backup, which I only belatedly realised I'd never decided
   about.** My reason for not encrypting the app's local database is that the
   operating system's sandbox protects it. But nothing in the app opts out of
   Android's automatic cloud backup, so the database — every coordinate in it —
   is eligible to be copied to the user's Google account by the platform. Turning
   it off is one line. Whether *off* is right for research data, or whether a
   managed-device posture is what NAU would expect instead, is a policy question
   and I'd rather ask than guess. The same applies to iOS and iCloud device
   backups.
8. **What NAU requires** of a system holding location data for protected species
   if it's ever to run on university infrastructure, or be named in a
   data-management plan or IRB submission.

Three items I previously flagged as mine rather than yours are closed and
re-verified: the client refuses an unencrypted server address at the point the
connection is actually made rather than where it's typed; platform-level
transport protection is confirmed on physical hardware; and the sign-in
rate-limiting problem is resolved by refusing to run rather than by hoping.

I have a written plain-language summary of the whole risk picture — assets,
threat actors, what holds up, what doesn't, and what's deliberately out of scope
— that I can send or walk through, whichever is easier for you. It's a few pages
and assumes no knowledge of the codebase. There's also a detailed running record
of every round of testing if that's more useful than the summary. I'm happy to
meet if that beats reading either.

No urgency on my side: nothing is exposed and nothing will be until this is
resolved, so please take the time you need.

Thank you,

Michael Shafer
michael.shafer@nau.edu
