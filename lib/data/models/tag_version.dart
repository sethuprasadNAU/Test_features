import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'pulse_mode.dart';
import 'sync_meta.dart';
import 'tag.dart';

part 'tag_version.freezed.dart';

/// **What a tag read at a moment — task 11.32.**
///
/// A bearing points at one of these ([Observation.tagVersionId]) rather than
/// carrying its own copy of the tag's frequency and name, so editing the tag
/// afterwards cannot change what the bearing says it was recorded against.
///
/// ## Two reads, and they must stay different
///
/// - *"What was this bearing recorded against?"* resolves through the version.
/// - *"What is this tag now?"* reads the [Tag] row.
///
/// **Do not reconcile them.** A tag whose bearings read 148.520 for six weeks
/// and 148.535 afterwards *is* a drift record, and that is more useful to a
/// biologist than a tag row that only remembers today. A future reader who
/// "helpfully" makes them agree destroys the measurement history this table
/// exists to keep.
///
/// ## What it carries, and what it deliberately does not
///
/// Only the `Tags` columns `tagColumnKinds` declares
/// [TagColumnKind.measurementContext]. Not colour — recolouring a tag is meant
/// to redraw every record already on the map, immediately and without asking.
/// Not the collar's dates, status or notes — a bearing has no use for its own
/// copy of what later happened to the transmitter.
///
/// The field list below therefore mirrors `Tables.tagVersions`, whose column
/// set is *derived* from that classification. If you are adding a field here by
/// hand, something upstream is wrong: the classification is what decides, and
/// the schema test is what catches the mismatch.
///
/// ## Correction versus change
///
/// Only the person editing knows which they mean, so the app asks (see
/// `TagVersionRepository.recordEdit`). A **change** — the transmitter drifted —
/// appends a new version and leaves earlier bearings pointing at the old one. A
/// **correction** — it was typed in wrong — rewrites [effectiveFrom]'s version
/// in place, so every bearing taken since that value took effect reads the
/// corrected one, and versions before it are untouched.
@freezed
abstract class TagVersion with _$TagVersion {
  const TagVersion._();

  const factory TagVersion({
    required String tagVersionId,

    /// The project the tag this versions lives in (task 11.219). Part of the
    /// key: a version belongs to one project's copy of a collar, and two
    /// projects holding the same collar keep separate chains, which is what
    /// copy-on-add means applied to history.
    required String projectId,

    /// The tag this is a version of.
    required String tagId,

    /// When this version took effect (UTC).
    ///
    /// Provenance, not a lookup key. An observation names its version by id and
    /// never by "whichever version was current at my timestamp" — the two
    /// disagree whenever a bearing is entered after the fact, and the id is the
    /// answer that stays true.
    required DateTime effectiveFrom,
    required double frequencyMhz,
    double? pulseRate,
    String? pulsePattern,
    required String tagName,

    /// The tag's pulse modes as this version read them — task 11.187. Slot 1's
    /// rate is [pulseRate]; see `pulse_modes.dart`.
    String? pulseMode1Name,
    String? pulseMode2Name,
    double? pulseMode2RateBpm,
    String? pulseMode3Name,
    double? pulseMode3RateBpm,
    required SyncMeta sync,
  }) = _TagVersion;

  /// The modes the tag had **when this version was current** — the answer to
  /// "what mode was that bearing heard on", as opposed to [Tag.pulseModes],
  /// which answers "what modes does this collar have now".
  ///
  /// A mode somebody has since switched off is still here, because this row
  /// still says it was there. That is the point of the table.
  List<PulseMode> get pulseModes => buildPulseModes([
    (pulseMode1Name, pulseRate),
    (pulseMode2Name, pulseMode2RateBpm),
    (pulseMode3Name, pulseMode3RateBpm),
  ]);

  /// The version a tag reads *right now* — used to write a tag's first version
  /// at creation, and the new version an "it changed" edit appends.
  factory TagVersion.of(
    Tag tag, {
    required String tagVersionId,
    required DateTime effectiveFrom,
    required SyncMeta sync,
  }) => TagVersion(
    tagVersionId: tagVersionId,
    projectId: tag.projectId,
    tagId: tag.tagId,
    effectiveFrom: effectiveFrom.toUtc(),
    frequencyMhz: tag.frequencyMhz,
    pulseRate: tag.pulseRate,
    pulsePattern: tag.pulsePattern,
    tagName: tag.tagName,
    pulseMode1Name: tag.pulseMode1Name,
    pulseMode2Name: tag.pulseMode2Name,
    pulseMode2RateBpm: tag.pulseMode2RateBpm,
    pulseMode3Name: tag.pulseMode3Name,
    pulseMode3RateBpm: tag.pulseMode3RateBpm,
    sync: sync,
  );

