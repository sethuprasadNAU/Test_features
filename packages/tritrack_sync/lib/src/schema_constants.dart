/// Table name constants — single source of truth for the app's repositories
/// and DDL, and for the server's Postgres schema and queries. Client and
/// server must never disagree about a table's name.
abstract final class Tables {
  static const users = 'Users';
  static const userEmails = 'User_Emails';
  static const projects = 'Projects';
  static const projectMemberships = 'Project_Memberships';

  /// **Task 11.240.** The animal — the thing actually being tracked.
  ///
  /// Until schema v16 the schema had no row for it, and the animal existed
  /// only as the collar's label. That is fine until the animal changes
  /// collars — Michael's case, raised 2026-09-13: *"Animal named Marie was at
  /// 160.321 MHz last field season, but in March we put on tag 160.523
  /// MHz."* Two `Tags` rows, one bird, and nothing in the database that could
  /// say so.
  ///
  /// **An individual never lists its tags, and since schema v17 a tag does
  /// not name its individual either.** The link is [deployments] — a dated
  /// row — and "Marie's collars", "Marie's track" and "whose bearing was
  /// this" are all queries over it. Every bearing stays attached to the
  /// transmitter it was heard from (see `Tables.observations`; the column
  /// deliberately does not exist there), so a mistake about who wore what is
  /// corrected by editing one deployment's dates, never by touching a
  /// bearing. `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §2 is the
  /// argument.
  ///
  /// **Shaped on `Tags`, because the reasoning is identical (task 11.219).**
  /// Project-scoped, keyed `(individual_id, project_id)`, carried in archives,
  /// and given a `lineage_id` that means exactly what it means on a tag:
  /// recorded, exported, read by nothing live. The same bird in Ponui 2025
  /// and Ponui 2026 is two rows with one lineage — one animal in an export,
  /// and never a word about it in the app, because no message about a tag or
  /// an animal may reveal that another project exists (cancelled task 11.29's
  /// standing rule).
  ///
  /// **Colour lives here and nowhere else.** `color_hex` is the animal's,
  /// not the transmitter's: Marie is one colour across both collars, and
  /// last season's bearings recolour with her. `Tags.color_hex` is retired —
  /// see `TagColumnKind.retired`.
  ///
  /// **Its `status` is the animal's, not the collar's.** *"A few
  /// mortalities"* is a fact about a bird; *"collar removed"* is a fact about
  /// a transmitter. See `IndividualStatus`. There is deliberately **no
  /// capture date** — design §5: for a collared animal the earliest
  /// deployment's `attached_date` already is when it entered the study, and a
  /// stored field would duplicate it and then disagree with it.
  static const individuals = 'Individuals';
  static const tags = 'Tags';

  /// **Task 11.243 (schema v17, schema major 5): a tag on an animal, between
  /// two dates.**
  ///
  /// `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` is the decision; §§2 and
  /// 4 are this table. The short version of why the link needs its own row:
  ///
  /// **A [tags] row is a piece of equipment — a transmitter somebody bought
  /// — and it is created before any animal exists.** It used to be a
  /// deployment (it carried `date_put_on`, `date_removed` and, from v16,
  /// `individual_id`), and the rule for a refurbished collar was *make a
  /// second `Tags` row*. That would have made the equipment inventory lie
  /// about how many collars the project owns, with two rows carrying one
  /// identifier. So the dates and the animal moved here.
  ///
  /// **Three things it buys, which are the argument for it (§2):**
  ///
  /// 1. **A bearing gets its animal from time, not from a pointer.**
  ///    Correcting a deployment's dates re-attributes exactly the window
  ///    corrected and nothing else.
  /// 2. **A dropped collar stops lying.** A collar that falls off keeps
  ///    transmitting, and bearings taken on it afterwards fall outside every
  ///    deployment — so the animal is honestly *unknown* rather than being
  ///    attributed to whoever wore it last.
  /// 3. **Michael's interlock is an interval rule** and is natural on a table
  ///    of intervals. See `DeploymentInterlock`.
  ///
  /// **`attached_date` may be null**, per Michael 2026-09-13: *"It is okay to
  /// make the tag put on date and tag off dates empty."* A deployment with no
  /// attached date **covers no interval and therefore attributes no
  /// bearings** — the correct consequence, stated rather than patched around,
  /// and asserted in `DeploymentRepository`'s tests because it is the thing
  /// that will look like a bug the first time it is met.
  ///
  /// **No `lineage_id`, unlike [tags] and [individuals].** A deployment is a
  /// fact inside one project: *this project's* collar was on *this project's*
  /// animal. It says nothing that two projects could hold a copy of, so there
  /// is nothing for a lineage to identify. A season clone (task 11.56) copies
  /// deployments and re-points both ends at the new project's rows.
  static const deployments = 'Deployments';
  static const projectTags = 'Project_Tags';
  static const triangulationSessions = 'Triangulation_Sessions';
  static const observations = 'Observations';

