import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../../core/text/role_labels.dart';

import '../models/sync_meta.dart';
import '../models/tag.dart';
import '../models/tag_draft.dart';
import '../models/tag_fields.dart';
import '../models/tag_library_entry.dart';
import 'base_repository.dart';
import 'deployment_repository.dart';
import 'individual_repository.dart';
import 'mutation_authorization.dart';
import 'tag_library_repository.dart';
import 'tag_version_repository.dart';

/// **Who may create, edit, and retire a project's tag (task 11.11, rewritten
/// by 11.219).**
///
/// ## What changed, and what did not
///
/// `Tags` used to be a **global** table: one row per collar, linked to
/// projects through `Project_Tags`, and therefore outside the role gradient
/// [BaseRepository.insertRow] applies everywhere else — there was no
/// `project_id` to resolve a role against. That is what made this class carry
/// its own rules and what made [assertMayEdit] walk *every project the tag
/// belongs to*.
///
/// Since task 11.219 a tag belongs to exactly one project, so this is an
/// ordinary project-scoped table and the gradient applies to it like any
/// other. **The asymmetry survives, because it was never about globality:**
///
/// - **Creating is open to contributors.** Restricting creation to owners
///   looks like it would prevent duplicates and does not — two owners, each
///   offline, each adding "F12" for the same collar, collide exactly as an
///   owner and a contributor would. The duplicate comes from working offline,
///   not from who may write. Meanwhile a field tech on a transect with no
///   signal who hears an unlisted collar and cannot create a tag **cannot
///   record the observation at all**, which trades a tidiness problem for
///   permanent data loss on the app's primary use case. A `viewer` still
///   creates nothing, per 11.3's gradient with no exception.
/// - **Editing and retiring is owners only.** Creating a tag is additive and
///   recoverable; changing an existing one changes what it *means* to every
///   observation already pointing at it, and those cannot be re-recorded.
///
/// Near-duplicates that get created anyway are warned about at the point of
/// creation (`NearDuplicateTags`). Nothing here refuses one.
///
/// **Advisory, as everywhere on this side of the wire.** The boundary is
/// `RowAuthorizer._authorizeTagLifecycle` on the server, which makes the same
/// two decisions against rows arriving from an untrusted device.
class TagRepository extends BaseRepository {
  TagRepository(super.db)
    : super(
        table: Tables.tags,
        pk: const ['tag_id', 'project_id'],
        rule: MutationRule.anyUser,
      );

  static const _uuid = Uuid();

