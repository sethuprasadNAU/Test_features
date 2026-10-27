/// Row-level authorization for pushed rows (task 10.10).
///
/// Phase 8's rule table runs on the client, where it is advisory: it stops a
/// new screen from *accidentally* offering an edit it shouldn't, but anyone
/// who can craft an HTTP request bypasses it entirely. This is the same rule
/// table (`package:tritrack_sync`'s [tableMutationRules], not a second copy)
/// re-applied against the server's own data, where it is the boundary.
library;

import 'package:postgres/postgres.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../schema/postgres_schema.dart';
import '../sync/project_reachability.dart';
import 'project_authorizer.dart';

/// Why a row was refused. Reported as a single opaque `unauthorized` outcome
/// on the wire — the distinction exists for the diagnostics console (10.13)
/// and for tests, not for the caller, who should learn nothing about *why* a
/// probe failed.
enum DenialReason {
  /// The row claims to belong to a different project than the request.
  crossProjectClaim,

  /// The stored row with this primary key lives in a different project. An
  /// update would have moved it into the caller's project.
  crossProjectCapture,

  /// The row's [MutationRule] does not permit this caller.
  ruleDenied,

  /// The caller's role forbids **creating** a tag — they are a `viewer`
  /// (task 11.11's exception-free reading of 11.3's gradient).
  ///
  /// Distinct from [roleForbidsWrite] only in where it is decided: creating a
  /// tag used to be judged outside the role gradient entirely, because
  /// `Tags` was a global table with no `project_id` to resolve a role
  /// against. Task 11.219 gave it one, so the gradient reaches it — this
  /// stays as the tag-shaped statement of the same refusal, and as the place
  /// the asymmetry with [changeTagRequiresOwner] is written down.
  createTagForbidden,

  /// The push changes nothing, and the stored row it matched is one the caller
  /// may not be shown. Answering "the server already holds that" would be an
  /// existence oracle for a row they cannot otherwise reach (task 10.29).
  concealedNoOp,

  /// The row names a user other than the caller, and no replication provenance
  /// backs the name — the server already holds that identity. Disclosure: the
  /// name is a reachability edge, so it would deliver a stranger's profile and
  /// address history on the next pull.
  namesForeignUser,

  /// An update would change *who a stored row names* — its author, its owner,
  /// or who last touched it. Integrity: fabricated attribution, and (for
  /// `author` rows) irrevocable, because the forger is locked out of the row
  /// afterwards.
  reattribution,

  /// An update changes the stored row while its audit column still names
  /// somebody else — so the record would say a change this caller made was
  /// made by that person (task 11.24). Distinct from [reattribution], which
  /// refuses a name being *changed*: this refuses one being left alone.
  ///
  /// The separation is not cosmetic. Task 11.18 shipped a "…then withdrawn by
  /// *name*" sentence in the Team log that reads exactly this column, and the
  /// route to a false one was to leave the name as found rather than to
  /// rewrite it — which every other clause here permits by design.
  unattributedChange,

  /// The row carries an email address the server has never authenticated for
  /// the `user_id` it belongs to. An identity email is what the client merger
  /// dedups people by, so an unverified one is [reattribution] by another
  /// route — see [RowAuthorizer._authorizeEmailClaim].
  unauthenticatedEmail,

  /// The [MutationRule]'s governing column (`user_id`, `owner_user_id`, or the
  /// ownership rules' `project_id`) is present but is not a
  /// string (task 10.64, the J-4 class reached through row content instead of
  /// the envelope). Refused rather than treated as absent: [MutationRule.
  /// permits] reads a `null` governing value as *permitted*, so silently
  /// coercing a wrongly-typed one to `null` would turn a malformed value into
  /// an approval — worse than the uncaught `TypeError` this replaced, which at
  /// least failed the whole push instead of admitting the row.
  malformedGoverningColumn,

  /// The write would leave the project with no open `owner` membership at all
  /// (task 11.1). Refused rather than applied: a project nobody can manage has
  /// no recovery path on a server that has no privileged operator. See
  /// [RowAuthorizer._authorizeOwnerRemoval].
  lastOwnerRemoval,

  /// The caller's **role** in the project forbids writing its data at all —
  /// they are a `viewer` (task 11.3). Distinct from [ruleDenied], which is
  /// about *this row*: a viewer is refused every row of the project, including
  /// ones they authored themselves before the role changed.
  roleForbidsWrite,

  /// The row would **create** something whose existence is itself a permission
  /// — a membership, a project, a tag link — and the caller is not entitled to
  /// issue that grant (task 11.3). See
  /// [RowAuthorizer._authorizeGrantingInsert] and [SyncTable.insertIsAGrant].
  unauthorizedGrant,

  /// The row takes a teammate's observation out of position estimation and the
  /// caller is not an owner of the project (task 11.7). Distinct from
  /// [roleForbidsWrite], which refuses a viewer everything: this refuses a
  /// *contributor* one particular kind of row, because removing evidence with
  /// no replacement to offer is the "data quality" rung the role gradient
  /// reserves for owners. Superseding — which puts a corrected record in the
  /// original's place — stays contributor-level and is not refused here.
  excludeRequiresOwner,

  /// The row would **change a tag that already exists** — rename it, move
  /// its frequency, retire it, or take it out of the project — and the caller
  /// is not an owner of that project (task 11.11, carrying task 11.24 and
  /// task 11.26's known instance).
  ///
  /// **Creating a tag stays contributor-level** ([createTagForbidden] is the
  /// only bar there, and only for a viewer). Creating is additive and
  /// recoverable; changing an existing tag rewrites what every observation
  /// already pointing at it means, and those cannot be re-recorded.
  ///
  /// **It absorbed the old `removeTagRequiresOwner` in task 11.219.** Taking
  /// a tag out of a project used to be a `Project_Tags` link being
  /// deactivated or tombstoned, and needed a clause of its own because that
  /// link table was [MutationRule.anyUser] — whose `governingColumn` is null,
  /// so `permits` returned true for every member with write rights, and a
  /// contributor's device pushing the row directly had it accepted and the
  /// tag vanished from every member's pickers. **Reproduced live before it
  /// was fixed**, both ways: `status` set to `inactive` answered `updated`,
  /// and so did a tombstone on the same row.
  ///
  /// A tag belongs to one project now, so removing it *is* changing it and
  /// one rule covers both — including that tombstone route, which the app
  /// has no method for and a crafted push does.
  changeTagRequiresOwner,

  /// The row would **tombstone an existing `Individuals` row** — delete an
  /// animal — and the caller is not an owner of that project (task 11.255,
  /// `PERMISSIONS_MATRIX.md` §4.7 IN4 and §8 entry 13, Michael's option (a),
  /// 2026-09-15).
  ///
  /// **Only the tombstone moves. Every other write to `Individuals` stays
  /// contributor-level** — naming a new animal, editing its name, colour,
  /// status, species, sex or notes, and linking or unlinking a collar are all
  /// still the ordinary [MutationRule.anyUser] gradient. Task 11.254 measured
  /// that a merge reaches this same tombstone by a different door
  /// (`IndividualMerge.merge` re-points collars, then calls
  /// `IndividualRepository.remove`), so holding this one write to the owner
  /// rung is what closes the irreversible half of both a delete and a merge
  /// at once — see [changeTagRequiresOwner] for the sibling shape on `Tags`,
  /// which this deliberately does not copy wholesale: an animal's *edit*
  /// changes what no bearing means (bearings attach to the collar, not the
  /// animal), so there is no reason to hold that half to the owner rung the
  /// way a tag's own identity is, and task 11.244's "a contributor may
  /// correct a mistaken animal" stays true for everything short of deleting
  /// its record.
  deleteIndividualRequiresOwner,

  /// The row points at a row this server does not hold and this push is not
  /// going to establish — a bearing naming a triangulation session that was
  /// refused, an observation naming a tag that was, a project-scoped row with
  /// no `Projects` row behind it (task 11.46).
  ///
  /// **This is the only reason here that is not a permission judgement.** It
  /// is referential integrity, refused at the same seam as everything else
  /// because of what happens otherwise: the schema's foreign keys are
  /// `DEFERRABLE INITIALLY DEFERRED` (task 10.5), so a dangling reference does
  /// not raise at the INSERT that made it — it raises at COMMIT, after every
  /// per-row outcome has already been decided, and takes the **whole request**
  /// down with it. What a person saw was a publish or a sync that died with an
  /// unexplained error and no record of which row caused it, while the rows
  /// that were perfectly fine went down with it. Refusing the one row instead
  /// costs that row nothing it was not already going to lose (its referent was
  /// refused too) and lets the rest of the push land.
  ///
  /// See [RowAuthorizer._authorizeReferences] for why this cannot become an
  /// existence oracle, which is the question every check in this enum has to
  /// answer.
  danglingReference,
}

/// A project's current owners, and the open owner membership rows they came
/// from. See [RowAuthorizer._ownership].
class _ProjectOwnership {
  const _ProjectOwnership({
    required this.owners,
    required this.ownerRowKeys,
    required this.openMemberUserIds,
  });

  /// Null when the server holds no such project — see
  /// [MutationRule.permittedByOwners], which reads null and empty differently.
  final Set<String>? owners;

  /// `membership_id`s of the rows [owners] was computed from. Empty when
  /// [owners] came from the `Projects.owner_user_id` fallback instead.
  final Set<String> ownerRowKeys;

  /// Everyone holding an **open** membership of any role — `end_date` and
  /// `deleted_at` both null. Read for the pair invariant in
  /// [RowAuthorizer._authorizeGrantingInsert]: at most one open row per
  /// (project, user).
  final Set<String> openMemberUserIds;
}

/// The outcome of authorizing one row.
class AuthzVerdict {
  const AuthzVerdict.allow() : reason = null;
  const AuthzVerdict.deny(DenialReason this.reason);

  final DenialReason? reason;

  bool get isAllowed => reason == null;
}

