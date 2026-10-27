import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../db/data_arrival.dart';
import '../repositories/project_role_lookup.dart';
import '../repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'merge_report.dart';
import 'restored_project_arrival.dart';
import 'schema_migrator.dart';
import 'sync_conflicts.dart';
import 'unknown_columns.dart';

/// How an incoming backup's rows are reconciled with rows already present.
enum MergeStrategy {
  /// Per-row last-write-wins on the sync clock (revision → updated_at →
  /// device). The safe default for combining two field devices' data.
  lastWriteWins,

  /// The incoming copy always wins on conflict ("overwrite" / restore intent).
  /// Still deduped, validated, and transactional; still additive — it never
  /// hard-deletes local rows that the backup happens not to contain.
  preferIncoming,
}

/// Where the rows being merged came from, and therefore which of security
/// model **§4.19**'s clauses apply to them.
///
/// **This is one knob because the alternative already failed.** Until task
/// 10.73 the merger took an [IdentityTrust] parameter and nothing else, and
/// every *other* trust decision — whether the clock is bounded, whether
/// authorship may come from the payload, whether an overwrite needs consent,
/// whether validation may be switched off — was either absent or a separate
/// argument a caller could set independently. Finding K-1 is what that cost:
/// the file-import call site got the loosest setting of each, on the path that
/// reaches every column of every table. §4.19 clause 1's lesson was *two lists
/// that were never the same list and had no reason to stay in step*; two
/// parameters that must always agree are the same defect with a different
/// shape. There is now one input, and everything derives from it.
enum MergeOrigin {
  /// A `.zip` the user picked, a file from a linked cloud folder, or anything
  /// else nobody authenticated.
  ///
  /// **Deliberate is not trusted, and the product's own copy is why.** §4.19.1
  /// originally deferred this path as *"a deliberate whole-project act on a
  /// file the user chose"* — while `data_export_screen.dart` tells the user the
  /// same archive "can be shared via WhatsApp, email, or cloud storage". A
  /// colleague who has legitimately received a project backup holds every
  /// `project_id`, `observation_id` and `user_id` needed to target rows
  /// precisely and can hand back an edited file as "here's the merged
  /// version"; anyone with write access to the linked cloud folder can drop a
  /// file with the expected name, which the user later picks believing it is
  /// their own. Choosing a file says where the bytes came from, not who wrote
  /// them.
  untrustedArchive,

  /// A page pulled from the server this device authenticated to.
  ///
  /// Bounded elsewhere and differently on purpose: rows passed §4.17/§4.18
  /// server-side before delivery, the clock is *classified* rather than
  /// refused (`ClockSkew.classify` — the server must not rewrite history it
  /// did not author), and overwrites are already captured to `Sync_Conflicts`
  /// by task 10.12's sync-side record, so §4.19 rule 4's consent gate would be
  /// a prompt on every background sync with nothing new to show.
  authenticatedServer;

  /// Whether an incoming payload's email addresses may be believed as
  /// *identity* — see [IdentityTrust], which is the whole of that decision and
  /// is now derived here rather than passed alongside.
  IdentityTrust get identityTrust => switch (this) {
        MergeOrigin.untrustedArchive => IdentityTrust.emailMatchesPerson,
        MergeOrigin.authenticatedServer => IdentityTrust.serverAssignsIdentity,
      };

  /// Whether §4.19's clauses 2, 3 and 4 — no authorship from the payload, a
  /// bounded merge clock refused rather than clamped, and no unseen
  /// destruction — apply, and whether clause 5's validation is an invariant
  /// rather than a parameter.
  bool get isUntrusted => this == MergeOrigin.untrustedArchive;
}

/// Whether an incoming payload's email addresses may be believed as *identity*.
///
/// **The question task 10.55 had to answer out loud.** The merger's dedup
/// treats a matching email as proof that two `user_id`s are the same person and
/// then rewrites `user_id`, `owner_user_id` and `last_modified_by` across the
/// whole payload ([ProjectMerger._buildUserRemap], *"tier 1 always wins
/// outright"*). Finding I-4 showed a server would happily deliver a forged
/// address; the server now refuses one (`RowAuthorizer._authorizeEmailClaim`).
/// The answer to *"should the client keep trusting it anyway?"* is **no, not on
/// the sync path** — and the reason is not distrust of our own server, it is
/// that on that path the heuristic buys nothing:
///
/// - **A backup file has no authority at all.** Nobody assigned its ids; dedup
///   by email is the only thing standing between "merged my phone's export" and
///   two of me. The user chose the file, the import is a deliberate one-off,
///   and the [MergeReport] tells them how many users were deduped. The
///   heuristic is load-bearing and stays.
/// - **A synced server has already assigned the ids.** `ServerIdentityAdopter`
///   exists precisely because *"the server is authoritative for the `user_id`
///   behind an email"*, and a device adopts that id at sign-in behind proof of
///   mailbox control. By the time a pulled page arrives, the same person has
///   the same id on both sides — so tier 1 has nothing left to do, and running
///   it anyway leaves a rewrite primitive keyed on an unauthenticated string,
///   on a path that is continuous, automatic and unattended. One bad row, or
///   one server that is not ours, and every observation on the page changes
///   whose it is.
///
/// Both halves of that are why this is a parameter rather than a deletion: the
/// rule is not wrong, it is right for exactly one of the two sources.
enum IdentityTrust {
  /// A payload nobody authenticated — a restored or imported backup file. Dedup
  /// people by normalized email, current and prior (Phases 6 and 7).
  emailMatchesPerson,

  /// A payload from an authenticated server, which assigned the `user_id`s
  /// itself. No email-based remap of any tier; ids arrive as authoritative.
  serverAssignsIdentity,
}

