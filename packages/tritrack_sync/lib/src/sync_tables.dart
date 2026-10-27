import 'mutation_rules.dart';
import 'schema_constants.dart';
import 'table_columns.dart';

/// Which set of reachable ids narrows a **global** table to one project.
///
/// The one global id kind a project reaches is people. This enum is closed
/// rather than open-ended: a second kind would be a genuine new question about
/// what a project may see, and should read as one.
///
/// **It held two members until task 11.219 (schema v14).** Tags were the
/// other, and copy-on-add removed them by construction rather than by policy:
/// a tag now belongs to exactly one project, so `Tables.tags` and
/// `Tables.tagVersions` narrow by `WHERE project_id = ?` like the other nine
/// tables and nothing has to compute which tag ids a project can see. That is
/// what deleted `RowAuthorizer._authorizeTagReferences` (161 lines under about
/// 200 lines of argument), `_tagIsClaimedElsewhere`, `_tagRowExists`,
/// `_noteEstablishedTag` and the whole offer-order constraint tags imposed.
/// See `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §1.1 and §2.4.
enum GlobalReachSet {
  /// The `user_id`s this project's rows name.
  users,
}

/// How a global table — one with no [SyncTable.projectScopeColumn] — is
/// narrowed to the rows one project may see.
///
/// **Declared rather than looked up, because the lookup was silently
/// skippable.** Through task 11.31 this lived in two hand-written maps on the
/// server: `SyncService._globalFilters`, whose `if (filter == null) continue;`
/// meant a global table missing an entry was **never delivered by pull at all**
/// — no error, no log, just a table that does not sync — and
/// `RowAuthorizer._mayKnowRowExists`, whose own comment admitted it was a
/// hand-maintained mirror of the first (`isTag ? 'tag_id' : 'user_id'`, which
/// silently reads `user_id` off any global table that is not `Tags`). Task
/// 11.32 adds the fourth global table, so the pattern was one entry away from
/// its fifth instance in three weeks. Declaring it here makes both of those
/// derived, and [assertEveryGlobalTableDeclaresItsScope] makes omitting it a
/// failed test rather than a table that quietly never arrives.
class GlobalScope {
  const GlobalScope({required this.column, required this.reach});

  /// The column carrying the id that decides reachability — **not necessarily
  /// the primary key**. `User_Emails` is keyed by `user_email_id` but scoped by
  /// the `user_id` whose history it records, and `Tag_Versions` by the `tag_id`
  /// it is a version of; deriving the column from [SyncTable.primaryKey] would
  /// have returned every address, and every tag's history, on the server.
  final String column;

  /// The reachable-id set [column] is checked against.
  final GlobalReachSet reach;
}

/// The columns of [table] whose values feed the reachable-id set [reach].
///
/// **The one place the mapping from a reach set to the columns that fill it is
/// written down.** Before this, it was written twice: `ProjectReachability`
/// on the server chose `identityUserColumns` or `tagColumns` inline while
/// collecting both sets in one pass, and nothing on the client asked the
/// question at all — which is task 11.41's finding. A push that narrowed
/// global tables by a *different* answer from the one pull narrows them by
/// would offer rows the server is bound to refuse, and each refusal becomes a
/// record the device holds and reports as "not on the server" forever.
///
/// `last_modified_by` is deliberately absent from the user set — see
/// [SyncTable.identityUserColumns] and the note in `ProjectReachability`: it
/// is an audit column any caller may set to any value, so treating it as a
/// reachability edge would let one row of your own project pull a stranger's
/// name and address history.
///
/// Exhaustive over [GlobalReachSet] with no `default`, so a third reach set is
/// a compile error here rather than a silently empty column list.
List<String> reachColumnsFor(SyncTable table, GlobalReachSet reach) =>
    switch (reach) {
      GlobalReachSet.users => table.identityUserColumns,
    };

/// Table metadata the backup/merge engine needs to operate *generically* over
/// every table without per-model code. Because every model funnels through a
/// uniform `toColumns()`/`fromRow()` column-map (see the app's `data/models`),
/// the exporter and merger only ever handle `Map<String, Object?>` rows plus
/// this descriptor — one shape to reason about, and adding a table means
/// adding one entry here rather than touching the engine. The server's merge
/// of pushed rows uses the same descriptors.
/// Whether a table's rows travel in a project archive (task 11.30).
///
/// See [SyncTable.archiveDisclosure] for why this is asked per table and not
/// derived from anything else.
enum ArchiveDisclosure {
  /// Goes into the `.zip`. Either the app displays it, or the merge cannot
  /// reconstruct the project without it.
  carried,

  /// Deliberately left out. The archive is narrower than the database, and the
  /// reason is recorded at the declaration site rather than here.
  withheld,
}

