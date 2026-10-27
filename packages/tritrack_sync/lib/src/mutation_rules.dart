/// The authorization rule table, shared by the app's advisory repository
/// checks and the server's enforced ones (tasks 8.2–8.5, 10.10).
///
/// The *rule table* lives here, in the shared package, for the same reason
/// [MergeResolver] does (task 10.1): a client and a server that disagree about
/// who may write a row are as bad as two that disagree about which write wins.
/// One definition means the disagreement cannot exist.
///
/// **Enforcement is deliberately not shared.** The app checks against sqflite
/// through `BaseRepository`; the server checks against Postgres inside the
/// sync transaction, over rows that arrive from an untrusted network. Those
/// are different lookups with different failure modes, and the security model
/// is explicit that the client's version is advisory UX while the server's is
/// the boundary. What must match is *which* rule governs *which* table, and
/// what that rule means — which is exactly what this file fixes.
library;

import 'schema_constants.dart';

/// Which rule governs mutations to a table.
enum MutationRule {
  /// Only the user named in the row's `user_id` column may modify it. For
  /// `Users` that column *is* the primary key, so the rule reads as "only you
  /// may edit your own profile".
  author('user_id'),

  /// Only an **owner of the project this row is** may modify it — `Projects`,
  /// whose `project_id` is its own primary key.
  ///
  /// **Task 11.1 moved this off `owner_user_id`.** Through Phase 10 the rule
  /// compared the actor against the row's `owner_user_id` directly, because
  /// with no transfer feature that column and `Project_Memberships` could not
  /// diverge. They can now, so the permitted set is [resolveProjectOwners]'s
  /// answer for [projectColumn]'s project, and `owner_user_id` survives as the
  /// creator/audit record plus that function's bootstrap fallback.
  ///
  /// [governingColumn] still names `owner_user_id` — it is the column whose
  /// *type* must be checked and whose value may not be rewritten (the
  /// reattribution invariant), which is a separate question from who may write
  /// the row. See [permits], which refuses to answer for this rule.
  owner('owner_user_id'),

  /// **Any current member of that row's project who holds write rights** may
  /// modify it — shared project data with no single author (tags, estimates,
  /// sessions, tag links).
  ///
  /// **Task 11.3 narrowed this from "any identified user."** Task 11.1 left it
  /// alone deliberately: narrowing needs a membership table with real non-owner
  /// members in it, and until task 11.2 created invitations, `anyUser` and
  /// "project member" were the same set, so the narrowing would have been
  /// untestable. Both halves of that premise are now false.
  ///
  /// **The narrowing is not expressed here, and that is deliberate.** This enum
  /// value answers only *which column singles a person out on this row* — and
  /// for shared project data the honest answer is still "none." Membership and
  /// role are properties of the caller and the project, not of the row, and
  /// answering them needs a database. They are enforced where that lookup lives
  /// and where it is the boundary rather than advice:
  ///
  /// - **Membership** — `ProjectAuthorizer.resolve` on the server, which every
  ///   sync route consults before a row is looked at, so a caller with no
  ///   relationship to the project never reaches an `anyUser` row of it. The
  ///   client's `BaseRepository` holds the same line against its local copy.
  /// - **Role** — `ProjectRoleRights.mayWriteProjectData`, checked by
  ///   `RowAuthorizer` server-side and `BaseRepository` client-side. A `viewer`
  ///   writes nothing, including these tables.
  ///
  /// Writing the narrowing into [permits] instead would mean making it
  /// asynchronous and database-bound — the shape task 11.1 had to give the two
  /// ownership rules, and which it made throw here rather than answer wrongly.
  /// Two of five rules already require a lookup; a third would leave [permits]
  /// answering for one rule out of five.
  anyUser(null),

  /// Only an **owner of the project named in the row's `project_id` column**
  /// may modify it — task 8.4's answer for `Project_Memberships` rows
  /// themselves: a contributor must not be able to grant themselves (or anyone
  /// else) a different role.
  ///
  /// 8.4 resolved this via `Projects.owner_user_id` rather than the membership
  /// table, to avoid needing a membership row to authorize a membership-row
  /// mutation. Task 11.1 has to close that loop anyway — an owner who received
  /// the project by transfer holds a membership row and *not* `owner_user_id`,
  /// so resolving through the column would leave them unable to manage anyone.
  /// [resolveProjectOwners] keeps the circularity harmless: a project with no
  /// open owner membership falls back to `owner_user_id`, so the bootstrap case
  /// 8.4 was protecting still resolves without a membership row existing.
  projectOwner('project_id'),

