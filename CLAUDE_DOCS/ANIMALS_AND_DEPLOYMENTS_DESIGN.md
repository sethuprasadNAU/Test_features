# Animals, tags and deployments

**Written 2026-09-14 by the planning session, from Michael's review of task 11.241 and the
conversation that followed. This document is the decision; tasks cite its sections rather than
restating them.**

It supersedes two decisions made on 2026-09-13, and says so where it does.

---

## 1. Three things, and what each one is for

| | What it is | Created when |
| --- | --- | --- |
| **Tag** | **A transmitter you own.** Equipment. | You buy it and enter it — **before any animal** |
| **Individual** | **An animal you are studying.** The subject. | You decide to study it, or you catch it |
| **Deployment** | **A tag on an animal, between two dates.** | You put that collar on that animal |

**Michael's workflow, in his words, is what forces this shape:** *"create a project, add a listing of
all the tags they purchased, then build a list of individuals … Only after they add the animals in
their list would they link a tag to an animal."*

> **A tag with no animal is the normal starting state, not an exception.** Anything that treats an
> unlinked tag as incomplete — hiding it, listing it last, inventing an animal for it — has this
> backwards.

### 1a. The one route that creates all three at once, and why it is not a relapse

**Decided by Michael 2026-09-14, mid-task, during 11.249.** The Record screen's quick-add — the
"＋ Add new tag" on the tag wheel, for a tech who hears a collar that is not in the list — now writes
**a tag, an animal and a deployment attached today, in one transaction**, asking for the tag ID, the
frequency and the animal's name as three separate fields.

**This is the app asserting an animal on a person's behalf, which §1 has just forbidden, so the
reason it is allowed here is worth writing down rather than remembering.** Everywhere else, inventing
an animal would be a scientific claim nobody made — an empty animal row named after a collar,
implying a study subject that may not exist. **On this screen the claim has already been made:** the
person is about to record a bearing on that collar, which is a recorded assertion that something is
wearing it. Refusing to create the animal would not avoid the claim; it would only leave the
bearing's animal unnamed, and — after task 11.249's rule that the wheel offers only collars on an
animal today — it would make the new collar vanish from the wheel it was just added from.

**The scope is exactly this one dialog.** Project Setup, the Tag Library, the CSV import and
`copyFromLibrary` all still create equipment and nothing else (task 11.245 item 2).

**A second route, added by task 11.321 (2026-09-30): More → Animals → *Quick add*.** It creates
animals, tags (or copies them in) and deployments together, for a batch being collared. **The same
reasoning holds and is stronger**: the person is typing the animal names themselves, so nothing is
asserted on their behalf. Every row is written in one transaction or none, with the date the tags
went on chosen at the top. `tag_creation_never_invents_animal_test.dart` declares this route.
**A row whose Tag ID is already on the project but whose frequency differs stops and asks** (task 11.339,
Michael, 2026-10-08: *stop and ask*), the way a frequency matching two tags already did. Its review line
names both frequencies, and nothing is added until the person picks *Use the existing tag* or *Create
anyway*. Task 11.324 had made the existing tag the default there, which in a pasted table attached the
animal to the wrong collar whenever the Tag ID matched by coincidence and nobody read the line. A row whose
Tag ID **and** frequency both match uses that tag without asking: its frequency already finds it.

**A third, older route the guard could not see until task 11.322: season clone.** It copies the old
season's animals and tags in one write. It invents nothing; every animal and tag is a copy of one that
already existed. The widened guard now sees it and declares it.

---

## 2. Why the link needs its own row (and why the 2026-09-13 rule is withdrawn)

On 2026-09-13 the rule was: **a redeployed collar gets a new tag row.** That was defensible only
while a tag row was created *at the moment of deployment*. It is not defensible now.

**Under §1, a tag row is a piece of equipment.** Asking somebody to create a second inventory row for
a collar they already own would make the inventory lie about how many collars they have, with two
rows carrying the same identifier. **That is a false record, not an inconvenience.**

**So the dates belong to the link, and the link is a row.** `Tags.date_put_on` and
`Tags.date_removed` move onto `Deployments`; `Tags.individual_id` (added the day before, task 11.240)
is removed.

**Three things this buys, which are the argument for it:**