class SyncTable {
  const SyncTable({
    required this.name,
    required this.primaryKey,
    required this.insertIsAGrant,
    required this.archiveDisclosure,
    this.projectScopeColumn,
    this.globalScope,
    this.userColumns = const [],
    this.tagColumns = const [],
    this.emailColumns = const [],
    this.deactivationColumns = const ['deleted_at'],
  });

  /// SQL table name (from [Tables]).
  final String name;

  /// Whether **creating** a row in this table is itself the granting of a
  /// permission (task 11.3).
  ///
  /// Phase 8's rule table governs edits and deletes and deliberately does not
  /// authorize inserts, on the reasoning that creating a row is normally adding
  /// your own data and harms nobody. That reasoning is sound for a field
  /// observation and false for `Project_Memberships`, where **the row's
  /// existence is the permission** — an unauthorized insert there is not a
  /// spurious record, it is a stranger joining the project. Tasks 11.1 and 11.2
  /// each hand-checked their own insert path in the app for exactly this
  /// reason; neither binds a device that pushes the row over the wire instead.
  ///
  /// **Required rather than defaulted, on purpose.** A default is silence, and
  /// silence is how a new table joins the permissive branch. Declaring it makes
  /// adding a table a decision somebody had to write down — the same discipline
  /// [tableMutationRules] enforces by having no default entry.
  ///
  /// True here does not by itself decide anything: it routes the insert to
  /// `RowAuthorizer._authorizeGrantingInsert`, which is an exhaustive switch
  /// whose unhandled branch **denies**. So flagging a table without also
  /// deciding what may create its rows fails closed and loudly, rather than
  /// quietly inheriting whatever the rule table happened to permit.
  final bool insertIsAGrant;

  /// Whether this table's rows may leave the device in a **project archive** —
  /// the `.zip` somebody emails to a colleague (task 11.30).
  ///
  /// **This is a different question from every other one on this class, and
  /// that is why it is here rather than inferred.** The rest of `SyncTable`
  /// describes who may *change* a row. Export is not gated by role and the
  /// security model is right that it cannot be: a member who can read the data
  /// can copy it. So the only question left is *width* — not "may this person
  /// have it" but "is this something the app ever showed them in the first
  /// place."
  ///
  /// **What it cost to leave implicit.** `ProjectExporter` collected every
  /// reachable global row, which swept in the whole of [Tables.userEmails] —
  /// every prior address every named person on the project had ever used. No
  /// screen in this app displays a prior address; the merge reads them and
  /// nothing else does. So the archive carried a roster of people's old email
  /// addresses to whoever received the file, and the security model's phrase
  /// "data they are authorized to see" did not cover it, because nobody was
  /// ever authorized to see it — it simply came along.
  ///
  /// **Required rather than defaulted, for the reason [insertIsAGrant] is:** a
  /// default is silence, and silence is how the next table with a hidden column
  /// joins the archive without anybody deciding it should. Declaring it makes
  /// adding a table a decision somebody had to write down. The test that fails
  /// when the exporter and this declaration disagree — including one that
  /// builds a real archive and reads the bytes back — is
  /// `test/security/archive_disclosure_test.dart`.
  final ArchiveDisclosure archiveDisclosure;

  /// Primary-key column(s). `(<id>, project_id)` for a project-scoped table,
  /// a single surrogate/UUID key for the two remaining global ones.
  final List<String> primaryKey;

  /// The column that scopes a row to one project, if any. Rows in
  /// project-scoped tables are collected by `WHERE <col> = ?` during export.
  /// Null for the two global tables (Users, Tags), which are collected by
  /// reachability (only the rows a project's data references).
  final String? projectScopeColumn;

  /// For a **global** table (one with no [projectScopeColumn]): the column and
  /// reachable-id set that narrow it to one project's rows. Null for a
  /// project-scoped table, whose scope column already answers the question.
  ///
  /// Exactly one of [projectScopeColumn] and this must be set — see
  /// [assertEveryGlobalTableDeclaresItsScope], and see [GlobalScope] for what
  /// it cost to leave this implicit.
  final GlobalScope? globalScope;

  /// Columns that hold a `user_id` (or `owner_user_id`). These are rewritten
  /// during merge when an incoming user is deduped onto a local user with a
  /// different id (cross-device identity anchor = normalized email).
  ///
  /// They are also the complete list of the ways a row can *name* a person,
  /// which is what the server's row-naming authorization invariant iterates
  /// (task 10.20). Adding a user-bearing column without adding it here would
  /// make that invariant silently skip it — see [identityUserColumns] for the
  /// one distinction drawn inside this set.
  final List<String> userColumns;

  /// Columns that hold a `tag_id` — used to gather the reachable global Tags
  /// rows during export.
  final List<String> tagColumns;

