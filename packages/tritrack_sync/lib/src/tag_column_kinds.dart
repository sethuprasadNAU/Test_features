import 'schema_constants.dart';
import 'table_columns.dart';

/// What each column of `Tags` means to a **record already taken against that
/// tag** — task 11.32.
///
/// ## The problem this exists to solve
///
/// A bearing names a tag and nothing more, so every field a bearing depends on
/// — the frequency the receiver was tuned to, the name in the field notebook —
/// lives only on the tag row. Edit the tag and every bearing ever recorded
/// against it retroactively claims to have been taken at the new values. Nobody
/// did anything wrong and the dataset now says something false.
///
/// The obvious fix is to copy frequency, pulse rate and name onto the
/// observation. **That is the same defect one size up**: "the fields worth
/// copying" is a hand-maintained list, and it drifts the moment somebody adds a
/// column to `Tags`. That exact pattern has been found four times on this
/// project in two weeks — the stale count of synced tables, the two
/// governing-column lists, task 10.97's seven named text columns, and N-1's
/// three tables.
///
/// So the copy is not a list of fields. It is a **version of the tag**
/// (`Tables.tagVersions`), whose column set is *derived* from this map, and
/// which each observation points at through `Observations.tag_version_id`.
/// Declaring a column [TagColumnKind.measurementContext] here is the whole of
/// what it takes to make it travel with every bearing — nobody has to remember
/// to copy it anywhere.
///
/// ## Why the kind cannot be guessed, and why there is no default
///
/// Colour is the case that proves it. Under a rule that freezes everything,
/// recolouring a tag would redraw last season's bearings in the old colour,
/// which is nobody's intent: colour is a display key a person chooses, not a
/// measurement taken in the field. Freezing it would be exactly as wrong as
/// letting frequency float.
///
/// So the judgement is genuinely per column, and it is not automatable. What
/// *is* automatable is refusing to let somebody skip it —
/// [assertEveryTagColumnDeclaresItsKind] fails when a column of `Tags` has no
/// entry here, and fails again when an entry names a column `Tags` does not
/// have. **An undeclared column fails rather than falling back**, because
/// "current" and "versioned" are each silently wrong about half the columns
/// already in the table. Same discipline as [tableMutationRules] (no default
/// entry), [SyncTable.insertIsAGrant] (required, not defaulted) and task
/// 10.97's text bounds: the judgement cannot be automated, but omitting it can
/// be made impossible.
enum TagColumnKind {
  /// **The tag's identity.** `tag_id` — the thing a version is a version *of*,
  /// carried on the version row as its parent reference rather than as a copy
  /// of a value.
  identity,

  /// **A display key the person chose, never a measurement.** This held
  /// `color_hex` from schema v9 to v15.
  ///
  /// There is no such thing as "the colour it was then". Recolouring is
  /// *meant* to apply everywhere and immediately, including to every record
  /// already drawn on a map, and it must ask the user nothing. A display column
  /// is read live on every read, never frozen onto a version.
  ///
  /// **No `Tags` column declares this since schema v16 (task 11.240)**, and
  /// that is the point of keeping the kind: it was *because* colour is
  /// live-read that moving its home to `Individuals.color_hex` changed where
  /// the value comes from and nothing about how it behaves. Every screen that
  /// drew a collar's colour already read it fresh; it now reads the animal's.
  /// `Tags.color_hex` itself is [retired].
  display,