  /// **Either** the user named in the row's `user_id` column **or** any
  /// current owner of the project named in its `project_id` column may modify
  /// it — task 11.15, and the rule table's first disjunction.
  ///
  /// Every other rule is a single condition. This one exists because
  /// `Observation_Exclusions` has two legitimate authorities over the same
  /// row and neither is sufficient alone:
  ///
  /// - **The mark's author**, because a supersede is a judgement someone made
  ///   and withdrawing your own judgement must not require asking anyone.
  /// - **A current project owner**, because the author can leave. Under plain
  ///   [author] a contributor who wrongly marked a colleague's bearing as
  ///   replaced and then left the project made that mark *permanent*: no
  ///   owner could withdraw it, and neither could the observation's own
  ///   author. For data behind a publication or a permit, a discarded bearing
  ///   nobody can restore is a real loss, and the person who could explain it
  ///   is gone.
  ///
  /// **It is in the table rather than hand-coded at the withdraw call site on
  /// purpose.** The next feature that needs "author or owner" — a note, an
  /// annotation, a flag — must find it here, not write a second copy. Six
  /// instances of one defect shape is how this project learned that.
  ///
  /// Like the two ownership rules it cannot be answered from the row alone
  /// ([resolvesProjectOwners] is true), so [permits] refuses it and
  /// [permittedByOwners] is the entry point — passing both halves, which is
  /// why that method takes the author id as a required argument that no
  /// caller can forget.
  ///
  /// It is *not* authorization state: a mark is field data, so replication
  /// and naming treat it exactly as they treat [author]. See
  /// [namesRowAuthor].
  authorOrOwner('user_id');

  const MutationRule(this.governingColumn);

  /// The row column this rule is anchored to: the id of the only user allowed
  /// to mutate the row ([author]), the creator/audit record whose type must
  /// still be checked and whose value may not be rewritten ([owner]), or the
  /// project whose owners alone may ([projectOwner]); null when the rule
  /// doesn't single anyone out ([anyUser]).
  ///
  /// **This is no longer the whole answer for the ownership rules.** Before
  /// task 11.1 it was — `viaProject` marked the one rule needing a second
  /// lookup, and [permits] compared the resolved value against the actor. The
  /// flag is gone because the distinction it drew (one hop vs. two) is not the
  /// one that matters: what matters is whether the permitted set is a single
  /// named user or a project's current owners, which is [resolvesProjectOwners].
  final String? governingColumn;

  /// Whether deciding this rule needs the project's current owner set, which
  /// only a database can supply — so [permits] cannot answer and
  /// [permittedByOwners] must.
  ///
  /// True for [owner] and [projectOwner], whose permitted set *is* the owners
  /// and which differ only in *which* project governs (the one the row is, or
  /// the one it belongs to); and for [authorOrOwner], whose permitted set is
  /// the owners **plus** the one user the row names. All three name the
  /// project in [projectColumn] and resolve it through [resolveProjectOwners].
  bool get resolvesProjectOwners =>
      this == MutationRule.owner ||
      this == MutationRule.projectOwner ||
      this == MutationRule.authorOrOwner;

  /// Whether this rule is *authorization state* — a row whose content is
  /// somebody's rights, rather than field data about the world.
  ///
  /// [owner] and [projectOwner] govern `Projects` and `Project_Memberships`;
  /// replicating one of those is not replication, it is privilege escalation,
  /// and the server's naming and replication exemptions are drawn on exactly
  /// this line. [authorOrOwner] is deliberately **not** authorization state:
  /// an observation mark is a field judgement that happens to have two
  /// authorities, so it sits on the [author] side of that line.
  bool get isAuthorizationState =>
      this == MutationRule.owner || this == MutationRule.projectOwner;

  /// Whether the row names a single user in [userColumn] who is one of the
  /// people this rule permits — true for [author] and [authorOrOwner].
  ///
  /// This is what the server's insert-only replication exemption keys on: a
  /// row that names its own author is field data somebody else's device may
  /// legitimately carry.
  bool get namesRowAuthor =>
      this == MutationRule.author || this == MutationRule.authorOrOwner;

