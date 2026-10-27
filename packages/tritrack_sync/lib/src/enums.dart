// Closed value sets from the schema spec, each with its exact stored string
// (`db`). Storing an enum rather than a bare string gives compile-time
// exhaustiveness and one authoritative spelling per value. `fromDb` throws on
// an unknown value so a bad/legacy string surfaces loudly rather than silently
// degrading — callers validating external input (CSV/share import, Phase 6)
// should catch that and reject the row with a clear message.

import 'pulse_modes.dart';
import 'schema_constants.dart';

enum ProjectRole {
  owner('owner'),
  contributor('contributor'),
  viewer('viewer');

  const ProjectRole(this.db);
  final String db;

  static ProjectRole fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

enum TagStatus {
  active('active'),
  recovered('recovered'),
  lost('lost'),
  malfunction('malfunction');

  const TagStatus(this.db);
  final String db;

  static TagStatus fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// What is known about the **animal** — task 11.240. Distinct from
/// [TagStatus], which is about the transmitter, and named from what a field
/// biologist needs rather than from what the tag enum happens to have.
///
/// **A recovered collar must not make a dead animal read as alive**, and the
/// reverse: a collar that stopped transmitting says nothing about the bird.
/// Nothing derives one of these from a [TagStatus] after creation — the two
/// are edited by a person, separately. (The v16 backfill is the one place a
/// tag status seeds one, once, and it is documented there.)
enum IndividualStatus {
  /// Last known to be alive.
  alive('alive'),

  /// A mortality — Michael's *"a few mortalities"*.
  dead('dead'),

  /// Fate unknown: signal lost, collar came off, never re-sighted.
  unknown('unknown');

  const IndividualStatus(this.db);
  final String db;

  static IndividualStatus fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// An individual's sex, where it is recorded at all (task 11.240). The column
/// is nullable — null means nobody wrote it down, which is a different fact
/// from [unknown], where somebody looked and could not tell.
enum IndividualSex {
  male('male'),
  female('female'),
  unknown('unknown');

  const IndividualSex(this.db);
  final String db;

  static IndividualSex fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

enum ProjectTagStatus {
  active('active'),
  inactive('inactive');

  const ProjectTagStatus(this.db);
  final String db;

  static ProjectTagStatus fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// Why an observation is out of position estimation (task 11.7).
///
/// Both values take the row out of the solver's input; they differ in what the
/// person doing it is asserting, and in who may do it.
enum ObservationExclusionKind {
  /// A better record of the same event exists — named in
  /// `superseded_by_observation_id`. **Available to any contributor or owner,
  /// on anyone's observation**, because that is the whole point of supersede:
  /// editing an observation stays author-only, so correcting a colleague's
  /// bearing has to be expressed as a new record plus this pointer, not as a
  /// rewrite of theirs.
  superseded('superseded'),

  /// The observation is bad and there is no replacement to offer — a bounced
  /// signal, a bearing taken through a ridge. **Owner-only**: this is the
  /// "data quality" rung of the role gradient, and unlike [superseded] it
  /// removes evidence without putting anything in its place.
  excluded('excluded');

  const ObservationExclusionKind(this.db);
  final String db;

  static ObservationExclusionKind fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// Where a stored coordinate came from — **the provenance of the number, not a
/// quality score.**
///
/// One vocabulary across every table that stores a position, which is why
/// [gpsFixAdjusted] was added here (task 11.93) rather than as a truth-point
/// convention of its own: a third meaning invented for one table is a third
/// thing for whoever does the arithmetic in R to interpret, and this project
/// has already paid for that once.
enum PositionSource {
  /// The device's own GPS fix, unedited.
  gpsFix('gps_fix', 'GPS fix'),

  /// A pin placed by hand on the map. Says nothing about accuracy: a pin is
  /// only as good as the person's ability to identify the spot in imagery
  /// whose own registration is commonly off by a few metres.
  manualPin('manual_pin', 'Placed by hand on the map'),

  /// A coordinate typed in, or carried in from outside the app.
  manualEntry('manual_entry', 'Entered by hand'),

  /// **A GPS fix that was later moved by hand** (task 11.93).
  ///
  /// A third thing, and it needed its own value the moment truth-point
  /// positions became editable. Recording it as [gpsFix] would claim the
  /// coordinate is where the phone said it was; recording it as [manualPin]
  /// would throw away that it began as a measurement. Neither is true, and
  /// somebody scoring estimates against these points needs to be able to tell
  /// all three apart.
  ///
  /// **Only truth points can carry it today**, because they are the only
  /// records whose position this app lets anybody change. It lives on the
  /// shared enum anyway: the day a bearing's position becomes editable, the
  /// correct value already exists rather than being invented a second time.
  gpsFixAdjusted('gps_fix_adjusted', 'GPS fix, later moved by hand');

  const PositionSource(this.db, this.label);
  final String db;

  /// The wording the screens use, added by task 11.93 when truth points began
  /// showing their position's provenance. Kept beside [db] for the reason
  /// [GroundTruthKind] keeps its own label here: two surfaces describing the
  /// same stored value in different words is how a reader ends up thinking
  /// they are different values.
  final String label;