1. **A bearing gets its animal from time, not from a pointer.** Correcting a deployment's dates
   re-attributes exactly the window corrected, and nothing else. The danger the 2026-09-13 rule was
   invented to *avoid* — a correction silently rewriting who every past bearing was about — is
   **solved** here rather than prohibited.
2. **A dropped collar stops lying.** A collar that falls off keeps transmitting, and bearings taken
   on it afterwards fall outside every deployment. **The animal is honestly unknown.** Under a single
   `individual_id` they would belong to that animal forever.
3. **Michael's interlock (§6) is an interval rule.** It is natural on a table of intervals and only
   half-expressible on a column.

---

## 3. Tags — the inventory row

Keeps: `tag_id`, `project_id`, `lineage_id`, `tag_name`, `frequency_mhz`, the pulse-mode columns,
`notes`, `status`, `color_hex` (retired/nullable — see §5).

**Loses:** `date_put_on`, `date_removed`, `capture_date`, `individual_id`.

- **`tag_name` is the tag's identifier, not an animal's name.** Every label reading *"Tag / animal
  name"* becomes **"Tag ID"**. The column keeps its name; the words a person reads change. Michael:
  *"so that there isn't any confusion that a tag identifier and an animal name are different."*
- **`status` here is the equipment's** — working, failed, retired, lost. **It is not "deployed"**:
  whether a collar is currently on an animal is derived from §4 and must not be stored twice.

---

## 4. Deployments — the dated link

`deployment_id`, `project_id`, `tag_id`, `individual_id`, `attached_date`, `removed_date` (null =
still on), plus the standard sync columns. **Project-scoped like everything else.**

- **`attached_date` may be null**, per Michael 2026-09-13: *"It is okay to make the tag put on date
  and tag off dates empty."* A deployment with no attached date covers no interval, so it attributes
  no bearings — **that is the correct consequence and must be stated, not patched around.**
- **No `lineage_id`.** A deployment is a fact inside one project. A season clone (`/11-56`) copies
  deployments and re-points both ends at the new project's rows.
- **The capture that put this collar on is this row's `attached_date`.** There is no separate capture
  record — see §8.
- **A deployment date is the field site's calendar day, at its own midnight in the row's zone — since
  task 11.331 (2026-10-10, schema v20); see §4c.** Each project has a time zone and each deployment row
  records the zone its days were written in, so a row is the same day on every phone and on the server.
  The rest of this bullet is the history that decision replaced, kept because it is why.
  *Until v20:* **a deployment date is a local calendar day, at its own midnight.** Decided by task 11.244,
  2026-09-14, and recorded here because the design did not make it and it is load-bearing:
  **UTC midnight would place a 9 a.m. collaring in New Zealand *before* the deployment it belongs
  to, and silently lose the first morning of bearings.** The reasoning is on `deploymentDateFor`.
  **Known cost, written down rather than discovered:** the same row renders as the neighboring day
  on a device in another timezone. For a crew working one study area that is invisible; **for a
  project spanning zones it is a real ambiguity**, and it is in Discovered Scope rather than fixed.
  **It grew a second face on 2026-09-15 and the two share one trigger.** §4a tells a bare day from a
  swap time by asking whether the value sits at *this device's* midnight, so across zones a New
  Zealand crew's date-only removal reads in Arizona as a removal at 5 a.m. the previous day — and
  that day's bearings are attributed to the animal on one device and to nobody on the other. **The
  first project whose crew spans zones is the trigger for both**, and the fix on that day is an
  explicit instant or offset column, not a cleverer sentinel. Task 11.251 recorded it in Discovered
  Scope.

### 4a. What a dated interval means when a bearing has a clock — decided 2026-09-15

**The bug that forced this.** `Deployment.covers()` compared a bearing's instant against a
midnight-stamped day, half-open, so **a bearing taken at 2 p.m. on the day a collar came off was
attributed to nobody** — and on a same-day swap, to the *next* animal instead. Michael saw both on
his map. **It was not an edge case in the code even though it is one in the field:** §5a closes an
animal's previous collar automatically whenever a new one is attached, so the "removal day" case
fires on every ordinary recapture.

**Michael's decision, 2026-09-15**, choosing between *report the day as contested*, *ask for the
swap time*, and *freeze the animal onto the bearing*:

> *"I'm leaning toward b. I think adding a switch time would help. It is extra data entry but
> honestly this will likely never happen: a tag removed from an animal one day and mounted on
> another on the same day. This is a real edge case… If asking for a time of the swap is needed to
> get around this issue so be it."*

**So there are two rules, and the first one does most of the work:**

1. **A date-only deployment covers the whole of both its end days.** Attached on the 3rd, removed on
   the 9th, means the 3rd through the 9th inclusive. **This alone fixes the bearing taken on the day
   a collar came off**, which is the common case and has nothing to do with swaps. §4's
   calendar-day decision is unchanged; what changes is that a *day* is a day and not the instant it
   begins.
2. **A same-day swap may carry a time, and a time beats a day.** The §5a confirmation — the one that
   already stops and names both collars and both dates — **offers a time, prefilled with now.** In
   the field the swap and the tap happen minutes apart, so this is a value to accept rather than a
   value to type. The same instant closes the outgoing deployment and opens the incoming one, so the
   two can never disagree.

**Freezing the animal onto the bearing (option c) is refused**, and this is the place that says so:
§2 decided a bearing gets its animal from *time* precisely so that **correcting a wrong date
corrects the bearings**. A pointer written at record time would make every mis-dated deployment
permanently unfixable.

**And the case neither rule covers is still possible, so it gets an answer rather than a guess.**
Two deployments can both cover a moment — dates typed by hand rather than swapped through the
confirmation, a row from an older build, a crew member who skipped the time. **The derivation then
reports the moment as *contested* and names the candidates; it never picks one.** A reader shows it
neutrally. **This is expected to be rare exactly because rule 2 exists** — which is Michael's own
argument for rule 2, applied to the leftovers.

> **The columns already hold instants, so this needs no new column.** `attached_date` and
> `removed_date` are `TEXT` holding encoded UTC instants; `deploymentDateFor` is what discards the
> time by rebuilding local midnight. **Storing a real time is a change to what the app writes, not
> to the schema.**
>
> **Which makes it a compatibility hazard the wire-shape freeze cannot see**, and that must be a
> written decision rather than a silent one: an app build on the same schema major that has not had
> this change reads a 3 p.m. `removed_date` as a *day* and computes a different answer from the
> same bytes. **That is "a name reused for new meaning"** — named on `wire_shape_freezes.dart` as
> the one thing the freeze is blind to. The alternatives are to accept it (pre-beta, few devices,
> §9 already says wipe) or to add a nullable instant column so an older build sees nothing rather
> than something it misreads. **Task 11.251 decides and records which.**

**Decided by task 11.251, 2026-09-15: the existing columns, and the hazard is accepted — because it
was measured and found not to be one.** The columns have declared a UTC instant since the table
existed; the app narrowed what it wrote to midnights and is now widening it back on a swap, which is
not a column given a new meaning. And every reader in a build without this change gives a
correct-by-its-own-rule answer to a timed value: the old `covers()` read the column as an instant,
which a timed value is; the wheel's day rule normalized it to its day; the interlock's `overlapDays`
ceilings hours to days and calls a same-instant swap zero. The only place two builds disagree is a
*date-only* removal day, and that disagreement is the bug this section exists to fix. The nullable
column would have touched the wire, the server's schema and the shared interlock for a case Michael
expects to *"likely never happen"*, and an older build would then have computed the whole-day answer
— the same one it computes today. Not worth it pre-beta, with few devices and §9 already saying
wipe. **Reopen triggers, both named on `deploymentEndHasTime` — which now lives in
`packages/tritrack_sync/lib/src/deployment_interlock.dart`, the app re-exporting it** (moved
2026-09-16 by task 11.263, because the interlock needs the sentinel too): a build without this change
found in the field beside one with it (§9 applies), and the first project whose crew spans time
zones — where a date-only row written at one zone's midnight is not at the other's, and the sentinel
fails; the plan's Discovered Scope carries that one.

> **The cross-zone trigger gained a second reader on 2026-09-16, and it is the server.** It reads the
> bare-day sentinel **in its own zone — UTC in the container** — so a bare day written in Arizona
> reads there as 07:00 (narrower), **and a timed swap landing on exactly 17:00:00 Arizona reads as a
> UTC bare day and is refused on push** (wider). Priced on `DeploymentInterlock`'s doc comment: one
> minute in 1 440, for a hand-picked time. **Both faces close the same way** — a nullable instant
> column, or a stored zone beside each date. **The trigger is no longer only about two crews; a
> single crew already has one server in another zone.**