  /// Whether [tag]'s measurement columns still read the way this version
  /// records them.
  ///
  /// This is the question that decides whether a tag edit asks the person
  /// anything at all: a colour-only edit, or one that touches only the collar's
  /// dates and status, leaves this true and must prompt for nothing. Keeping
  /// the common case frictionless is part of the requirement.
  bool matches(Tag tag) =>
      frequencyMhz == tag.frequencyMhz &&
      pulseRate == tag.pulseRate &&
      pulsePattern == tag.pulsePattern &&
      tagName == tag.tagName &&
      // Task 11.187. Renaming a mode, re-rating one, or switching one on or
      // off is a change to what a bearing was heard on, so it raises the
      // correction-or-change question exactly as a frequency edit does — which
      // is Michael's answer 2 of 2026-09-07, and it costs nothing new because
      // these columns are `measurementContext` like the four above.
      //
      // **The modes are compared, not the five raw columns**, and the
      // difference is not cosmetic. A slot-1 name of NULL and a slot-1 name of
      // "Normal" are the same tag — NULL there means "never said" and reads as
      // the default everywhere — so comparing the columns would make merely
      // opening a tag and recolouring it ask a person whether their earlier
      // bearings were wrong. That is exactly the frictionless-common-case rule
      // this method exists to keep.
      //
      // Slot identity survives the derivation: [PulseMode] carries its slot
      // and compares on it, so switching slot 2 off and slot 3 on with the same
      // words is still seen as the change it is.
      //
      // What it does *not* see is a rate sitting in a slot with no name. That
      // is inert by construction — nothing reads a rate without a mode to read
      // it for — so it is not a change to anything a bearing was recorded
      // against.
      _sameModes(pulseModes, tag.pulseModes);

  static bool _sameModes(List<PulseMode> a, List<PulseMode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  factory TagVersion.fromRow(Map<String, Object?> row) => TagVersion(
    tagVersionId: row['tag_version_id'] as String,
    projectId: row['project_id'] as String,
    tagId: row['tag_id'] as String,
    effectiveFrom: DbCodec.decodeUtc(row['effective_from']),
    frequencyMhz: row['frequency_mhz'] as double,
    pulseRate: row['pulse_rate'] as double?,
    pulsePattern: row['pulse_pattern'] as String?,
    tagName: row['tag_name'] as String,
    pulseMode1Name: row['pulse_mode_1_name'] as String?,
    pulseMode2Name: row['pulse_mode_2_name'] as String?,
    pulseMode2RateBpm: (row['pulse_mode_2_rate_bpm'] as num?)?.toDouble(),
    pulseMode3Name: row['pulse_mode_3_name'] as String?,
    pulseMode3RateBpm: (row['pulse_mode_3_rate_bpm'] as num?)?.toDouble(),
    sync: SyncMeta.fromRow(row),
  );

  Map<String, Object?> toColumns() => {
    'tag_version_id': tagVersionId,
    'project_id': projectId,
    'tag_id': tagId,
    'effective_from': DbCodec.encodeUtc(effectiveFrom),
    'frequency_mhz': frequencyMhz,
    'pulse_rate': pulseRate,
    'pulse_pattern': pulsePattern,
    'tag_name': tagName,
    'pulse_mode_1_name': pulseMode1Name,
    'pulse_mode_2_name': pulseMode2Name,
    'pulse_mode_2_rate_bpm': pulseMode2RateBpm,
    'pulse_mode_3_name': pulseMode3Name,
    'pulse_mode_3_rate_bpm': pulseMode3RateBpm,
    ...sync.toColumns(),
  };
}

/// A tag as one particular record saw it: the measurement context frozen at the
/// moment of recording, plus the display and lifecycle facts read live.
///
/// **This is the "what was this bearing recorded against?" read**, and it is
/// the only shape the app should render a historical record's tag through. It
/// exists as a type rather than as two variables at each call site so that
/// nobody accidentally shows today's frequency next to last season's bearing —
/// which is the whole harm task 11.32 closes.
class RecordedTagState {
  const RecordedTagState({required this.tag, required this.version});