  static PositionSource fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// What a coordinate's [PositionSource] becomes once somebody moves it by hand
/// (task 11.93).
///
/// **A fix that is nudged stops being a fix and does not become a plain pin.**
/// [PositionSource.gpsFixAdjusted] is the third answer, and it is why the
/// column and the editable position had to ship together: item 2 without item
/// 3 would have left a hand-moved measurement still claiming to be one.
///
/// **A coordinate whose source was never recorded becomes
/// [PositionSource.manualPin], not [PositionSource.gpsFixAdjusted].** The
/// weaker claim is the true one: we know a person placed *this* coordinate by
/// hand, and we do not know that it began as a measurement — a row written
/// before schema v11 genuinely does not say. Claiming it refines a GPS fix
/// would be inventing provenance, which is the thing this table's whole
/// no-backfill rule exists to prevent.
PositionSource positionSourceAfterHandMove(PositionSource? current) =>
    switch (current) {
      PositionSource.gpsFix ||
      PositionSource.gpsFixAdjusted =>
        PositionSource.gpsFixAdjusted,
      // A typed coordinate that is then dragged on a map is a placed pin: the
      // number on screen came from the map, not from what was typed.
      PositionSource.manualPin ||
      PositionSource.manualEntry ||
      null =>
        PositionSource.manualPin,
    };

enum ObservationType {
  directional('directional'),
  omnidirectional('omnidirectional'),

  /// A general note tied to a tag + position — no radio/bearing data.
  note('note');

  const ObservationType(this.db);
  final String db;

  static ObservationType fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// The record-type selector on the Record screen. The first three map to an
/// [ObservationType] (an `Observation` row); [noSignal] instead records a
/// multi-tag `NonDetection` (negative evidence — "scanned these frequencies,
/// heard nothing"), which is a separate model, so it has no [ObservationType].
enum RecordType {
  /// **Shown as "Bearing", stored as `directional`** — Michael, 2026-09-07,
  /// asked for the shorter word to give the record-type picker back some
  /// width. It is the only one of these five whose displayed word differs
  /// from its stored one, and it is a display change alone: `db` is
  /// unchanged, so every row already written, every CSV export and every
  /// sync payload still say `directional`.
  directional('directional', 'Bearing'),
  omnidirectional('omnidirectional', 'Omni'),
  note('note', 'Note'),
  noSignal('no_signal', 'No Signal'),

  /// Task 11.33: where the animal or the collar actually turned out to be,
  /// stored as an `Actual_Tag_Locations` row rather than an `Observation`.
  ///
  /// **It is a separate table on purpose, and that is the whole safety
  /// property.** A truth point is the yardstick the position estimates are
  /// measured against; if it could reach the solver it would be measuring
  /// itself. Keeping it out of `Observations` means no solver query has to
  /// *remember to exclude* it — the exclusion is structural, not a rule
  /// somebody has to keep applying. See
  /// `test/data/analysis/ground_truth_not_in_solver_test.dart`.
  groundTruth('ground_truth', 'Truth');

  const RecordType(this.db, this.label);
  final String db;
  final String label;

  static RecordType fromDb(String value) => values.firstWhere(
    (e) => e.db == value,
    orElse: () => RecordType.directional,
  );

  /// The [ObservationType] this record type saves as, or null for [noSignal]
  /// (which is stored as a `NonDetection`, not an `Observation`).
  ObservationType? get observationType => switch (this) {
    RecordType.directional => ObservationType.directional,
    RecordType.omnidirectional => ObservationType.omnidirectional,
    RecordType.note => ObservationType.note,
    RecordType.noSignal => null,
    // A truth point is not an observation at all — see [groundTruth].
    RecordType.groundTruth => null,
  };
}

enum BearingCaptureMethod {
  singlePoint('single_point'),
  rangeCapture('range_capture');

  const BearingCaptureMethod(this.db);
  final String db;

  static BearingCaptureMethod fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// Peak vs. null antenna method. `null` is a Dart keyword, so the enum member
/// is [nullMethod]; its stored value remains the spec's `"null"`.
enum BearingMethod {
  peak('peak'),
  nullMethod('null');

  const BearingMethod(this.db);
  final String db;