**The Record wheel asks by the moment too — decided 2026-09-16, withdrawing a rule from 2026-09-14.**
Task 11.249 made the wheel offer any collar whose deployment *spans today*, closed at both ends,
on Michael's ruling that on a handover day *"they both should be listed for that one day."*
**That was right while a deployment knew only calendar days.** Rule 2 above changed what the data can
say, and **the wheel is the last reader still asking by the day** — the Log's filter, the Map's
filter and the Map's color all ask by the moment.

> **The argument for the whole day collapsed under one question from Michael, 2026-09-16:** *"Taken
> off at 9 am but their bearing is at 11 am but on the old tag. Wouldn't the old tag be with me not
> the animal?"* **Yes.** A bearing on a collar after it comes off is a bearing on the collar in
> somebody's bag, and it is not a record worth keeping the collar on the wheel for. **The planning
> session's defense of the rule used exactly that example and it was wrong.** The remaining defense —
> entering the morning's bearing after lunch — **does not exist either: the Record screen stamps
> `DateTime.now()` and there is no backdating.**

**So: a collar is offered until the moment it comes off.** After a timed swap the old collar leaves
the wheel the instant the swap is confirmed and the new one appears. **Two collars for one animal
appear only when the removal carries no time** — a hand-typed date — which is precisely the case
where the app genuinely cannot tell, and §4a's contested rule already governs it.

**Where the time is offered, and where it is not.** The §5a confirmation offers it on any same-day
swap — the animal already wears a collar that comes off, *or* the chosen collar came off another
animal today — and **not** when a collar goes from the shelf onto a bare animal, because a time there
can only lose the morning's bearings (collared at 9 a.m. in the field, linked at 2 p.m. at the truck).
*Set removed date* offers one when the picked day is today, because that is the outgoing end of the
tag's swap and it is written on the other animal's screen, where the confirmation cannot reach it.
**A third shape, added 2026-09-16 by task 11.263:** the link confirmation also offers a time when the
animal's *previous* collar came off **earlier today on her own screen** — there is nothing to close
and no history on the new collar, so neither of the first two shapes fires. **Without it the ordinary
two-step — collar 1 off with a time, collar 2 on — produced a bare-day link overlapping the morning
and was refused.** Three shapes, not two.
~~Dismissing the time picker records the day alone.~~ Correcting an attached date writes a bare day
and drops any time the row carried.

### 4c. A deployment day is the field site's day — decided 2026-10-06, built 2026-10-10 (task 11.331)

**Michael's decision (`CLAUDE.md` standing decision 4):** give each project a field-site time zone; do
not convert deployment days to plain dates. The cross-zone trigger §4 and §4a recorded twice — a crew in
two zones, and a server in another zone — is closed by it.

- **The project has a time zone**, an IANA name (`Projects.time_zone`). It defaults to the zone at the
  center of the project's area — the center's own zone, a sea zone at sea (`Etc/GMT±N`, shown in plain
  words, never by its raw inverted name), never the nearest land — read offline from boundaries the app
  ships; with no area, the creator's phone's zone. The creator sees it in words on the project form and
  can change it; when an area is set later and its zone differs, the form offers it.