/// Applies [tableMutationRules] to rows arriving over sync.
///
/// ## Two questions, not one — five, since task 11.3
///
/// Authorization here answers **who owns this row** (the rule table, below),
/// **who does this row name** (the invariant in [_authorizeNaming]), **what
/// does it claim that person's address is** (the invariant in
/// [_authorizeEmailClaim]), **what may this caller's role write at all**
/// ([_authorizeRole]), and **may they create a row that is itself a
/// permission** ([_authorizeGrantingInsert]).
///
/// The last two are task 11.3's, and both exist because the rule table answers
/// a question about a *row* while a team raises two about a *person*. A
/// `viewer`'s refusal is not a property of any row they push — it is the same
/// refusal for every one of them — and a membership insert's refusal cannot
/// come from the rule table at all, because Phase 8 deliberately authorizes no
/// inserts. Leaving either to fall out of the existing checks would have worked
/// today and broken silently on the next edit to those checks, which is the
/// failure shape §5.9 was written to stop repeating.
///
/// Until task 10.20 it answered only the first, and Security Gate C found four
/// live exploits of the gap — three disclosure, one integrity — that every
/// prior review and the whole test suite had missed, because each looked like
/// a different bug. They were one omission: a row's `user_id`, `owner_user_id`
/// and `last_modified_by` are not payload, they are *claims about a person*,
/// and a claim about someone else is either a way to reach their global rows
/// or a way to put their name on a record they never made.
///
/// The third question is that same omission found once more, one column over
/// (task 10.55, finding I-4). An identity `email` is a `user_id` in the
/// client's eyes — the merger dedups people by address — so a naming invariant
/// enforced on `user_id` and not on `email` was reachable straight through the
/// column beside it. See [_authorizeEmailClaim].
///
/// Gate B had already patched two instances of this by hand — dropping
/// `last_modified_by` from pull's reachability computation, and forbidding a
/// `Project_Memberships` row that named anyone but the caller. Neither was
/// wrong; both were the same rule written once per column. [_authorizeNaming]
/// is that rule stated once, over [SyncTable.userColumns], for every table, and
/// the membership special case is gone because it now falls out.
///
/// ## The one exemption, and why it is shaped the way it is
///
/// A legitimate push routinely carries rows the pusher did not author. A
/// project's first publish (task 10.9) uploads a `Users` row for every person
/// its data references, and Phase 6's share/import features deliberately
/// replicate observations authored elsewhere, preserving the author's sync
/// clock verbatim. A naive "the `user_id` must equal the session user" would
/// refuse all of that and break publish outright — including at the foreign-key
/// level, since the referenced `Users` row would be refused alongside the
/// observation that needs it.
///
/// The exemption is drawn along two lines at once.
///
/// First, it applies **only to [MutationRule.author] rows** — the ones that
/// record who observed what. Those are the only rows replication legitimately
/// carries with someone else's name on them. `owner` and `projectOwner` rows
/// (`Projects`, `Project_Memberships`) are *authorization state*, not field
/// data: replicating those is not replication, it is privilege escalation.
/// Leaving them in cost nothing to write and would have let any member of a
/// project insert a membership row promoting themselves to owner — which is
/// exactly what the test named "a member cannot grant themselves a role"
/// caught before this clause existed.
///
/// Second, it is drawn at **insert versus update**, which is where the risk
/// changes:
///
/// - **Inserting** a row attributed to someone else *introduces* a record the
///   server has never seen. That is what replication is. It is confined to a
///   project the caller already has write access to, and in Phase 10 nobody
///   else can read that project.
/// - **Updating** a row attributed to someone else *overwrites an existing
///   record*. That is forgery, it is never something the app's own UI can
///   produce (the client rule forbids it too), and it is precisely the
///   acceptance criterion "a request authenticated as one user cannot mutate
///   another user's observation". Always denied, with no exemption.
///
/// Note the third case never reaches here at all: a push that does not
/// *change* the stored row needs no permission, because nothing is mutated.
/// [SyncService] authorizes only rows whose merge decision changes something,
/// which is what lets a device re-offer its whole project every sync without
/// tripping over rows it merely carries. That mirrors the narrowness of the
/// client's `MutationActor.replication` bypass rather than widening it.
///
/// ## The rule task 10.29 had to state out loud
///
/// Gate C's finding D-1 found this class answering, through the push response's
/// per-row `outcomes` map, the very question task 10.21 had just stopped the
/// HTTP status code from answering: *does this thing exist on this server?* It
/// did so three ways at once — a stranger's registration status, a tag id, a
/// row's primary key — and two of those predated the remediation.
///
/// The reason all three were here is that the argument against each was already
/// written down and had only ever been applied to the instance in front of it.
/// [authorizeWrite]'s own comment below says a row aimed at an unreachable
/// project must be refused outright "rather than answered with 'the server
/// already has a newer copy of that', which is an existence oracle for rows in
/// other people's projects" — correct, and true of every row, not just
/// cross-project ones. So, stated once, for the whole class:
///
/// > **A row's outcome may not depend on server state the caller has no other
/// > way to observe.** Where authorization has to consult such state, the two
/// > branches must converge on one answer — and it has to be the refusal, since
/// > the permissive branch is the one that *is* the answer.
///
/// Three consequences, each replacing a branch that used to fork on hidden
/// state:
///
/// 1. **Naming a stranger is refused whether or not the server knows them.**
///    The "the server has never heard of them" clause is gone; see
///    [_authorizeNaming].
/// 2. **A no-op is not a free pass.** Whether the stored row it matched may be
///    shown to the caller is checked before "nothing changed" is reported back,
///    because "nothing changed" is itself a statement about that row.
/// 3. **A tag may be referenced only where pull would already deliver it.**
///    That was `_authorizeTagReferences`, 161 lines of it. **Task 11.219
///    deleted the clause by deleting the question:** a tag belongs to one
///    project now, so a tag reference is a same-project reference and the
///    scope check at the top of [_decide] is the whole of the answer. What
///    is left of the tag rules is [_authorizeTagLifecycle], which is about
///    who may create versus change one and was never about globality.
///
/// What remains, and is stated rather than hidden: a client-chosen primary key
/// that is free accepts and one that is taken refuses, so a push still reveals
/// whether an id it names is in use. Security Model §4.13 already bounded that
/// for `Projects`; D-1 is why it is now written there as a property of every
/// table.
class RowAuthorizer {
  RowAuthorizer({
    required this.session,
    required this.projectId,
    required this.userId,
    required this.access,
  });

  final Session session;

  /// The project the *request* is scoped to, from the sync envelope.
  final String projectId;

  /// The authenticated caller. Never taken from the payload — `device_id` and
  /// any `user_id` in a row are forgeable client-side values.
  final String userId;

  /// The caller's already-resolved relationship to [projectId].
  final ProjectAccess access;

  /// Memoised per push. A read-only question about state that cannot change
  /// while a push is being authorized: [SyncService] decides every row before
  /// it writes any of them, so a batch is judged against one consistent
  /// pre-push snapshot.
  ProjectReachability? _reachable;

  /// Authenticated account addresses by `user_id`, memoised per push. A cached
  /// null means "asked, and the server holds no account for them" — see
  /// [_authenticatedEmail].
  final Map<String, String?> _accountEmails = {};

  /// Whether [userId] may write [incoming] over [existing] (null = insert).
  ///
  /// [changesStoredRow] comes from the merge decision. When false the push is
  /// a no-op — the server's copy already wins — so there is no mutation to
  /// authorize and the rule check is skipped. The cross-project checks are
  /// **not** skipped: they run on every row regardless, because a row aimed at
  /// a project the caller cannot reach must be refused outright rather than
  /// answered with "the server already has a newer copy of that", which is an
  /// existence oracle for rows in other people's projects.
  ///
  /// Two stages, and the order between them is the whole of task 11.46:
  /// [_decide] answers *may this caller write this row*, and only a row that
  /// survives that is asked *does what it points at exist* — see
  /// [_authorizeReferences]. Running integrity last is what keeps it from
  /// answering a question authorization would have refused to answer.
  Future<AuthzVerdict> authorizeWrite({
    required SyncTable table,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
    required bool changesStoredRow,
  }) async {
    final verdict = await _decide(
      table: table,
      incoming: incoming,
      existing: existing,
      changesStoredRow: changesStoredRow,
    );
    if (!verdict.isAllowed) return verdict;

    // A no-op writes nothing, so it can dangle nothing, and asking anyway
    // would be a question about server state on a row that is not changing.
    if (changesStoredRow) {
      final dangling = await _authorizeReferences(
        table: table,
        incoming: incoming,
      );
      if (dangling != null) return dangling;
    }

    // **Made here rather than at the four allow paths inside [_decide], and
    // that placement is load-bearing.** A row refused by
    // [_authorizeReferences] must vouch for nothing — the same rule Security
    // Gate B's re-run established for a no-op, one stage later.
    //
    // **The second note this used to make is gone with task 11.219.** A
    // push carrying a new tag and the bearing that uses it needed the tag
    // recorded as *established by this push*, because both were judged
    // against one pre-push snapshot in which neither existed yet, and the
    // tag was a global row the project had to be shown to reach. A tag is
    // project-scoped now: the bearing and the tag claim the same project and
    // the scope check answers both, so there is nothing to vouch for.
    if (changesStoredRow || existing != null) {
      _noteWritten(table, incoming);
    }
    return verdict;
  }