  /// **Kept on the wire, written as null, read by nothing.** `Tags.color_hex`
  /// since schema v16 (task 11.240).
  ///
  /// Colour moved to the animal — `Individuals.color_hex` — and it has
  /// exactly one home. This column could not simply go: dropping a wire
  /// column is a major bump, and v16 was scoped as additive. So it stays,
  /// nullable, and a v16 writer sends null. **Making it nullable turned out
  /// to be a major bump too** — a v15 device stores it `NOT NULL` and refuses
  /// a null — so task 11.242 spent major 4 on exactly this column, and
  /// `wire_shape_freeze.dart` now refuses the next relaxation before it
  /// ships. Whether to *drop* the column while major 4 is still free is the
  /// planning session's call, recorded in the plan's Discovered Scope. The v16 migration copies every
  /// tag's colour onto the individual it creates for that tag and then nulls
  /// the tag's, on both sides of the wire and in an archive, so that after
  /// v16 no `Tags.color_hex` anywhere holds a value a reader could mistake
  /// for the current one.
  ///
  /// **Not a fallback.** A tag with no individual draws
  /// `TagColorPalette.noIndividual`, a rendering constant, never this column.
  /// `Tag.fromRow` does not read it, and a test recolours an individual and
  /// asserts every tag on it reads the new colour with this column still
  /// null — the mechanism, rather than this sentence.
  retired,

  /// **Context of the measurement itself — versioned.** `frequency_mhz`,
  /// `pulse_rate`, `pulse_pattern`, `tag_name`, and the five pulse-mode
  /// columns task 11.187 added.
  ///
  /// These are what a bearing was *taken against*. A receiver tuned to 148.520
  /// was tuned to 148.520 whatever the tag row says today, and a field notebook
  /// naming "F12" is unmatchable against a dataset that has since renamed the
  /// collar. Every column of this kind becomes a column of
  /// `Tables.tagVersions`, and an edit to one asks the person whether they are
  /// correcting a mistake or recording a change.
  measurementContext,

  /// **A fact about the collar's own life — current state only.** `status`
  /// and `notes`.
  ///
  /// A bearing has no use for its own copy of these. They describe what
  /// happened to the transmitter, not the moment a bearing was taken, and the
  /// only useful answer to "what is the collar's status" is today's. No
  /// per-observation copy, and editing one asks nothing.
  ///
  /// **It held four more columns until schema v17.** `date_put_on`,
  /// `date_removed`, `capture_date` and `individual_id` were never facts
  /// about the collar's life — they were facts about one *deployment* of it,
  /// and task 11.243 moved them to `Tables.deployments`. The tell was that
  /// this kind had to carry a rule about redeployment to stay correct; see
  /// the entries below.
  collarLife,

  /// **Sync and merge bookkeeping**, the six columns every table carries.
  ///
  /// Listed rather than exempted. An exemption is where this project keeps
  /// finding its next problem, and "the sync columns obviously don't count" is
  /// precisely the sentence that would let `last_modified_by` quietly become
  /// the only unclassified column in the table. The version row carries its
  /// own set of these, describing the version's own write — not the tag's.
  bookkeeping,

  /// **Where this copy of the tag came from — recorded, never acted on.**
  /// `lineage_id` and `copied_at`, added by task 11.219 (schema v14).
  ///
  /// Copy-on-add gives each project its own row for a collar, so two projects'
  /// tags are the same physical transmitter exactly when their `lineage_id`
  /// values match. That fact is for a person reading two exported files, or an
  /// analysis in R spanning several seasons. **It is not for the app**, and
  /// this kind is the declaration of that.
  ///
  /// Concretely, a provenance column:
  ///
  /// - is **not** copied onto a `Tables.tagVersions` row — a version records
  ///   what the collar read, and where the row came from is not a measurement;
  /// - is **never** declared in `SyncTable.userColumns`, `tagColumns` or
  ///   `emailColumns`, so nothing computed from it can decide which rows a
  ///   pull or an archive delivers. That is enforced rather than promised —
  ///   see `assertSealedColumnsFeedNoReachability`;
  /// - **renders nowhere.** No screen resolves a lineage into words about
  ///   another project, because there is nothing to resolve: a lineage id
  ///   names no row. That is the whole reason `TAG_COPY_ON_ADD_DESIGN.md`
  ///   §2.3 chose a lineage identifier over a pointer at the source row.
  provenance,
}