- **Each deployment row records the zone its days were written in** (`Deployments.time_zone`, the
  project's zone at that moment). **A bare day is the start of that day in that zone.** Every screen,
  each form's "today", the interlock and `deployments.csv` read a row's days in its own zone; a same-day
  swap time is still an exact instant.
- **Changing the project's zone rewrites nothing.** Rows keep their zones, so recorded days stay the
  same days, and a phone offline with older rows cannot disagree. New links and "today" use the new zone.
  **What it does to bearing matching:** at the edge of a day, a row written under the old zone ends at
  the old zone's midnight, so the boundary of *that* row moves by the zones' difference — usually an hour
  — compared with a row written after the change.
- **The interlock compares two bare days as days**, each in its own zone, so after a mid-season zone
  change the 16th still starts after the 15th ends (`DeploymentInterlock`, "two rows written in
  different zones"). Anything with a time is compared as instants.
- **The server stops guessing.** A row with a zone is read in it, exactly as the device reads it; the
  11.266 flag (`zonelessEndsAreInstants`) now applies only to a row with no zone — one from a build
  older than v20.
- **Existing rows (the v20 migration).** Each project took its area's zone (or the phone's); each
  deployment took its project's — **except a row whose dates sit at the migrating phone's midnight and
  not at the project zone's**, which keeps the phone's zone so the days somebody typed do not change.
  Those rows are listed by id in the migration's log line. **A deviation from the plan's wording**
  ("assign each the project's zone"), recorded in task 11.331's report.
- **Older and newer builds (same major, 6).** A v19 app pushing to a v20 server sends no zone; the server
  stores null and reads the row as instants, as before. A v20 app pulling such a row reads it in the
  phone's own zone, as v19 did. A v19 app pulling a v20 row keeps the zone column it does not know
  untouched (`UnknownColumnStore`) and reads the days in its own zone — the old behavior, for that phone.

### 4b. A removal can be corrected, and "I don't know when" is a choice — 2026-09-16

**Task 11.261, from Michael's phone:** *"the app doesn't provide a way to change the removal time of
a tag."* He was right, and it was worse than he said. **`Set removed date` rendered only while there
was no removed date**, so a removal could be recorded once and never corrected — while the *attached*
date had an editor all along. **That asymmetry was never a decision; it was an oversight, and this
section is where the corrected rule lives.**

- **A removed date and time can be edited after the fact**, by the same rung that set them —
  contributor-level, like every other deployment edit. **Task 11.255's owner rung is on destruction,
  and correcting a date is not destruction.**
- **A removal can be cleared.** *"I recorded it as off and it is still on her."* The alternative was
  *Remove record*, which says the collar was **never** on that animal — a different and destructive
  claim, and the wrong tool for a mis-tap.
- **"Day only" is a choice, not a cancel.** The dialog offers **Day only / Set a time / Cancel**.
  The old behavior — *dismiss the picker to record the day alone* — **is withdrawn**: it was honest
  and backwards, because cancelling reads as abandoning the action, and a person who genuinely
  wanted to abandon it had nowhere to go.
- **One writer, reached from two places.** The Record screen's handover prompt (task 11.260) keeps
  its own entry point — **a round trip to More → Animals mid-bearing costs a field crew more than
  the duplication saves** — but both call `writeRemovedDate`, so there is one set of refusals and
  one place to fix. **That was task 11.261's call against this session's stated preference, with its
  reason, and it is the better answer to the concern that was actually raised.**
- **Editing a removal re-attributes the bearings it spans, and the screen says how many before it
  happens.** That follows §2 — a bearing gets its animal from time — and §5a's rule that a change to
  records the person did not open must be named first.

**Confirmed by the planning session, 2026-09-15 — both of those are the right calls and neither is
provisional.** Not offering a time when a collar goes from the shelf onto a bare animal is the
stronger of the two: **with no competing deployment there is nothing to disambiguate, so a time
there can only subtract.** ~~And a time picker for a day in the past would be asking a person to
invent a number, which is the thing §4 declined to do in the first place.~~
**Narrowed 2026-09-17 by task 11.265, and the distinction is the whole of it: asking is not
inventing — prefilling is.** Not offering a time on a past day is right **where nothing needs one**,
and wrong where a swap on that past day cannot otherwise be recorded at all. **A time picker with no
prefill asks the person who was there for a fact they hold**; refusing to record what happened puts
the data at *absent* rather than *approximate*, which is worse. See §6b.

**One correction the planning session owes this section.** The hazard paragraph above — mine, written
before the task ran — called storing a time *"a name reused for new meaning."* **It is not, and 11.251
was right to say so.** These columns have declared a UTC instant since the table existed; what
changed is that the app stopped narrowing what it writes into them. **A build without this change
reads a timed value correctly** — the old `covers()` compared instants, the wheel normalized to the
day, the interlock ceilings hours — which 11.251 measured rather than argued, by watching the
timed-swap test stay green under the old body. **The only disagreement between builds is on a
date-only removal day, and that disagreement is this section's bug.** The freeze was never blind
here; I mis-classified it.

---

## 5. Individuals — the animal

As built by task 11.240, with one removal and one clarification.

> **Corrected 2026-09-14 by task 11.243, which checked rather than assumed.** This section said
> `unknown` was *"added"*; `IndividualStatus` has carried alive/dead/unknown since schema v16, so §5
> needed no code at all. **The document was wrong about the code and a test now says so**
> (`individuals_test.dart`) — which is the right repair: a claim in a document that nothing checks
> is the next thing to go stale.

- **No capture date. Dropped 2026-09-14, and the reasoning is worth keeping** because the planning
  session proposed it and Michael asked the right question: *"Do we even really need this? How would
  it be used?"*
  - **For any collared animal the answer is already there:** the earliest deployment's
    `attached_date` *is* when that animal entered the study. A stored field would duplicate it and
    then disagree with it.
  - **The only case it would add anything** is an animal caught and released *without* a collar,
    later collared — and **that is the handling event §8 puts out of scope.**
  - **It is cheap to add later and that is why deferring costs nothing:** a new *nullable* column is
    an additive change the wire-shape freeze permits without a major bump. **If a real use appears,
    it arrives then, with the use written down beside it.**
  - `Tags.capture_date` is removed rather than moved.
- **`status` here is the animal's — alive, dead, unknown** (already built; see the correction
  above). *"Unknown" asked for by Michael 2026-09-14,
  and it is the honest default*: a collar goes quiet and the animal's fate is usually not known.
  **"Lost to follow-up" is deliberately not a fourth value** — it says the same thing as unknown in
  more words, and the standing rule is simplicity over verbosity.
  **A recovered collar must never change an animal's status**, and an animal's death must never
  change a collar's.