  /// Whether §4.17's clause 2 — *"this project already reaches them"* — may
  /// vouch for a row governed by this rule naming somebody other than the
  /// caller.
  ///
  /// False for [isAuthorizationState] (a membership row is somebody's rights,
  /// and replicating one is not replication but privilege escalation) and for
  /// [namesRowAuthor] (task 11.24: a record that names an author must name the
  /// caller). True for [anyUser] alone, whose only user column *is* the audit
  /// column — so "clause 2 still applies here" is exactly "shared project
  /// vocabulary still replicates."
  ///
  /// **Task 11.93 narrowed where this getter is the whole answer.** It still
  /// decides whether a *table* may carry a foreign name at all; which of that
  /// table's columns may is [SyncTable.vouchesForAForeignNameIn], because
  /// `Actual_Tag_Locations` now names a finder while keeping [anyUser]. An
  /// identity column never vouches, on any table.
  ///
  /// **The server's `RowAuthorizer._authorizeNaming` asks that getter**, and
  /// the client's offer filter is built from the same declarations. It lives
  /// here
  /// rather than on either side for the reason this whole file does: a client
  /// that offers rows the server is bound to refuse produces a warning nobody
  /// can act on, which is task 11.43's finding, and one definition is what
  /// makes that disagreement impossible rather than merely unlikely.
  bool get vouchesForAForeignName => !isAuthorizationState && !namesRowAuthor;

  /// Whether an **audit** name — `last_modified_by`, *who last edited this* —
  /// may be replicated into a new row of a table governed by this rule
  /// without the project having to reach the person it names (task 11.47).
  ///
  /// ## The claim an edited-by column is entitled to make
  ///
  /// [vouchesForAForeignName] asks clause 2's question — *"does this project
  /// already reach them?"* — of every user column alike. That question is the
  /// right one for a column that says **who a record is about**, and the
  /// wrong one for a column that says **who last touched it**. The two harms
  /// clause 2 exists to bound both come apart here:
  ///
  /// - **Disclosure does not arise.** An identity column is a reachability
  ///   edge: naming somebody in one is why their `Users` and `User_Emails`
  ///   rows get delivered on the next pull. The audit column is deliberately
  ///   *not* such an edge — `ProjectReachability.resolve` excludes it by
  ///   construction, via [SyncTable.identityUserColumns], and it is a foreign
  ///   key on neither side of the wire. Nothing is delivered on the strength
  ///   of an audit name, so replicating one discloses nothing that asking
  ///   about it would not disclose more.
  /// - **Attribution is already bounded, one line up.** Task 11.24's rule is
  ///   that a record naming its author must name the caller, and
  ///   [namesRowAuthor] is where that is enforced. This getter is false for
  ///   exactly those tables, so it cannot loosen it. What is left — the
  ///   [anyUser] tables — is shared vocabulary: a tag, a session, an
  ///   estimate, a known location. "Who last renamed this tag" is a far
  ///   weaker claim than "who recorded this bearing", and it is not what task
  ///   11.24 was protecting.
  ///
  ///   **That paragraph used to end "whose *only* user column is the audit
  ///   column", and task 11.93 falsified it** by giving
  ///   `Actual_Tag_Locations` a `user_id`. The argument survives because the
  ///   line it depends on is per column, not per table: an identity column is
  ///   refused a foreign name on every table (see
  ///   [SyncTable.vouchesForAForeignNameIn]), so relaxing the audit column
  ///   here still cannot reach one.
  ///
  /// ## Why the weak claim was worth this much
  ///
  /// **The cost of refusing it is not paid by the claim; it is paid by the
  /// caller's own field data.** A `Tags` row refused because a colleague last
  /// renamed it makes every bearing *of the caller's own* that uses that tag
  /// a foreign global reference, so it is refused too. A note about who
  /// renamed somebody else's tag blocked the person's own observations from
  /// reaching the server — and, because the colleague is typically somebody
  /// who handed over an archive and moved on, it blocked them **forever**:
  /// clause 2 could never come true, so the rows were held indefinitely
  /// rather than held pending anything.
  ///
  /// ## What is deliberately *not* relaxed
  ///
  /// - **Identity columns.** Unchanged, on every table. A row that says who
  ///   made a measurement is still only accepted from that person's device.
  ///   Michael's decision of 2026-08-28 — a record restored from a
  ///   colleague's archive keeps their name — is what makes that permanent,
  ///   and it is an accepted outcome rather than a defect.
  /// - **The update path.** An update genuinely *is* being performed by the
  ///   caller, so a stored row cannot be left claiming somebody else made
  ///   this change (`DenialReason.unattributedChange`). This getter governs
  ///   inserts only, where the audit name is honest provenance carried from
  ///   the device the row was replicated off.
  /// - **[namesRowAuthor] tables**, which is what keeps task 11.18's
  ///   *"…then withdrawn by name"* sentence unforgeable: an
  ///   `Observation_Exclusions` row is governed by [authorOrOwner], so this is
  ///   false for it and its audit column is still checked.
  ///
  /// Derived from the rule and from [auditUserColumn] rather than from the
  /// five tables that prompted it, per task 10.66's standing criterion — a
  /// seventh shared-vocabulary table inherits this by declaring its rule.
  bool get replicatesAForeignAuditName => vouchesForAForeignName;