  static BearingMethod fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// **The two pulse modes every tag used to have — now a legacy projection of
/// `Observations.pulse_mode` (task 11.187).**
///
/// Until schema v12 a tag's modes were these two words, baked into the schema
/// and the same for every collar. Michael, 2026-09-07: *"the person who enters
/// the tag should be able to set those, because some tags have only one mode
/// and some have more than one."* So the modes moved onto the tag
/// ([pulseModeColumns]) and a bearing records **which slot** it was heard on
/// (`Observations.pulse_mode`).
///
/// **This enum could not simply be deleted, and that is a wire rule rather
/// than sentiment.** `signal_type` is `NOT NULL` on a table that already holds
/// records, and dropping a column — or reusing its name for a new meaning —
/// is on `SyncSchemaVersionException`'s list of changes unknown-column
/// preservation cannot save. Either would cost a [schemaMajorVersion] bump and
/// strand every device in the field.
///
/// So it stays, with **exactly the meaning it always had**, and it now does two
/// jobs:
///
/// 1. **It is the mode of every record written before v12.** Nothing is
///    backfilled — [pulseModeSlotOf] does the mapping on read, which is the
///    same choice `tag_version_id` made in schema v9 and for the same reason:
///    a row that never recorded a slot should not be given one now. Michael's
///    answer of 2026-09-07 decides what those records are *called*: *"records
///    already stored as `regular_pulse` / `mortality_signal` adopt the new
///    default names"* — [defaultPulseModeNames] — and the word *Regular*
///    leaves the app.
/// 2. **It is what a build that predates v12 sees.** [forPulseModeSlot] is the
///    projection written on every new row.
///
/// **The projection is lossy on slot 3, and knowingly so.** This field can
/// express two things, so a third mode has no honest value here; it projects to
/// [regularPulse], which is the correct answer to the only question two values
/// can ask — *was this the tag's second (historically mortality) slot?* Nothing
/// in this build reads `signal_type` when `pulse_mode` is present, so the loss
/// is confined to an older reader. **The clean removal wants a major bump; if
/// one is ever spent for another reason, spend this with it.**
enum SignalType {
  regularPulse('regular_pulse'),
  mortalitySignal('mortality_signal');

  const SignalType(this.db);
  final String db;

  static SignalType fromDb(String value) =>
      values.firstWhere((e) => e.db == value);

  /// The value written to `signal_type` for a bearing heard on [slot].
  ///
  /// Total on purpose, including for null: the column is `NOT NULL`, so there
  /// is no branch in which a caller may decline to answer. A record with no
  /// mode — one with no tag, which has no modes to number — writes
  /// [regularPulse], which is what it wrote before v12 as well.
  static SignalType forPulseModeSlot(int? slot) =>
      slot == 2 ? mortalitySignal : regularPulse;
}

/// **Which pulse-mode slot a record was heard on**, given both the column that
/// knows ([storedSlot], `Observations.pulse_mode`) and the one that only knows
/// two answers ([legacy], `signal_type`).
///
/// The stored slot wins wherever it exists. Where it does not — every row
/// written before schema v12, and every pasted replica, which deliberately
/// drops it — the legacy field is the *only* mode information the record has,
/// and mapping it is transcription rather than a guess: the build those rows
/// were written under offered exactly two modes, in this order.
int pulseModeSlotOf({int? storedSlot, required SignalType legacy}) =>
    storedSlot ?? (legacy == SignalType.mortalitySignal ? 2 : 1);

/// Five qualitative levels per the schema (resolved 2026-07-16 in favor of the
/// technical doc's 5-level set over the mockup's 4). `medium` may display as
/// "Moderate" in the UI, but the stored value stays `medium`.
enum SignalStrength {
  faint('faint'),
  weak('weak'),
  medium('medium'),
  strong('strong'),
  veryStrong('very_strong');

  const SignalStrength(this.db);
  final String db;

  static SignalStrength fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

enum BearingQuality {
  good('good'),
  fair('fair'),
  suspectedBounce('suspected_bounce');

  const BearingQuality(this.db);
  final String db;

  static BearingQuality fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// Coordinate display preference (Project Setup, schema v2): decimal degrees,
/// degrees-minutes-seconds, or UTM — "biologists and GIS handoffs vary"
/// (TC:266). Display-only; all storage stays decimal-degree lat/lon.
enum CoordinateFormat {
  dd('dd'),
  dms('dms'),
  utm('utm');

  const CoordinateFormat(this.db);
  final String db;

  static CoordinateFormat fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

enum EstimationMethod {
  lenthMle('lenth_mle');

  const EstimationMethod(this.db);
  final String db;

  static EstimationMethod fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}

/// What was actually found at a ground-truth point (task 11.33).
///
/// **This distinction is not cosmetic, and nothing may collapse it to a
/// boolean.** Only [animalAndCollar] validates the triangulation of a live
/// collared animal: the radio was transmitting from the animal, and the
/// estimate computed from those bearings can be compared to where the animal
/// was. The other two cannot be compared to a bearing-derived estimate without
/// saying what they are:
///
/// - [collarOnly] says where the *transmitter* was, which may be where it was
///   shed days earlier. Scoring an estimate against it would report the app as
///   wrong at exactly the moment it was right.
/// - [animalOnly] is a sighting with no radio involved, so it validates no
///   signal at all.
///
/// Whatever later computes accuracy statistics must read this column and say
/// which kinds it counted. Task 11.33 stores the distinction and deliberately
/// computes nothing from it.
enum GroundTruthKind {
  animalAndCollar('animal_and_collar', 'Animal + tag'),
  animalOnly('animal_only', 'Animal only'),
  collarOnly('collar_only', 'Tag only');

  const GroundTruthKind(this.db, this.label);
  final String db;

  /// The wording shown on the record screen.
  final String label;

  static GroundTruthKind fromDb(String value) =>
      values.firstWhere((e) => e.db == value);
}