  /// **Task 11.7.** Why exclusion is a table of its own rather than a couple of
  /// columns on `Observations`, which is the shape everyone reaches for first:
  ///
  /// `Observations` is governed by [MutationRule.author] — only the person who
  /// recorded an observation may write its row — and Phases 6 and 8 went to
  /// deliberate trouble to keep it that way, because an observation is a
  /// primary scientific record and an owner rewriting a colleague's field note
  /// breaks provenance in a way that matters to a publication or a permit.
  /// Sync is *row-level*: the server receives whole rows and authorizes whole
  /// rows, so it cannot tell "an owner touched only the exclusion columns"
  /// from "an owner rewrote the bearing." A data-quality mark stored on the
  /// observation therefore could never leave the device that made it.
  ///
  /// So the mark is a row of its own, authored by the person making it. The
  /// observation is never written at all — which is the strongest possible
  /// form of task 11.7's rule that neither action may rewrite the original's
  /// `user_id`, `last_modified_by`, or any measurement column.
  ///
  /// **Do not "simplify" this into edit access on `Observations`.** That is
  /// the change this comment exists to stop.
  static const observationExclusions = 'Observation_Exclusions';

  /// **Task 11.32.** What a bearing was recorded against, as opposed to what
  /// its tag says today.
  ///
  /// A bearing names a `tag_id` and nothing else, so the frequency the receiver
  /// was tuned to and the name written in the field notebook live only on the
  /// tag row. Tags must be editable — VHF transmitters drift and names get
  /// corrected — so before this table every tag edit retroactively rewrote what
  /// every earlier bearing claimed to have been taken against.
  ///
  /// **Why a table and not three columns on `Observations`.** Copying
  /// frequency, pulse rate and name onto the observation is a hand-maintained
  /// list of "the fields worth copying", and it drifts the first time somebody
  /// adds a column to `Tags`. That pattern had already been found four times in
  /// two weeks when this was written. Instead a row here is the tag's
  /// measurement state at a moment, its column set **derived** from
  /// [tagColumnKinds], and `Observations.tag_version_id` points at the one that
  /// was current when the bearing was taken. Declaring a new tag column
  /// `measurementContext` is the whole of what it takes to make it travel.
  ///
  /// **Why not an opaque blob of tag state on each observation**, which would
  /// also inherit new columns: an unstructured value on a synced table is
  /// exactly the unknown-column surface it took several rounds to harden, and
  /// `RowValidator` cannot check inside one.
  ///
  /// **Project-scoped, like `Tags` (task 11.219, schema v14).** A version is a
  /// version of one project's tag, so it lives in that project and pull
  /// narrows it by `project_id` like the other nine tables. It was global
  /// until copy-on-add, when a tag stopped being a thing several projects
  /// could point at.
  ///
  /// **Never edited except by a correction.** A tag edit is one of two things
  /// and only the person knows which: a *change* (the transmitter drifted)
  /// appends a new version and leaves earlier bearings reading the old one; a
  /// *correction* (it was typed wrong) rewrites the current version in place,
  /// so every bearing taken since that value took effect reads the corrected
  /// one. Earlier versions are never touched by either — the difference between
  /// them **is** the drift record.
  static const tagVersions = 'Tag_Versions';
  static const nonDetections = 'Non_Detections';
  static const estimatedPositions = 'Estimated_Positions';
  static const actualTagLocations = 'Actual_Tag_Locations';