  /// The permission half of [authorizeWrite]. Every `allow` it returns is
  /// provisional until [_authorizeReferences] has also passed.
  Future<AuthzVerdict> _decide({
    required SyncTable table,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
    required bool changesStoredRow,
  }) async {
    final scope = table.projectScopeColumn;
    if (scope != null) {
      // The row must claim the project the request is scoped to. Rejected
      // rather than quietly rewritten: silently relabelling a row's project
      // would move data between projects on the caller's say-so.
      if (incoming[scope] != projectId) {
        return const AuthzVerdict.deny(DenialReason.crossProjectClaim);
      }
      // And the row it would overwrite must already live there.
      //
      // **This is unreachable as of task 10.35, and is kept deliberately.**
      // It existed because primary keys were looked up globally: without it a
      // caller could push a row carrying *another project's* primary key but
      // their own `project_id` and capture that row out of a project they
      // could not otherwise reach. Keys are now project-scoped, so
      // `SyncService._findRow` includes `project_id` in its predicate and can
      // only ever return a row from this project — and the check above has
      // already established that `incoming[scope] == projectId`.
      //
      // Kept rather than deleted because it is the *statement* of the
      // invariant, not just an implementation of it. `_findRow` builds its
      // predicate generically from `SyncTable.primaryKey`; a future edit there,
      // or a table added without `project_id` in its key, would reopen the hole
      // silently. This turns that into a refusal instead. It costs one
      // comparison on a value already in memory.
      //
      // It was also the check that made Phase 6.3's shared observations
      // permanently unsyncable — see `TriTrack_Security_Model.md` §4.13. That
      // was not this check being wrong; it was correct given global keys, and
      // fixing it meant changing the keys rather than weakening it.
      if (existing != null && existing[scope] != projectId) {
        return const AuthzVerdict.deny(DenialReason.crossProjectCapture);
      }
    }

    // Creating a tag and changing one are different rungs, and neither is
    // expressible as a [MutationRule] over a row's columns. See
    // [_authorizeTagLifecycle].
    final tags = _authorizeTagLifecycle(
      table: table,
      existing: existing,
      changesStoredRow: changesStoredRow,
    );
    if (tags != null) return tags;

    // Deleting an animal is a different rung from editing one — task 11.255.
    // See [_authorizeIndividualLifecycle].
    final individualDelete = _authorizeIndividualLifecycle(
      table: table,
      incoming: incoming,
      existing: existing,
      changesStoredRow: changesStoredRow,
    );
    if (individualDelete != null) return individualDelete;

    if (!changesStoredRow) {
      // Nothing is mutated, so no *mutation* needs permission — but the answer
      // still is one. "The server already holds a copy of that" is a statement
      // about the stored row, and a caller who may not be shown that row may
      // not be told it exists either (task 10.29, finding D-1). This is the
      // same argument the cross-project checks above are made from, applied to
      // every row rather than only to the ones aimed at another project: it is
      // what stops a push of a stranger's `Users` row answering
      // `lost_to_server` where an unknown one answers `inserted`.
      if (existing != null &&
          !await _mayKnowRowExists(table: table, row: existing)) {
        return const AuthzVerdict.deny(DenialReason.concealedNoOp);
      }
      // **A no-op used to be able to vouch for a tag, and that was a live
      // cross-project write.** Security Gate B's re-run against task 11.3
      // found it: a deliberately stale copy of somebody else's tag needs no
      // write permission (it changes nothing), so it reached this branch,
      // recorded the tag id as established, and a second row for the same id
      // later in the same batch short-circuited every check behind it. The
      // whole mechanism is gone with task 11.219 — a tag is project-scoped,
      // so nothing has to be vouched for — and this note stays because the
      // shape (a no-op earning a privilege) is one to recognise elsewhere.
      return const AuthzVerdict.allow();
    }

    final rule = tableMutationRules[table.name];
    if (rule == null) {
      // Not reachable — `assertEveryTableHasAMutationRule` covers this in
      // tests — but a missing rule must fail closed rather than fall through
      // to "permitted", which is how authorization gaps normally ship.
      return const AuthzVerdict.deny(DenialReason.ruleDenied);
    }

    // **Leaving a project (task 11.28).** Computed once, here, and consulted
    // in exactly two places below — the role gradient and the ownership rule —
    // because those are the two refusals a person leaving would otherwise hit.
    // It is a shared predicate rather than a check written here so the app and
    // the server cannot disagree about what a departure is; see
    // [isSelfDeparture] for what it does and does not permit, and note that it
    // deliberately does **not** decide the last-owner question, which
    // [_authorizeOwnerRemoval] still answers below.
    final selfDeparture = isSelfDeparture(
      table: table.name,
      callerUserId: userId,
      existing: existing,
      incoming: incoming,
    );

    // **The role gradient (task 11.3).** Asked before anything about *this*
    // row, because it is not about this row: a `viewer` may write nothing in
    // this project, whatever the rule table would otherwise say and whoever
    // authored it. See [_authorizeRole].
    //
    // The one write it does not govern is a person ending their own membership
    // (task 11.28). A `viewer` is precisely the person most likely to want off
    // a project, and refusing them here would leave the gap M8 named open for
    // the role it hurts most. Nothing else about a viewer's rights moves: the
    // exception is one column on one row that names them.
    final role = _authorizeRole(table);
    if (role != null && !selfDeparture) return role;

    // **The owner-only rung inside a contributor-writable table (task 11.7).**
    final exclusion = _authorizeExclusionKind(
      table: table,
      incoming: incoming,
      existing: existing,
    );
    if (exclusion != null) return exclusion;

    // Who the row *names* — independent of who owns it. See below.
    final naming = await _authorizeNaming(
      table: table,
      rule: rule,
      incoming: incoming,
      existing: existing,
    );
    if (naming != null) return naming;

    // And what the row claims that person's *address* is — the same question
    // one column over. See [_authorizeEmailClaim].
    final email = await _authorizeEmailClaim(table: table, incoming: incoming);
    if (email != null) return email;

    // **Creating a row that is itself a permission (task 11.3).** The rule
    // table below authorizes *changing* a row; for three tables the row's
    // existence is the grant, so creating one has to be authorized separately.
    // See [_authorizeGrantingInsert] and [SyncTable.insertIsAGrant].
    if (existing == null && table.insertIsAGrant) {
      final grant = await _authorizeGrantingInsert(
        table: table,
        incoming: incoming,
      );
      if (grant != null) return grant;
    }

    // Authorized against the **stored** row for an update, exactly as the
    // client's `BaseRepository._authorize` does: whether you may change a row
    // is a property of the row as it stands, never of what the caller claims
    // it should become. Checking the incoming copy instead would let a caller
    // take over any row by asserting their own id in it.
    final governingRow = existing ?? incoming;
    // Task 10.64: on an insert (`existing == null`), `governingRow` is the
    // caller's own `incoming` — untrusted. `_authorizeNaming` above already
    // walks every [SyncTable.userColumns] entry and *tolerates* a wrongly
    // typed one (`named is! String` → `continue`, by design: an absent value
    // "names nobody"), which for [MutationRule.author]/[MutationRule.owner]
    // is the very column [rule.governingColumn] names — so a malformed value
    // reaches here regardless. Checked explicitly, once, rather than inside
    // [_governingValue] itself, because the two outcomes for "not a string"
    // are different depending on *why* it isn't one: a genuinely absent value
    // must keep meaning "nothing to single out, so nothing to deny" (`null`,
    // [MutationRule.permits]'s contract); a present-but-wrong-type value must
    // never collapse into that same `null`, because a caller who cannot make
    // a column absent (every identity column is `NOT NULL`) could otherwise
    // make it *wrong-typed* instead and reach the same "nothing to deny"
    // outcome — a bypass, not a fix, for the `TypeError` this replaced.
    final rawGoverning = rule.governingColumn == null
        ? null
        : governingRow[rule.governingColumn];
    if (rawGoverning != null && rawGoverning is! String) {
      return const AuthzVerdict.deny(DenialReason.malformedGoverningColumn);
    }
    if (rule.resolvesProjectOwners) {
      // Task 11.1: the permitted set includes the project's current owners,
      // not the single user named in `Projects.owner_user_id`. Read from the
      // *stored* row for an update, exactly as above —
      // `governingRow[projectColumn]` is the project the row already belongs
      // to, and the cross-project scope checks have already established it is
      // the one the envelope names.
      final projectId = governingRow[rule.projectColumn];
      if (projectId != null && projectId is! String) {
        return const AuthzVerdict.deny(DenialReason.malformedGoverningColumn);
      }
      final owners = projectId == null
          ? null
          : await _projectOwners(projectId as String);
      // Task 11.15: for [MutationRule.authorOrOwner] the set also includes the
      // user the row names, which for that rule is exactly the column
      // `rawGoverning` was read from and type-checked above.
      //
      // **Task 11.28's exception is ORed in here, and nowhere else, on
      // purpose.** Landing it inside this branch rather than as an early
      // `allow` above is what keeps [_authorizeOwnerRemoval] on the path: a
      // person leaving is subject to the last-owner rule exactly as an owner
      // removing them would be, and a project cannot be emptied of owners by
      // its last one walking out.
      if (selfDeparture ||
          rule.permittedByOwners(
            userId,
            owners: owners,
            authorUserId: rule.userColumn == null
                ? null
                : rawGoverning as String?,
          )) {
        final lastOwner = await _authorizeOwnerRemoval(
          table: table,
          incoming: incoming,
          existing: existing,
          owners: owners,
        );
        if (lastOwner != null) return lastOwner;
        return const AuthzVerdict.allow();
      }
    } else if (rule.permits(userId, _governingValue(rule, governingRow))) {
      return const AuthzVerdict.allow();
    }

    // The replication exemption, deliberately inserts-only *and*
    // author-rows-only. See the class doc. Keyed on
    // [MutationRule.namesRowAuthor] rather than on `author` by name since task
    // 11.15: `authorOrOwner` rows are field data that names its own author,
    // which is precisely what this exemption is for, and enumerating rules
    // here is how it would have been silently dropped.
    final isInsert = existing == null;
    if (isInsert && rule.namesRowAuthor && _mayReplicate(table)) {
      return const AuthzVerdict.allow();
    }

    return const AuthzVerdict.deny(DenialReason.ruleDenied);
  }

  /// **The role gradient, server-side (task 11.3).**
  ///
  /// > `viewer` writes nothing; `contributor` writes its own and nothing else;
  /// > `owner` everything, plus membership and settings.
  ///
  /// Returns a denial when the caller's role forbids writing this project's
  /// data at all, and null to fall through to the row-level rules.
  ///
  /// **One caller-side exception, and it is not applied here (task 11.28).**
  /// A person ending their own membership is permitted whatever their role,
  /// including `viewer`. That is decided by [isSelfDeparture] at the single
  /// call site above rather than inside this method, so this stays the plain
  /// statement of the gradient and the exception stays visible next to the
  /// other one it composes with (the last-owner rule).
  ///
  /// ## What this adds, and what was already there
  ///
  /// Two of the three rungs were already enforced, by the rule table rather
  /// than by anything role-shaped: [MutationRule.author] is what holds a
  /// contributor to their own observations, and [MutationRule.owner] /
  /// [MutationRule.projectOwner] are what reserve project settings and
  /// membership to owners. What had **no** enforcement anywhere was `viewer`.
  /// `ProjectAuthorizer` returned one undifferentiated `member`, so a viewer
  /// and a contributor were the same caller on both sides of the wire: a
  /// viewer could record observations, and could write every
  /// [MutationRule.anyUser] table — tags, sessions, position estimates,
  /// recovered-tag locations — because that rule permits everyone who gets
  /// this far. Read-only was a label on an invitation and nothing else.
  ///
  /// ## Why it is asked here rather than at the route
  ///
  /// A blanket `403` on push for a viewer would be simpler and is wrong twice
  /// over. It would refuse the one push a viewer legitimately makes — their own
  /// `Users` profile row, which is theirs and not the project's — and, worse,
  /// it would make every locally-recorded row disappear into a transport-level
  /// refusal the client reports as a failed sync rather than as a per-row
  /// decision. Task 10.28's rule is that a refused row is held, counted, and
  /// explained, never dropped; a per-row `unauthorized` gets that treatment and
  /// a `403` does not.
  ///
  /// ## Scope: project-scoped tables only, and why the global ones differ
  ///
  /// - `Users`, `User_Emails` — a person's own identity, not a project's data.
  ///   A viewer may still fix their own name. [_authorizeNaming] and
  ///   [_authorizeEmailClaim] already confine these to the caller themselves.
  ///
  /// **`Tags` used to be a third exemption and is not one any more (task
  /// 11.219).** It was global, so this method skipped it and the gradient
  /// was applied inside `_authorizeTagReferences` instead. It is
  /// project-scoped now, so the ordinary refusal above reaches it — which
  /// refuses a viewer every tag row of the project, as it should. The rung
  /// task 11.11 splits in two (a contributor may **create** a tag, only an
  /// owner may **change** one) is finer than this gradient can express and
  /// lives in [_authorizeTagLifecycle]; `absent` still passes here, which is
  /// what keeps a first publish working.
  AuthzVerdict? _authorizeRole(SyncTable table) {
    if (table.projectScopeColumn == null) return null;
    if (access.permitsProjectWrite) return null;
    return const AuthzVerdict.deny(DenialReason.roleForbidsWrite);
  }