/// Merges a decoded [ProjectBackup] into the live database — the Phase 6
/// import/merge core.
///
/// Guarantees:
/// - **All-or-nothing.** Every write happens inside one transaction; any error
///   rolls the whole thing back, so a bad import can never leave a
///   half-merged project. (Archive corruption is caught earlier, in
///   [BackupArchive.decode], before this is ever reached.)
/// - **No resurrection.** Tombstones travel in the backup and merge by the same
///   last-write-wins rule ([MergeResolver]); a stale delete can't undo a newer
///   live edit and vice-versa.
/// - **Cross-device identity.** The same person has a different `user_id` per
///   device, so incoming users are deduped by normalized email onto the local
///   user and every foreign key that pointed at the incoming id is rewritten
///   ([UserRepository.normalizeEmail] is the shared anchor). **This applies to
///   backup files only** — a payload pulled from a server arrives with ids that
///   server already assigned, and its addresses are not treated as identity.
///   See [IdentityTrust], which is the whole of that decision.
/// - **Forward-only schema.** An older backup is migrated up to the current
///   schema first ([SchemaMigrator]); a newer one is refused.
///
/// ## What an untrusted archive may do to rows this device already holds
///
/// Security model **§4.19** answers *"when data from an untrusted party is
/// parsed into a row this device already holds, what is it allowed to do to
/// it?"* It was written against one pasted `TT1:` string reaching one
/// `Observations` row (finding J-1). Finding **K-1** is the same defect here,
/// on a path that reaches every column of all eleven synced tables — and this
/// path had none of the five clauses. Reproduced under the *default* strategy
/// with validation on: an observation moved to (0,0), its `user_id` reassigned
/// to the attacker, `last_modified_by` forged to name the victim, declination
/// and WMM model version erased, a second observation tombstoned, the project's
/// owner reassigned, an attacker `Users` row planted — reported as
/// *"Inserted: 1, Updated: 3"* with **zero** `Sync_Conflicts` rows behind it.
///
/// The clauses, as they land here (each keyed on [MergeOrigin], and **each
/// independently load-bearing** — the gate measured four separate wrong fixes,
/// listed with the clause that actually answers each):
///
/// 0. **The person doing the restoring must be allowed to write in the project
///    the archive is for** — the §4.21 role gradient, resolved from this
///    device's own membership rows before any row of the file is applied
///    ([UntrustedImportRules.receiverMayImport]). Numbered clause 6 in §4.19
///    because it arrived last (task 11.19 on the share path, task 11.20 here);
///    first in this list because it is first in the code, and for a reason
///    peculiar to this path — the archive carries the project's own
///    `Project_Memberships` rows, so a check made any later could be answered
///    with rights the file itself had just granted.
///
///    **The hard part is what it does when the device cannot answer, and it
///    abstains.** Membership is server-derived. A reinstalled phone restoring
///    last season's archive has no membership rows for that project and no
///    `Projects` row either — and that is the case restore exists for, under
///    a Phase 10 invariant that the app works fully with no server. So a role
///    this device cannot resolve **permits**, identically to
///    `BaseRepository.assertRoleMayWrite` and to the share path. What is
///    refused is the case where the device *does* have an answer and the
///    answer is `viewer`. Any check stricter than that would trade the
///    feature's most important use for a gap that costs one person a view of
///    their own device — see [UntrustedImportRules.receiverMayImport] and
///    §4.19 clause 6 for the reasoning in full, written down because the
///    obvious fix here is the wrong one.
///
/// 1. **Write only the columns the payload can express.** An archive is a full
///    column dump, so unlike the share format there is no narrower carried set
///    to intersect with — what this clause forbids here is the *widening*: a
///    column absent from an incoming row is left alone rather than written as
///    `NULL`, and columns this build does not recognize are held verbatim
///    ([UnknownColumnStore]) rather than dropped.
///
/// 2. **Authorship never comes from a payload.** On a row that already exists,
///    the identity columns ([SyncTable.identityUserColumns] — `user_id`,
///    `owner_user_id`) are **not written at all**, and `last_modified_by` is
///    restated as the person performing the import, never the file's claim.
///    This is the clause that answers "the project's owner was reassigned" and
///    "`last_modified_by` named the victim".
///
/// 3. **The merge clock is bounded, and out-of-range is refused, not clamped**
///    ([UntrustedImportRules.checkClock]), on every table and including
///    `deleted_at`. **This is the clause that answers the gate's fact (a)** —
///    that removing the "Overwrite with backup" button fixes nothing, because
///    the full damage lands under the *default* `lastWriteWins` strategy on the
///    strength of `revision: 9223372036854775807` alone. And it answers fact
///    (b): [RowValidator] does run on this path and stopped none of it, because
///    it has never inspected the clock, `deleted_at` or authorship — it is a
///    domain-bounds check, and the clock is not a domain bound.
///
/// 4. **Nothing that replaces a held value is written without consent, and the
///    prior version survives the write.** `confirmChanges` defaults to
///    refusing; without it an import that would replace anything writes
///    **nothing at all** and returns the field-by-field list of what it would
///    change. Consent is all-or-nothing across the archive, because a
///    per-row prompt over eleven tables is a prompt the user clicks through.
///    Every accepted overwrite writes the prior row to `Sync_Conflicts` first,
///    so *recoverable* is a property of the write and not of the user having
///    taken a backup — which on this path would be circular.
///
/// 5. **[RowValidator] runs, as an invariant rather than an option.** It was
///    already running here (`validate` defaults to true and no caller turned it
///    off), but a default is not an invariant; on this origin the parameter
///    cannot be set to false.
///
/// **Plus one clause §4.19 did not need and this path does: the merge is scoped
/// to the manifest's project.** The gate's fact (c): a file whose manifest
/// named project A rewrote the owner of an unrelated local project B, because
/// `manifest.projectId` was read only for the *"Switch to this project"*
/// button. A row whose project column disagrees with the manifest is refused.
///
/// **And what the clauses do not claim.** An archive is unauthenticated, like a
/// share payload, so the guarantee is *visibility and recoverability*, not
/// prevention: a file can still create records, and via the email dedup those
/// records can be attributed to a person the device knows (the gate's fact
/// (d)). The dedup is load-bearing on this path and stays — see [IdentityTrust]
/// — so what it owes is a count, and [MergeReport.rowsReattributed] is it.
/// Signing archives would close the residual and needs a key the sender holds
/// and the receiver trusts: Phase 11 identity work, recorded as Discovered
/// Scope rather than left implicit.
class ProjectMerger {
  const ProjectMerger(this.db);

  final DatabaseExecutor db;