  /// All tables, in the order a device offers them to the server.
  ///
  /// **Two properties, both load-bearing, both checked.**
  ///
  /// 1. **FK-safe creation order** — parents before children, which is the
  ///    order the merger inserts in and the order the DDL creates in.
  /// 2. **Reach before it is needed (task 11.43, reopened)** — a table whose
  ///    rows name a global id is offered only after the table that establishes
  ///    the project's claim on that id. See `offer_order.dart`, which derives
  ///    the constraint from the declarations rather than restating this list,
  ///    and `assertOfferOrderEstablishesReachBeforeItIsNeeded`, which fails if
  ///    a table is added in a position that breaks it.
  ///
  /// **Property 2 no longer binds anything, and the history is worth keeping.**
  /// `Project_Tags` used to sit between `Tags` and `Tag_Versions` because a
  /// publish sends one table per HTTP request, each its own Postgres
  /// transaction, so the server's reachability escape for a tag-bearing row —
  /// the committed `Project_Tags` link — had to be on the server *before* the
  /// request carrying `Tag_Versions` arrived. With the wrong order every first
  /// publish of a project with a tag version had exactly one row refused, told
  /// the person their sync was incomplete, and cleared itself minutes later.
  /// Found on an Android device by task 11.66, not by any test.
  ///
  /// Task 11.219 removed the constraint rather than the guard: tags are
  /// project-scoped now, so no table on this list names an id it needs another
  /// table to vouch for, and `assertOfferOrderEstablishesReachBeforeItIsNeeded`
  /// currently has nothing to order. **It stays**, because the fourteenth
  /// table that names a global id will meet it, and because the reason it
  /// exists is that this was invisible to every test for a month.
  ///
  /// `Project_Tags` has left this list with the wire (task 11.219). The table
  /// itself stays in the app's local SQLite schema, unused, because it is the
  /// only durable record of what the v14 migration did and because an archive
  /// written before v14 still carries its rows.
  static const all = [
    users,
    userEmails,
    projects,
    projectMemberships,
    // Task 11.240: before `tags` and `deployments`, because the merger
    // inserts parents first. A tag stopped naming its individual at v17; a
    // deployment names both, so both come before it.
    individuals,
    tags,
    // Task 11.243: after both the tables it references.
    deployments,
    tagVersions,
    triangulationSessions,
    observations,
    observationExclusions,
    nonDetections,
    estimatedPositions,
    actualTagLocations,
  ];
}

/// The highest schema version this codebase understands. The app's SQLite
/// migrations (`lib/data/db/migrations.dart`) and the server's Postgres
/// migrations must both be defined up to exactly this version — this is the
/// one place that number is written down, so the two schemas can't drift
/// apart on "what version is current" without a compile-time-visible mismatch
/// at either call site.
///
/// This is the **minor** half of the two-part version (task 10.18): it moves on
/// every schema change, compatible or not, because it is also the migration
/// counter and migration numbers can never be reused or reset. Compatibility is
/// decided by [schemaMajorVersion] alone.
///
/// **v20 (task 11.331) is a minor:** `Projects.time_zone` and
/// `Deployments.time_zone`, both nullable — the field site's zone, and the
/// zone each deployment row's days were written in.
const int latestSchemaVersion = 20;