  /// **Task 11.7: excluding a teammate's observation is owner-only.**
  ///
  /// Returns a denial when [incoming] is an `Observation_Exclusions` row of
  /// kind `excluded` and the caller is not an owner; null in every other case.
  ///
  /// ## Why this is not expressible in the rule table
  ///
  /// A [MutationRule] answers "who may change this stored row", once per
  /// table. This table needs two answers depending on a *column value*:
  /// superseding is contributor-level, excluding is owner-level. Splitting the
  /// two kinds into two tables to make the rule table fit would be the tail
  /// wagging the dog — they are the same record with the same lifecycle,
  /// differing only in what the person is asserting.
  ///
  /// ## Why the server checks it at all, when the app already does
  ///
  /// Because the app's check is advice and this is the boundary — the standing
  /// asymmetry this project keeps re-learning at gates. `ObservationExclusion
  /// Repository.assertMayMark` stops a contributor's *screen* from offering the
  /// control; nothing about it stops a device pushing the row directly, and a
  /// claimed control that does not fire on the wire is the shape Gate C, D and
  /// H each found at least once.
  ///
  /// ## The `absent`/unresolvable case permits, as everywhere else
  ///
  /// [_authorizeRole] has already refused a viewer and a non-member. What is
  /// left here is the first-publish case, where the project's own rows are
  /// being uploaded before the `Projects` row that would give the caller a
  /// role — refusing that would break publishing a project that already
  /// contains marks, which is the ordinary case for a project used offline.
  AuthzVerdict? _authorizeExclusionKind({
    required SyncTable table,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
  }) {
    if (table.name != Tables.observationExclusions) return null;
    const excluded = ObservationExclusionKind.excluded;
    // **Both copies, and task 11.24 is why.** As first written this read only
    // `incoming['kind']`, which is a value the caller chose — so the check
    // could be made not to fire by lying about what the stored mark is. Live
    // against the build before this fix: a demoted owner's own honest
    // withdrawal of their `excluded` mark answered `unauthorized`, and the
    // *same* withdrawal with `kind` flipped to `superseded` in the same row
    // answered `updated`. One row both escaped the rung and rewrote what the
    // mark said it was.
    //
    // The client never had this defect — `ObservationExclusionRepository.
    // assertMayMark` reads the stored row — which is the asymmetry §4.23
    // warns about running in the unusual direction: the boundary was the
    // looser of the two.
    final incomingKind = incoming['kind'];
    final storedKind = existing?['kind'];
    if (incomingKind != excluded.db && storedKind != excluded.db) return null;
    if (access == ProjectAccess.owner || access == ProjectAccess.absent) {
      return null;
    }
    return const AuthzVerdict.deny(DenialReason.excludeRequiresOwner);
  }

  /// **Creating a row whose existence is itself a permission (task 11.3).**
  ///
  /// Returns a denial when the caller may not issue the grant [incoming] would
  /// create, and null when they may.
  ///
  /// Phase 8's rule table governs edits and deletes and deliberately does not
  /// authorize inserts: creating a row is normally adding your own data. That
  /// is right for a field observation and wrong for `Project_Memberships`,
  /// where **the insert is the grant** — an unauthorized one is not a spurious
  /// record, it is a stranger on the project. Task 11.1 hand-checked
  /// `grantOwner` and task 11.2 hand-checked invite redemption, both in the
  /// app; neither binds a device that pushes the row over the wire instead,
  /// which is the check this is.
  ///
  /// ## Stated as a class, not as one table's special case
  ///
  /// [SyncTable.insertIsAGrant] is the classification and it is required on
  /// every table, so adding a table is a decision somebody wrote down. The
  /// switch below is exhaustive over the three tables that answer yes, and its
  /// unhandled branch **denies** — flagging a table without deciding what may
  /// create its rows fails closed and loudly rather than inheriting whatever
  /// the rule table happened to permit.
  ///
  /// ## The membership rule, in full
  ///
  /// Three conditions, and each closes a different way in:
  ///
  /// 1. **The row names the caller.** [_authorizeNaming] already refuses a
  ///    `projectOwner`-ruled row naming anyone else, so this is a restatement
  ///    — deliberately, because the refusal that matters most here should not
  ///    be reachable only as a side effect of a check about disclosure.
  /// 2. **The caller is a current owner, or the project has no owner set at
  ///    all yet.** The second half is the bootstrap, and it is not a loophole:
  ///    `owners == null` means the server holds no `Projects` row for this id,
  ///    which on this route can only happen inside a push that is establishing
  ///    the project with the caller as its owner (`_establishesProject` in
  ///    `sync_routes.dart` gates that, and `attemptPublish` rolls the whole
  ///    thing back unless the caller ends up owning it).
  /// 3. **The caller holds no open membership of this project already.** The
  ///    pair invariant — at most one open row per (project, user) — enforced
  ///    against a hostile device rather than only in the app. Two open rows
  ///    make role lookup arbitrary (`findForUser` takes `rows.first`), which
  ///    is a way to end up with permissions nobody granted. Task 11.10's
  ///    partial unique index is the backstop for the concurrent case this
  ///    check cannot see; this is the one that produces a legible refusal.
  ///
  /// Together these leave exactly one membership insert the push path accepts:
  /// a project's own creator, bootstrapping their owner row as they publish,
  /// or backfilling it on a project that predates task 8.4. **Adding somebody
  /// else is not a push at all** — it is an owner approving a join request, or
  /// re-admitting a past member, where the **server** writes the row itself
  /// from the request's own `project_id` and the role the owner chose at that
  /// moment (`JoinService`, `SyncService.insertServerAuthoredRow`). That is why
  /// this needs no permissive branch for joining, and must not grow one: a
  /// pushed row would name its own role, its own user and its own project, and
  /// the authorizer would have to prove each matched a decision somebody
  /// actually made. Handing the attacker the pen is the alternative design, not
  /// a simpler version of this one.
  ///
  /// **Task 11.81 changed what grants a membership and deliberately did not
  /// change this.** Approval replaced invite redemption, and it was built to
  /// land in exactly the same place: one server-authored insert, shaped by
  /// nothing in any request body. That is why not one line below had to move.
  Future<AuthzVerdict?> _authorizeGrantingInsert({
    required SyncTable table,
    required Map<String, Object?> incoming,
  }) async {
    const denied = AuthzVerdict.deny(DenialReason.unauthorizedGrant);
    switch (table.name) {
      case Tables.projects:
        // Creating a project makes the caller its owner — of nothing yet. The
        // grant is bounded by [_authorizeNaming], which refuses an `owner`-ruled
        // insert naming anybody but the caller, so this cannot create a project
        // for someone else; and by `_establishesProject`/`attemptPublish` on the
        // route, which refuse a push aimed at a project id that is already
        // taken. Nothing further to check.
        return null;
      case Tables.projectMemberships:
        final projectId = incoming['project_id'];
        final named = incoming['user_id'];
        if (projectId is! String || named is! String) return denied;
        // (1) names the caller.
        if (named != userId) return denied;
        final ownership = await _ownership(projectId);
        final owners = ownership.owners;
        // (2) a current owner, or the bootstrap.
        if (owners != null && !owners.contains(userId)) return denied;
        // (3) the pair invariant, against the stored rows **and** against what
        // this push has already been cleared to create. A push is authorized
        // row by row before any row is written, so without the second half two
        // membership rows in one batch would each see a snapshot containing
        // neither and both be allowed — leaving the two open rows for one pair
        // that the invariant exists to prevent. Same shape and same reason as
        // [_ownershipsRemovedThisPush] and [_writtenThisPush].
        final pair = '$projectId/$userId';
        if (ownership.openMemberUserIds.contains(userId) ||
            _membershipsGrantedThisPush.contains(pair)) {
          return denied;
        }
        _membershipsGrantedThisPush.add(pair);
        return null;
      default:
        // A table flagged [SyncTable.insertIsAGrant] with no case here. Fails
        // closed on purpose — see the class note above.
        return denied;
    }
  }