  /// Creates a tag inside [Tag.projectId].
  ///
  /// The project is read off the row rather than passed beside it — it is
  /// half the key now, not a separate fact — and the role gradient in
  /// [BaseRepository.insertRow] resolves against it, so a `viewer` is refused
  /// here rather than one write too late.
  ///
  /// **Writes the tag's first `Tag_Versions` row too (task 11.32)**, so every
  /// record taken against it from now on can point at what the tag read when
  /// the record was made. It is done here rather than at the tag-creation
  /// call sites — the tag dialog, the record screen's quick-add, the
  /// pasted-share screen and the spreadsheet import — because four call sites
  /// is four places to forget, and a tag created without a version silently
  /// gives every bearing on it a null measurement context forever.
  ///
  /// **And records the collar in this device's tag library, for the same
  /// reason** (task 11.219). A person who creates a collar straight into a
  /// project still owns that collar, and a library that only knew about tags
  /// created *in* it would be empty for everybody who never used it — which
  /// would make "copy from your library" an option nobody could ever take.
  /// The entry carries the tag's own [Tag.lineageId], which is what later
  /// makes the two recognisable as one transmitter.
  ///
  /// Pass `recordInLibrary: false` where the collar is somebody else's — the
  /// paste screen's relabelling of an incoming record is the case — so that
  /// importing a colleague's bearing does not quietly claim their equipment.
  ///
  /// The version is stamped from the tag row's own sync metadata rather than
  /// from a fresh clock, so the tag and its first version agree about when
  /// they came into existence even when the caller is replaying an older
  /// `now`.
  ///
  /// **It no longer invents an animal, and that is task 11.243's change.**
  /// Task 11.240 gave every newly-created tag a new `Individuals` row named
  /// after the collar, because a `Tags` row was then a *deployment* with a
  /// `NOT NULL` date — so there was, by construction, an animal. A tag is a
  /// piece of equipment now: **a collar with no animal is the normal
  /// starting state, not an exception** (design §1), and anything that
  /// invents one for it has the model backwards. Linking a collar to an
  /// animal is a deliberate act and writes a `Deployments` row
  /// (`DeploymentRepository.link`, and the screen task 11.244 builds).
  ///
  /// A tag created this way therefore draws in
  /// [TagColorPalette.noIndividual] until somebody says whose it is.
  ///
  /// Returns the tag as stored, which is the argument unchanged. The return
  /// value is kept so the call sites — four of them — do not all have to
  /// change again when they are next touched.
  Future<Tag> insert(Tag tag, {bool recordInLibrary = true}) async {
    await insertRow(tag.toColumns());
    await TagVersionRepository(db).createInitialVersion(
      tag,
      now: tag.sync.createdAt,
      modifiedBy: tag.sync.lastModifiedBy,
      deviceId: tag.sync.originDeviceId,
    );
    if (!recordInLibrary) return tag;
    final library = TagLibraryRepository(db);
    if (await library.findByLineage(tag.lineageId) != null) return tag;
    await library.insert(TagLibraryEntry.of(tag, tagId: _uuid.v4()));
    return tag;
  }

  /// Copies [entry] out of this device's tag library and into [projectId],
  /// returning the project's own new tag.
  ///
  /// **This is the whole of copy-on-add** and the reason task 11.219 exists.
  /// The new row takes a fresh `tag_id` and keeps the library entry's
  /// [Tag.lineageId], so:
  ///
  /// - editing the project's tag changes neither the library entry nor any
  ///   other project's copy, which is what Michael decided on 2026-08-22;
  /// - the two are still recognisable as one physical collar in an export,
  ///   by an equal lineage and by nothing else;
  /// - and the project's row names nothing outside the project, so no message
  ///   about a tag can reveal that another project exists.
  ///
  /// [copiedAt] is stamped, because this copy genuinely was made now. That is
  /// the one case where `copied_at` is not null.
  ///
  /// [tagId] is minted here unless the caller already needs it — task
  /// 11.321's one-step link plans the deployment before the copy exists. It
  /// must be fresh, for the reason [TagLibraryEntry.copyInto] gives.
  Future<Tag> copyFromLibrary(
    TagLibraryEntry entry, {
    required String projectId,
    required String modifiedBy,
    String? deviceId,
    DateTime? now,
    String? tagId,
  }) async {
    final at = now ?? DateTime.now();
    final tag = entry.copyInto(
      projectId,
      tagId: tagId ?? _uuid.v4(),
      copiedAt: at,
      sync: SyncMeta.initial(
        now: at,
        modifiedBy: modifiedBy,
        originDeviceId: deviceId,
      ),
    );
    // `recordInLibrary: false`: the library entry this came from is already
    // there, and re-recording it would be the second half of a duplicate.
    //
    // **No animal is created** (task 11.243). A collar copied into a project
    // is a collar that project now owns, not a collar that is on something;
    // whose it is is a separate act. The library entry's colour is dropped on
    // the floor here, which it was not at v16 — see `TagLibraryEntry.colorHex`
    // for the seed it used to be. Task 11.244 decides whether the linking
    // screen offers it as the new animal's starting colour.
    await insertRow(tag.toColumns());
    await TagVersionRepository(db).createInitialVersion(
      tag,
      now: at,
      modifiedBy: modifiedBy,
      deviceId: deviceId,
    );
    return tag;
  }

  // `nextColorHex` and `tagCount` used to live here. Colour is the animal's
  // since task 11.240, so the round-robin is `IndividualRepository
  // .nextColorHex` and counts animals rather than collars.