/// The **major** half of the schema version — the compatibility boundary.
///
/// Two builds sync if and only if their majors match. [latestSchemaVersion] may
/// differ freely: an older build preserves columns it doesn't recognize verbatim
/// (see the app's `UnknownColumnStore`) and hands them back untouched, so the
/// only thing a minor difference costs is that the older build cannot *display*
/// the new field.
///
/// Bumping this strands every device in the field until it updates, so it is a
/// last resort — see "Schema evolution rules" in `TriTrack_Technical_Context.md`
/// for the five standing rules that make bumping it almost never necessary, and
/// for the requirement that any bump carry written justification in the plan
/// doc naming what was tried instead.
///
/// **v2 (task 10.35, schema v6) — the first bump.** Primary keys on the six
/// project-scoped data tables became `(<id>, project_id)`. Justification is in
/// `TriTrack_Security_Model.md` §4.13 and task 10.35's entry in the plan doc,
/// including what was tried instead; the short version is that global keys
/// were not only D-1 arm (c)'s existence oracle but a permanent silent refusal
/// of Phase 6.3's shared observations, which land in a different project than
/// they came from by default. It was spent while nothing was deployed, which
/// is the only time it is cheap.
///
/// **v3 (task 11.219, schema v14) — the second, and spent for the same reason
/// at the same price.** Adding a tag to a project now *copies* it, so `Tags`
/// and `Tag_Versions` gained a `project_id`, became keyed
/// `(<id>, project_id)`, and `Project_Tags` left the wire. The full argument
/// is `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`; what was tried instead is its
/// §2.1 **Design A**, which delivers copy-on-add as a *behaviour* with no bump
/// at all and was rejected on measurement rather than taste: under A the
/// server still cannot know the invariant, so every line of machinery that
/// polices cross-project tag sharing stays load-bearing —
/// `_authorizeTagReferences`, the orphan clause, the offer-order constraint
/// and the "linking is a grant" flag. A buys the product decision and none of
/// the security one.
///
/// **It was spent on 2026-09-10 because nobody is in the field.** A major bump
/// strands every device until it updates; there were no devices. That window
/// closes the day a beta team installs, and this design gets more expensive —
/// not less — from that day on.
///
/// **v4 (task 11.242, schema v16) — the third, spent on a change that had
/// already shipped as a minor.** Task 11.240 moved colour from the collar to
/// the animal and made `Tags.color_hex` **nullable** — non-null becoming
/// nullable, the mirror image of the additive change the five rules permit —
/// and left this constant at 3. So a v15 app and a v16 server both announced
/// "major 3", the boundary let them sync, and the v15 app then failed on the
/// first tag row it was handed: its own `Tags.color_hex TEXT NOT NULL` refused
/// the null, the page rolled back, the cursor never moved, and the phone
/// reported the wreck as a fault in *itself* (measured in the app's
/// `test/data/sync/v15_device_meets_v16_row_test.dart`, which holds the v15
/// schema against a v16 row for as long as either exists). **A boundary that
/// declares two builds compatible when one of them cannot store the other's
/// rows is not a boundary.** Bumping here makes the v15 build *refuse*, with
/// the sentence the client already owns for it — "This version of TriTrack is
/// too old to sync with the server. Update the app to continue syncing" —
/// instead of failing forever behind a message that blames the wrong party.
///
/// **What was tried instead:** keeping `Tags.color_hex` non-null and
/// mirroring the animal's colour into it, so a v15 reader finds a valid value.
/// Rejected because it buys compatibility with a second copy of a value —
/// the two-sources-of-truth 11.240's own brief forbade — and because the
/// thing it would preserve, one un-updated phone syncing across a schema
/// change, does not exist: **on 2026-09-13 Michael's is the only device, so
/// the bump costs nothing today**, and a mirror column would have to be kept
/// honest for as long as the schema lives. The window in which a bump is
/// free closes the day a second phone installs; this is the second time it
/// has been spent for exactly that reason (see v3), and the reasoning does
/// not improve with waiting.
///
/// **And the class is now checked rather than remembered.** `wire_shape_freeze.dart`
/// holds a frozen picture of every wire table's columns at each major, and
/// `assertWireShapeCompatibleWithMajor` fails a build in which a shared column
/// has changed type, lost or gained `NOT NULL`, left its primary key, or gone
/// missing without this constant moving. 11.240's relaxation would have gone
/// red on the day it was made.
///
/// **v5 (task 11.243, schema v17) — the fourth, and the first spent on a
/// deletion.** `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` is the
/// decision. `Tags` **loses four columns** — `date_put_on`, `date_removed`,
/// `capture_date` and `individual_id` — and [Tables.deployments] arrives to
/// hold the first two and the last one as a *dated* link. A tag is a piece of
/// equipment now; it was a deployment before.
///
/// Three of the nine kinds of change are in this one bump, and any one of
/// them would require it on its own:
///
/// - **Four columns deleted.** A v16 device keeps writing `date_put_on` on
///   every tag row it sends, and the server no longer has the column; it also
///   keeps *showing* a `date_put_on` that nothing maintains.
/// - **A `NOT NULL` column deleted.** `Tags.date_put_on` was NOT NULL, so a
///   v17 row has no value a v16 device could store even if the column were
///   tolerated — the mirror image of the v15/v16 case that cost major 4.
/// - **A new table.** Additive on its own; it is here because the other two
///   are not.
///
/// **What was tried instead: nothing, and that is the honest answer.** There
/// is no expression of "the dates belong to the link" that leaves `Tags`
/// alone — keeping the columns and writing them null is the two-sources-of-
/// truth this schema has now refused twice (11.240's brief, 11.242's rejected
/// mirror column), and it would leave a NOT NULL column with no writer.
/// The design considered the alternative *model* instead (a second `Tags` row
/// per redeployment, the rule of 2026-09-13) and withdrew it in §2: it makes
/// the equipment inventory report two collars where the project owns one.
///
/// **It is spent for the third time for the same reason and at the same
/// price: on 2026-09-13 Michael's phone is still the only device and the beta
/// server holds development data only.** He is wiping both (§9), so this bump
/// costs one redeploy and one rebuild. **That is the whole of the argument,
/// and it expires the day a beta team installs** — this is the third major
/// spent inside that window (see v3 and v4), and the window is the asset
/// being consumed.
///
/// **v6 (task 11.323, schema v19) — the fifth, spent on `NOT NULL` losing
/// its hold on three columns, the same kind of change as v4.**
/// `Estimated_Positions.semi_major_axis`, `semi_minor_axis` and
/// `rotation_angle` become nullable, and **empty means no ellipse**. Two
/// bearings that cross always cross exactly, so there is no scatter to
/// measure and the solver returns a point with no covariance. The app wrote
/// that as an ellipse of 0 × 0 m — a perfectly precise position, in the
/// record and in every backup — and [NumericBound.positiveMeasurement] then
/// refused 0 at the server, so **a two-bearing estimate was saved on the
/// phone and never synced.** Michael chose this change over refusing to save
/// such an estimate (2026-10-06).
///
/// **What was tried instead.** (1) *Keep the columns `NOT NULL` and write a
/// placeholder:* any positive number would be an invented measurement, and a
/// major-5 device would draw it as a real ellipse — standing rule 2 (a column
/// that changes meaning changes name) in its worst form. (2) *Add new nullable
/// ellipse columns and retire these:* the old ones would still be `NOT NULL`
/// with nothing honest to write in them, which is (1) again. (3) *Do not let a
/// two-bearing estimate be saved:* no schema change at all, offered to
/// Michael and declined — the estimate is a real point, and the record should
/// hold it with its missing ellipse said plainly.
///
/// **Spent inside the same window as v3, v4 and v5:** on 2026-10-06 the only
/// installs are Michael's own devices, before the beta. Release order is the
/// standing one — the central server first, then the app.
///
/// Note the boundary is asserted on the wire but deliberately *not* against
/// backup archives: `SchemaMigrator` migrates a v1 archive forward rather than
/// refusing it. See its doc comment for why the asymmetry is principled — and
/// for why major 5 is the first crossing that is deliberately **lossy**, which
/// that comment now says out loud rather than inheriting the claim.
const int schemaMajorVersion = 6;