  /// **The row-naming invariant (task 10.20, Gate C finding C-1).**
  ///
  /// A row may not name a user other than the caller, in any of
  /// [SyncTable.userColumns], on any table — unless real replication
  /// provenance backs the name. Returns a denial, or null to fall through to
  /// the ownership rules.
  ///
  /// Naming someone has exactly two effects, and the exemption has to be
  /// narrow enough to stop both. **For two years it stopped one.** This
  /// sentence claimed both and finding N-1 (Security Model §18.3) found the
  /// gap — the exemption was reasoned about entirely in terms of disclosure,
  /// and attribution was left to the sentence rather than to the code. It is
  /// left standing, corrected, because a claim a check does not meet is worth
  /// more as a repaired record than as a deleted one.
  ///
  /// - **Disclosure.** An identity column is a reachability edge: pull
  ///   delivers the `Users` rows a project's data names, and `_globalFilters`
  ///   maps `User_Emails` by the same id, so a single forged `user_id` hands
  ///   over a stranger's name, address, *and* their prior address history.
  /// - **Attribution.** A telemetry record carries whose observation it was.
  ///   Stamping someone else's name on one is fabrication of the primary
  ///   scientific record, and it is worse than it first looks: once the row
  ///   names the victim the forger can no longer touch it, so there is no
  ///   later edit of theirs to point at.
  ///
  /// ### Insert: the replication seam
  ///
  /// A first publish legitimately carries rows authored by colleagues — that
  /// is what Phase 6's import produces and what task 10.9 uploads. Two ways a
  /// name is legitimate on the way in:
  ///
  /// 1. **It is the caller.** Always fine.
  /// 2. **This project already reaches them** — but only on a table whose
  ///    rows do not name an author. Someone the caller may already pull
  ///    discloses nothing by being named once more, which is why this clause
  ///    was correct as written; what it never answered is *attribution*. See
  ///    [SyncTable.vouchesForAForeignNameIn], which is where task 11.24
///    narrowed it and why.
  /// 3. **It is an audit name on such a table** — *who last edited this
  ///    shared vocabulary*, which clause 2 is simply the wrong question to
  ///    ask of. See [MutationRule.replicatesAForeignAuditName] (task 11.47)
  ///    for the argument and for what it deliberately leaves alone. This is
  ///    not the removed third clause below: that one asked about **server**
  ///    state and leaked the answer; this one asks about nothing at all.
  ///
  /// Anything else on insert is refused. A genuine collaborator's imported
  /// observations do not replicate from a relaying device at all: they are
  /// their author's to push. Nothing is lost meanwhile — `SyncHeldRowStore`
  /// holds the refused row on the device and explains it (task 10.28).
  ///
  /// ### The clause that used to be here, and why it had to go (task 10.29)
  ///
  /// Until Gate C's finding D-1 there was a third clause: *the server has
  /// never heard of them* — neither a `Users` row nor an `auth_accounts` row —
  /// permitted the insert, on the grounds that disclosure needs an identity to
  /// disclose and the caller is the only source either side has for an unknown
  /// one. The disclosure argument was sound. What it missed is that **asking
  /// the question answers it.** An ordinary registered user with no
  /// relationship to anyone could push an observation naming a `user_id` taken
  /// from a share payload or a CSV export and read a stranger's registration
  /// status straight off the outcome map: `unauthorized` if that person had an
  /// account here, `inserted` if they did not. §1 ranks researcher identity as
  /// an asset in its own right and §2.1 is organised around an actor for whom
  /// "which of these researchers is on this server" is the reconnaissance.
  ///
  /// The two branches had to converge, and they converge on the refusal:
  ///
  /// - Converging the other way is finding C-1 again — naming a registered
  ///   stranger is precisely the disclosure the invariant exists to stop.
  /// - Keeping the branch and hiding the difference is not available either:
  ///   the permissive branch *writes a row*, and no amount of care over what
  ///   is reported back conceals that.
  /// - And the disclosure argument was never the whole case. Naming someone is
  ///   also **attribution**, and stamping a stranger's name on a telemetry
  ///   record is fabrication of the primary scientific record whether or not
  ///   the server has heard of them. That harm alone decides which branch
  ///   survives.
  ///
  /// ### Update: no exemption at all, and the audit column must be the caller
  ///
  /// An **identity** column may only be left as it was found, or set to the
  /// caller. Replication introduces records; it never rewrites who an existing
  /// record is about.
  ///
  /// The **audit** column is stricter still, and task 11.24 made it so: it
  /// must name the caller. Leaving it as found is what every other clause
  /// here permits, and it is exactly how a false one gets written — task
  /// 11.18's "…then withdrawn by *name*" sentence reads this column, and an
  /// insert-only fix for N-1 would have left that sentence forgeable. See
  /// [DenialReason.unattributedChange].
  ///
  /// This is not a new judgement. `ProjectMerger._patchFor` already restates
  /// the audit column as the importing user on the client's own untrusted
  /// import path, with §4.19 rule 2's reason — *"a forgeable audit column is
  /// the worse trade"*. The same decision is now made where it can be
  /// enforced rather than only where it can be advised.
  ///
  /// ### Which tables clause 2 still applies to
  ///
  /// [SyncTable.vouchesForAForeignNameIn] is the answer, and it is derived
  /// from the declaration rather than listed: authorization state is excluded
  /// because replicating somebody's rights is privilege escalation, and any
  /// column naming who a record is *about* is excluded because a record that
  /// names an author must name the caller (task 11.24, made per-column by
  /// task 11.93).
  /// Drawing the first line here is what makes Gate B's hand-written
  /// `Project_Memberships` check unnecessary: an unsolicited membership row
  /// naming a stranger is refused because it names a stranger, not because of
  /// the table it is in.
  Future<AuthzVerdict?> _authorizeNaming({
    required SyncTable table,
    required MutationRule rule,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
  }) async {
    for (final column in table.userColumns) {
      final named = incoming[column];

      // **The update rules are asked before "does this row name me", and task
      // 11.93 had to move them there.**
      //
      // Both checks used to sit behind `if (named == userId) continue`, which
      // reads as "a row naming the caller is always fine". On an *update* of a
      // row that names somebody else, it is the opposite: writing your own
      // name over theirs is the reattribution this clause exists to refuse.
      // Nothing exploited it while every table naming an author also refused
      // the write itself — you cannot rewrite the author of a row you may not
      // touch. `Actual_Tag_Locations` is the first table where both are true
      // at once: **any contributor may write it, and it says who found the
      // collar**, so before this a colleague could take credit for finding
      // somebody else's lion by pushing one edited row. Caught by
      // `authorization_test.dart`'s "but cannot rewrite who found it", which
      // failed the first time it ran.
      if (existing != null) {
        // **Task 11.24, and this is the update half of N-1.** The audit
        // column is not payload the caller is carrying — it is a claim about
        // who performed *this* change, and this change is the caller's. A
        // push that reaches here has already been established to change the
        // stored row (`authorizeWrite` returns on a no-op before this runs),
        // so there is no such thing as an update that legitimately leaves
        // somebody else's name in it.
        if (column == auditUserColumn) {
          // An absent audit name names nobody and claims nothing; the column
          // is nullable precisely so a row need not carry one.
          if (named is! String || named.isEmpty) continue;
          if (named == userId) continue;
          return const AuthzVerdict.deny(DenialReason.unattributedChange);
        }
        // **An identity column may not change on an update, whoever asks and
        // whichever direction.** Compared including nulls: `user_id` on this
        // table is nullable (a point recorded before schema v11 records no
        // finder), so "absent names nobody" would otherwise let an edit
        // *erase* an attribution as easily as forge one. A client that legibly
        // holds the row round-trips the value it was given — including an
        // older build, which preserves columns it does not recognise verbatim.
        if (named == existing[column]) continue;
        return const AuthzVerdict.deny(DenialReason.reattribution);
      }

      // An absent value names nobody, so there is nothing here to disclose or
      // attribute on an insert.
      if (named is! String || named.isEmpty) continue;
      if (named == userId) continue;

      // **Task 11.93 made this per column rather than per rule.** The old
      // form asked `_replicableName(rule)`, which was the same answer for
      // every column of a table — safe only while every vouching table's one
      // user column was the audit one. `Actual_Tag_Locations` now names a
      // finder *and* keeps `anyUser`, so the two halves want opposite
      // answers. [SyncTable.vouchesForAForeignNameIn] draws the line where it
      // belongs: an identity column must name the caller whatever the write
      // rule permits.
      if (!table.vouchesForAForeignNameIn(column)) {
        return const AuthzVerdict.deny(DenialReason.namesForeignUser);
      }
      // **Task 11.47: clause 2 is not asked of an audit name.**
      //
      // `last_modified_by` says *who last edited this*, not *who this record
      // is about*, and clause 2's question — "does this project already reach
      // them?" — is the wrong question to ask of it. It is not a reachability
      // edge (`ProjectReachability.resolve` excludes it by construction) and
      // it is a foreign key on neither side, so nothing is delivered on the
      // strength of it and there is no disclosure to bound. Attribution is
      // bounded one line up, by [SyncTable.vouchesForAForeignNameIn], which
      // since task 11.93 refuses a foreign identity name on every table —
      // including the one that names a finder and still lets any contributor
      // write it.
      //
      // What it cost to ask it anyway: a `Tags` row a colleague last renamed
      // was refused, which made every bearing *of the caller's own* using
      // that tag a foreign global reference and refused those too — and since
      // the colleague was typically somebody who handed over an archive and
      // left, clause 2 could never come true and the rows were held forever.
      if (column == auditUserColumn && rule.replicatesAForeignAuditName) {
        continue;
      }
      // **Clause 2 itself, and as of task 11.47 no row reaches it.** Said
      // plainly rather than left for somebody to discover, because dead
      // authorization code that reads as live protection is its own hazard:
      // getting here needs a rule that vouches for a foreign name *and* a
      // column that is not the audit one, and every table satisfying the
      // first has [auditUserColumn] as its only user column, so the branch
      // above always takes it first. Task 11.93 did not change that: the
      // table it added an identity column to is refused one branch earlier,
      // because an identity column no longer vouches on any table.
      //
      // It is kept rather than deleted because it is the correct answer for a
      // shape that does not exist yet — a shared-vocabulary table that also
      // names somebody — and deleting it would mean rediscovering the rule
      // the next time one is added. `mutation_rules_test.dart`'s "every
      // relaxed table has no identity column for it to reach" is the tripwire
      // that fires when that day comes; until it does, nothing here is
      // load-bearing and no test should be written as though it were.
      if (await _projectAlreadyNames(named)) continue;
      // No third clause. Whether the server holds this identity is not asked,
      // because asking it is what leaked it — see the doc above.
      return const AuthzVerdict.deny(DenialReason.namesForeignUser);
    }
    return null;
  }

  /// Whether clause 2 — *this project already reaches them* — may vouch for a
  /// name on an insert into a table governed by [rule].
  ///
  /// **This is task 11.24's decision, and it is drawn on the rule rather than
  /// on a list of tables.** Two rules are excluded, for two different reasons
  /// that happen to land on the same answer:
  ///
  /// - **Authorization state** ([MutationRule.isAuthorizationState] —
  ///   `Projects`, `Project_Memberships`). Excluded since task 10.20:
  ///   replicating somebody's rights is not replication, it is privilege
  ///   escalation.
  /// - **Rows that name their own author** ([MutationRule.namesRowAuthor] —
  ///   `Observations`, `Observation_Exclusions`, `Non_Detections`, and
  ///   `Users`/`User_Emails`, which a different invariant already covers).
  ///   Excluded by task 11.24, finding N-1: **a record that names an author
  ///   must name the caller.**
  ///
  /// ### Why N-1 needed this, when clause 2 was correct as written
  ///
  /// Clause 2 answers *"would naming this person disclose anything?"* — and
  /// the answer is still no, which is why §4.17's reasoning was never wrong.
  /// But §4.17 names **two** harms in the same breath, disclosure and
  /// **attribution**, and says of the clause it removed that attribution
  /// "alone settles which branch survives". Clause 2 was never measured
  /// against attribution, because when it was written a project's reach was
  /// one person's own devices and it had no reachable instance at all.
  ///
  /// **What reopened it was not the invitation record §4.17 planned for.** It
  /// was `Project_Memberships.user_id` landing inside [ProjectReachability]
  /// (task 11.2), which puts every teammate into the vouching set as a side
  /// effect of being a teammate — a strictly wider statement than *"this
  /// person was invited here, so their rows may arrive"*, and nothing was
  /// written down when the wider one took effect. That silence is the root
  /// cause of the finding, and it is recorded here so the next widening of
  /// reachability has to walk past it.
  ///
  /// ### What it costs, measured rather than assumed
  ///
  /// Nothing at all in ordinary field work: every site in the app that writes
  /// one of these rows — recording a bearing, recording a non-detection,
  /// superseding, excluding, editing your own record — sets `user_id` to the
  /// signed-in user, and there is no "recorded by somebody else" control
  /// anywhere. What it refuses is one device **relaying** another person's
  /// records: a pasted share payload, a project archive imported and pushed,
  /// the first publish of a project that absorbed either, and a shared field
  /// device after a second person signs in. Those rows are held on the device,
  /// counted, and explained (task 10.28) — never dropped — which is the
  /// machinery §4.17 built precisely so this trade could be made.
  ///
  /// ### Why not a real provenance record instead
  ///
  /// The alternative on the table was to narrow clause 2 to *"is there a
  /// record showing this person authored data that arrived with this
  /// caller?"* — a different query, not a tightening of this one. It was
  /// rejected because it is a new provenance mechanism, and nine rounds of
  /// evidence on this project say new mechanisms are where findings come
  /// from. This reuses a trade §4.17 already accepted and a hold path task
  /// 10.28 already built.
  ///
  /// ### The shared tables are deliberately untouched
  ///
  /// Every [MutationRule.anyUser] table's only user column *is*
  /// [auditUserColumn] — they have no identity column at all — so leaving
  /// clause 2 in force for them is exactly "shared project vocabulary still
  /// replicates".
  ///
  /// **Task 11.47 went one step further for exactly those tables**, and the
  /// paragraph above is why it could: if their only user column is the audit
  /// column, then asking clause 2 of them is asking a question about
  /// reachability of a column that is not a reachability edge. They no longer
  /// have to satisfy it — see [MutationRule.replicatesAForeignAuditName]. The
  /// sentence below, about what clause 2 keeps working, is now the *smaller*
  /// half of the answer for these tables rather than the whole of it.
  ///
  /// ### What this paragraph used to claim, and what is actually true
  ///
  /// It used to end: *"That is what keeps a first publish working when the
  /// project's tags were created by a colleague, which would otherwise
  /// cascade: a held `Tags` row makes every observation referencing it a
  /// foreign global reference, and the refusal spreads from a name to the
  /// field data."*
  ///
  /// **Task 11.46 measured it, and the claim was false.** Clause 2 vouches for
  /// a name only when [_projectAlreadyNames] says the project already reaches
  /// that person, and on a *first* publish the project on this server reaches
  /// nobody at all — it is being created by the request that is asking. So a
  /// tag a colleague last edited is refused on a first publish, every time.
  /// The reproduction is in `test/integration/publish_and_join_test.dart`
  /// ("a first publish whose tag a colleague last edited…"): the `Tags` row
  /// and the bearing using it come back `unauthorized`. (The `Project_Tags`
  /// link that used to be refused alongside them stopped existing in task
  /// 11.219.)
  ///
  /// **The cascade the sentence warned about is real; the disaster it implied
  /// is not.** The refusal does spread from the tag to the field data —
  /// exactly as described — but [_authorizeReferences] refuses the bearing
  /// *cleanly*, as one more `unauthorized` row that `SyncHeldRowStore` holds
  /// and explains. The project itself still publishes. Task 11.43 predicted
  /// this ended in a foreign-key violation and a dead request, and along the
  /// tag path it does not, because the authorization check gets there first.
  ///
  /// It ended in a dead request **one table over**, where no equivalent check
  /// existed: a `Triangulation_Sessions` row a colleague last edited is
  /// refused here, and the caller's own bearing naming it through
  /// `Observations.(session_id, project_id)` was not. That is what
  /// [_authorizeReferences] now closes, and it is why the correction to this
  /// comment is worth more than the sentence it replaced.
  ///
  /// **What clause 2 does keep working** is every publish *after* the first,
  /// and every push into a project that already reaches the colleague — a
  /// teammate's tag edits replicating between devices once they are both on
  /// the project. That is a narrower claim than the one this paragraph made,
  /// and it is the one the code holds.
  ///
  /// **Third instance, and recorded as a class rather than a third anecdote.**
  /// The exclusion-reference comment (task 11.9) and the session-revocation
  /// comment (task 11.23) were the first two: a comment asserting a property
  /// that was adjacent to, but not the same as, the one the code actually
  /// held. Task 11.25 is turning the permissions matrix into a test for
  /// exactly this reason — a claim nothing executes drifts from the code
  /// silently — and this instance belongs to that write-up, not to a bug list.
  ///
  /// **The predicate itself lives in the shared package (task 11.43)** as
  /// [MutationRule.vouchesForAForeignName], narrowed per column by task 11.93
  /// as [SyncTable.vouchesForAForeignNameIn], which is what
  /// [_authorizeNaming] calls. The client builds its "may this device offer
  /// the row at all" filter from the same declarations: a client that offers
  /// rows the server is bound to deny produces a warning the user cannot act
  /// on, which is exactly what 11.43 was opened for, and one definition is
  /// what makes the two answers unable to disagree.

