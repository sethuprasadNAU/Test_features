import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../models/observation.dart';
import '../models/sync_meta.dart';
import '../models/tag.dart';
import '../models/tag_version.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

/// What a person means by a tag edit — task 11.32.
///
/// **The app cannot tell these apart, and it must not guess.** Editing a
/// frequency because the transmitter drifted and editing it because it was
/// typed in wrong produce byte-identical edits and opposite correct answers, so
/// the only place the answer exists is the person doing it.
///
/// This is deliberately the same question, in the same shape, as the
/// supersede-versus-overwrite decision already taken for observations, and it
/// should read the same way on screen.
///
/// **There is no default value here on purpose.** Drift and typo are both
/// common, so either default is silently wrong a good share of the time — and
/// silence is the whole harm this task exists to fix. The caller must supply
/// one; see [TagEditIntent.prompt] for the copy the screens use.
enum TagEditIntent {
  /// *"Fixing a mistake — update every record."*
  ///
  /// The stored value was never true. The current version is rewritten in
  /// place, so every record taken since that value took effect now reads the
  /// corrected one. **Earlier versions are untouched** — a correction to
  /// today's frequency says nothing about a genuine change six weeks ago, and
  /// flattening the two would destroy the drift record.
  correction,

  /// *"It changed — leave earlier records as they were."*
  ///
  /// A new version is appended, effective now. Existing records keep pointing
  /// at the version they were taken against; records made from here on point at
  /// the new one. The difference between the two **is** the drift record.
  change;

  /// The wording the edit screen offers, so the two call sites cannot drift
  /// into asking the same question two different ways.
  String get prompt => switch (this) {
    TagEditIntent.correction => 'Fixing a mistake — update every record',
    TagEditIntent.change => 'It changed — leave earlier records as they were',
  };

  /// The one-line consequence shown under [prompt].
  String get consequence => switch (this) {
    TagEditIntent.correction =>
      'Records already taken against this tag will show the corrected value. '
          'Use this when the old value was simply wrong.',
    TagEditIntent.change =>
      'Records already taken keep the old value. Use this when the tag itself '
          'changed — a transmitter that drifted, or a re-tagged animal.',
  };
}

/// Reads and writes `Tag_Versions` — what a tag read at the moment a record was
/// taken (task 11.32).
///
/// ## The two reads this repository keeps apart, permanently
///
/// - [recordedStateOf] answers *"what was this bearing recorded against?"* by
///   resolving the observation's `tag_version_id`.
/// - `TagRepository.findById` answers *"what is this tag now?"*.
///
/// **Nothing here reconciles them**, and nothing added later should. A tag
/// reading one frequency for six weeks and another afterwards is a drift record
/// and is scientifically more useful than a tag row that only remembers today.
///
/// ## Authorization
///
/// A version row is governed exactly as the tag it versions is: creating one is
/// part of creating or editing a tag, and this repository is only ever called
/// from inside those operations, after `TagRepository`'s own checks have run.
/// It carries no second gate of its own for the same reason
/// `ProjectTagRepository` does not re-ask what `TagRepository` just asked —
/// two copies of one rule is how they drift. The boundary is
/// `RowAuthorizer._authorizeTagReferences`, which reaches a `Tag_Versions` row
/// through its `tag_id` exactly as it reaches the `Tags` row.
class TagVersionRepository extends BaseRepository {
  TagVersionRepository(super.db)
    : super(
        table: Tables.tagVersions,
        pk: const ['tag_version_id'],
        rule: MutationRule.anyUser,
      );

  static const _uuid = Uuid();

  Future<TagVersion?> findById(String id, {bool includeDeleted = false}) async {
    final row = await findRowById(id, includeDeleted: includeDeleted);
    return row == null ? null : TagVersion.fromRow(row);
  }