/// Every column of `Tables.tags`, and what it means to a record taken against
/// that tag. See [TagColumnKind]; see
/// [assertEveryTagColumnDeclaresItsKind] for what keeps it total.
///
/// **Adding a column to `Tags` means adding it here, and choosing.** There is
/// no default and no fallback, on purpose.
const Map<String, TagColumnKind> tagColumnKinds = {
  'tag_id': TagColumnKind.identity,
  // Task 11.219 (schema v14). A tag now belongs to exactly one project, so the
  // scope is part of what the tag *is* — the same kind `tag_id` carries, and
  // for the same reason: a version row names its parent rather than copying a
  // measurement.
  'project_id': TagColumnKind.identity,
  'frequency_mhz': TagColumnKind.measurementContext,
  'pulse_rate': TagColumnKind.measurementContext,
  // **Retired from the form at task 11.268 (item 6) — kept `measurementContext`
  // here rather than moved to [TagColumnKind.retired], and that is a
  // deliberate departure from the `color_hex` precedent, not an oversight.**
  // Michael: *"Do tags need 'pulse patterns'? We don't use that anywhere?"* —
  // right: no screen displays it and nothing computes with it. But unlike
  // `color_hex`, this column has been versioned since schema v9, so
  // [versionedTagColumnNames] (derived from this map) already puts it on
  // `Tag_Versions`, and `_versionedTagColumns` in `table_columns.dart` derives
  // that table's real schema from the same classification. Reclassifying it
  // as [TagColumnKind.retired] would derive `pulse_pattern` off
  // `Tag_Versions` entirely — a column the SQLite and Postgres migrations
  // still build — which `schema_matches_shared_spec_test.dart` would then
  // catch as a mismatch only a migration can fix. That is the schema-major
  // bump the plan says not to spend on a field nobody reads. So: the kind is
  // unchanged, the column keeps accumulating (null) history exactly as any
  // other `measurementContext` column does, and the actual retirement lives
  // one layer up, in `tag_form.dart`: the field is off the form and every
  // write sends null.
  'pulse_pattern': TagColumnKind.measurementContext,
  'tag_name': TagColumnKind.measurementContext,
  // `date_put_on`, `date_removed` and `capture_date` were `collarLife` here
  // until schema v17 (task 11.243). They were never facts about the
  // *collar's* life — they were facts about one deployment of it — and that
  // is where they live now. `Tables.deployments` carries no kinds of its own
  // because nothing is ever recorded *against* a deployment: a bearing names
  // a tag, and the animal is derived by interval afterwards.
  'status': TagColumnKind.collarLife,
  'notes': TagColumnKind.collarLife,
  // Task 11.240 (schema v16). Held `TagColumnKind.display` from v9 to v15;
  // colour is the animal's now and lives on `Individuals.color_hex`. See
  // [TagColumnKind.retired] for why the column is still here at all.
  'color_hex': TagColumnKind.retired,
  // Task 11.187. **Every one of these is measurement context, and the reason
  // is the one `pulse_rate` already had**: a bearing was heard on a mode with
  // a name and a rate, and renaming or re-timing that mode afterwards must not
  // rewrite what the bearing says it was. `assertPulseModeColumnsAreVersioned`
  // is what stops a later slot being added as anything else.
  'pulse_mode_1_name': TagColumnKind.measurementContext,
  'pulse_mode_2_name': TagColumnKind.measurementContext,
  'pulse_mode_2_rate_bpm': TagColumnKind.measurementContext,
  'pulse_mode_3_name': TagColumnKind.measurementContext,
  'pulse_mode_3_rate_bpm': TagColumnKind.measurementContext,
  // Task 11.219 (schema v14): where this copy came from. See
  // [TagColumnKind.provenance] — recorded, exported, and read by nothing live.
  'lineage_id': TagColumnKind.provenance,
  'copied_at': TagColumnKind.provenance,
  // **`individual_id` was here for one schema version and its removal is the
  // point of task 11.243.** At v16 it was `collarLife`, and that was only
  // safe under a rule of Michael's from 2026-09-13 — *a refurbished collar
  // redeployed on a different animal gets a NEW `Tags` row* — because a
  // current-state column applies a correction to every bearing the row ever
  // took. Break that rule and one edit silently rewrites who every past
  // bearing was about.
  //
  // **Nothing in the schema could enforce that rule, and the rule itself was
  // withdrawn a day later** (design §2): a second inventory row for a collar
  // the project already owns makes the equipment list false. The link is a
  // dated row now, so the case the kind was anxious about — a collar moving
  // between animals — is expressed rather than prohibited, and a correction
  // re-attributes exactly the window corrected.

  // The six global sync/merge columns (`syncColumns`).
  'created_at': TagColumnKind.bookkeeping,
  'updated_at': TagColumnKind.bookkeeping,
  'deleted_at': TagColumnKind.bookkeeping,
  'revision': TagColumnKind.bookkeeping,
  'last_modified_by': TagColumnKind.bookkeeping,
  'origin_device_id': TagColumnKind.bookkeeping,
};