  /// **The email-claim invariant (task 10.55, Gate C finding I-4).**
  ///
  /// A row may not carry an identity email address the server has not
  /// authenticated for the `user_id` that row is about. Returns a denial, or
  /// null to fall through to the ownership rules.
  ///
  /// ### Why this is [_authorizeNaming] again, one column over
  ///
  /// The row-naming invariant makes `user_id` unforgeable. It does nothing
  /// about `email`, and on the client an email *is* an identity: the merger
  /// dedups incoming users onto local ones by normalized address and then
  /// rewrites `user_id`, `owner_user_id` and `last_modified_by` across the
  /// whole page (`ProjectMerger._buildUserRemap`, *"tier 1 always wins
  /// outright"*). So an attacker who pushes their **own** `Users` row — legal
  /// under every check above, it names nobody but themselves — carrying a
  /// colleague's address gets that colleague's local id substituted for their
  /// own on every row of the next pull. **That is finding C-1's harm exactly**
  /// — an attacker's observations attributed to a colleague, permanently —
  /// reached through the email column instead of the id column. Live against
  /// the build before this check, such a push answered `200 'updated'`.
  ///
  /// It is not reachable in Phase 10, because no cross-user membership exists
  /// and the row is therefore never delivered to a victim. **Phase 11's whole
  /// purpose is to open that door**, which is why this is a precondition on it
  /// rather than a Phase 11 task.
  ///
  /// ### The rule, and why it has exactly one permitting branch
  ///
  /// > The address on the row must equal the address the server holds in
  /// > `auth_accounts` for that `user_id` — the address whose mailbox somebody
  /// > proved control of to sign in (§4.2).
  ///
  /// Everything else refuses, and deliberately converges:
  ///
  /// - a different address than the account's — the forgery;
  /// - an address the server has never seen — unverifiable, and refusing it is
  ///   also what keeps this from becoming a registration oracle. "Is
  ///   `alice@example.org` registered here?" would be answerable off the
  ///   outcome map (`unauthorized` versus `inserted`) the moment *any* address
  ///   were accepted on the strength of nothing, which is finding D-1's shape
  ///   and the reason [_authorizeNaming]'s third clause had to go;
  /// - a `user_id` with no account at all — a replicated colleague imported
  ///   from a file. Their `Users` row is already refused by [_authorizeNaming]
  ///   unless the project reaches them, so this costs nothing today; what it
  ///   settles for Phase 11 is that an invitation record must carry a
  ///   *server-authenticated* address, not one the inviter typed.
  ///
  /// ### `User_Emails` is included, and that ends its replication
  ///
  /// A *prior*-address row is unverifiable by construction: the server mints a
  /// fresh account per address (`auth_accounts.email` is UNIQUE), so it has no
  /// record that this person once used that mailbox. Under the rule above the
  /// only `User_Emails` row that can land is one naming the caller's **current**
  /// authenticated address — which asserts nothing the `Users` row does not
  /// already say — so in practice a genuine address history stops replicating,
  /// and that is the intended answer rather than a casualty of one.
  ///
  /// The merger's prior-email tiers are the *same* remap tier 1 is — tier 2b
  /// matches an incoming user's claimed prior address against a local user's
  /// current one — so accepting an unverifiable address history here would
  /// leave I-4 open on the table next door: the vector [_mayReplicate] already
  /// refuses for *other* people and had no answer for the caller's own row.
  /// Address history still travels in exported backup files, where it is used
  /// and where no server is claiming to have checked it. **The server carries
  /// only identity it has authenticated.**
  ///
  /// Nothing is lost on the wire: a refused row is held on the device and
  /// explained (task 10.28), not dropped.
  ///
  /// ### Consequence worth stating plainly
  ///
  /// Changing your address in the profile screen while signed in now stops your
  /// own `Users` row syncing until you sign in with the new address. That is
  /// the correct shape — a change of identity should cost a proof of mailbox
  /// control, which is the one thing §4.2 knows how to demand — but it is a
  /// visible behaviour change, logged as discovered scope for Phase 11's
  /// account UI.
  Future<AuthzVerdict?> _authorizeEmailClaim({
    required SyncTable table,
    required Map<String, Object?> incoming,
  }) async {
    const denied = AuthzVerdict.deny(DenialReason.unauthenticatedEmail);
    if (table.emailColumns.isEmpty) return null;
    // Whose address it is. A table that declares an identity email without
    // exactly one subject column cannot be checked, so it is refused rather
    // than waved through — `assertEveryEmailColumnHasASubject` turns that into
    // a test failure before it can ever be a refusal in the field.
    final subjects = table.identityUserColumns;
    if (subjects.length != 1) return denied;
    final named = incoming[subjects.single];
    if (named is! String || named.isEmpty) return denied;

    for (final column in table.emailColumns) {
      final claimed = incoming[column];
      // Absent or wrongly typed is `RowValidator`'s refusal to make, not
      // authorization's — it already answers `invalid` for both, before this
      // runs, and duplicating the judgement here would only let the two
      // disagree about which refusal a caller sees.
      if (claimed is! String) continue;
      final authenticated = await _authenticatedEmail(named);
      if (authenticated == null) return denied;
      if (normalizeEmail(claimed) != normalizeEmail(authenticated)) {
        return denied;
      }
    }
    return null;
  }

  /// The address [candidateUserId] proved control of at sign-in, or null if the
  /// server holds no account for them.
  ///
  /// Memoised per push for the same reason [_reachable] is: a push is judged
  /// against one consistent pre-push snapshot, and an account's address cannot
  /// change under it — a new address is a new account with a new `user_id`
  /// (`auth_accounts.email` is UNIQUE), never an update to this one.
  Future<String?> _authenticatedEmail(String candidateUserId) async {
    final cached = _accountEmails[candidateUserId];
    if (cached != null || _accountEmails.containsKey(candidateUserId)) {
      return cached;
    }
    final result = await session.execute(
      r'SELECT email FROM auth_accounts WHERE user_id = $1',
      parameters: [candidateUserId],
    );
    return _accountEmails[candidateUserId] = result.isEmpty
        ? null
        : result.first.first as String?;
  }

  /// Whether [candidateUserId] is already named by a row in [projectId] — and
  /// so already deliverable to this caller by pull.
  ///
  /// Asks [ProjectReachability], the same computation pull uses to decide
  /// which global rows a project may see. A write check and a read filter that
  /// disagreed about what a project reaches would leave a hole shaped exactly
  /// like the one task 10.10 closed.
  ///
  /// **Only a project the caller can actually reach may vouch (task 10.21).**
  /// The clause exists because naming someone the caller could already pull
  /// discloses nothing — an argument that evaporates if they cannot pull the
  /// project. It was also observable: a push of global rows names a project
  /// without belonging to it, and until this check that project's membership
  /// answered back through the outcome map, turning `inserted` versus
  /// `unauthorized` into a test for whether a project exists and who is in it.
  Future<bool> _projectAlreadyNames(String candidateUserId) async {
    if (!access.permitsSync) return false;
    return (await _projectReach()).users.contains(candidateUserId);
  }

  /// What [projectId] reaches, resolved once per push.
  ///
  /// Empty for a caller who cannot sync the project: a project they have no
  /// relationship to vouches for nothing (task 10.21), and computing its real
  /// closure would only be a way for that fact to leak.
  Future<ProjectReachability> _projectReach() async =>
      _reachable ??= access.permitsSync
      ? await ProjectReachability.resolve(session, projectId: projectId)
      : const ProjectReachability(users: {});

  /// Whether the caller may be shown [row] — used to gate the *losing* server
  /// copy returned after a conflict.
  ///
  /// Without this, push doubles as a read primitive: a caller who guesses a
  /// primary key can push a deliberately stale row, lose last-write-wins, and
  /// receive the server's full copy back in the conflict report. For
  /// project-scoped rows that is harmless (they already passed the project
  /// check), but a global `Users` or `User_Emails` row would disclose another
  /// person's name and email history to anyone who knows their id.
  Future<bool> canDisclose({
    required SyncTable table,
    required Map<String, Object?> row,
  }) async {
    final scope = table.projectScopeColumn;
    if (scope != null) return row[scope] == projectId;
    final rule = tableMutationRules[table.name];
    if (rule == null) return false;
    // A global row is disclosable only to someone the rule would let write it
    // — its author. `anyUser` globals (Tags) are shared vocabulary and carry
    // nothing personal, so the rule permitting everyone is the right answer
    // here too.
    //
    // No global table carries an ownership rule — `Projects` and
    // `Project_Memberships` are both project-scoped, so they returned above.
    // Fail closed rather than ask [MutationRule.permits] a question it now
    // refuses to answer, so that a future global table with an ownership rule
    // is a withheld row and a failing test, not a thrown exception mid-pull.
    if (rule.resolvesProjectOwners) return false;
    return rule.permits(userId, _governingValue(rule, row));
  }