  /// The version [tagId] currently reads at — the one a record taken *now*
  /// should point at — or null if the tag has none yet.
  ///
  /// Null is an ordinary answer, not an error. Tags created before schema v9
  /// have no versions and none is invented for them (see the migration's
  /// third deliberate absence); their first version is written the next time
  /// somebody edits the tag.
  ///
  /// Ordered by `effective_from` and then `created_at`, because two versions
  /// can legitimately share an effective moment after a merge, and "the latest"
  /// has to be a total order rather than an arbitrary one.
  Future<TagVersion?> currentFor(String tagId) async {
    final rows = await findRows(
      where: 'tag_id = ?',
      whereArgs: [tagId],
      orderBy: 'effective_from DESC, created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : TagVersion.fromRow(rows.first);
  }

  /// The `tag_version_id` a record being written right now should carry, or
  /// null if [tagId] has no version.
  ///
  /// **Null is written as null.** Nothing here mints a version to fill the gap:
  /// a record whose tag has no history genuinely does not know what the tag
  /// read, and inventing an answer is the falsehood this task removes.
  Future<String?> currentVersionIdFor(String? tagId) async {
    if (tagId == null || tagId.isEmpty) return null;
    return (await currentFor(tagId))?.tagVersionId;
  }

  /// Writes [tag]'s **first** version, the one every record taken against it
  /// from now on points at. Called from each of the four tag-creation paths.
  ///
  /// `effective_from` is [now], deliberately **not** the tag's own
  /// `date_put_on`. The collar may have gone on the animal in March and been
  /// entered in the app in May; this column records when the recorded values
  /// took effect *in this database*, not when the collar was deployed.
  /// Conflating the two would make the version claim to describe a period the
  /// app holds no records from.
  Future<TagVersion> createInitialVersion(
    Tag tag, {
    required DateTime now,
    required String? modifiedBy,
    String? deviceId,
  }) async {
    final version = TagVersion.of(
      tag,
      tagVersionId: _uuid.v4(),
      effectiveFrom: now,
      sync: SyncMeta.initial(
        now: now,
        modifiedBy: modifiedBy,
        originDeviceId: deviceId,
      ),
    );
    await insertRow(version.toColumns());
    return version;
  }

  /// Whether editing [before] into [after] changes anything a record carries a
  /// historical copy of — i.e. whether the person must be asked
  /// correction-or-change at all.
  ///
  /// **A colour-only edit must ask nothing**, and so must an edit that only
  /// touches the collar's dates, status or notes. Keeping the common case
  /// frictionless is part of the requirement, not a nicety.
  ///
  /// Derived from the `Tags` columns declared
  /// [TagColumnKind.measurementContext], through [TagVersion.of]'s projection
  /// of a tag onto a version, so a new versioned column joins this comparison
  /// without anybody editing it.
  static bool versionedFieldsChanged(Tag before, Tag after) {
    final stamp = _comparisonStamp;
    final sync = SyncMeta.initial(now: stamp);
    return !TagVersion.of(
      before,
      tagVersionId: 'x',
      effectiveFrom: stamp,
      sync: sync,
    ).matches(after);
  }

  /// A fixed instant used only to build the two throwaway version objects
  /// [versionedFieldsChanged] compares. Never stored.
  static final DateTime _comparisonStamp = DateTime.utc(2000);

  /// Applies a tag edit's consequence for the historical record, given what the
  /// person said they meant.
  ///
  /// Call this **after** `TagRepository.update` has written the new tag row,
  /// inside the same transaction. It does one of three things:
  ///
  /// - **Nothing at all**, when no versioned field moved. A recolour, a status
  ///   change, an edited note: the tag row is written and no version is touched.
  ///   [intent] must be null in this case, because the screen must not have
  ///   asked — and passing a non-null one is not an error, only pointless.
  /// - **[TagEditIntent.correction]** — rewrites the current version in place,
  ///   so every record taken since that value took effect reads the corrected
  ///   one. If the tag has no version yet (it predates schema v9), one is
  ///   created; that is not a backfill, because no existing record points at it
  ///   — records made before there was a version stay null, as they must.
  /// - **[TagEditIntent.change]** — appends a new version effective [now].
  ///   Records already taken keep pointing at the old one.
  ///
  /// **A null [intent] when a versioned field *did* move throws.** That is a
  /// caller who edited a frequency or a name without asking the person what
  /// they meant, and there is no answer this code could supply: either default
  /// is silently wrong a good share of the time, which is exactly the silence
  /// being fixed. Failing loudly in the first test that touches it is how such
  /// a call site gets found — the same choice `MutationRule.permits` makes for
  /// the ownership rules.
  ///
  /// Returns the version records taken from now on should point at.
  Future<TagVersion?> recordEdit(
    Tag edited, {
    required Tag before,
    required TagEditIntent? intent,
    required DateTime now,
    required String? modifiedBy,
    String? deviceId,
  }) async {
    if (!versionedFieldsChanged(before, edited)) return currentFor(edited.tagId);
    if (intent == null) {
      throw StateError(
        'Tag ${edited.tagId} was edited in a way that changes what earlier '
        'records were taken against (${versionedTagColumnNames.join(', ')}), '
        'but no TagEditIntent was given. The caller must ask the person '
        'whether this is a correction or a change — the app cannot tell, and '
        'guessing is the harm task 11.32 exists to remove. See TagEditIntent.',
      );
    }

    final current = await currentFor(edited.tagId);
    if (current == null || intent == TagEditIntent.change) {
      return createInitialVersion(
        edited,
        now: now,
        modifiedBy: modifiedBy,
        deviceId: deviceId,
      );
    }

    // A correction: the stored version was never true, so it is rewritten
    // rather than superseded. `effective_from` is deliberately NOT moved — the
    // period this version describes did not change, only what the tag read
    // during it.
    final corrected = TagVersion.of(
      edited,
      tagVersionId: current.tagVersionId,
      effectiveFrom: current.effectiveFrom,
      sync: current.sync,
    );
    await updateById(
      current.tagVersionId,
      corrected.toColumns(),
      // A version row names nobody, so `MutationRule.anyUser` singles nobody
      // out and this actor is only the audit stamp. A null id reaches here
      // only from a replication write, which is what `MutationActor
      // .replication` is for.
      actor: modifiedBy == null
          ? const MutationActor.replication(
              'a tag correction carrying no acting user',
            )
          : MutationActor.user(modifiedBy),
      deviceId: deviceId,
      now: now,
    );
    return findById(current.tagVersionId);
  }

  /// What [observation] was recorded against: the tag's live row for anything
  /// display or lifecycle, and the frozen version for the measurement context.
  ///
  /// [tag] is the observation's current `Tags` row, which the caller normally
  /// already holds. Returns null only when the observation names no tag at all
  /// (a general geotagged note).
  ///
  /// **An unresolvable `tag_version_id` yields a null version, not an error and
  /// not a substitution.** Sync legitimately delivers a bearing before the
  /// version row it names, and a record imported from a colleague's file may
  /// name a version this device will never hold. The honest answer in both
  /// cases is "not recorded on this device".
  Future<RecordedTagState?> recordedStateOf(
    Observation observation, {
    required Tag? tag,
  }) async {
    if (tag == null) return null;
    final versionId = observation.tagVersionId;
    return RecordedTagState(
      tag: tag,
      version: versionId == null
          ? null
          : await findById(versionId, includeDeleted: true),
    );
  }

  /// [recordedStateOf] for a list, with one query per distinct version rather
  /// than one per record — the shape the log, the map and the CSV export need.
  ///
  /// Records whose tag is not in [tagsById] are skipped: the caller could not
  /// render them anyway, and inventing a tag here would be the same guess in a
  /// different place.
  Future<Map<String, RecordedTagState>> recordedStatesFor(
    List<Observation> observations, {
    required Map<String, Tag> tagsById,
  }) => recordedStatesForRows([
    for (final o in observations)
      (
        rowId: o.observationId,
        tagId: o.tagId,
        tagVersionId: o.tagVersionId,
      ),
  ], tagsById: tagsById);

  /// [recordedStatesFor] for any record that carries a `tag_version_id`, not
  /// only an [Observation].
  ///
  /// **Generalised rather than copied** (task 10.66's rule, applied by task
  /// 11.92): truth points carry exactly the same column for exactly the same
  /// reason, and a second copy of the chunking and the never-fall-back-to-today
  /// rule is how the two would drift apart. [rows] gives each record's own id —
  /// the key of the returned map — alongside the tag it names and the version
  /// it was recorded against.
  Future<Map<String, RecordedTagState>> recordedStatesForRows(
    Iterable<({String rowId, String? tagId, String? tagVersionId})> rows, {
    required Map<String, Tag> tagsById,
  }) async {
    final records = rows.toList();
    final versionIds = {
      for (final r in records)
        if (r.tagVersionId != null) r.tagVersionId!,
    };
    final versions = <String, TagVersion>{};
    const chunkSize = 500; // under SQLite's 999-variable limit.
    final ids = versionIds.toList();
    for (var i = 0; i < ids.length; i += chunkSize) {
      final chunk = ids.sublist(
        i,
        i + chunkSize > ids.length ? ids.length : i + chunkSize,
      );
      final rows = await findRows(
        where: 'tag_version_id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
        includeDeleted: true,
      );
      for (final row in rows) {
        final version = TagVersion.fromRow(row);
        versions[version.tagVersionId] = version;
      }
    }
    return {
      for (final r in records)
        if (tagsById[r.tagId] != null)
          r.rowId: RecordedTagState(
            tag: tagsById[r.tagId]!,
            version: r.tagVersionId == null ? null : versions[r.tagVersionId],
          ),
    };
  }
}