  /// The column naming the user this rule permits, or null when it names none.
  ///
  /// Distinct from [governingColumn], which for [owner] names the creator/audit
  /// record and for [projectOwner] names a project — neither of which is "a
  /// user this rule permits". Only [namesRowAuthor] rules have one.
  String? get userColumn => namesRowAuthor ? governingColumn : null;

  /// The column naming the project whose owners govern this row, or null when
  /// [resolvesProjectOwners] is false.
  ///
  /// `Projects`, `Project_Memberships` and `Observation_Exclusions` all spell
  /// it `project_id`; for `Projects` that column is the primary key, so "the
  /// project this row is" and "the project this row belongs to" are one lookup.
  String? get projectColumn => resolvesProjectOwners ? 'project_id' : null;

  /// Whether [actorUserId] may mutate a row whose governing column holds
  /// [governingValue], under this rule. Pure and synchronous — the single
  /// source of truth shared by the app's repository-layer check, its UI-layer
  /// "can edit" affordances, and the server's enforced check, so no two of
  /// them can disagree about the same row.
  ///
  /// A null [governingValue] permits: there's nothing to single out, so
  /// nothing to deny. Callers that treat "row not found" as null must
  /// therefore decide for themselves whether a missing row is permitted —
  /// this method cannot tell the two apart.
  ///
  /// **Throws for [owner], [projectOwner] and [authorOrOwner].** Those need an
  /// owner *set*, not a column value, and the set needs a database — see
  /// [permittedByOwners]. Throwing rather than quietly keeping task 8.4's
  /// single-value comparison is the point (task 11.1): every call site that
  /// still asks the question the old way is a place ownership transfer would
  /// silently not apply, and failing loudly in the first test that touches it
  /// is how those get found. The two UI call sites 11.1 inherited were exactly
  /// that shape. Task 11.15 added [authorOrOwner] to the same list for the
  /// same reason in the opposite direction: answering it here would silently
  /// drop the owner half and leave the mark unwithdrawable, which is the very
  /// bug the rule exists to fix.
  bool permits(String? actorUserId, String? governingValue) {
    if (resolvesProjectOwners) {
      throw StateError(
        "MutationRule.$name is governed by the project's owner set, not by a "
        'single column value. Resolve the owners (resolveProjectOwners) and '
        'call permittedByOwners instead.',
      );
    }
    if (governingColumn == null) return true;
    return governingValue == null || governingValue == actorUserId;
  }

  /// Whether [actorUserId] may mutate a row governed by this rule, given the
  /// [owners] [resolveProjectOwners] returned for [projectColumn]'s project
  /// and the user the row itself names in [userColumn] ([authorUserId]).
  ///
  /// A null [owners] means the project could not be resolved at all — it is not
  /// on this device, or not on this server yet. That permits, on exactly the
  /// contract [permits] states for a null governing value: there is nothing to
  /// single out, so nothing to deny, and the caller decides what an unresolved
  /// project means. It is also what keeps a first publish working, where every
  /// row of the batch is authorized before any of them is written, so the
  /// batch's own `Projects` row is not yet stored. An **empty** [owners] is a
  /// different answer and denies: the project resolved, and named nobody.
  ///
  /// **[authorUserId] is required rather than optional (task 11.15).** Only
  /// [authorOrOwner] consults it; the two pure ownership rules ignore it, and
  /// pass null. Making it required is what stops the disjunction being lost by
  /// omission: a call site that forgot it would silently deny the mark's own
  /// author, which fails closed but fails *wrong*, and a wrong denial here is
  /// exactly the unwithdrawable-mark harm this rule was added to end. Every
  /// caller must state both halves, even the ones that have nothing to say.
  bool permittedByOwners(
    String? actorUserId, {
    required Set<String>? owners,
    required String? authorUserId,
  }) {
    if (!resolvesProjectOwners) {
      throw StateError(
        'MutationRule.$name is not governed by a project owner set; call '
        'permits instead.',
      );
    }
    // The author half of the disjunction, on the same contract [permits]
    // states: a row naming nobody has nothing to single out, so nothing to
    // deny — and a row naming you is yours whatever the owner set says.
    if (this == MutationRule.authorOrOwner) {
      if (authorUserId == null) return true;
      if (authorUserId == actorUserId) return true;
    }
    if (owners == null) return true;
    return actorUserId != null && owners.contains(actorUserId);
  }
}