  /// Whether the caller may be told that [row] is already on the server — the
  /// weaker of the two disclosure questions, and the one a no-op push asks.
  ///
  /// [canDisclose] governs handing back a row's *contents*; this governs
  /// admitting it exists. The looser bar is reachability, because a row this
  /// project reaches is one an ordinary pull would hand over in full anyway,
  /// so refusing to admit it exists would protect nothing while breaking the
  /// re-offers an ordinary client legitimately makes: a row whose local copy
  /// the server has not confirmed goes back up
  /// (`SyncEngine._collectChangedRows`), so a colleague's `Users` row inside
  /// this project's reach arrives as a no-op after a dropped connection, a
  /// re-publish, or a forgotten receipt — not as a probe. Task 10.33 made those
  /// re-offers rarer than the old `>=` watermark's did, which narrows how much
  /// traffic this permits without changing the argument for permitting it.
  ///
  /// Asking [ProjectReachability] rather than inventing a second rule keeps
  /// the write check and the read filter answering with one voice, so this
  /// can never admit something a pull would have withheld.
  Future<bool> _mayKnowRowExists({
    required SyncTable table,
    required Map<String, Object?> row,
  }) async {
    if (await canDisclose(table: table, row: row)) return true;
    // Only the global tables get this far — a project-scoped row has already
    // been established to live in this project by the scope checks, and
    // [canDisclose] answers on exactly that.
    //
    // **The column and the reachable set come from the table's declared
    // [SyncTable.globalScope] (task 11.32).** This was `isTag ? 'tag_id' :
    // 'user_id'` — a hand-maintained mirror of a hand-maintained map in
    // `SyncService`, and its own comment said so. Any global table that was
    // not `Tags` silently read `user_id`, found nothing, and answered "you may
    // not know" for a reason that had nothing to do with reachability. Reading
    // the declaration instead means pull and this check cannot disagree, which
    // is the whole property: this answers "would a pull have delivered it".
    final scope = table.globalScope;
    if (table.projectScopeColumn != null || scope == null) return false;
    final named = row[scope.column];
    if (named is! String || named.isEmpty) return false;
    final reach = await _projectReach();
    return switch (scope.reach) {
      GlobalReachSet.users => reach.users.contains(named),
    };
  }

  /// The value the rule compares against, for the rules that name a single
  /// user on the row itself ([MutationRule.author]). The ownership rules go
  /// through [_projectOwners] instead — see [authorizeWrite].
  String? _governingValue(MutationRule rule, Map<String, Object?> row) {
    final column = rule.governingColumn;
    return column == null ? null : row[column] as String?;
  }

  /// The current owners of [projectId], or null if this server holds no such
  /// project (task 11.1).
  ///
  /// Null and empty are different answers — see
  /// [MutationRule.permittedByOwners]. Null is the first-publish case: every
  /// row of a batch is authorized before any of them is written, so a publish's
  /// `Project_Memberships` row is judged while the `Projects` row establishing
  /// the project is still only a pending decision. That case was already
  /// permitted before 11.1, by the same reasoning and via the same null.
  ///
  /// Resolved by query rather than inferred from [access], for the reason task
  /// 10.10 gave when this was a single `owner_user_id` lookup: inferring would
  /// mean returning something falsy for "the caller is not an owner", and a
  /// falsy answer reads as *permitted*, so a member pushing a
  /// `Project_Memberships` row would have been allowed to grant themselves any
  /// role they liked. Asking for the real owners makes the comparison say what
  /// it means.
  Future<Set<String>?> _projectOwners(String projectId) async =>
      (await _ownership(projectId)).owners;

  /// The project's owner set and the primary keys of the open owner membership
  /// rows it came from, read once per push.
  ///
  /// Memoized per authorizer instance, which is per push. A push authorizes
  /// every row before writing any of them, so this cannot change mid-batch —
  /// reading it once is both cheaper and more consistent than re-reading it
  /// per row.
  Future<_ProjectOwnership> _ownership(String projectId) async {
    final cached = _ownershipByProject[projectId];
    if (cached != null) return cached;
    final project = await session.execute(
      'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1',
      parameters: [projectId],
    );
    var resolved = const _ProjectOwnership(
      owners: null,
      ownerRowKeys: {},
      openMemberUserIds: {},
    );
    if (project.isNotEmpty) {
      // Every membership row of the project, ended and tombstoned ones
      // included: [resolveProjectOwners] does that filtering, so this side
      // cannot drift from the client's by forgetting a clause.
      final memberships = await session.execute(
        'SELECT membership_id, user_id, role, end_date, deleted_at '
        'FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1',
        parameters: [projectId],
      );
      final rows = memberships.map((row) => row.toColumnMap()).toList();
      resolved = _ProjectOwnership(
        owners: resolveProjectOwners(
          membershipRows: rows,
          creatorUserId: project.first.first as String?,
        ),
        ownerRowKeys: {
          for (final row in rows)
            if (isOpenOwnerMembership(row)) row['membership_id'] as String,
        },
        openMemberUserIds: {
          for (final row in rows)
            if (row['end_date'] == null && row['deleted_at'] == null)
              if (row['user_id'] case final String userId) userId,
        },
      );
    }
    _ownershipByProject[projectId] = resolved;
    return resolved;
  }

  final Map<String, _ProjectOwnership> _ownershipByProject = {};

  /// (project, user) pairs this push has already been cleared to open a
  /// membership for, keyed `project_id/user_id`. See
  /// [_authorizeGrantingInsert]'s third condition.
  final Set<String> _membershipsGrantedThisPush = {};

  /// Membership rows this push has already been cleared to strip of ownership,
  /// keyed `project_id/membership_id`.
  ///
  /// A push is authorized row by row before any row is written, so without
  /// this, two rows each ending a different owner membership would each see
  /// the other still open and both be allowed — leaving zero owners, which is
  /// exactly what [_authorizeOwnerRemoval] exists to prevent. Same shape and
  /// same reason as [_noteEstablishedTag]'s within-batch bookkeeping.
  final Set<String> _ownershipsRemovedThisPush = {};

  /// **The last-owner guard (task 11.1).**
  ///
  /// A project must never reach zero open owner memberships. Nobody could then
  /// manage its membership, change its settings, or hand it on — and there is
  /// no privileged operator to appeal to, because a TriTrack server is a
  /// laptop in a lab. This is not an exotic edge case: someone leaving a lab,
  /// closing out their last stint on the way, is the ordinary path to it.
  ///
  /// Returns a denial when [incoming] would take the project's last open owner
  /// membership out of the owner set — by setting `end_date`, by tombstoning
  /// it, or by demoting its `role` — and null otherwise.
  ///
  /// Enforced here as well as on the client because the client cannot see the
  /// case that needs a server: two devices, each ending a *different* owner
  /// membership while offline. Each is legitimate alone; together they leave
  /// nobody. The second one to arrive is refused here.
  Future<AuthzVerdict?> _authorizeOwnerRemoval({
    required SyncTable table,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
    required Set<String>? owners,
  }) async {
    if (table.name != Tables.projectMemberships) return null;
    // An insert cannot remove an owner, and a row that is not currently an
    // open owner membership has no ownership to take away.
    if (existing == null || !isOpenOwnerMembership(existing)) return null;
    if (isOpenOwnerMembership(incoming)) return null;

    final projectId = existing['project_id'];
    final membershipId = existing['membership_id'];
    if (projectId is! String || membershipId is! String) return null;
    final key = '$projectId/$membershipId';

    final ownership = await _ownership(projectId);
    final remaining = ownership.ownerRowKeys
        .where((id) => !_ownershipsRemovedThisPush.contains('$projectId/$id'))
        .where((id) => id != membershipId)
        .length;
    if (remaining == 0) {
      return const AuthzVerdict.deny(DenialReason.lastOwnerRemoval);
    }
    _ownershipsRemovedThisPush.add(key);
    return null;
  }

  /// **Who may create a tag, and who may change one (task 11.11, rewritten
  /// by 11.219).**
  ///
  /// Returns a denial when the caller may not do what [existing] and
  /// [changesStoredRow] say they are doing to a `Tags` or `Tag_Versions`
  /// row; null in every other case.
  ///
  /// ## What this replaced, and why it is a tenth of the size
  ///
  /// It was `_authorizeTagReferences`: 161 lines under about 200 lines of
  /// argument, plus `_tagIsClaimedElsewhere`, `_tagRowExists`,
  /// `_noteEstablishedTag` and an `_establishedThisPush` set. All of that
  /// existed because **`Tags` was global** — no `project_id` — and governed
  /// by [MutationRule.anyUser], which is the one combination where "anyUser"
  /// meant *no authorization at all*: neither the project checks (there was
  /// no scope column) nor the rule (it permits everyone) applied, so any
  /// authenticated caller could overwrite or tombstone any tag on the
  /// server, and could disclose one by linking it into a project of their
  /// own. Three kinds of row carried a `tag_id` and each needed a different
  /// answer; absent, orphaned and claimed-by-a-stranger had to be one
  /// indistinguishable refusal (§4.13, finding D-1); and a tag created and
  /// first used in one push needed a within-batch record of what had been
  /// established, because every row was judged against one pre-push
  /// snapshot.
  ///
  /// **Task 11.219 deleted the question rather than the answer.** A tag
  /// belongs to exactly one project, so `Tags` and `Tag_Versions` are
  /// ordinary project-scoped tables: the scope check at the top of [_decide]
  /// refuses a row claiming another project, [_authorizeRole] refuses a
  /// viewer, and [_authorizeReferences] refuses a bearing whose tag will not
  /// be there — the same same-project composite check
  /// `Observations.(session_id, project_id)` has had since task 11.46. There
  /// is no reachability to compute, nothing to vouch for, and no oracle to
  /// close, because there is no global row to ask about.
  ///
  /// ## What survives, because it was never about globality
  ///
  /// The create/edit asymmetry, which is the only part of that 161 lines
  /// that was about the product:
  ///
  /// - **A contributor may create a tag.** Restricting creation to owners
  ///   looks like it would prevent duplicates and does not — two owners,
  ///   each offline, collide exactly as an owner and a contributor would —
  ///   while a field tech on a transect with no signal who cannot create a
  ///   tag **cannot record the observation at all**. A `viewer` creates
  ///   nothing, per 11.3's gradient with no exception.
  /// - **Only an owner may change an existing one.** A tag is referenced by
  ///   every observation of that collar, so renaming it, moving its
  ///   frequency, retiring it or removing it from the project rewrites what
  ///   those already-recorded rows mean, and they cannot be re-recorded.
  ///   Additive and recoverable on one side; retroactive and not on the
  ///   other.
  ///
  /// **Both halves apply to `Tag_Versions` too, and land differently.**
  /// Appending a version is project-write-level: it is additive and
  /// forward-only, it changes what records made *after* it read and never
  /// what an already-recorded bearing reads, and requiring an owner would
  /// refuse a contributor's own new tag's first version — *intermittently*,
  /// since a batch limit can split the `Tags` row and its first version
  /// across two pushes, leaving the second permanently held. Rewriting a
  /// version is the **correction** path and is the retroactive act, so it
  /// takes the owner rung like the tag itself.
  ///
  /// ## `absent` permits, as everywhere else
  ///
  /// A first publish uploads a project's tags before the `Projects` row that
  /// would give the caller any role at all. Only an **explicit** viewer is
  /// refused; refusing `absent` would break publish outright.
  AuthzVerdict? _authorizeTagLifecycle({
    required SyncTable table,
    required Map<String, Object?>? existing,
    required bool changesStoredRow,
  }) {
    if (table.name != Tables.tags && table.name != Tables.tagVersions) {
      return null;
    }
    if (existing == null) {
      if (access == ProjectAccess.viewer) {
        return const AuthzVerdict.deny(DenialReason.createTagForbidden);
      }
      return null;
    }
    // A push that changes nothing needs no write permission; the question a
    // no-op asks is [_mayKnowRowExists]'s, not this one.
    if (!changesStoredRow) return null;
    if (access == ProjectAccess.owner || access == ProjectAccess.absent) {
      return null;
    }
    return const AuthzVerdict.deny(DenialReason.changeTagRequiresOwner);
  }