  /// Columns that hold an **email address used as an identity anchor** — the
  /// value cross-device dedup treats as proof that two `user_id`s are the same
  /// person (`ProjectMerger._buildUserRemap`, `SharedObservationImporter`).
  ///
  /// Declared here for the same reason [userColumns] is: the server's check
  /// that a pushed address is one it has actually authenticated
  /// (`RowAuthorizer._authorizeEmailClaim`, task 10.55 / finding I-4) iterates
  /// this list rather than naming `Users` and `User_Emails` at the call site,
  /// so a future table carrying an identity email inherits the check instead of
  /// needing someone to remember it. A column holding an email that is *not* an
  /// identity anchor — a contact address on a project, say — does not belong
  /// here; the point of the list is which addresses a merge would believe.
  ///
  /// A table that declares one of these must have exactly one
  /// [identityUserColumns] entry, because the check has to know whose address
  /// it is. That is asserted rather than assumed — see
  /// [assertEveryEmailColumnHasASubject].
  final List<String> emailColumns;

  /// Columns whose arrival on a **live** row takes that row out of what the
  /// app shows — the complete set of ways a record can be made to go away
  /// without being deleted.
  ///
  /// Declared here for the same reason [userColumns] and [emailColumns] are,
  /// and finding **L-12** is what it cost not to be.
  /// `UntrustedImportRules.isDestructiveChange` spelled `deleted_at` out by
  /// hand, so an untrusted archive setting `Project_Memberships.end_date`
  /// applied with `destructiveChanges = 0` and no consent dialog — a
  /// deactivation the rule had never been told about. Deriving the predicate
  /// from a declared set is the same shape clause 2 already has with
  /// [identityUserColumns].
  ///
  /// **The membership between "empty" and "set" is the criterion**, not the
  /// column's type. A column whose *existing* value is replaced is already
  /// destructive by the ordinary `was != null` test; what needs declaring is
  /// only the null → non-null transition that hides a row. `status` columns
  /// (`Tags.status`) therefore do **not** belong here: it is `NOT NULL`, so
  /// deactivating through it always replaces a value and the ordinary test
  /// already catches it. `Tags.date_removed` does not
  /// belong either — it is a husbandry date, and nothing filters on it
  /// (`app_context_provider.dart` gates tag visibility on `status`).
  ///
  /// The sweep behind this list, and the test that keeps it honest, are in
  /// `test/security/deactivation_columns_test.dart`.
  final List<String> deactivationColumns;

  bool get isComposite => primaryKey.length > 1;

  /// The [userColumns] that say who a row *is about* — its author, its owner,
  /// its subject — as opposed to [auditUserColumn], which only records who
  /// last touched it.
  ///
  /// The distinction is not cosmetic, and it is not new: task 10.10 already
  /// drew it by hand when it excluded `last_modified_by` from the server's
  /// reachability computation. An identity column is a real edge — it is a
  /// foreign key, a rule's governing column, and the reason a global `Users`
  /// row is delivered to a project at all — while the audit column is
  /// free-text provenance that references nothing. Naming it here rather than
  /// spelling the column out at each call site is what stops the two places
  /// that care from drifting apart.
  List<String> get identityUserColumns => [
    for (final column in userColumns)
      if (column != auditUserColumn) column,
  ];

  /// Whether §4.17's clause 2 — *"this project already reaches them"* — may
  /// vouch for [column] of this table naming somebody other than the caller,
  /// on an insert.
  ///
  /// **This used to be a property of the rule alone**
  /// ([MutationRule.vouchesForAForeignName]), and it was the same answer for
  /// every column of a table. Task 11.47 could argue that safely because of a
  /// premise task 11.93 breaks: every table whose rule vouched had the audit
  /// column as its *only* user column, so "the rule vouches" and "no identity
  /// column is reachable" were the same statement.
  ///
  /// `Actual_Tag_Locations` is the shape that was predicted and has now
  /// arrived: shared field data any contributor may write ([MutationRule
  /// .anyUser], and task 11.93 was explicitly forbidden to tighten it) that
  /// **also names somebody** — who found the collar. For that table the two
  /// halves of the old premise want opposite answers, so the question is now
  /// asked per column:
  ///
  /// - **The audit column** keeps task 11.47's relaxation. `last_modified_by`
  ///   is not a reachability edge and nothing is delivered on the strength of
  ///   it, and refusing it cost people their *own* field data — see
  ///   [MutationRule.replicatesAForeignAuditName].
  /// - **An identity column never vouches**, whatever the rule says. Task
  ///   11.24's rule is that a record naming an author must name the caller,
  ///   and "Sarah found the lion here" is exactly the claim that rule exists
  ///   to make unforgeable. The write gate is untouched — a colleague may
  ///   still edit or delete the point — because who may change a record and
  ///   whose name it carries are different questions.
  ///
  /// The accepted cost is the one Michael accepted on 2026-08-28 for
  /// `Observations`, and it lands here identically: a truth point replicated
  /// from a colleague's archive is refused, held, counted and explained, and
  /// it keeps their name rather than being re-signed with the importer's.
  bool vouchesForAForeignNameIn(String column) {
    final rule = tableMutationRules[name];
    if (rule == null || !rule.vouchesForAForeignName) return false;
    return !identityUserColumns.contains(column);
  }
}