/// Which [MutationRule] governs each table.
///
/// Previously this mapping existed only as an argument passed by each of the
/// app's eleven repository constructors, which meant the server had no way to
/// consult it without reading Flutter code. Hoisting it here is what lets the
/// server enforce *the same* table-to-rule assignment rather than a
/// hand-copied second list that can drift.
///
/// Every table in [Tables.all] must appear. There is deliberately no default:
/// a table added without a rule should fail loudly (see
/// [assertEveryTableHasAMutationRule]) rather than silently inherit the most
/// permissive behaviour, which is how authorization gaps normally ship.
const Map<String, MutationRule> tableMutationRules = {
  Tables.users: MutationRule.author,
  Tables.userEmails: MutationRule.author,
  Tables.projects: MutationRule.owner,
  Tables.projectMemberships: MutationRule.projectOwner,
  // Task 11.240. Shared project vocabulary with no author, like the tag it
  // is named by — a contributor who identifies a chick in the field must be
  // able to record it, for the reason `TagRepository` gives for tag creation.
  // Unlike a tag, editing one changes what no bearing means: bearings attach
  // to the transmitter, and the animal is derived. So there is no owner-only
  // lifecycle rung here, and the ordinary gradient (a viewer writes nothing)
  // is the whole of the rule.
  Tables.individuals: MutationRule.anyUser,
  Tables.tags: MutationRule.anyUser,
  // Task 11.243. Shared project vocabulary with no author, like the two rows
  // it joins. **It is deliberately not owner-only, and that is worth stating
  // because a deployment looks more consequential than an animal.** Saying
  // which collar went on which bird, and when, is exactly the thing the
  // person holding the bird in the field knows and the owner does not — a
  // contributor records it or nobody does until the season is over. Editing
  // one *does* change what earlier bearings are attributed to, unlike
  // `Individuals` — but it re-attributes exactly the window it changes, and
  // no bearing is rewritten, which is the whole argument for the table
  // (design §2). A viewer writes nothing, per the ordinary gradient.
  //
  // **The interlock is not expressible here**, because a rule table governs
  // one row's columns and an overlap is a fact about the project's other
  // deployments. It lives in `DeploymentInterlock`, called from
  // `DeploymentRepository` on the device and from `SyncService` at the
  // boundary — the same two-enforcer shape the tag lifecycle rung has.
  Tables.deployments: MutationRule.anyUser,
  // Task 11.32. Same rule as the tag it is a version of, and for the same
  // reason: a version row is shared project vocabulary with no author. The rung
  // that actually matters here — that only an owner may change what a tag *is*
  // — is not expressible as a rule over a row's columns, so it lives where the
  // tag's own does: `TagRepository.assertMayEdit` on the device and
  // `RowAuthorizer._authorizeTagLifecycle` at the boundary, both of which
  // reach a `Tag_Versions` row through the project it now lives in (task
  // 11.219) rather than through a reachability computation over its `tag_id`.
  Tables.tagVersions: MutationRule.anyUser,
  Tables.triangulationSessions: MutationRule.anyUser,
  Tables.observations: MutationRule.author,
  // Task 11.7 made this [MutationRule.author] — the mark's author withdraws
  // it — and task 11.15 widened it to [MutationRule.authorOrOwner], because
  // under the narrower rule a mark made by someone who then left the project
  // could never be withdrawn by anybody. Who may *create* a mark is a
  // different and stricter question the rule table cannot express — a rule
  // governs updates to a stored row, and on an insert there isn't one — so it
  // is asserted at the point of the write, and the same assertion guards a
  // withdrawal so that an owner-only exclusion stays owner-only to undo; see
  // `ObservationExclusionRepository.assertMayMark`.
  Tables.observationExclusions: MutationRule.authorOrOwner,
  Tables.nonDetections: MutationRule.author,
  Tables.estimatedPositions: MutationRule.anyUser,
  Tables.actualTagLocations: MutationRule.anyUser,
};

/// Throws if any table in [Tables.all] has no entry in [tableMutationRules].
///
/// Called from tests on both sides of the wire. The point is that adding a
/// table is a change someone has to make a *decision* about, not one that
/// quietly defaults to permitting everyone.
void assertEveryTableHasAMutationRule() {
  final missing = [
    for (final table in Tables.all)
      if (!tableMutationRules.containsKey(table)) table,
  ];
  if (missing.isNotEmpty) {
    throw StateError(
      'No MutationRule declared for: ${missing.join(', ')}. Add an entry to '
      'tableMutationRules — there is no default on purpose.',
    );
  }
}