  /// **Every read of a tag goes through this join** (task 11.240, re-routed
  /// by 11.243): the collar's colour and the animal's name come from the
  /// animal of its **current deployment**, aliased so `Tag.fromRow` cannot
  /// confuse the colour with the retired `Tags.color_hex`.
  ///
  /// ## Which animal, when a collar can have had several
  ///
  /// The animal of the collar's **most recent** deployment — and since task
  /// 11.251 that is `DeploymentRepository.latestDeploymentsSubquery`, the
  /// same text `latestAnimalForTag` runs, embedded here rather than
  /// re-typed. The reasoning — why most recent rather than still-on, why the
  /// tie on `attached_date` breaks on `created_at` (Michael found the join
  /// and the Dart walk both wrong on a same-day reassignment, 2026-09-14),
  /// why a correlated `NOT EXISTS` and no window function — lives on that
  /// subquery. In short: this answers *"whose collar is this"*, which is
  /// what a list of equipment needs and has no timestamp to be asked with;
  /// *"which animal was this bearing about"* is a different question, takes
  /// a timestamp, and is `DeploymentRepository.animalForObservationIn`.
  ///
  /// A collar nobody has ever linked reads [TagColorPalette.noIndividual] and
  /// no animal name — **the normal starting state for a piece of equipment**
  /// (design §1), not a gap. **Since task 11.258 a collar whose only
  /// deployment names a tombstoned animal reads the same way** —
  /// `latestDeploymentsSubquery` will not name a dead row's colour or name,
  /// which used to leak here (and onto the Record wheel's grouping,
  /// `Tag.individualName ?? Tag.tagName`) until it was fixed.
  ///
  /// The subquery picks one deployment per collar, so this returns exactly
  /// one row per tag however many deployments a sync delivers. Reproduced in
  /// `tag_repository_test.dart`.
  ///
  /// [where] is AND-combined with the tombstone filter on the **tag**; the
  /// caller's columns are unqualified and resolve against `t` because every
  /// column name it uses is a tag column.
  Future<List<Map<String, Object?>>> _tagRows({
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    bool includeDeleted = false,
  }) {
    final clauses = <String>[
      if (!includeDeleted) 't.deleted_at IS NULL',
      if (where != null) '($where)',
    ];
    return db.rawQuery(
      'SELECT t.*, i.color_hex AS ${Tag.individualColorColumn}, '
      'i.name AS ${Tag.individualNameColumn} '
      'FROM ${Tables.tags} t '
      'LEFT JOIN (${DeploymentRepository.latestDeploymentsSubquery}) d '
      'ON d.tag_id = t.tag_id AND d.project_id = t.project_id '
      'LEFT JOIN ${Tables.individuals} i '
      'ON i.individual_id = d.individual_id AND i.project_id = d.project_id'
      '${clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}'}'
      '${orderBy == null ? '' : ' ORDER BY $orderBy'}',
      whereArgs,
    );
  }

  /// A tag by its id *within a project* — since task 11.219 the id alone
  /// identifies a row only there, exactly as an `observation_id` has since
  /// task 10.35. Two projects' copies of one collar have different ids, but
  /// an id arriving from an archive may legitimately exist in two projects.
  Future<Tag?> findById(
    String id, {
    required String projectId,
    bool includeDeleted = false,
  }) async {
    final rows = await _tagRows(
      where: 't.tag_id = ? AND t.project_id = ?',
      whereArgs: [id, projectId],
      includeDeleted: includeDeleted,
    );
    return rows.isEmpty ? null : Tag.fromRow(rows.first);
  }

  /// "Marie's collars" — every tag in [projectId] the animal [individualId]
  /// has ever worn, oldest deployment first.
  ///
  /// **It reads `Deployments` now** (task 11.243). The column it used to read
  /// is gone, and with it the thing that made this query wrong for a
  /// redeployed collar: a collar worn by two animals in turn appears under
  /// both, once per deployment, which is what actually happened.
  ///
  /// Tombstoned tags are included by default: a collar removed from the
  /// project was still worn by the animal, and a list of what she has worn
  /// that silently omits the retired ones is a false history.
  ///
  /// `setIndividual` — the owner-only door this class used to carry for
  /// `Tags.individual_id` — is gone with the column. Linking is
  /// `DeploymentRepository.link` and is a contributor's act; see
  /// `tableMutationRules` for why that rung moved.
  Future<List<Tag>> findByIndividual(
    String individualId, {
    required String projectId,
    bool includeDeleted = true,
  }) async {
    final rows = await _tagRows(
      where:
          't.tag_id IN (SELECT tag_id FROM ${Tables.deployments} '
          'WHERE individual_id = ? AND project_id = ? AND deleted_at IS NULL) '
          'AND t.project_id = ?',
      whereArgs: [individualId, projectId, projectId],
      includeDeleted: includeDeleted,
      orderBy: 't.frequency_mhz, t.tag_name',
    );
    return rows.map(Tag.fromRow).toList();
  }

  /// Every tag in one project.
  Future<List<Tag>> findByProject(
    String projectId, {
    bool includeDeleted = false,
  }) async {
    final rows = await _tagRows(
      where: 't.project_id = ?',
      whereArgs: [projectId],
      includeDeleted: includeDeleted,
      orderBy: 't.frequency_mhz, t.tag_name',
    );
    return rows.map(Tag.fromRow).toList();
  }

  /// Every tag row on this device, across every project it holds.
  ///
  /// **Four screens used to read this and mean four different things.** Since
  /// task 11.219 the honest answer to "what transmitters do I have" is the
  /// tag *library* ([TagLibraryRepository.findAll]), not this — a device
  /// holding one collar in three projects has three rows here and one there.
  /// What is left for this is the small set of places that genuinely need
  /// every project's rows at once: the CSV export of everything, and tests.
  Future<List<Tag>> findAll({bool includeDeleted = false}) async {
    final rows = await _tagRows(
      includeDeleted: includeDeleted,
      orderBy: 't.frequency_mhz, t.tag_name',
    );
    return rows.map(Tag.fromRow).toList();
  }

  /// Every project's copy of the collar [lineageId] identifies — what
  /// [pushToProjects] (task 11.250) reads to find what to update.
  ///
  /// **Reading a lineage here is permitted**, on the same terms
  /// `TagLibraryRepository.otherProjectCopyCount` already reads one: this is
  /// a device-local lookup among this device's own rows, not a decision
  /// about which rows travel. `assertSealedColumnsFeedNoReachability`
  /// governs the second thing, not the first.
  Future<List<Tag>> findByLineage(
    String lineageId, {
    bool includeDeleted = false,
  }) async {
    final rows = await _tagRows(
      where: 't.lineage_id = ?',
      whereArgs: [lineageId],
      includeDeleted: includeDeleted,
      orderBy: 't.frequency_mhz, t.tag_name',
    );
    return rows.map(Tag.fromRow).toList();
  }

  /// Whether a library edit from [before] to [after] would change anything
  /// [pushToProjects] writes — task 11.250.
  ///
  /// **Exactly the fields [TagColumnKind.measurementContext] and
  /// [TagColumnKind.collarLife] declare**, which is exactly what
  /// `TagDraft.onto` writes and [pushToProjects] pushes. Colour and identity
  /// are excluded on purpose: neither travels through the push.
  static bool libraryEditChangedPushableFields(
    TagFields before,
    TagFields after,
  ) =>
      before.frequencyMhz != after.frequencyMhz ||
      before.pulseRate != after.pulseRate ||
      before.pulsePattern != after.pulsePattern ||
      before.tagName != after.tagName ||
      before.status != after.status ||
      before.notes != after.notes ||
      before.pulseMode1Name != after.pulseMode1Name ||
      before.pulseMode2Name != after.pulseMode2Name ||
      before.pulseMode2RateBpm != after.pulseMode2RateBpm ||
      before.pulseMode3Name != after.pulseMode3Name ||
      before.pulseMode3RateBpm != after.pulseMode3RateBpm;

  /// **The one route that fixes a library edit everywhere — task 11.250.**
  ///
  /// A library edit reaches no project by construction
  /// (`TagLibraryRepository.update`'s own doc comment says so), which means a
  /// typo has to be corrected once per project plus once in the library. This
  /// is the action the tag form offers instead: apply [entry]'s current
  /// values to every project's copy of the same collar, in one push.
  ///
  /// **[intent] is asked once by the caller, not once per project.**
  /// Correcting a typo or recording a drift is a statement about the
  /// physical transmitter, so the answer is the same for every copy of it.
  /// It is passed straight through to [update] for each row — pass null only
  /// when the caller has determined the question does not apply to *any* of
  /// [entry]'s copies (see [libraryEditChangedPushableFields] and
  /// [TagVersionRepository.versionedFieldsChanged]). A row [update] decides
  /// still needed one throws [StateError], same as any other caller that
  /// skipped the question.
  ///
  /// **A project [actor] may not write to is refused, not skipped.** The
  /// owner-only rule on a project's tag ([assertMayEdit]) still applies here
  /// unchanged; a row that throws [UnauthorizedMutation] is counted rather
  /// than left silently unwritten. A push that quietly updated three of four
  /// copies would be worse than one that updated none.
  ///
  /// **Each project keeps its own `Tag_Versions` chain.** This calls [update]
  /// once per row, which is what writes that project's own version — the
  /// chains are never collapsed, which is copy-on-add applied to history.
  ///
  /// **Colour is not pushed.** `Tags.color_hex` is
  /// [TagColumnKind.retired] — read by nothing — and [update] moves an
  /// *individual's* colour whenever the tag it is given carries a different
  /// one than the row being replaced. Building the pushed row from [entry]'s
  /// colour would risk exactly that unintended move, so every row keeps its
  /// own [Tag.colorHex] untouched.
  Future<TagLibraryPushResult> pushToProjects(
    TagLibraryEntry entry, {
    required TagEditIntent? intent,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    final targets = await findByLineage(entry.lineageId);
    var updated = 0;
    var refused = 0;
    for (final tag in targets) {
      final edited = TagDraft.of(entry).onto(tag).copyWith(colorHex: tag.colorHex);
      try {
        await update(
          edited,
          actor: actor,
          intent: intent,
          deviceId: deviceId,
          now: at,
        );
        updated++;
      } on UnauthorizedMutation {
        refused++;
      }
    }
    return (updated: updated, refused: refused);
  }

  /// Edits a tag — including retiring it, which is a change to `status` and so
  /// arrives here like any other.
  ///
  /// Throws [UnauthorizedMutation] unless [actor] owns the project this tag
  /// belongs to. See [assertMayEdit].
  ///
  /// ## [intent] — what the person meant, which only they know (task 11.32)
  ///
  /// Editing a frequency because the transmitter drifted and editing it
  /// because it was typed in wrong are byte-identical edits with opposite
  /// correct answers for every bearing already recorded. So the caller must
  /// state which it is, and the parameter is **required** so that no screen
  /// can edit a tag without having decided.
  ///
  /// Pass **null** when nothing versioned moved — a recolour, a status change,
  /// an edited note. That is the common case and it must ask the person
  /// nothing; use [TagVersionRepository.versionedFieldsChanged] to find out
  /// before opening a dialog. Passing null when a versioned field *did* move
  /// throws rather than picking a side.
  ///
  /// The tag row is written first and the version consequence second, both
  /// inside whatever transaction the caller supplies. If a screen needs the
  /// two to be atomic — and the tag dialog does — it must hand this repository
  /// a transaction, exactly as `TagCsvCommit` does for a batch.
  ///
  /// ## This reaches no library entry, and that is deliberate (task 11.250)
  ///
  /// A project's tag is edited here alone; nothing here writes back to
  /// `Tag_Library`. That is the mirror of
  /// `TagLibraryRepository.update`'s own comment — a library edit reaches no
  /// project — and it is the same choice for the same reason: the library is
  /// one person's own record of their own equipment, and a teammate editing
  /// a project's copy should not silently rewrite it. The one route that
  /// moves a change the other way, library to project, is
  /// [pushToProjects], and it is always offered, never automatic.
  Future<int> update(
    Tag tag, {
    required MutationActor actor,
    required TagEditIntent? intent,
    String? deviceId,
    DateTime? now,
  }) async {
    await assertMayEdit(tag.projectId, actor);
    final before = await findById(
      tag.tagId,
      projectId: tag.projectId,
      includeDeleted: true,
    );
    final at = now ?? DateTime.now();
    // **The `..remove('individual_id')` that stood here is gone with the
    // column** (task 11.243). It existed because a `Tag` object held from
    // before the row was linked carried a null, and writing it would have
    // silently unlinked the collar. `Tag` cannot express that fact at all
    // now, so the hazard is structural rather than remembered — which is the
    // stronger version of the same guarantee.
    final changed = await updateByKey(
      {'tag_id': tag.tagId, 'project_id': tag.projectId},
      tag.toColumns(),
      actor: actor,
      deviceId: deviceId,
      now: at,
    );
    // A tag this device does not hold cannot have a history to record; the
    // update above changed nothing either.
    if (before != null) {
      await TagVersionRepository(db).recordEdit(
        tag,
        before: before,
        intent: intent,
        now: at,
        modifiedBy: actor.userId,
        deviceId: deviceId,
      );
      // Colour is the animal's (task 11.240). A tag edit that moved the
      // colour is an edit to the individual, and it lands there — which
      // recolours every collar the animal has worn, on purpose. The write
      // above put nothing in `Tags.color_hex`; `Tag.toColumns` sends null.
      //
      // **The animal is the one whose collar this is** (task 11.243), read
      // from `Deployments` rather than from a column on the tag — the same
      // animal the read join above showed the person the colour of, which is
      // the one they were editing. A collar nobody has linked has no colour
      // to move and the edit is a no-op: there is no animal for the person to
      // have been recolouring.
      final individualId = await DeploymentRepository(
        db,
      ).latestAnimalForTag(tag.tagId, projectId: tag.projectId);
      if (individualId != null && tag.colorHex != before.colorHex) {
        final individuals = IndividualRepository(db);
        final individual = await individuals.findById(
          individualId,
          projectId: tag.projectId,
          includeDeleted: true,
        );
        if (individual != null && individual.colorHex != tag.colorHex) {
          await individuals.update(
            individual.copyWith(colorHex: tag.colorHex),
            actor: actor,
            deviceId: deviceId,
            now: at,
          );
        }
      }
    }
    return changed;
  }

  /// Takes [tagId] out of [projectId] — the operation that used to
  /// deactivate a `Project_Tags` link.
  ///
  /// ## What "remove from project" means now, and why it is a tombstone
  ///
  /// Task 11.219 retired the link table, so there is no link status left to
  /// set. What a project holds is its **own tag row**, and taking the collar
  /// out of the project's pickers is a soft delete of that row — never a
  /// hard one. The row stays, so:
  ///
  /// - every bearing, session, estimate and truth point that names it still
  ///   resolves, and its foreign key still holds;
  /// - the Log, the map and the exports still say what those records were
  ///   taken against;
  /// - and it can be put back ([restoreToProject]), which is what the undo
  ///   on the confirmation bar does.
  ///
  /// **Owner-only, unchanged in substance since task 11.24.** Removing a tag
  /// edits shared project configuration every member sees, and a
  /// contributor's device once pushed a removal directly and the tag
  /// disappeared for the whole team. Creating a tag is contributor-level;
  /// removing one, and putting one back, are not (see [restoreToProject]).
  Future<int> removeFromProject(
    String tagId, {
    required String projectId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    await assertMayEdit(projectId, actor);
    return softDeleteByKey(
      {'tag_id': tagId, 'project_id': projectId},
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Puts a removed tag back into its project — the undo of
  /// [removeFromProject].
  ///
  /// **Owner-only, like the removal it undoes.** This used to be
  /// contributor-level, and the asymmetry between adding and removing was a
  /// decision (task 11.12, 2026-08-21): adding was additive and unblocking,
  /// removing edited what every member sees. **Task 11.219 moved the
  /// asymmetry.** With the link table gone, the tag *is* the project's row,
  /// and the server's `RowAuthorizer` reserves every change to an existing
  /// tag for an owner — clearing a tombstone is a change. The line now runs
  /// between *creating* a tag (contributor) and *changing* one (owner), not
  /// between add and remove. Michael confirmed that as the wanted rule on
  /// 2026-09-10 (task 11.221): contributors add new collars, owners change
  /// existing ones, and a contributor who needs a removed collar back creates
  /// a new record for it — the near-duplicate warning tells them it resembles
  /// one the project already has.
  ///
  /// The local check is the point: without it a contributor's put-back lands
  /// on the phone and is refused at the next push, minutes later, offline,
  /// with no explanation.
  Future<int> restoreToProject(
    String tagId, {
    required String projectId,
    required MutationActor actor,
    String? deviceId,
    DateTime? now,
  }) async {
    await assertMayEdit(projectId, actor);
    return restoreByKey(
      {'tag_id': tagId, 'project_id': projectId},
      actor: actor,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Whether editing [before] into [after] would change what earlier records
  /// were taken against — i.e. whether the edit screen must ask the
  /// correction-or-change question at all.
  ///
  /// Re-exported here so a screen holding a [TagRepository] does not have to
  /// reach for a second repository just to decide whether to show a dialog.
  static bool versionedFieldsChanged(Tag before, Tag after) =>
      TagVersionRepository.versionedFieldsChanged(before, after);

  /// Throws [UnauthorizedMutation] unless [actor] may change tags in
  /// [projectId] — the owner-only half of task 11.11, asked before a write
  /// and exposed so a screen can ask it before offering one.
  ///
  /// ## It used to walk every project the tag belonged to
  ///
  /// It had to: a tag was global, so "who owns this tag" had no single
  /// answer, and the old rule was *"owner of any one of the projects that
  /// link it, and a tag nobody links is nobody's."* Both halves are gone with
  /// the model that needed them. A tag has one project; that project's owner
  /// decides; a tag with no project is not a `Tags` row at all, it is a
  /// library entry, and the library is device-local so no role governs it.
  ///
  /// **What survives is the deferral rule**, for the same reason
  /// [BaseRepository.assertRoleMayWrite] states — and narrowed the same way by
  /// task 11.237: this SQLite file legitimately holds projects the device has
  /// no membership row for, and where it has nothing to answer with it
  /// defers to the server. Where it can see the person is not on the project
  /// at all, it refuses with the one shared snapshot refusal.
  Future<void> assertMayEdit(String projectId, MutationActor actor) async {
    if (actor.isReplication) return;
    final standing = await projectStandingFor(projectId, actor.userId);
    switch (standing) {
      case UnknownStanding():
        return;
      case NotAMemberStanding():
        throw UnauthorizedMutation.notAMember(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
        );
      case MemberStanding(:final role):
        if (role == ProjectRole.owner) return;
        throw UnauthorizedMutation(
          table: table,
          rowId: projectId,
          rule: rule,
          actorUserId: actor.userId,
          permitted:
              'an owner of this project (you are ${role.withArticle})',
        );
    }
  }
}

/// What [TagRepository.pushToProjects] did — task 11.250.
///
/// **Both counted, never one silently folded into the other.** A push that
/// updated three of four copies and said nothing about the fourth would be
/// worse than one that changed nothing at all.
typedef TagLibraryPushResult = ({int updated, int refused});