  /// The tag's current row. Read for anything
  /// [TagColumnKind.display] or [TagColumnKind.collarLife] — colour above all,
  /// which must change everywhere the instant somebody recolours the tag.
  final Tag tag;

  /// The version the record was taken against, or **null when the record does
  /// not know** — it predates schema v9, arrived in a pasted payload, or came
  /// from a device that has not sent the version row yet.
  ///
  /// Null is *not* an invitation to substitute the tag's current values. It
  /// means "not recorded", and every reader below returns null for the
  /// measurement fields rather than guessing.
  final TagVersion? version;

  /// Whether the recorded measurement context is known at all.
  bool get isRecorded => version != null;

  /// The frequency the receiver was tuned to, or null if not recorded.
  double? get recordedFrequencyMhz => version?.frequencyMhz;

  /// The name the tag carried when the record was taken, or null if not
  /// recorded.
  String? get recordedTagName => version?.tagName;

  double? get recordedPulseRate => version?.pulseRate;
  String? get recordedPulsePattern => version?.pulsePattern;

  /// The modes the tag had when the record was taken, or null if not recorded.
  List<PulseMode>? get recordedPulseModes => version?.pulseModes;

  /// **What to call the pulse mode a record was heard on** — task 11.187.
  ///
  /// [storedSlot] is `Observations.pulse_mode`, null on every record written
  /// before schema v12 and on every pasted replica. [legacy] is
  /// `Observations.signal_type`, which is `NOT NULL` and is therefore always
  /// available; together they settle *which* mode through [pulseModeSlotOf].
  /// This settles what it was **called**, in three steps that get progressively
  /// less certain and say so:
  ///
  /// 1. **The version knows.** The name on the `Tag_Versions` row this record
  ///    points at is the words as they stood when somebody keyed the bearing
  ///    in, and it stays right after the mode is renamed or switched off.
  /// 2. **No version, and no stored slot.** The record predates v12, so its
  ///    mode was one of two words fixed in the build that wrote it. Michael,
  ///    2026-09-07: those records adopt the new default names — so slot 1 reads
  ///    "Normal" and slot 2 reads "Mortality". That is transcription of a
  ///    constant, not a guess about a tag.
  /// 3. **A slot with nothing to name it.** Everything else — a v12 record
  ///    whose version row has not reached this device, or slot 3 with no
  ///    version — reads [unnamedPulseMode], "Mode 3". It says which mode and
  ///    declines to invent what it was called.
  ///
  /// **Step 3 never falls back to the tag's current mode names**, which is the
  /// tempting fourth branch and the one that would undo task 11.32: the collar
  /// in front of you today is not evidence about what its modes were called
  /// last season.
  String recordedPulseModeName({
    required int? storedSlot,
    required SignalType legacy,
  }) {
    final slot = pulseModeSlotOf(storedSlot: storedSlot, legacy: legacy);
    final modes = recordedPulseModes;
    if (modes != null) {
      final named = pulseModeAt(modes, slot);
      if (named != null) return named.name;
    }
    if (storedSlot == null && slot <= defaultPulseModeNames.length) {
      return defaultPulseModeNames[slot - 1];
    }
    return unnamedPulseMode(slot);
  }

  /// The rate of the mode a record was heard on, or null when nothing on this
  /// device records it. Never today's rate: same rule as
  /// [recordedPulseModeName] step 3.
  double? recordedPulseModeRateBpm({
    required int? storedSlot,
    required SignalType legacy,
  }) {
    final modes = recordedPulseModes;
    if (modes == null) return null;
    return pulseModeAt(
      modes,
      pulseModeSlotOf(storedSlot: storedSlot, legacy: legacy),
    )?.rateBpm;
  }

  /// Whether the tag has since been edited away from what this record was taken
  /// against — the drift a reader most wants flagged.
  ///
  /// False when nothing is recorded: an unknown past is not a known
  /// disagreement, and reporting it as one would be the same invention in the
  /// opposite direction.
  bool get differsFromCurrent =>
      version != null && !version!.matches(tag);
}