- **`color_hex` is the one home for color.** Unchanged from 11.240: it is the animal's color, so
  every collar it has ever worn draws in it.
  > **A note on citing that retirement as a precedent — added 2026-09-17, task 11.268.**
  > **`TagColumnKind.retired` applies to a `display`-kind column, not to one that is already
  > versioned.** `color_hex` could be retired cheaply because it had **never** been on
  > `Tag_Versions`. A `measurementContext` column is derived onto that table by
  > `versionedTagColumnNames`, so reclassifying one **derives it off a table the migrations still
  > build** — a mismatch only a migration fixes, which is a schema major. **Retiring a versioned
  > column is a migration, not a reclassification.**
  `Tags.color_hex` stays retired and nullable (decided
  2026-09-13; dropping it is a later major, not a free ride).

---

## 5a. Linking a tag — the dates fill themselves in, and say so

**Michael, 2026-09-14.** The model is only as good as the two seconds it takes to use in a truck.

**When a person links a tag to an animal:**

- **`attached_date` defaults to today.** Editable, but nobody should have to type it.
- **If that animal already has a tag with no removed date, that tag's `removed_date` is set to today
  too** — the recapture case: the old collar came off as the new one went on.
- **Both changes are shown and confirmed before they are written**, naming the dates and the tags:
  *"Link 150.523 to Marie, attached today. Marie's 150.321 will be recorded as removed today."*

> **The confirmation is not politeness — it exists because this writes to a row the person did not
> touch.** Silently amending a second record is how a field note becomes wrong without anybody
> making a mistake. **Name what will change, then change it.**

**The two rules fit together, which is worth noticing rather than discovering:** the handover writes
the same **instant** to one deployment's end and the next one's start — **no overlap at all**. The
interlock never fires on the ordinary case, which is what makes it a guard rather than an obstacle.
~~a **zero-day** overlap, comfortably inside §6's one-day allowance~~ — **there is no allowance since
§6a (2026-09-16); the sentence was written when there was, and task 11.264 found it still standing.**

**Edges to decide in the task, not here:** an existing deployment that already carries a removed date
is left alone; a deployment with no attached date is not silently given one.

---

## 6. The interlock — Michael's rule, 2026-09-13, verbatim in intent

> *"Put an interlock on the animal such that it can't have two tags linked to it unless the tags
> attached/removed dates don't overlap by more than one day (old tags are replaced by new tags on the
> same day). A tag can only have one [animal] that is currently on it per the tag dates. If a user
> tries to link a tag to an animal with dates that overlap by more than one day it tells the user to
> fix the removed/attached dates of the tags."*

Two constraints, one tolerance:

- **An animal's deployments may not overlap by more than one day.** The one-day allowance is the
  real-world handover: the old collar comes off and the new one goes on the same day.