/// The **schema (minor) version at which each major began** — the whole
/// history of the compatibility boundary, as data.
///
/// Every consumer that has to name a major without a Dart compiler to hand
/// derives it from this map's shape, and a test on each side checks the copy:
/// `server/backup/backup.sh` labels an archive with the major its database is
/// on, `server/backup/restore.sh` refuses an archive whose major this build
/// cannot read, and `scripts/backup_restore_drill.sh` asserts both. **Until
/// task 11.242 those three carried the history as hand-typed thresholds, and
/// all three were still saying "2" a week after v3 shipped** — a backup of a
/// v14 server was being labelled with the wrong major, in the sidecar and in
/// the signed comment, and nothing noticed because nothing read the constant.
/// `server/test/security/shipped_defaults_test.dart` reads it now.
///
/// Invariants, asserted in `schema_constants_test.dart`: keys are the
/// consecutive majors from 1 to [schemaMajorVersion]; values strictly
/// increase; the last is at most [latestSchemaVersion]; and major 1 begins
/// at schema 1.
const Map<int, int> schemaMajorFirstMinor = {
  1: 1,
  // Task 10.35: primary keys became `(<id>, project_id)`.
  2: 6,
  // Task 11.219: tags became project-scoped; `Project_Tags` left the wire.
  3: 14,
  // Task 11.242, for task 11.240's `Tags.color_hex` losing NOT NULL.
  4: 16,
  // Task 11.243: `Tags` loses four columns and `Deployments` arrives.
  5: 17,
  // Task 11.323: the estimate's ellipse columns lose NOT NULL (no ellipse).
  6: 19,
};

/// The major a database or archive at schema [minor] belongs to — the lookup
/// the shell scripts above perform with a chain of `-ge` tests.
int schemaMajorFor(int minor) {
  var major = 1;
  for (final entry in schemaMajorFirstMinor.entries) {
    if (minor >= entry.value) major = entry.key;
  }
  return major;
}