  /// Merges [backup] into the local database under [origin]'s trust rules.
  ///
  /// [importingUserId] is the person performing the import on this device —
  /// what `last_modified_by` is restated to when an untrusted archive updates a
  /// row that already exists (clause 2), **and whose rights clause 6 checks in
  /// the project [backup]'s manifest names**. One parameter for both, not two:
  /// they are the same person, and [MergeOrigin]'s own note is what two
  /// arguments that must always agree cost on this path.
  ///
  /// Null falls back to leaving `last_modified_by` in place; what neither
  /// branch does is take the file's word for it. For clause 6 a null id
  /// resolves to a null role and therefore permits — the same *this device
  /// cannot say* reading, since a device with no identity has no membership
  /// answer either. In the app that state is unreachable: task 7.1 made
  /// identity capture a non-skippable first-run gate and the import screen
  /// reads `currentUserProvider`. It is reachable in tests, which is where
  /// most of the merger's callers that omit this live.
  ///
  /// [confirmChanges] is that person's explicit consent to replace values this
  /// device already holds. Without it an import that would do so returns
  /// [MergeOutcome.needsConfirmation] and writes nothing — clause 4 expressed
  /// as a parameter the caller cannot forget, because the default refuses.
  ///
  /// [now] is this device's clock, injectable for tests; every row's merge
  /// clock is bounded against one reading of it.
  Future<MergeReport> merge(
    ProjectBackup backup, {
    MergeStrategy strategy = MergeStrategy.lastWriteWins,
    MergeOrigin origin = MergeOrigin.untrustedArchive,
    bool validate = true,
    bool confirmChanges = false,
    String? importingUserId,
    DateTime? now,
  }) async {
    assert(
      !origin.isUntrusted || validate,
      'Validation is an invariant on an untrusted archive (§4.19 clause 5), '
      'not a parameter. Passing validate: false here is the state §4.19.1 '
      'recorded as "validation is an opt-out parameter rather than an '
      'invariant" — which is finding K-1.',
    );
    final clockNow = (now ?? DateTime.now()).toUtc();
    // A default is not an invariant: forced rather than merely defaulted, so a
    // release build with asserts stripped enforces the same rule.
    final validateRows = origin.isUntrusted || validate;

    // Migrate the in-memory payload forward (throws SchemaTooNewException here,
    // before any DB write, if the backup is from a newer app).
    final migratedFrom = SchemaMigrator.migrateToCurrent(backup);

    final report = MergeReport(
      byTable: {},
      usersDeduped: 0,
      schemaMigratedFrom: migratedFrom,
      currentSchemaVersion: latestSchemaVersion,
      issues: [],
    );

    // Everything below is one transaction: a throw anywhere rolls it all back,
    // and the plan below is read inside the same transaction it is applied in,
    // so nothing can change between deciding and writing.
    final result = await _asTransaction((txn) async {
      // **§4.19 clause 6 (task 11.20), and its position is load-bearing three
      // times over.** A restore is a write into a project, so the §4.21 role
      // gradient governs the person doing it exactly as it governs every other
      // write the app makes — and until this check, nothing on the device
      // asked. A viewer could restore an archive over a project they are only
      // allowed to read; the server refused every row on the next sync, so
      // nobody else's record was ever at risk, but their device showed them a
      // project the project does not agree with until they found out.
      //
      // **First, and against the manifest's project.** The merge is already
      // scoped to `manifest.projectId` (the gate's fact (c) in `_plan`), so
      // there is exactly one project to hold a role in. Resolving the role in
      // whatever project happens to be *open* on this screen instead would let
      // an owner of project A restore an archive of project B they may only
      // read — a different project's answer to this project's question.
      //
      // **Second, before a single row is applied — which is what stops the
      // archive authoring its own permission.** The file contains the
      // project's own `Projects` row and its `Project_Memberships` rows. Ask
      // after, or per-row inside `_plan`, and an archive carrying a membership
      // row naming the importer as `owner` would grant itself the rights it is
      // then checked against. That is the class task 11.3's Gate B run named
      // — a permission read from state a permissive branch wrote — and here it
      // is avoided structurally rather than by ordering the tables carefully.
      //
      // **Third, inside the transaction**, so the answer cannot change between
      // deciding and writing, which is the same reason `_plan` reads in the
      // transaction it is applied in.
      //
      // What it does *not* do — and this is the whole design question the task
      // existed to answer — is refuse when this device has no membership
      // answer. See [UntrustedImportRules.receiverMayImport]: a null role
      // permits. A reinstalled phone restoring last season's archive holds no
      // `Projects` row and no membership rows for it, and that is the case
      // restore exists for. The check fires exactly where the device has
      // grounds and abstains exactly where it has none.
      if (origin.isUntrusted) {
        final receiverRole = await readProjectRole(
          txn,
          projectId: backup.manifest.projectId,
          userId: importingUserId,
        );
        if (!UntrustedImportRules.receiverMayImport(receiverRole)) {
          return _MergePass(
            remap: const UserRemap(remap: {}, priorMatched: {}),
            reattributed: 0,
            changes: const [],
            outcome: MergeOutcome.refusedNotPermitted,
            receiverRole: receiverRole,
          );
        }
      }

      // No remap at all when the payload's ids came from an authenticated
      // server — see [IdentityTrust]. Skipped rather than computed-and-ignored
      // so there is no branch anywhere downstream that could still apply it.
      final remapResult = origin.identityTrust == IdentityTrust.serverAssignsIdentity
          ? const UserRemap(remap: {}, priorMatched: {})
          : await _buildUserRemap(txn, backup);
      final remapped = _remappedRows(backup, remapResult.remap);

      // Task 11.239: an archive written before task 11.224's fork names a
      // collar by the id this device has since replaced. Matched by lineage
      // onto the tag this device already holds for the manifest project —
      // see [_matchForkedTags] for the measurement and the scoping. Only an
      // untrusted archive: a page pulled from the server carries the server's
      // own ids, and rewriting those on the way in would leave this device
      // and the server disagreeing about which row a bearing belongs to.
      final matched = origin.isUntrusted
          ? await _matchForkedTags(txn, backup, remapped.byTable)
          : _MatchedTags(byTable: remapped.byTable, tags: 0);

      // Task 11.237: which of the four cases this import is, from the
      // archive's own (remapped) membership rows and the device's, before a
      // row is written. See [ImportCase] for the table and for what each way
      // the file could lie costs. Only an untrusted archive is an *import*;
      // a sync pull through this same merger is not classified.
      final importCase = origin.isUntrusted
          ? await _classifyImport(
              txn,
              backup,
              rowsByTable: matched.byTable,
              importingUserId: importingUserId,
            )
          : null;

      // Pass one reads and decides; pass two writes. Split because clause 4's
      // answer to "this would destroy something" is *write nothing at all*,
      // and that has to be knowable before the first statement rather than
      // undone after the last one — a rollback would work but would leave the
      // report describing writes that no longer exist.
      final plan = await _plan(
        txn,
        backup,
        rowsByTable: matched.byTable,
        strategy: strategy,
        origin: origin,
        validateRows: validateRows,
        importingUserId: importingUserId,
        clockNow: clockNow,
        report: report,
      );

      if (plan.destructive && !confirmChanges) {
        return _MergePass(
          remap: remapResult,
          reattributed: remapped.rows,
          changes: plan.changes,
          outcome: MergeOutcome.needsConfirmation,
          importCase: importCase,
          tagsMatchedByLineage: matched.tags,
        );
      }

      await _apply(txn, plan, backup: backup, origin: origin, now: clockNow);
      return _MergePass(
        remap: remapResult,
        reattributed: remapped.rows,
        changes: plan.changes,
        outcome: MergeOutcome.applied,
        importCase: importCase,
        tagsMatchedByLineage: matched.tags,
        restored: [
          for (final row in plan.restored)
            RestoredProjectArrival(
              projectId: row['project_id']! as String,
              projectName: row['project_name'] as String? ?? '',
              restoredBy: row['last_modified_by'] as String?,
              restoredByName: await _nameOf(
                txn,
                row['last_modified_by'] as String?,
              ),
            ),
        ],
        deleted: [
          for (final row in plan.deleted)
            ProjectDeletionArrival(
              projectId: row['project_id']! as String,
              projectName: row['project_name'] as String? ?? '',
              deletedBy: row['last_modified_by'] as String?,
              deletedByName: await _nameOf(
                txn,
                row['last_modified_by'] as String?,
              ),
            ),
        ],
      );
    });

    final merged = MergeReport(
      byTable: report.byTable,
      usersDeduped: result.remap.remap.length,
      usersMatchedViaPriorEmail: result.remap.priorMatched.length,
      rowsReattributed: result.reattributed,
      schemaMigratedFrom: migratedFrom,
      currentSchemaVersion: latestSchemaVersion,
      issues: report.issues,
      outcome: result.outcome,
      changes: result.changes,
      receiverRole: result.receiverRole,
      importCase: result.importCase,
      tagsMatchedByLineage: result.tagsMatchedByLineage,
    );
    // Every route by which somebody else's data reaches this device lands
    // here: a sync pull hands each page to this merger, a join is a pull from
    // cursor zero, and restoring a backup is the same call with a file behind
    // it. Announcing here rather than in each of those callers is task 11.45 —
    // the caller that forgot was the sync pull, and the symptom was a
    // colleague's bearings sitting in SQLite with the map showing nothing.
    if (merged.totalInserted + merged.totalUpdated + merged.rowsReattributed >
        0) {
      DataArrival.announce();
    }
    // After the commit, like the announcement above: a listener that reads
    // the database must find the project live.
    ProjectRestoration.announce(result.restored);
    // Task 11.313: the symmetric announcement, after the same commit — a
    // listener that reads the database must find the project already
    // tombstoned.
    ProjectDeletionAnnouncement.announce(result.deleted);
    return merged;
  }