/// The `Tags` columns a record carries its own historical copy of — the ones
/// `Tables.tagVersions` is built from, and the ones whose edit raises the
/// correction-or-change question.
///
/// Derived from [tagColumnKinds] rather than written out, which is the whole
/// point: this is the list that would otherwise go stale.
Set<String> get versionedTagColumnNames => {
  for (final entry in tagColumnKinds.entries)
    if (entry.value == TagColumnKind.measurementContext) entry.key,
};

/// Throws unless [tagColumnKinds] classifies **exactly** the columns
/// `Tables.tags` declares — every one of them, and nothing else.
///
/// Called from tests on both sides of the wire, like
/// [assertEveryTableHasAMutationRule]. It fails in both directions on purpose:
///
/// - **An undeclared column** is the failure this whole mechanism exists for. A
///   new tag column with no kind is a field that is either silently frozen into
///   history or silently rewritten by every edit, and which of those is wrong
///   depends entirely on what the column means.
/// - **A declared column `Tags` does not have** means the schema moved and this
///   map did not. A stale entry naming a dropped column is how a derived list
///   quietly becomes a hand-kept one again — and if the stale entry is a
///   `measurementContext` one, `Tables.tagVersions` grows a column of a
///   deleted field.
///
/// [tagColumns] exists so a test can hand it a deliberately doctored column
/// list and watch it throw. An assertion nobody has seen fail is an assertion
/// nobody knows works, which is the shape eight consecutive security gates kept
/// finding in this project's own instruments.
void assertEveryTagColumnDeclaresItsKind({List<ColumnSpec>? tagColumns}) {
  final columns = tagColumns ?? tableSpecsByName[Tables.tags]!.columns;
  final declared = tagColumnKinds.keys.toSet();
  final actual = {for (final c in columns) c.name};

  final undeclared = [
    for (final c in columns)
      if (!declared.contains(c.name)) c.name,
  ];
  final stale = [
    for (final name in tagColumnKinds.keys)
      if (!actual.contains(name)) name,
  ];

  if (undeclared.isNotEmpty) {
    throw StateError(
      'Tag column(s) with no declared kind: ${undeclared.join(', ')}. Every '
      'column of ${Tables.tags} must say what it means to a record already '
      'taken against that tag — add an entry to tagColumnKinds. There is no '
      'default: TagColumnKind.display and TagColumnKind.measurementContext are '
      'each silently wrong about half the columns already in this table, so a '
      'column that does not choose is a column whose history is wrong one way '
      'or the other. See tag_column_kinds.dart.',
    );
  }
  if (stale.isNotEmpty) {
    throw StateError(
      'tagColumnKinds declares column(s) ${Tables.tags} does not have: '
      '${stale.join(', ')}. The schema moved and this map did not — a stale '
      'measurementContext entry puts a column for a deleted field on '
      '${Tables.tagVersions}.',
    );
  }
}