- **A tag is on at most one animal at any moment**, by the same dates.
- **A link that would violate either is refused**, with a sentence naming the dates to fix — never
  silently adjusted.

**The server applies this too, or it is advisory only.** A rule enforced on one device is not a rule
about the record; it is a rule about that device.

### 6a. The one-day tolerance is withdrawn — 2026-09-16

**Michael, pushing back on the machinery built to explain the overlap:** *"What if we just enforce a
rule that every animal in the list can't have more than one tag attached and can't have more than
one tag with removal times that overlap or the same."* **He is right, and the tolerance is the
source of everything that was built around it.**

**Why it existed and why the reason is gone.** The one-day allowance was the only way to record a
handover when a deployment knew nothing finer than a calendar day: both collars were stamped *the
15th*, so they had to be allowed to overlap on the 15th. **Task 11.251 gave a swap a time** — the old
collar ends at 14:32 and the new one starts at 14:32, **an overlap of zero.** The tolerance is now
reachable only by choosing *Day only* on a same-day removal.

**The rule, from 2026-09-16:**

- **Two deployments of one animal may not overlap at all.** Same for one tag across animals.
- **A same-day handover requires a time.** The app already offers one defaulted to *now*, so it is a
  tap rather than a typed number, and the person is nearly always recording the swap as it happens.
- **"Day only" is not offered when it would create an overlap.** It stays for a *past* day, where a
  time would be invented (§4a) — ~~and a past-day removal cannot overlap with today in any case~~.
  **That justification was too narrow and task 11.264 caught it: it looked only at *today*, and the
  pair a past-day removal overlaps is on that past day.** See §6b.

### 6b. A handover that happened on a past day — 2026-09-17

**Task 11.264 found the hole §6a opened.** Collar 1 off Kea on the 10th, collar 2 on the same day,
entered on the 12th: *Set removed date* offers no time for a past day, *Edit attached date* writes
only bare days, and **two bare days on one date are refused since §6a** — with a sentence telling the
person to do something **no control offers**. That is a refusal with no way forward, which this
project already names as a trap.

**The rule: a time is offered on a past day exactly where one is needed, and never prefilled.**

- **Needed** means another deployment of that animal already covers the picked day. **Only then.**
- **Never prefilled.** A prefilled time on a past day would be the app inventing a number; an empty
  picker asks the person who was there for a fact they hold. **§4b's rule survives intact for every
  day that needs nothing.**
- **The alternative was to leave a real handover unrecordable**, which puts the data at *absent*
  rather than *approximate*. **Approximate and recorded beats exact and missing.**

> **What §6b does not resolve, found by task 11.265 while building it — and the doc says so rather
> than reading as a promise.** *"A time is offered exactly where another deployment already covers
> the day"* is the right trigger and **it cannot, on its own, walk two never-yet-timed rows to zero
> overlap.** The arithmetic, worked through rather than guessed: you date collar 1's removal to the
> 10th when nothing else is on the 10th, so **no conflict is detected and no time is offered** — a
> bare day claiming its whole 24 hours. Attaching collar 2 on the 10th is then **refused**, so that
> row is never written, so **collar 1's removal never acquires the neighbor that would make its
> editor offer a time.** Each control is correct; **the pair deadlocks.**
>
> **The fix is §5a's own shape, not a wider trigger:** when a collar is attached on a past day and
> the animal's current collar carries a bare-day removal on that same day, **ask for both times in
> one confirmation**, exactly as the same-day swap already does for today. **Task 11.270.**
> **Broadening "offer a time whenever the day is past" is the wrong answer** — it reopens §4b and
> asks for numbers nobody needs.

**How rare, honestly: unknown, and not countable from a device.** Michael expects a same-day swap to
be rare and a late-entered one rarer still. **It is fixed because the refusal names an impossible
action, not because the case is common.**
- **Everything built to explain a live overlap is deleted, not improved:** the Record screen's
  handover prompt (task 11.260) and its collar chooser (task 11.262). **The state they describe can
  no longer be created.**

> **This is the second decision withdrawn for the same reason in three days**, the first being the
> Record wheel's whole-day rule (§4a). **Both existed because a deployment could not say when**, and
> both survived task 11.251 unexamined. **`CLAUDE.md` carries the rule; task 11.264 is the sweep**,
> because two instances found by a phone is a pattern rather than a coincidence.