/// The `last_modified_by` audit column carries a `user_id` on every table, so
/// it is always part of the user-column set for id remapping.
const String auditUserColumn = 'last_modified_by';

/// All tables in FK-safe order (parents before children) — the order the
/// merger inserts in so a child's FK target already exists. Mirrors
/// [Tables.all]; the ordering is asserted against it in tests.
///
/// **Keys are project-scoped (task 10.35, schema major 2).** Every table whose
/// [projectScopeColumn] is `project_id` — other than `Projects` itself, whose
/// id *is* the scope — is keyed `(<id>, project_id)` rather than by the id
/// alone. `Users` and `User_Emails` stay globally keyed because they have no
/// project column and cannot get one without breaking the reachability model
/// pull's read filter is built on.
///
/// **`Tags` and `Tag_Versions` used to be in that sentence and are not any
/// more (task 11.219, schema major 3).** Copy-on-add gives each project its
/// own copy of a collar, so both tables took a `project_id` and joined the
/// composite-key class. It is the same move as v6's and it buys the same
/// thing one table further out: the server stops needing to compute which tag
/// ids a project may see, and the code that did it is deleted rather than
/// kept.
///
/// **The id leads and the scope follows, which looks backwards and is
/// deliberate.** `(project_id, <id>)` would read more naturally, but the
/// leading column of a primary key is the one its
/// index can be searched on alone, and the query this schema actually runs most
/// is "find this row by its id" — every by-id repository helper on the client
/// does exactly that. Putting `project_id` first would turn each of those into
/// a scan. The reverse lookup ("everything in this project, in sequence order")
/// is already served by the `(project_id, server_seq)` indexes the server
/// creates. Uniqueness is identical under either order.
///
/// **The [SyncTable.insertIsAGrant] column, decided table by table (task
/// 11.3).** The question asked of each was the one the brief asks: *is there a
/// row here whose existence is itself a permission?* **Two answer yes.**
///
/// - `Projects` — inserting one creates a project you own, which is a grant,
///   albeit only over data that does not exist yet.
/// - `Project_Memberships` — the insert *is* the grant. This is the table the
///   flag exists for.
///
/// **`Project_Tags` was the third and it is gone (task 11.219).** It was the
/// row that linked a *global* tag to a project, and so the one operation that
/// legitimately widened what a project may read. Under copy-on-add there is no
/// global tag to link: adding a tag to a project creates a row **inside** a
/// project the caller is already in, which widens nothing. The flag did not
/// become false — the operation it described stopped existing.
///
/// Everything else answers no, and for one of two reasons. `Users` and
/// `User_Emails` are global rows carrying no rights at all — sign-in identity
/// comes from the server's own `auth_accounts`, never from these — and the
/// remaining eight are field records or a project's own configuration, where a
/// new row is somebody's data and confers nothing on anybody.
const List<SyncTable> syncTables = [
  SyncTable(
    name: Tables.users,
    primaryKey: ['user_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    globalScope: GlobalScope(
      column: 'user_id',
      reach: GlobalReachSet.users,
    ),
    userColumns: ['user_id', auditUserColumn],
    emailColumns: ['email'],
  ),
  SyncTable(
    name: Tables.userEmails,
    primaryKey: ['user_email_id'],
    insertIsAGrant: false,
    // **The finding task 11.30 exists for.** This table is every address every
    // user has ever used, kept so cross-device merge can still recognise a
    // person who changed their email. No screen renders it — not the profile
    // screen, not the team roster, nowhere — so a member has never seen a
    // colleague's prior address in this app, and an archive that carried it
    // handed one to whoever the file was forwarded to.
    //
    // **What withholding costs, stated rather than discovered.** The merge has
    // three tiers of identity matching. Tier 1 (both sides' current addresses)
    // and tier 2a (the incoming current address against a prior address *this*
    // device already recorded) are unaffected — they read the local table,
    // which is untouched. Only tier 2b breaks: the case where the *sender*
    // changed their address and only the sender's history knows the old one.
    // In that one case an imported archive produces two user rows for one
    // person instead of one.
    //
    // **That trade is deliberate and it is the right way round.** A duplicated
    // observer is visible and correctable. A colleague's former address, once
    // it is in a file that has been emailed on, is neither. Devices that sync
    // to a server are not affected at all: this table still syncs over the
    // authenticated channel, so identity convergence for a real team is
    // unchanged. It is only the offline `.zip` that is narrowed.
    archiveDisclosure: ArchiveDisclosure.withheld,
    // Keyed by `user_email_id`, scoped by the `user_id` whose history it is.
    globalScope: GlobalScope(
      column: 'user_id',
      reach: GlobalReachSet.users,
    ),
    userColumns: ['user_id', auditUserColumn],
    emailColumns: ['email'],
  ),
  SyncTable(
    name: Tables.projects,
    primaryKey: ['project_id'],
    // Creating a project makes the caller its owner.
    insertIsAGrant: true,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['owner_user_id', auditUserColumn],
  ),
  SyncTable(
    name: Tables.projectMemberships,
    primaryKey: ['membership_id', 'project_id'],
    // The row's existence *is* the permission.
    insertIsAGrant: true,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
    // The one table with a second way out. A membership is deactivated by
    // setting `end_date`, not by tombstoning the row —
    // `ProjectMembershipRepository`'s "current" means `end_date IS NULL` — and
    // finding L-12 is the consent dialog that did not fire because of it.
    deactivationColumns: ['deleted_at', 'end_date'],
  ),
  // **Task 11.240 (schema v16): the animal.** Project-scoped for the reason
  // `Tags` is, placed before `Tags` and `Deployments` because both name it
  // and the merger inserts parents first. `insertIsAGrant` is false for the
  // reason it is on every field table: naming a new animal inside a project
  // the caller is already in confers nothing on anybody. No `tagColumns` —
  // an individual never lists its collars; the link is `Deployments`.
  //
  // Its `lineage_id` and `copied_at` are sealed exactly as the tag's are —
  // see [provenanceColumns] — so "which project's individual is the same
  // bird" is a question only an export can answer.
  SyncTable(
    name: Tables.individuals,
    primaryKey: ['individual_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
  ),
  // **Task 11.219 (schema v14, schema major 3): a tag belongs to one project.**
  //
  // Adding a tag to a project *copies* it into that project, so the project's
  // tag is its own — editing it changes neither the person's own tag library
  // nor any other project. Structurally that makes this an ordinary
  // project-scoped table: `insertIsAGrant` stays false because creating a row
  // inside a project the caller is already in grants nobody anything, and
  // there is no longer a link row whose existence widens what a project may
  // read. `Project_Tags` was that row and it has left this list.
  //
  // `tagColumns` still names `tag_id`, and it still means what it always did —
  // *this column holds a tag id*. What changed is that nothing computes
  // reachability from it any more (see [GlobalReachSet]); it survives because
  // the held-row explanation and `UntrustedImportRules` still need to know
  // which columns name a tag.
  SyncTable(
    name: Tables.tags,
    primaryKey: ['tag_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  // **Task 11.243 (schema v17, schema major 5): the dated link.** See
  // `Tables.deployments` for the design; what this declaration says is that
  // it is an ordinary project-scoped field table.
  //
  // `insertIsAGrant: false` for the reason every field table has it: saying
  // which animal a collar is on, inside a project the caller is already in,
  // confers nothing on anybody. `tagColumns` names `tag_id` because that is
  // what the column holds — the held-row explanation and
  // `UntrustedImportRules` both need to know which columns name a tag — and
  // not because anything computes reachability from it (nothing has since
  // task 11.219; see `GlobalReachSet`).
  //
  // **No `provenanceColumns` entry, because there is no lineage to seal.** A
  // deployment is a fact inside one project and no two projects hold "the
  // same" one.
  SyncTable(
    name: Tables.deployments,
    primaryKey: ['deployment_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  // **Task 11.32** — what a bearing was recorded against. See
  // `Tables.tagVersions` for why this is a table rather than three columns on
  // `Observations`, and `tagColumnKinds` for how its column set is derived.
  //
  // **Project-scoped since task 11.219, and placed straight after `Tags`.** A
  // version is a version of one project's tag, so it lives in that project:
  // `TAG_COPY_ON_ADD_DESIGN.md` §2.2's answer to "where does a tag's history
  // live once the tag is project-local" is *beside its tag, one chain per
  // project copy*. Task 11.32's design is otherwise untouched — a bearing
  // still holds a reference to the tag's state as it was, never a copy of
  // selected fields.
  //
  // **Its position used to be load-bearing three times over and now is once.**
  // It was FK-safe insert order for the merger, authorization order within one
  // push, and — the one task 11.43 reopened for — the order
  // `ProjectPublisher` sends *separate HTTP requests* in, where a tag could
  // only be vouched for by a `Project_Tags` row committed by an earlier
  // request. That third constraint is gone: a version and its tag are in the
  // same project, so the ordinary project scope answers the question and
  // `offer_order.dart` imposes nothing here. The FK order remains, which is
  // why this still follows `Tags`.
  //
  // `insertIsAGrant: false` — a version row confers nothing on anybody.
  SyncTable(
    name: Tables.tagVersions,
    primaryKey: ['tag_version_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  SyncTable(
    name: Tables.triangulationSessions,
    primaryKey: ['session_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  SyncTable(
    name: Tables.observations,
    primaryKey: ['observation_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  // Task 11.7. `userColumns` names `user_id` (whoever marked the observation)
  // so a backup carries that person's `Users` row — the Team log has to be able
  // to say *who* took a bearing out of analysis, and an unattributable mark is
  // exactly the provenance hole this feature exists to avoid.
  //
  // `observationColumns` is deliberately absent from `SyncTable` — the
  // observation this row names is always in the same project, so the ordinary
  // project scope already carries it.
  SyncTable(
    name: Tables.observationExclusions,
    primaryKey: ['exclusion_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
  ),
  SyncTable(
    name: Tables.nonDetections,
    primaryKey: ['non_detection_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
  ),
  SyncTable(
    name: Tables.estimatedPositions,
    primaryKey: ['position_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: [auditUserColumn],
    tagColumns: ['tag_id'],
  ),
  // **Task 11.93 added `user_id` — who walked in and found the collar.**
  //
  // Declaring it here is what makes the finder's `Users` row travel with the
  // point: an identity column is a reachability edge, so a synced or archived
  // truth point can be attributed on the Log and the Team tab instead of
  // sorting last under a blank. It also puts the column under
  // `RowAuthorizer._authorizeNaming`, which is the half that matters —
  // see [SyncTable.vouchesForAForeignNameIn] for why an identity column on an
  // `anyUser` table is the shape task 11.47 predicted and left a tripwire for.
  //
  // **The rule stays `anyUser` on purpose.** Michael settled it on
  // 2026-08-31: recording who found a point does not make editing it
  // author-only, because the person who saw the pride and the person driving
  // the truck may not be the same person.
  SyncTable(
    name: Tables.actualTagLocations,
    primaryKey: ['location_id', 'project_id'],
    insertIsAGrant: false,
    archiveDisclosure: ArchiveDisclosure.carried,
    projectScopeColumn: 'project_id',
    userColumns: ['user_id', auditUserColumn],
    tagColumns: ['tag_id'],
  ),
];

/// Lookup by table name.
final Map<String, SyncTable> syncTablesByName = {
  for (final t in syncTables) t.name: t,
};

/// Throws if a table declares an [SyncTable.emailColumns] entry without exactly
/// one [SyncTable.identityUserColumns] entry to say *whose* address it is.
///
/// Called from tests on both sides of the wire, like
/// [assertEveryTableHasAMutationRule]. The server's email-claim check
/// (task 10.55) has to resolve the address to a `user_id` before it can ask
/// whether the server ever authenticated it; a table that gave it two subjects,
/// or none, would leave it guessing. It fails closed at runtime — see
/// `RowAuthorizer._authorizeEmailClaim` — and this turns that into a build-time
/// conversation instead.
/// Throws if any declared [SyncTable.deactivationColumns] entry is not a real
/// column of that table, or is not nullable.
///
/// Called from tests alongside [assertEveryEmailColumnHasASubject], and it
/// checks the two things a typo would break silently. A misspelled entry would
/// simply never match a column name, so the consent gate would go back to
/// missing exactly the deactivation finding L-12 was about — a declared set
/// that fails open is the hand-written name with extra ceremony. Nullability is
/// checked because the null → non-null transition *is* the criterion: a `NOT
/// NULL` column can never make it, so declaring one here would be a statement
/// about the schema that is not true.
void assertEveryDeactivationColumnExists() {
  final bad = <String>[];
  for (final table in syncTables) {
    final spec = tableSpecsByName[table.name];
    if (spec == null) {
      bad.add('${table.name} (no column spec)');
      continue;
    }
    for (final column in table.deactivationColumns) {
      final declared =
          spec.columns.where((c) => c.name == column).firstOrNull;
      if (declared == null) {
        bad.add('${table.name}.$column (no such column)');
      } else if (spec.isNotNull(declared)) {
        bad.add('${table.name}.$column (NOT NULL — it can never arrive)');
      }
    }
  }
  if (bad.isNotEmpty) {
    throw StateError(
      'Declared deactivation columns that do not exist or cannot be set: '
      '${bad.join(', ')}. A deactivation column is one whose arrival on a '
      'live row hides it; see SyncTable.deactivationColumns.',
    );
  }
}

/// The two free-text, delimited-id-list columns Security Model §5.9(b)
/// accepted, and which task 11.3 re-derived against a real multi-member
/// project rather than Phase 10's one-member-per-project assumption.
///
/// Neither has a foreign key on either side of the wire, so either can name a
/// row in another project. §5.9(b) accepted that on one condition, restated
/// here because it is the whole of the acceptance: **neither column feeds
/// reachability.** Nothing computed from them decides which rows a pull
/// delivers, so a foreign id stored in one is a dangling reference and not a
/// disclosure. The population changed in Phase 11 and that argument did not:
/// the columns are written by people who already hold the project's data, and
/// no read filter consults them.
///
/// The acceptance is conditional, and this is the condition made enforceable.
/// See [assertSealedColumnsFeedNoReachability].
const Map<String, String> unvalidatedIdListColumns = {
  Tables.nonDetections: 'tag_ids_listened_for',
  Tables.estimatedPositions: 'observation_ids_used',
};

/// The **provenance** columns task 11.219 added, and the reason they are
/// sealed: `TAG_COPY_ON_ADD_DESIGN.md` §2.3 requires that nothing live ever
/// reads a tag's lineage.
///
/// A `lineage_id` says two projects' tags are the same physical collar. That
/// is a fact for somebody comparing two exported files or running a
/// multi-season analysis in R — **not for the app**, and emphatically not for
/// anything that decides which rows travel. Folding it into a reach set would
/// make one project's tag deliver another project's rows on the strength of a
/// value both copies happen to share, which is the disclosure cancelled task
/// 11.29's standing rule forbids: no message about a tag may reveal that
/// another project exists.
///
/// Unlike [unvalidatedIdListColumns] this is not a risk somebody accepted —
/// it is a design property, and this is the mechanism §2.3 asked for instead
/// of a comment. Both are checked by
/// [assertSealedColumnsFeedNoReachability], because the question is the same
/// one: *has this column been wired into something that decides what a
/// project may see?*
const Map<String, List<String>> provenanceColumns = {
  Tables.tags: ['lineage_id', 'copied_at'],
  // Task 11.240: an individual's lineage means what a tag's does, and is
  // sealed for the same reason. Two seasons' projects holding one bird is a
  // fact for an export, never for a read filter.
  Tables.individuals: ['lineage_id', 'copied_at'],
  // Task 11.56: a project's lineage says which projects are seasons of one
  // study — Ponui 2025 and Ponui 2026 — and is sealed for the reason the
  // other two are: a project's row must never be resolved into words about
  // another project the reader may not be on.
  Tables.projects: ['lineage_id', 'copied_at'],
};

/// Throws if a **sealed** column — one of [unvalidatedIdListColumns] or
/// [provenanceColumns] — has been declared in one of the sets that decide
/// what a project reaches.
///
/// **Two different reasons, one mechanism.** §5.9(b) *accepted a risk* on the
/// condition that its two delimited-id-list columns feed nothing; §2.3 of
/// `TAG_COPY_ON_ADD_DESIGN.md` *designed a property* — a tag's lineage is
/// recorded, exported and read by nothing live. Both are one-line edits away
/// from being false, and the edit is the same edit: adding the column name to
/// `userColumns`, `tagColumns` or `emailColumns`. So they are checked
/// together, and the failure message says which of the two reasons the caller
/// has just broken.
///
/// **This is the tripwire on §5.9(b)'s acceptance, not a style check.** The
/// accepted risk is bounded by "neither column feeds `ProjectReachability`,"
/// and a future feature that wants "which observations does this estimate
/// depend on" as a first-class relationship would fold one of them in — at
/// which point every value written under Phase 10's unchecked assumption
/// becomes a live cross-project disclosure vector, on the day that computation
/// ships rather than the day the column changed. §5.9(b) said "decide whether
/// these columns need a real check *before* any future feature folds them into
/// reachability"; a sentence in a document cannot enforce a *before*, and this
/// can. Whoever trips it owes the columns a real reachability check first.
///
/// Called from tests on both sides of the wire, like
/// [assertEveryTableHasAMutationRule].
///
/// [tables] exists so a test can hand it a deliberately doctored descriptor
/// and watch it throw. An assertion nobody has seen fail is an assertion
/// nobody knows works, which is the shape eight consecutive security gates
/// kept finding in this project's own instruments.
void assertSealedColumnsFeedNoReachability({
  List<SyncTable> tables = syncTables,
}) {
  final foldedIdLists = <String>[];
  final foldedProvenance = <String>[];
  for (final table in tables) {
    final idListColumn = unvalidatedIdListColumns[table.name];
    final sealed = <String>{
      if (idListColumn != null) idListColumn,
      ...?provenanceColumns[table.name],
    };
    if (sealed.isEmpty) continue;
    // The three declared sets every reachability, naming and collection
    // computation walks: `ProjectReachability.resolve` reads
    // identityUserColumns, `ProjectExporter` collects an archive's global rows
    // by userColumns and tagColumns, `RowAuthorizer._authorizeNaming` reads
    // userColumns, and `_authorizeEmailClaim` reads emailColumns.
    for (final declared in {
      ...table.userColumns,
      ...table.tagColumns,
      ...table.emailColumns,
    }) {
      if (!sealed.contains(declared)) continue;
      if (idListColumn == declared) {
        foldedIdLists.add('${table.name}.$declared');
      } else {
        foldedProvenance.add('${table.name}.$declared');
      }
    }
  }
  final problems = <String>[
    if (foldedIdLists.isNotEmpty)
      'Delimited-id-list columns now feed reachability: '
          '${foldedIdLists.join(', ')}. Security Model §5.9(b) accepted these '
          'columns as unvalidated **on the condition** that nothing computed '
          'from them decides which rows a pull delivers. Folding one in turns '
          'every historical value into a cross-project disclosure vector. '
          'Give the column a real reachability check before declaring it '
          'here.',
    if (foldedProvenance.isNotEmpty)
      'Provenance columns now feed reachability: '
          '${foldedProvenance.join(', ')}. TAG_COPY_ON_ADD_DESIGN.md §2.3 '
          'chose a lineage identifier over a pointer at the source row '
          'precisely so that a tag never names anything outside its own '
          'project, and required that nothing live ever read it. A reach set '
          'is exactly "something live that reads it": two projects\' copies '
          'of one collar share a lineage, so this would deliver one project\'s '
          'rows on the strength of another project\'s tag. If a feature '
          'genuinely needs cross-project lineage, it belongs in an export, '
          'not in a read filter.',
  ];
  if (problems.isNotEmpty) throw StateError(problems.join('\n\n'));
}

void assertEveryEmailColumnHasASubject() {
  final bad = [
    for (final table in syncTables)
      if (table.emailColumns.isNotEmpty &&
          table.identityUserColumns.length != 1)
        table.name,
  ];
  if (bad.isNotEmpty) {
    throw StateError(
      'Tables declare an identity email column with no single subject: '
      '${bad.join(', ')}. An identity email belongs to exactly one user_id — '
      'declare that column in userColumns, or drop the email from '
      'emailColumns if the address is not an identity anchor.',
    );
  }
}

/// Throws unless every table declares exactly one way of being scoped to a
/// project: [SyncTable.projectScopeColumn] for a project-scoped table, or
/// [SyncTable.globalScope] for a global one — never both, never neither.
///
/// Called from tests on both sides of the wire, like
/// [assertEveryTableHasAMutationRule].
///
/// **The failure it exists to catch is a table that silently never syncs.**
/// Pull narrows a global table by its [GlobalScope]; before task 11.32 that
/// lived in a hand-written map on the server whose miss branch was
/// `continue`, so a global table nobody had added to it was simply never
/// delivered — with no error and nothing in a log. There is no shape of test
/// that notices a table quietly missing from a page, which is why this is an
/// assertion about the declaration instead.
///
/// It also checks that the declared column is a real, non-nullable column of
/// that table, for the reason [assertEveryDeactivationColumnExists] gives: a
/// misspelled entry would match no column, narrow every page to nothing, and
/// look exactly like a table with no rows in it.
///
/// [tables] exists so a test can hand it a deliberately doctored descriptor and
/// watch it throw.
void assertEveryGlobalTableDeclaresItsScope({
  List<SyncTable> tables = syncTables,
}) {
  final bad = <String>[];
  for (final table in tables) {
    final scoped = table.projectScopeColumn != null;
    final global = table.globalScope;
    if (scoped && global != null) {
      bad.add('${table.name} (declares both a project scope and a global one)');
      continue;
    }
    if (!scoped && global == null) {
      bad.add('${table.name} (declares neither)');
      continue;
    }
    if (global == null) continue;
    final spec = tableSpecsByName[table.name];
    if (spec == null) {
      bad.add('${table.name} (no column spec)');
      continue;
    }
    final declared = spec.columns.where((c) => c.name == global.column);
    if (declared.isEmpty) {
      bad.add('${table.name}.${global.column} (no such column)');
    } else if (!spec.isNotNull(declared.first)) {
      bad.add(
        '${table.name}.${global.column} (nullable — a row with no value in it '
        'would be reachable from no project and could never be delivered)',
      );
    }
  }
  if (bad.isNotEmpty) {
    throw StateError(
      'Tables with no usable project scope: ${bad.join(', ')}. Every synced '
      'table must say how it narrows to one project — projectScopeColumn for a '
      'project-scoped table, globalScope for a global one. A global table with '
      'no scope is never delivered by pull at all, silently. See GlobalScope.',
    );
  }
}