  /// **Who may delete an animal (task 11.255).**
  ///
  /// Returns a denial when [incoming] tombstones a live `Individuals` row and
  /// the caller is not an owner of that project; null in every other case,
  /// including every other write `Individuals` accepts.
  ///
  /// ## Why this is one column, not the whole table
  ///
  /// [_authorizeTagLifecycle] holds *every* change to a stored `Tags` row to
  /// the owner rung, because a tag's own identity is retroactive — renaming
  /// or retuning it rewrites what every bearing already recorded against it
  /// means. An animal is not that: `PERMISSIONS_MATRIX.md`'s IN2 row is
  /// explicit that editing one changes what no bearing means, because
  /// bearings attach to the collar and the animal is only derived through it.
  /// So this asks a narrower question than [_authorizeTagLifecycle] does —
  /// not "is this table's rule table entry `anyUser`", but "does this
  /// particular write set `deleted_at`" — and a `MutationRule` cannot express
  /// that split (one rule per table, no delete/update distinction), which is
  /// why it is a branch here rather than a second rule.
  ///
  /// ## `existing['deleted_at']` decides "live", not [incoming]'s
  ///
  /// Read from the **stored** row, exactly as [_authorizeExclusionKind] reads
  /// `existing['kind']`: whether a write tombstones a row is a property of
  /// what the row was, never of what the caller claims it is becoming. A row
  /// already tombstoned has nothing left for this to refuse — clearing
  /// `deleted_at` on an `Individuals` row is not a path the app or the sync
  /// protocol offers (there is no `restore` on `IndividualRepository`), and
  /// refusing it here would be inventing a rung for a write nobody can make.
  ///
  /// ## `absent`/unresolvable permits, as everywhere else
  ///
  /// A first publish uploads a project's animals before the `Projects` row
  /// that would give the caller a role at all; refusing `absent` would break
  /// that publish outright, the same reasoning [_authorizeTagLifecycle]
  /// gives.
  AuthzVerdict? _authorizeIndividualLifecycle({
    required SyncTable table,
    required Map<String, Object?> incoming,
    required Map<String, Object?>? existing,
    required bool changesStoredRow,
  }) {
    if (table.name != Tables.individuals) {
      return null;
    }
    if (existing == null || !changesStoredRow) return null;
    final wasLive = existing['deleted_at'] == null;
    if (!wasLive || incoming['deleted_at'] == null) return null;
    if (access == ProjectAccess.owner || access == ProjectAccess.absent) {
      return null;
    }
    return const AuthzVerdict.deny(DenialReason.deleteIndividualRequiresOwner);
  }

  /// **Task 11.46. Whether every row [incoming] points at will exist.**
  ///
  /// Returns [DenialReason.danglingReference] when one will not, or null.
  ///
  /// ## What this is for, and why it is not a permission check
  ///
  /// The schema's foreign keys are `DEFERRABLE INITIALLY DEFERRED` (task 10.5),
  /// which means a reference to a row that is not there does **not** fail at
  /// the INSERT that made it. It fails at COMMIT — after `applyPush` has
  /// decided and reported an outcome for every row in the batch, and outside
  /// the reach of anything that could turn it into one. The request dies whole:
  /// `errorHandlerMiddleware` catches the throw and answers `internal_error`,
  /// every row in the push is rolled back including the ones that were fine,
  /// and the person on the other end gets an error that names nothing and
  /// suggests nothing.
  ///
  /// That is reachable today, and not hypothetically. A project built from a
  /// colleague's archive carries rows a colleague last touched; those rows are
  /// refused by [_authorizeNaming] (correctly — see
  /// [SyncTable.vouchesForAForeignNameIn]); and any
  /// row of the caller's *own* that points at one of them is then a reference
  /// to something the server does not hold. `Triangulation_Sessions` is the
  /// reproduced instance — a session a colleague last edited, and the owner's
  /// own bearing naming it through
  /// `Observations.(session_id, project_id)`.
  ///
  /// **Refusing the one row is strictly better than losing the request.** The
  /// row was never going to land — its referent did not — and a refusal is a
  /// thing this system already knows how to carry: `SyncHeldRowStore` keeps it
  /// on the device, counts it, and explains it (task 10.28). The rest of the
  /// push lands instead of being rolled back with it.
  ///
  /// ## Why this cannot become an existence oracle
  ///
  /// It answers "is there a row here" against server state, which is the shape
  /// [RowAuthorizer]'s class doc forbids branching on. It is safe **because of
  /// where it runs**: [authorizeWrite] calls it only after [_decide] has
  /// allowed the row, so a caller can only ever reach it with references they
  /// were already entitled to make. Every foreign key in the schema is already
  /// narrowed by an earlier check before this one is asked:
  ///
  /// - **`user_id` / `owner_user_id` → `Users`.** [_authorizeNaming] refuses
  ///   any name but the caller's on these tables, so the only identity that
  ///   reaches here is one the caller *is*.
  /// - **`(tag_id, project_id)` → `Tags`.** Composite with the project id
  ///   since task 11.219, and the project is the caller's own by the scope
  ///   check, so what shows through is whether a tag exists **inside a
  ///   project the caller can already read every row of** — which is not a
  ///   disclosure. It used to be a single-column reference into a global
  ///   table, and needed `_authorizeTagReferences` to narrow it first.
  /// - **`project_id` → `Projects`.** The scope check at the top of [_decide]
  ///   has already required the row to claim the project in the envelope, and
  ///   the route's project gate gave the caller a relationship to it.
  /// - **`(session_id, project_id)` → `Triangulation_Sessions`.** Composite
  ///   with the project id, and the project is the caller's own by the line
  ///   above, so what shows through is whether a session exists **inside a
  ///   project the caller can already pull in full**.
  ///
  /// That reasoning is per-key and the key list is derived, so a foreign key
  /// added later inherits the check but *not* the argument. It is guarded
  /// rather than trusted: `test/authz/reference_integrity_test.dart` asserts
  /// [foreignKeys] matches the constraints the built database actually has, so
  /// a new one cannot arrive here unnoticed.
  ///
  /// ## MATCH SIMPLE
  ///
  /// Postgres treats a composite key with any NULL component as satisfied, and
  /// `Observations.session_id` is nullable precisely so a session-less bearing
  /// is unconstrained. Skipping on any null component is that rule, not an
  /// optimisation — checking it instead would refuse rows the database accepts.
  Future<AuthzVerdict?> _authorizeReferences({
    required SyncTable table,
    required Map<String, Object?> incoming,
  }) async {
    for (final fk in foreignKeys) {
      final (from, columns, refTable, refColumns) = fk;
      if (from != table.name) continue;
      final values = [for (final column in columns) incoming[column]];
      if (values.any((value) => value == null)) continue;
      if (_writtenThisPush.contains(
        _referenceKey(refTable, refColumns, values),
      )) {
        continue;
      }
      if (await _referentExists(refTable, refColumns, values)) continue;
      return const AuthzVerdict.deny(DenialReason.danglingReference);
    }
    return null;
  }

  /// The referenced keys this push has already been allowed to write.
  ///
  /// The same necessity the retired `_establishedThisPush` existed for,
  /// generalised — and since task 11.219 it is the only one left, because a
  /// tag no longer needs vouching for:
  /// `applyPush` decides every row before it writes any of them, so at the
  /// moment a bearing is judged, the session it names has been *allowed* but
  /// not yet inserted — a database lookup would say it is not there. Rows are
  /// judged in `syncTables` order, which is foreign-key-safe order, so a
  /// referent is always decided before the rows pointing at it.
  ///
  /// That ordering is asserted rather than assumed —
  /// `test/authz/reference_integrity_test.dart` fails if a table in
  /// [syncTables] references one declared after it.
  final Set<String> _writtenThisPush = {};

  /// Records the referenced keys [incoming] will satisfy once written.
  ///
  /// Derived from [foreignKeys] rather than from a list of "tables things
  /// point at": a table nothing references contributes nothing here, and one
  /// that gains a reference later is covered without an edit.
  void _noteWritten(SyncTable table, Map<String, Object?> incoming) {
    for (final fk in foreignKeys) {
      final (_, _, refTable, refColumns) = fk;
      if (refTable != table.name) continue;
      final values = [for (final column in refColumns) incoming[column]];
      if (values.any((value) => value == null)) continue;
      _writtenThisPush.add(_referenceKey(refTable, refColumns, values));
    }
  }

  /// A stable key for one referenced tuple. The separator is a NUL, which no
  /// id or column name in this schema contains, so two different tuples cannot
  /// collide by concatenation.
  static String _referenceKey(
    String refTable,
    List<String> refColumns,
    List<Object?> values,
  ) => '$refTable\u0000${refColumns.join('\u0000')}'
      '\u0000${values.join('\u0000')}';

  Future<bool> _referentExists(
    String refTable,
    List<String> refColumns,
    List<Object?> values,
  ) async {
    // Identifiers come from the const [foreignKeys] declaration, never from a
    // request; every value is bound.
    final predicate = [
      for (var i = 0; i < refColumns.length; i++) '${refColumns[i]} = \$${i + 1}',
    ].join(' AND ');
    final result = await session.execute(
      'SELECT EXISTS(SELECT 1 FROM ${quoted(refTable)} WHERE $predicate)',
      parameters: values,
    );
    return result.first.first! as bool;
  }

  /// Whether the caller may introduce a row authored by someone else.
  ///
  /// Requires write access to the project for project-scoped rows. Global
  /// rows (`Users`, `User_Emails`, `Tags`) have no project to check: inserting
  /// one records a person or tag the server has never seen, which is what an
  /// FK-complete replication of imported data requires, and which grants the
  /// caller nothing — sign-in identity is resolved from the server's own
  /// `auth_accounts` table, never from these.
  /// [ProjectAccess.absent] counts, because that is the publish case: on a
  /// project's very first push nobody owns it on the server yet, and the
  /// `Projects` row establishing ownership is arriving in the same batch. That
  /// is not a gap — the `Projects` row is itself subject to the `owner` rule,
  /// so this path cannot create a project for someone else, and the schema's
  /// foreign keys refuse a batch of project-scoped rows with no `Projects` row
  /// behind them.
  bool _mayReplicate(SyncTable table) {
    // **Never `User_Emails`.** It records a person's address *history*, and the
    // client merger's identity dedup treats a matching prior email as proof
    // that two user ids are the same person (`ProjectMerger`'s prior-email
    // fallback). So inserting an address row for someone else is not
    // replication — it is a way to make a victim's rows get re-attributed to
    // an attacker-controlled identity on the next merge, which is the exact
    // forgery this class claims to prevent, reached through an adjacent table.
    // The cost of refusing is a weaker dedup fallback for imported users, not
    // a broken sync.
    if (table.name == Tables.userEmails) return false;
    if (table.projectScopeColumn == null) return true;
    return access.permitsSync;
  }
}