**What survives the withdrawal.** §4a's **contested** answer stays — for rows written by an older
build, for the cross-zone case §4 records, and as the derivation's honest reply when it is asked
about a moment two rows really do cover. **What changes is that this app can no longer create one.**

> **And the Record screen is not locked.** Michael raised it — *"maybe the record screen should lock
> out the recording until the user fixes the overlap"* — and it is refused here with the reason:
> refusing at the source means the state cannot arise from this build, so a lockout could only ever
> fire on legacy data, and **locking a field crew out of recording, in the field, to fix a
> data-entry problem is a large hammer for a case that pre-beta data makes nearly impossible.** The
> contested rendering on the Map and the Log is enough for anything historical.

---

### 6c. A bearing about a deleted animal still names her — decided 2026-09-17

**Task 11.272 made this choice in code and said so, which is why it is being decided here rather
than discovered later.** The Log resolves a bearing's animal with deleted animals **included**, so a
record taken while a since-deleted animal wore the collar still carries **her name and her color**.
**The Map does the opposite** — it holds only live animals, so the same bearing falls back to a
neutral swatch and the collar's own name.

**The Log is right and the Map should follow.**

- **Deleting an animal does not move a bearing.** §5's delete confirmation promises exactly that, and
  it is true. **The bearing still happened and it was still about her**, and the app still holds the
  deployment row that says so.
- **So drawing it neutral is not discretion — it is a fact the app has and declines to show.** The
  alternative reading, that a destroyed record should stop being named, does not survive the
  promise the delete confirmation already makes.
- **Consequence, stated rather than discovered:** the Map's legend will gain a row for an animal that
  no longer exists. **That is correct** — the legend describes what is drawn, and her bearings are
  drawn.

**Until the Map is changed, the two screens disagree**, and the disagreement is recorded here so the
next reader meets a decision rather than an accident.

---

## 7. What does not change

**Observations still name a tag version.** You observed a signal from a transmitter, not an animal.

**The animal for an observation is derived**: the deployment whose tag matches and whose interval
contains the observation's time. **No `individual_id` on `Observations`, ever** — that would freeze a
derivation that must stay correctable, and undo task 11.32 at a larger scale.

`Triangulation_Sessions`, `Estimated_Positions` and `Actual_Tag_Locations` stay tag-scoped.
`Non_Detections.tag_ids_listened_for` stays sealed.

**"Same animal as…"** (built in 11.241, and confirmed working on Michael's phone) survives: it
re-points the absorbed animal's **deployments** and moves no bearings.

---

## 8. Out of scope, by decision — not deferred

**Michael, 2026-09-14: *"This isn't a general field recording tool."*** So:

- **No record of a handling event that is not a collaring.** A recapture where measurements are taken
  and no collar changes has no row and will not get one. **This is a decision, not a gap waiting for
  a trigger.**
- **No morphometrics, no health, no sampling.** The app records where an animal was and what was
  heard from it.
- **CSV import of animals: later, its own entry.** Michael: *"we'll want a csv import eventually but
  we'll do that later."*

---

## 9. Migration — there is none, and that is deliberate

**Michael, 2026-09-14: he will wipe.** Every device, and the beta server, hold development data only.

- **The affected tables are dropped and recreated.** No data-preserving path is written, because
  writing one would be machinery serving nothing.
- **Task 11.240's one-animal-per-tag backfill is removed**, not compensated for. The spurious animals
  it created disappear with the wipe rather than needing a cleanup screen.
- **What it costs Michael:** one server redeploy, one phone rebuild, and re-entering his test tags
  and animals once.

---

## 10. Version consequences

**This is schema major 5.** Columns leave `Tags`, a table arrives, and `wire_shape_freeze.dart` will
say so — which is the freeze working as task 11.242 built it.

- Justify it on `schemaMajorVersion` the way majors 2, 3 and 4 are justified, extend
  `schemaMajorFirstMinor`, and run `tool/freeze_wire_shape.dart`.
- **Re-derive the out-of-tree wire readers** before the bump — `TriTrack_Technical_Context.md`
  §"What speaks the wire and is not the app" carries the grep. **The backup scripts were wrong for
  three days after the last bump because no such list existed.**
- **Server first, then the app**, as with major 4.