  /// The name on [userId]'s `Users` row here, or null when this device holds
  /// none or only a blank placeholder the server wrote before the person's
  /// own device pushed their profile.
  static Future<String?> _nameOf(DatabaseExecutor db, String? userId) async {
    if (userId == null) return null;
    final rows = await db.query(
      Tables.users,
      columns: ['first_name', 'last_name'],
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    if (rows.isEmpty) return null;
    final name = [
      (rows.single['first_name'] as String? ?? '').trim(),
      (rows.single['last_name'] as String? ?? '').trim(),
    ].where((part) => part.isNotEmpty).join(' ');
    return name.isEmpty ? null : name;
  }

  /// Runs [action] inside a transaction. [DatabaseExecutor] is either a
  /// [Database] (start a real transaction) or already a [Transaction] (nested
  /// merge — reuse it). Keeps the merger usable both standalone and composed.
  Future<T> _asTransaction<T>(
    Future<T> Function(DatabaseExecutor txn) action,
  ) {
    final database = db;
    if (database is Database) {
      return database.transaction((txn) => action(txn));
    }
    return action(database);
  }

  /// Builds the incoming→local user id remap, considering both a current
  /// email match (always authoritative) and, only when no current match
  /// exists, a prior-email fallback (Phase 7) in either direction — see
  /// [UserRemap] for the two prior-email tiers.
  Future<UserRemap> _buildUserRemap(
    DatabaseExecutor txn,
    ProjectBackup backup,
  ) async {
    // Tier 1: local users, normalized current-email -> chosen local id. On
    // the (unusual) case of two local users sharing an email, prefer a live
    // row, then the lexically smallest id, so the choice is deterministic.
    final emailToId = <String, String>{};
    final localDeleted = <String, bool>{};
    final localRows = await txn.query(Tables.users);
    for (final row in localRows) {
      final id = row['user_id'] as String;
      final email = UserRepository.normalizeEmail(row['email'] as String? ?? '');
      if (email.isEmpty) continue;
      final deleted = row['deleted_at'] != null;
      final existing = emailToId[email];
      if (existing == null) {
        emailToId[email] = id;
        localDeleted[email] = deleted;
      } else {
        final existingDeleted = localDeleted[email] ?? false;
        final preferNew = (existingDeleted && !deleted) ||
            (existingDeleted == deleted && id.compareTo(existing) < 0);
        if (preferNew) {
          emailToId[email] = id;
          localDeleted[email] = deleted;
        }
      }
    }
    // Frozen snapshot of genuinely-local current emails, taken before the
    // incoming loop below starts anchoring *incoming-only* emails into
    // `emailToId` too (tier 1's existing incoming-dup-collapsing behavior).
    // Tier 2b must only match a real local user, never another incoming row
    // that merely happens to share an email absent from the local database.
    final localCurrentEmailToId = Map<String, String>.of(emailToId);

    // Tier 2a: local prior emails (an address this device recorded when one
    // of its own users changed email) -> id. An address recorded as a prior
    // email by more than one *distinct* local user is ambiguous — e.g. a
    // shared institutional address reassigned to a different person — and is
    // excluded rather than guessed at.
    final localPriorEmailToId = <String, String?>{};
    for (final row in await txn.query(Tables.userEmails)) {
      if (row['deleted_at'] != null) continue;
      final email = UserRepository.normalizeEmail(row['email'] as String? ?? '');
      if (email.isEmpty) continue;
      final userId = row['user_id'] as String;
      if (!localPriorEmailToId.containsKey(email)) {
        localPriorEmailToId[email] = userId;
      } else if (localPriorEmailToId[email] != userId) {
        localPriorEmailToId[email] = null; // ambiguous
      }
    }

    // Tier 2b inputs: each incoming user's own prior addresses, as carried in
    // the backup's own User_Emails rows, keyed by their incoming user_id.
    final incomingPriorEmails = <String, Set<String>>{};
    for (final row in backup.rowsFor(Tables.userEmails)) {
      final email = UserRepository.normalizeEmail(_asStringOrEmpty(row['email']));
      final userId = _asStringOrNull(row['user_id']);
      if (email.isEmpty || userId == null) continue;
      incomingPriorEmails.putIfAbsent(userId, () => {}).add(email);
    }

    final remap = <String, String>{};
    final priorMatched = <String>{};

    for (final row in backup.rowsFor(Tables.users)) {
      // Task 10.78, finding K-11b: this used to be `row['user_id'] as String`
      // — a naked, non-nullable cast on data read straight from an
      // unauthenticated archive, reached before the `RowValidator` loop in
      // `_plan` (below) ever runs. A non-string `user_id` threw an uncaught
      // `TypeError` and took the whole merge down with it, rather than being
      // refused as one invalid row the way `RowValidator` would refuse it a
      // few lines later for every other malformed column. Skipping it here
      // just means this row cannot anchor or be targeted by a dedup match —
      // `_plan`'s validation pass still sees the row and refuses it on its
      // own merits (or accepts it, if `user_id` is the only wrong part and
      // this build's tolerance for that turns out wider than expected).
      final incomingId = _asStringOrNull(row['user_id']);
      if (incomingId == null) continue;
      final email = UserRepository.normalizeEmail(_asStringOrEmpty(row['email']));
      if (email.isEmpty) continue;

      final currentTarget = emailToId[email];
      if (currentTarget != null && currentTarget != incomingId) {
        // Tier 1 always wins outright — never fall through to a prior-email
        // tier once a current-current match is found.
        remap[incomingId] = currentTarget;
        continue;
      }
      if (currentTarget == null) {
        // First time we've seen this email: it anchors future incoming dups.
        emailToId[email] = incomingId;
      }

      // Tier 2a: incoming's current email matches a local user's prior one.
      final priorTarget = localPriorEmailToId[email];
      if (priorTarget != null && priorTarget != incomingId) {
        remap[incomingId] = priorTarget;
        priorMatched.add(incomingId);
        continue;
      }

      // Tier 2b: one of the incoming user's own prior emails matches a local
      // user's current one.
      final ownPriorEmails = incomingPriorEmails[incomingId];
      if (ownPriorEmails != null) {
        for (final priorEmail in ownPriorEmails) {
          final target = localCurrentEmailToId[priorEmail];
          if (target != null && target != incomingId) {
            remap[incomingId] = target;
            priorMatched.add(incomingId);
            break;
          }
        }
      }
    }
    return UserRemap(remap: remap, priorMatched: priorMatched);
  }

  /// The backup's rows with every user-referencing column rewritten so foreign
  /// keys point at the deduped local user ids — covering
  /// `user_id`/`owner_user_id` and the `last_modified_by` audit column on every
  /// table — plus how many rows that touched.
  ///
  /// The count is reported to the user as [MergeReport.rowsReattributed], and
  /// counting is the whole of the fix for the gate's fact (d): the rewrite is
  /// keyed on an unauthenticated email string and is *supposed* to happen (it
  /// is what stops a re-import of your own phone's export producing two of
  /// you), so the defect was never that it fires — it is that a file claiming
  /// the holder's address could re-attribute its own rows to them and nothing
  /// said so.
  ///
  /// **Finding L-6 is why this returns rows instead of rewriting them in
  /// place**, and the count is the symptom rather than the defect. The screen
  /// calls [merge] twice on the same [ProjectBackup] — once to obtain clause
  /// 4's plan, once with the user's consent — which is the correct shape for a
  /// gate whose answer is *write nothing at all*. It only worked once because
  /// pass one mutated the caller's object: by pass two every id was already
  /// local, the remap came back empty, and `usersDeduped` and
  /// `rowsReattributed` read **0** on exactly the hostile import §4.19.2 says
  /// they are owed for. *A plan pass that mutates its own input is the defect*;
  /// a plan is a description, and describing something twice must give the same
  /// answer. Rows that need no rewrite are shared rather than copied, so the
  /// common case allocates nothing.
  /// See [ImportCase] — the classification, asked of the archive's remapped
  /// rows and of this device's own, inside the transaction and before the
  /// plan.
  ///
  /// *Already here* is a `Projects` row for the manifest's project, tombstoned
  /// or not: a deleted copy re-imported is still a merge into the same row.
  /// *Member* is `resolveProjectRole` — the same rule every gate and the
  /// server use — over the archive's rows, or over the device's where the
  /// device has any; the clause-6 read above is not reused here because it
  /// answers about the device only, and for a project that is not here yet
  /// the archive is the only witness.
  Future<ImportCase> _classifyImport(
    DatabaseExecutor txn,
    ProjectBackup backup, {
    required Map<String, List<Map<String, Object?>>> rowsByTable,
    required String? importingUserId,
  }) async {
    final projectId = backup.manifest.projectId;
    final here = await txn.query(
      Tables.projects,
      columns: ['project_id'],
      where: 'project_id = ?',
      whereArgs: [projectId],
      limit: 1,
    );
    final alreadyHere = here.isNotEmpty;

    final archiveProject = <Map<String, Object?>>[
      for (final row in rowsByTable[Tables.projects] ?? const [])
        if (row['project_id'] == projectId) row,
    ];
    final archiveMemberships = <Map<String, Object?>>[
      for (final row in rowsByTable[Tables.projectMemberships] ?? const [])
        if (row['project_id'] == projectId) row,
    ];
    final creator = archiveProject.isEmpty
        ? null
        : archiveProject.first['owner_user_id'];
    final archiveSaysMember =
        resolveProjectRole(
          membershipRows: archiveMemberships,
          creatorUserId: creator is String ? creator : null,
          userId: importingUserId,
        ) !=
        null;
    final deviceSaysMember =
        alreadyHere &&
        (await readProjectStanding(
          txn,
          projectId: projectId,
          userId: importingUserId,
        )) is MemberStanding;
    final member = archiveSaysMember || deviceSaysMember;

    return switch ((alreadyHere, member)) {
      (true, true) => ImportCase.merge,
      (false, true) => ImportCase.adopt,
      (true, false) => ImportCase.mergeIntoSnapshot,
      (false, false) => ImportCase.snapshot,
    };
  }

  _RemappedRows _remappedRows(ProjectBackup backup, Map<String, String> remap) {
    if (remap.isEmpty) return _RemappedRows(byTable: backup.tables, rows: 0);
    var rows = 0;
    final byTable = <String, List<Map<String, Object?>>>{...backup.tables};
    for (final table in syncTables) {
      final source = backup.rowsFor(table.name);
      if (source.isEmpty) continue;
      final rewritten = <Map<String, Object?>>[];
      for (final row in source) {
        Map<String, Object?>? copy;
        for (final col in table.userColumns) {
          final current = row[col];
          if (current is! String) continue;
          final mapped = remap[current];
          if (mapped == null) continue;
          (copy ??= Map<String, Object?>.of(row))[col] = mapped;
        }
        if (copy != null) rows++;
        rewritten.add(copy ?? row);
      }
      byTable[table.name] = rewritten;
    }
    return _RemappedRows(byTable: byTable, rows: rows);
  }

  /// **Task 11.239 — an archive written before the fork meets a device that
  /// has forked, and the same collar lands in one project twice.**
  ///
  /// `Tags` is keyed `(tag_id, project_id)`. When schema v14 found one collar
  /// linked to two projects on a device, task 11.224's fork kept the original
  /// id in the earlier project and gave the later project a **fresh id** with
  /// `lineage_id` naming the original. A v13 archive of that later project was
  /// written before any of that happened, so its `Tags` row still carries the
  /// original id, and [SchemaMigrator]'s v14 step keys it `(t1, B)`. This
  /// device holds `(t2, B)` with `lineage_id = t1`. Nothing about the primary
  /// key makes those the same row, so before this method both were inserted
  /// and every bearing in the archive was filed under `t1` while every bearing
  /// taken since the fork sat under `t2` — one animal, two rows, its record
  /// split between them. **Measured, not reasoned:**
  /// `test/data/sync/forked_collar_archive_test.dart` reproduces it, and its
  /// first run counted two.
  ///
  /// **The device's `lineage_id` is the thing that knows `t2` is `t1`.** The
  /// archive cannot know it — the fork happened after the file was written —
  /// but the importing device can, so the repair belongs here and not in the
  /// migrator, which sees only the payload.
  ///
  /// **What it does.** For each incoming `Tags` row in the manifest project
  /// whose id this project does not already hold: if this project holds
  /// exactly one tag of the same lineage, the incoming row is re-keyed onto
  /// it, and every column `syncTables` declares as naming a tag follows —
  /// derived from `tagColumns`, which is the fork's four tables plus
  /// `Tag_Versions`, and which the sealed-column assertion guarantees never
  /// includes `Non_Detections.tag_ids_listened_for`. That column is then
  /// re-derived by [SchemaMigrator.relinkNonDetections] against the re-keyed
  /// payload, exactly as it is for a v14 archive: the id no longer resolves
  /// in the payload, the payload's same-lineage row does, so the "no signal"
  /// entry follows the collar. **One derivation reused, not a third written.**
  /// The re-keyed `Tags` row carries the device's own `copied_at` rather than
  /// the archive's null, because the row it is now about was copied and the
  /// archive is not in a position to say otherwise. Everything else about it
  /// — name, frequency, status — merges by last-write-wins like any other
  /// row this device already holds, so an edit made before the archive was
  /// written still arrives, and one that would replace something goes
  /// through the consent gate.
  ///
  /// **Scoped to the manifest project, per row, on both sides.** The device
  /// query asks *which tags does this project hold*, never *which projects
  /// hold this lineage* — the question Security Model §5.9(b) forbids — and a
  /// payload row naming another project is left alone here and refused by
  /// [_plan] as it always was.
  ///
  /// **Two shapes are refused rather than guessed at**, and both throw a
  /// [BackupFormatException] before a row is written:
  ///
  /// - the payload itself carries two `Tags` rows of one lineage in the
  ///   manifest project. Every route in the app that copies a collar into a
  ///   project refuses a lineage the project already holds, so no build
  ///   writes such a file on purpose — but this is an untrusted path, and a
  ///   file that says one collar is two rows cannot be merged onto one row
  ///   without choosing which of them the record belongs to.
  /// - this device already holds two tags of one lineage in the project and
  ///   the archive brings a third id of that lineage. The device is the thing
  ///   that is malformed there — most likely by exactly this defect, before
  ///   this repair existed — and matching against one of two is a guess.
  ///
  /// Returns the rows to plan from — **copies, never the caller's maps**, the
  /// same rule as [_remappedRows] — and how many tags were matched, which
  /// the import report shows so a person can see it happened.
  Future<_MatchedTags> _matchForkedTags(
    DatabaseExecutor txn,
    ProjectBackup backup,
    Map<String, List<Map<String, Object?>>> byTable,
  ) async {
    final projectId = backup.manifest.projectId;
    final incoming = [
      for (final row in byTable[Tables.tags] ?? const <Map<String, Object?>>[])
        if (row['project_id'] == projectId) row,
    ];
    if (incoming.isEmpty) return _MatchedTags(byTable: byTable, tags: 0);

    // The payload's own consistency first, unconditionally: two rows, one
    // lineage, one project is refused whether or not this device holds any.
    final payloadIdByLineage = <String, String>{};
    for (final row in incoming) {
      final id = row['tag_id'];
      final lineage = row['lineage_id'];
      // A row missing either is RowValidator's to refuse and name, not ours.
      if (id is! String || lineage is! String) continue;
      final prior = payloadIdByLineage[lineage];
      if (prior != null && prior != id) {
        throw const BackupFormatException(forkedTagArchiveRefusal);
      }
      payloadIdByLineage[lineage] = id;
    }

    final held = await txn.query(
      Tables.tags,
      columns: const ['tag_id', 'lineage_id', 'copied_at'],
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
    final heldIds = {for (final h in held) h['tag_id'] as String};
    final heldByLineage = <String, List<Map<String, Object?>>>{};
    for (final h in held) {
      heldByLineage.putIfAbsent(h['lineage_id'] as String, () => []).add(h);
    }

    final rekey = <String, String>{};
    final copiedAt = <String, Object?>{};
    for (final row in incoming) {
      final id = row['tag_id'];
      final lineage = row['lineage_id'];
      if (id is! String || lineage is! String) continue;
      // The same row, by key: an ordinary merge, and nothing to match.
      if (heldIds.contains(id)) continue;
      final sameLineage = heldByLineage[lineage] ?? const [];
      if (sameLineage.isEmpty) continue;
      if (sameLineage.length > 1) {
        throw const BackupFormatException(forkedTagDeviceRefusal);
      }
      rekey[id] = sameLineage.single['tag_id'] as String;
      copiedAt[id] = sameLineage.single['copied_at'];
    }
    if (rekey.isEmpty) return _MatchedTags(byTable: byTable, tags: 0);

    final rewritten = <String, List<Map<String, Object?>>>{...byTable};
    for (final table in syncTables) {
      if (table.tagColumns.isEmpty) continue;
      final source = byTable[table.name] ?? const <Map<String, Object?>>[];
      if (source.isEmpty) continue;
      rewritten[table.name] = [
        for (final row in source)
          if (row['project_id'] != projectId)
            row
          else
            _rekeyTagRow(table, row, rekey: rekey, copiedAt: copiedAt),
      ];
    }
    // Copied before the relink step rewrites values in place — L-6's rule.
    rewritten[Tables.nonDetections] = [
      for (final row
          in byTable[Tables.nonDetections] ?? const <Map<String, Object?>>[])
        Map<String, Object?>.of(row),
    ];
    SchemaMigrator.relinkNonDetections(rewritten);
    return _MatchedTags(byTable: rewritten, tags: rekey.length);
  }

  /// One row of a tag-naming table with every declared tag column that names
  /// a re-keyed id moved onto the device's id. The `Tags` row itself also
  /// takes the device's `copied_at` — see [_matchForkedTags].
  static Map<String, Object?> _rekeyTagRow(
    SyncTable table,
    Map<String, Object?> row, {
    required Map<String, String> rekey,
    required Map<String, Object?> copiedAt,
  }) {
    Map<String, Object?>? copy;
    for (final column in table.tagColumns) {
      final current = row[column];
      if (current is! String) continue;
      final mapped = rekey[current];
      if (mapped == null) continue;
      (copy ??= Map<String, Object?>.of(row))[column] = mapped;
      if (table.name == Tables.tags && column == 'tag_id') {
        copy['copied_at'] = copiedAt[current];
      }
    }
    return copy ?? row;
  }

  /// Pass one: decide what every incoming row would do, writing nothing.
  ///
  /// Reads happen inside the caller's transaction, so the state this plan was
  /// built against is the state [_apply] writes over. [report]'s per-table
  /// counters and [MergeReport.issues] are filled here — they describe the plan,
  /// which on the [MergeOutcome.applied] path is also what happened, and on the
  /// consent gate is what *would* happen. That is the same list describing the
  /// offer and the receipt, which is what stops the consent given and the change
  /// made from disagreeing.
  ///
  /// [rowsByTable] is the backup's own rows with the user remap applied — a
  /// *copy*, never the caller's maps. See [_remappedRows] and finding L-6.
  Future<_MergePlan> _plan(
    DatabaseExecutor txn,
    ProjectBackup backup, {
    required Map<String, List<Map<String, Object?>>> rowsByTable,
    required MergeStrategy strategy,
    required MergeOrigin origin,
    required bool validateRows,
    required String? importingUserId,
    required DateTime clockNow,
    required MergeReport report,
  }) async {
    final writes = <_PlannedWrite>[];
    final changes = <MergeFieldChange>[];
    final restored = <Map<String, Object?>>[];
    final deleted = <Map<String, Object?>>[];

    for (final table in syncTables) {
      final rows = rowsByTable[table.name] ?? const <Map<String, Object?>>[];
      if (rows.isEmpty) continue;
      final stats = report.statsFor(table.name);

      for (final row in rows) {
        // Scoped to the manifest's project before anything else. The gate's
        // fact (c): a file whose manifest named project A rewrote the owner of
        // an unrelated local project B, because `manifest.projectId` was read
        // only for the "Switch to this project" button. Applied on both
        // origins — a page pulled for one project has no business carrying
        // another's rows either, and a check that only runs on the path where
        // it has already been exploited is how this class of finding recurs.
        //
        // `Users` and `User_Emails` declare no project column: they are
        // global by schema (`syncTables`' own note) and are reached by
        // reachability rather than by scope, so there is nothing to compare.
        //
        // **`Tags` was the third and task 11.219 closed a live behaviour by
        // removing it from that list.** While tags were global this
        // exemption applied to them, so an incoming `Tags` row with an id
        // you already held was merged into your row by last-write-wins —
        // **whatever project of yours that tag belonged to** — and identifiers
        // are random UUIDs, so this needed the two devices to genuinely be
        // talking about one tag row, which is precisely what happened when
        // two people worked from one shared tag. Importing a colleague's
        // archive could rewrite a row in your own tag list. It is gone by
        // construction rather than by a check: a tag is project-scoped, so
        // the comparison above is the one that runs.
        final scopeColumn = table.projectScopeColumn;
        if (scopeColumn != null && row[scopeColumn] != backup.manifest.projectId) {
          stats.refused++;
          report.issues.add(RowIssue(
            table: table.name,
            primaryKeyValue: _rowKey(table, row),
            field: scopeColumn,
            message: 'belongs to project "${row[scopeColumn]}", but this '
                'backup is for "${backup.manifest.projectId}"',
          ));
          continue;
        }

        if (validateRows) {
          final issues = RowValidator.validate(table.name, row);
          if (issues.isNotEmpty) {
            report.issues.addAll(issues);
            stats.invalid++;
            continue;
          }
        }

        // Clause 3. Refused, never clamped: clamping a hostile clock to "now"
        // leaves it winning last-write-wins against every honest local edit —
        // the attack succeeds and the bound reports that it worked.
        if (origin.isUntrusted) {
          final clockIssues =
              UntrustedImportRules.checkClock(table.name, row, now: clockNow);
          if (clockIssues.isNotEmpty) {
            report.issues.addAll(clockIssues);
            stats.refused++;
            continue;
          }
        }

        final where = table.primaryKey.map((c) => '$c = ?').join(' AND ');
        final args = table.primaryKey.map((c) => row[c]).toList();
        final existingRows = await txn.query(
          table.name,
          where: where,
          whereArgs: args,
          limit: 1,
        );

        // A row from a newer schema minor carries columns this build has no
        // place for. They are split off and held rather than dropped, and go
        // back out untouched on the next push (task 10.18) — dropping them is
        // what made version skew data loss in the first place.
        final parts = UnknownColumnStore.split(table.name, row);
        final known = parts.known;

        if (existingRows.isEmpty) {
          // Clause 1's shape on this path: the incoming row's own columns, and
          // only those. A column the file omitted is absent from the statement
          // rather than written as NULL.
          writes.add(_PlannedWrite(
            table: table,
            row: row,
            unknown: parts.unknown,
            values: known,
            where: where,
            whereArgs: args,
            existing: null,
          ));
          stats.inserted++;
          continue;
        }

        final existing = existingRows.first;
        final wins = strategy == MergeStrategy.preferIncoming ||
            MergeResolver.incomingWins(known, existing);
        if (!wins) {
          // The local row is authoritative, and so are the values held
          // against it.
          stats.skipped++;
          continue;
        }

        final patch = _patchFor(
          table,
          known,
          origin: origin,
          importingUserId: importingUserId,
        );
        // Clause 4's diff is computed only where clause 4 applies. A pulled
        // page runs unattended in the background, where there is nobody to ask
        // and task 10.12's sync-side capture has already recorded the
        // overwrite — a gate here would stop every background sync waiting for
        // consent that cannot arrive.
        if (origin.isUntrusted) {
          changes.addAll(_changesAgainst(table, row, existing, patch));
        }
        // Task 11.302: a server page taking a project from deleted to live
        // is somebody's restore, and the person holding this device may not
        // have been told the project ever left. See [ProjectRestoration].
        if (origin == MergeOrigin.authenticatedServer &&
            table.name == Tables.projects &&
            existing['deleted_at'] != null &&
            known.containsKey('deleted_at') &&
            known['deleted_at'] == null) {
          restored.add(known);
        }
        // Task 11.313: the symmetric case — a server page taking a project
        // from live to deleted is somebody's deletion, and the member
        // holding this device just watched it vanish with no explanation
        // (task 11.302's Discovered Scope). See [ProjectDeletionAnnouncement].
        if (origin == MergeOrigin.authenticatedServer &&
            table.name == Tables.projects &&
            existing['deleted_at'] == null &&
            known.containsKey('deleted_at') &&
            known['deleted_at'] != null) {
          deleted.add(known);
        }

        writes.add(_PlannedWrite(
          table: table,
          row: row,
          unknown: parts.unknown,
          values: patch,
          where: where,
          whereArgs: args,
          existing: existing,
        ));
        stats.updated++;
      }
    }

    return _MergePlan(
      writes: writes,
      changes: changes,
      restored: restored,
      deleted: deleted,
    );
  }

  /// The columns an update from [origin] may write, given the incoming row's
  /// [known] column map. Clause 2 lives here.
  Map<String, Object?> _patchFor(
    SyncTable table,
    Map<String, Object?> known, {
    required MergeOrigin origin,
    required String? importingUserId,
  }) {
    final patch = Map<String, Object?>.of(known)
      ..removeWhere((k, _) => table.primaryKey.contains(k));
    if (!origin.isUntrusted) return patch;

    // Who a row is *about* — its author, its owner, its subject — is never
    // taken from a file for a row this device already holds. Iterating
    // `identityUserColumns` rather than naming `user_id`/`owner_user_id` is
    // deliberate: that list is the declared complete set of the ways a row can
    // name a person (it is what the server's row-naming invariant iterates,
    // task 10.20), so a table that gains a user column inherits this clause
    // instead of needing someone to remember it here.
    for (final column in table.identityUserColumns) {
      patch.remove(column);
    }

    // `last_modified_by` is provenance, not identity, so it is restated rather
    // than dropped: this device really is where the change happened, and the
    // person who chose the file is who caused it. The fidelity cost is named
    // rather than hidden — when the file's row was genuinely last touched by a
    // third party, that fact does not survive the import. §4.19 rule 2 already
    // made this trade for the share path and gave the reason: a forgeable audit
    // column is the worse trade. In K-1 the file set it to the *victim*, so the
    // row recorded its own destruction as the victim's edit.
    if (importingUserId != null) {
      patch[auditUserColumn] = importingUserId;
    } else {
      patch.remove(auditUserColumn);
    }
    return patch;
  }

  /// Which columns [patch] would actually change on [existing].
  ///
  /// [UntrustedImportRules.consentDiffExempt] is excluded for the reason
  /// documented there — one criterion, **derived** rather than listed, and
  /// applied identically on the share path. `incoming` is the pre-split row,
  /// used only to name the record.
  ///
  /// The merge clock is the part finding **L-2** rewrote. It is no longer
  /// exempt, because the merge reads it; it is also not diffed column by
  /// column, because that is the always-alarming prompt the exemption existed
  /// to avoid. It is judged as one thing —
  /// [UntrustedImportRules.isUnexplainedClockAdvance] — and shown only when the
  /// change the file carries cannot account for it. An ordinary correction
  /// still mentions no clock at all. Finding **M-17** is why "account for" is a
  /// magnitude rather than a presence: a flat allowance let one filled column
  /// buy a thousand versions of the row's future.
  List<MergeFieldChange> _changesAgainst(
    SyncTable table,
    Map<String, Object?> incoming,
    Map<String, Object?> existing,
    Map<String, Object?> patch,
  ) {
    final rowKey = _rowKey(table, incoming);
    final changes = <MergeFieldChange>[];
    MergeFieldChange change(String column) => MergeFieldChange(
          table: table.name,
          rowKey: rowKey,
          column: column,
          was: existing[column],
          becomes: patch[column],
        );

    for (final entry in patch.entries) {
      if (UntrustedImportRules.consentDiffExempt.contains(entry.key)) continue;
      if (UntrustedImportRules.mergeClockColumns.contains(entry.key)) continue;
      if (existing[entry.key] == entry.value) continue;
      changes.add(change(entry.key));
    }

    if (UntrustedImportRules.isUnexplainedClockAdvance(
      existing: existing,
      patch: patch,
      otherChanges: changes.length,
    )) {
      // Every clock column, not just `revision`: once the advance is one the
      // file cannot explain, the user is entitled to the whole of what moved.
      for (final column in UntrustedImportRules.mergeClockColumns) {
        if (!patch.containsKey(column)) continue;
        if (existing[column] == patch[column]) continue;
        changes.add(change(column));
      }
    }
    return changes;
  }

  /// Pass two: write the plan. Reached only once clause 4's gate has passed.
  Future<void> _apply(
    DatabaseExecutor txn,
    _MergePlan plan, {
    required ProjectBackup backup,
    required MergeOrigin origin,
    required DateTime now,
  }) async {
    // Only opened if there is something to record, so an insert-only import
    // does not create the table as a side effect.
    var conflictTableReady = false;
    final store = UnknownColumnStore(txn);

    for (final write in plan.writes) {
      final existing = write.existing;
      if (existing == null) {
        await txn.insert(
          write.table.name,
          write.values,
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        await store.hold(
          backup.manifest.projectId,
          write.table,
          write.row,
          write.unknown,
        );
        continue;
      }

      // Clause 4's second half. The prior version is captured before it stops
      // existing, so "recoverable" is a property of the write rather than of
      // the user having a backup — which on the *backup restore* path would be
      // circular reasoning. Unconditional on the update, exactly as the share
      // path does it: an overwrite is an overwrite whichever path carried it.
      //
      // Not on the server path, where task 10.12's sync-side capture already
      // records the same thing and doing it twice would double every entry.
      if (origin.isUntrusted) {
        if (!conflictTableReady) {
          await SyncConflictStore.ensureTable(txn);
          conflictTableReady = true;
        }
        await SyncConflictStore(txn).record(
          projectId: backup.manifest.projectId,
          tableName: write.table.name,
          rowKey: _rowKey(write.table, write.row),
          localSnapshot: existing,
          incomingSnapshot: {...existing, ...write.values},
          detectedAtUtc: now,
        );
      }

      await txn.update(
        write.table.name,
        write.values,
        where: write.where,
        whereArgs: write.whereArgs,
      );
      await store.hold(
        backup.manifest.projectId,
        write.table,
        write.row,
        write.unknown,
      );
    }
  }

  static String _rowKey(SyncTable table, Map<String, Object?> row) =>
      table.primaryKey.map((c) => '${row[c] ?? '?'}').join('/');
}

/// `value` if it is already a [String], else `null` — never throws.
///
/// Task 10.78, finding K-11b: `_buildUserRemap` reads identity fields
/// straight off `backup` — an unauthenticated archive — before `RowValidator`
/// ever sees them, and used naked `as String?`/`as String` casts to do it.
/// `as String?` tolerates `null` but still throws on any other wrong type
/// (an `int`, a `bool`, a nested map); this never throws, matching the same
/// fix this class already applies at every other trust boundary
/// (`sync_routes.dart`'s `_asString`, `sync_protocol.dart`'s
/// `requireSyncString`).
String? _asStringOrNull(Object? value) => value is String ? value : null;

/// [_asStringOrNull], defaulting to `''` for call sites that already treat an
/// empty string as "nothing to match" (every email field here does).
String _asStringOrEmpty(Object? value) => _asStringOrNull(value) ?? '';

/// The backup's rows after the user remap, and how many rows it touched —
/// returned rather than written back into the caller's [ProjectBackup]. See
/// [ProjectMerger._remappedRows] and finding L-6.
class _RemappedRows {
  const _RemappedRows({required this.byTable, required this.rows});

  final Map<String, List<Map<String, Object?>>> byTable;
  final int rows;
}

/// The backup's rows after [ProjectMerger._matchForkedTags], and how many
/// incoming tags were matched onto a tag this device already held for the
/// same collar. Copies, never the caller's maps — see [_RemappedRows].
class _MatchedTags {
  const _MatchedTags({required this.byTable, required this.tags});

  final Map<String, List<Map<String, Object?>>> byTable;
  final int tags;
}

/// **Task 11.239.** Said when a backup carries two tag records of one collar
/// in the project it is for. Asserts no cause — see
/// [ProjectMerger._matchForkedTags] for the two shapes this refuses and why
/// neither is guessed at.
const String forkedTagArchiveRefusal =
    'This backup holds two records for the same tag, and TriTrack cannot '
    'tell which the bearings belong to, so it imported nothing. Your project '
    'is unchanged. Try another backup of this project if you have one, and '
    'report this.';

/// **Task 11.239.** Said when this device already holds two tag records of
/// one collar in the project and the backup brings a third. The device is
/// the thing that is inconsistent; the sentence still names what to do.
const String forkedTagDeviceRefusal =
    'This device already holds two records for the same tag, so TriTrack '
    'cannot tell which one the backup matches, and it imported nothing. Your '
    'project is unchanged. Report this: the two records here need merging '
    'first.';

/// One row the plan will write, with everything [ProjectMerger._apply] needs
/// and nothing it would have to re-derive.
class _PlannedWrite {
  const _PlannedWrite({
    required this.table,
    required this.row,
    required this.unknown,
    required this.values,
    required this.where,
    required this.whereArgs,
    required this.existing,
  });

  final SyncTable table;

  /// The incoming row as it arrived, before the known/unknown split — what
  /// [UnknownColumnStore.hold] is given and what the row is named by.
  final Map<String, Object?> row;
  final Map<String, Object?> unknown;

  /// The columns to write: the full known map on an insert, the clause-2
  /// narrowed patch on an update.
  final Map<String, Object?> values;

  final String where;
  final List<Object?> whereArgs;

  /// The local row this write replaces, or null if this is an insert.
  final Map<String, Object?>? existing;
}

class _MergePlan {
  const _MergePlan({
    required this.writes,
    required this.changes,
    this.restored = const [],
    this.deleted = const [],
  });

  final List<_PlannedWrite> writes;
  final List<MergeFieldChange> changes;

  /// `Projects` rows this plan takes from tombstoned to live, from a server
  /// page — see [ProjectRestoration].
  final List<Map<String, Object?>> restored;

  /// `Projects` rows this plan takes from live to tombstoned, from a server
  /// page — see [ProjectDeletionAnnouncement].
  final List<Map<String, Object?>> deleted;

  bool get destructive => changes.any((c) => c.isDestructive);
}

/// What one run of the transaction body produced, so the report can be built
/// outside it.
class _MergePass {
  const _MergePass({
    required this.remap,
    required this.reattributed,
    required this.changes,
    required this.outcome,
    this.receiverRole,
    this.importCase,
    this.tagsMatchedByLineage = 0,
    this.restored = const [],
    this.deleted = const [],
  });

  /// Projects this run brought back from a server-side restore — see
  /// [ProjectRestoration]. Empty unless the plan was applied.
  final List<RestoredProjectArrival> restored;

  /// Projects this run took from live to deleted, from a server page — see
  /// [ProjectDeletionAnnouncement]. Empty unless the plan was applied.
  final List<ProjectDeletionArrival> deleted;

  /// See [MergeReport.importCase].
  final ImportCase? importCase;

  /// See [MergeReport.tagsMatchedByLineage].
  final int tagsMatchedByLineage;

  final UserRemap remap;
  final int reattributed;
  final List<MergeFieldChange> changes;
  final MergeOutcome outcome;

  /// Only ever set on [MergeOutcome.refusedNotPermitted] — see
  /// [MergeReport.receiverRole] for why a permitted run must not carry one.
  final ProjectRole? receiverRole;
}

/// Result of [ProjectMerger._buildUserRemap]: which incoming user ids remap
/// onto which local ids, and which of those remaps were only possible via a
/// prior-email fallback rather than an exact current-email match — reported
/// distinctly in [MergeReport] so a historical-address match is visible to
/// the user rather than folded silently into an ordinary dedup.
class UserRemap {
  const UserRemap({required this.remap, required this.priorMatched});

  /// `{incomingUserId: localUserId}`, entries only where the id changes.
  final Map<String, String> remap;

  /// The subset of [remap]'s keys resolved via a prior email rather than a
  /// current-current match.
  final Set<String> priorMatched;
}
