import 'pulse_modes.dart';
import 'row_refusal.dart';
import 'schema_constants.dart';
import 'tag_column_kinds.dart';

/// The storage kind of a column, in the only three flavours this schema uses.
///
/// Deliberately not a full type system — it exists so the app's SQLite DDL and
/// the server's Postgres DDL can be checked against one canonical declaration
/// rather than drifting apart silently. Each side maps these to its own native
/// types (`TEXT`/`REAL`/`INTEGER` on SQLite; `text`/`double precision`/`bigint`
/// on Postgres).
enum ColumnType { text, real, integer }

/// What shape a text column's value must have, beyond its length.
///
/// **Each shape declares the [RowIssueCode] a violation of it reports**
/// (task 11.124). That is the whole reason the code lives here rather than at
/// the place the row is refused: the bound is what decides what went wrong, so
/// the bound is what names it. A code chosen at a refusal site is a
/// hand-maintained list, and adding a shape below would then mean remembering
/// to teach every such site about it — task 11.88's rule. Here, adding a shape
/// without a code does not compile.
enum TextShape {
  /// Anything printable, up to the length cap. Names, notes, free prose.
  ///
  /// **No shape rule, so no violation code** — the only way a `free` column
  /// fails is on length or type, which every text column shares.
  free(null),

  /// Must satisfy `RowValidator.isWellFormedIdentifier` — no control
  /// characters, non-empty after trimming. **A shape, not a length**, which is
  /// the distinction task 10.97 asked for: a column holding an id is not
  /// bounded by picking a bigger number, it is bounded by what an id can be.
  identifier(RowIssueCode.textNotAnIdentifier),

  /// A **person's name**: must satisfy `RowValidator.isWellFormedPersonName` —
  /// **letters, marks, digits, spaces, dashes and a short list of name
  /// punctuation, and nothing else.** May be empty, because the server
  /// deliberately mints a nameless `Users` row for somebody it has not been
  /// told the name of (`JoinService`), and refusing that would refuse the
  /// honest case.
  ///
  /// **This was a denylist until task 11.89 and is an allowlist now**, because
  /// the denylist was demonstrably unfinishable: it named the control
  /// characters and the bidirectional overrides, was written by somebody
  /// thinking about exactly this attack, and still admitted `U+2028 LINE
  /// SEPARATOR` — which let a stranger asking to join choose what the second
  /// line of the owner's approval tile said (finding R-1). The full argument,
  /// and what each allowed character class is for, is on
  /// `RowValidator.isWellFormedPersonName`.
  ///
  /// **Why a person's name has a shape at all, when a tag name does not**
  /// (task 11.81). Every other free-text column in this schema is read as
  /// *data*. A person's name is read as *identity*: it is the string an owner
  /// looks at when deciding whether to admit somebody to a project, and it is
  /// the string that says who recorded an observation. A right-to-left
  /// override character makes `Ann Smith` render as somebody else's name
  /// entirely, and the reader has no way to see that anything happened.
  ///
  /// **This shape did not exist before task 11.81, and the honest version of
  /// that is: `Users.first_name` was bounded by length alone.** Nothing
  /// refused a control character or a bidi override in a name on any write
  /// path. It was added here, on the column that already existed, rather than
  /// invented as a second set of rules for the join-request route — because
  /// two sets of bounds on "a person's name" is how they come to disagree.
  personName(RowIssueCode.textNotAName),

  /// A **`#RRGGBB` colour**: must satisfy `TagColorPalette.isValidHex`
  /// (task 11.136).
  ///
  /// The rule itself is not new — `RowValidator` has always refused a
  /// malformed `Tags.color_hex`. What is new is that it is *declared* here
  /// rather than written as one more inline call, so the refusal carries a
  /// code and the person is told which value to fix instead of reading task
  /// 11.122's "the server did not say which part".
  hexColor(RowIssueCode.textNotAColor);

  const TextShape(this.violationCode);

  /// The code a value failing this shape is refused under, or null for a
  /// shape with no rule of its own ([free]). Read by `RowValidator`; never
  /// written out at a site that refuses a row.
  final RowIssueCode? violationCode;
}

/// The bound a text column's value must satisfy (task 10.97).
///
/// **Why this is declared per column rather than applied uniformly.** A single
/// global cap is either so large it permits the thing being prevented or so
/// small it refuses a legitimate value. A tag name and a field note are both
/// free text and want different limits; `observation_id` is text and wants a
/// *shape* instead of a limit. So the bound is a judgement recorded at the
/// column, and `assertEveryTextColumnIsBounded` makes a new text column with no
/// judgement a failing test rather than an unchecked value.
///
/// **What being unbounded cost, measured rather than supposed.** With no length
/// check anywhere, a 5 MiB tag name was stored and then delivered to every
/// device on the project — findings L-7 and N-7. Nothing refused it at entry,
/// nothing refused it on the wire, and every teammate's phone paid for it on
/// every sync. The caps below are all far above any honest field value and far
/// below anything that hurts.
class TextBound {
  const TextBound({required this.maxLength, this.shape = TextShape.free});

  final int maxLength;
  final TextShape shape;

  /// A primary key, foreign key, or authorship column. Length matches
  /// `RowValidator.maxPrimaryKeyLength` — asserted equal in
  /// `row_validator_test.dart`, since the two live in different files and a
  /// silent disagreement would mean a value refused by one gate and accepted
  /// by the other.
  static const identifier = TextBound(
    maxLength: 200,
    shape: TextShape.identifier,
  );

  /// An email address. 320 is RFC 5321's longest legal address, and matches
  /// `RowValidator.maxEmailLength` and the bound `/auth/magic-link` applies.
  static const email = TextBound(maxLength: 320);

  /// An ISO-8601 timestamp or date string. Generous enough for any offset or
  /// fractional-second form; nowhere near enough to be a payload.
  static const timestamp = TextBound(maxLength: 64);

  /// A closed-enum column. Membership of the allowed set is the real bound —
  /// this only stops a multi-megabyte string being *carried* to the place that
  /// rejects it, and keeps the refusal message printable.
  static const enumerated = TextBound(maxLength: 64);

  /// A short human-supplied label: a tag name, a project name, an antenna
  /// type. Long enough for any name somebody means; short enough that it is a
  /// name.
  static const name = TextBound(maxLength: 200);

  /// **A person's name** — `Users.first_name`, `Users.last_name`, and the
  /// claimed name on a join request. The same length as [name], and one extra
  /// rule: see [TextShape.personName] for why identity text is bounded more
  /// tightly than data text.
  ///
  /// **This is the single declaration of what a name may be.** The join-request
  /// route reuses it rather than restating it (task 11.81, Michael's decision
  /// 1), so a name that would be refused on a synced `Users` row cannot arrive
  /// through the request route instead.
  static const personName = TextBound(
    maxLength: 200,
    shape: TextShape.personName,
  );

  /// A free-text note field. The one place a biologist legitimately writes
  /// paragraphs, so the cap is generous — but it is a cap.
  static const notes = TextBound(maxLength: 10000);

  /// A delimited list of ids in one column (`tag_ids_listened_for`,
  /// `observation_ids_used`). Sized for a few hundred identifiers, which is
  /// far past any real session.
  static const idList = TextBound(maxLength: 20000);

  /// A `#RRGGBB` colour. The format check is the real bound; the length stops
  /// an oversize value reaching it.
  static const hexColor = TextBound(maxLength: 16, shape: TextShape.hexColor);

  /// **An IANA time-zone name** — `America/Phoenix`, `Etc/GMT+7` (task
  /// 11.331). The longest name in the tz database is 32 characters; 64 is
  /// room for any the database adds. Shaped as an identifier (no control
  /// characters, not blank) and **not** checked against a list of known
  /// names: a newer build's tz database may name a zone this one has never
  /// heard of, and refusing that row would strand it. A reader that does not
  /// know a name reads the row as having no zone (`FieldTimeZone`).
  static const timeZoneName = TextBound(
    maxLength: 64,
    shape: TextShape.identifier,
  );
}

/// Which part of a [NumericBound] a value failed, and **the [RowIssueCode] a
/// failure of that part is refused under** (task 11.136).
///
/// This is [TextShape]'s counterpart for numbers, and it exists for the same
/// reason: the bound is what decides what went wrong, so the bound is what
/// names it. Before this, a latitude of 999 and a frequency outside the VHF
/// window carried **no code at all** — not by oversight, but because the
/// checks were written inline in `RowValidator` and there was no declaration
/// to read a code off. Coding them where they stood would have meant typing a
/// code at each of the twenty-nine check sites, which is the hand-maintained
/// list task 11.88 ruled out. So the checks moved onto the columns, and the
/// code falls out of the declaration.
///
/// Adding a limit below without a code does not compile.
enum NumericLimit {
  /// The value is not a number at all — a string no reading turns into one, a
  /// bool, an array, an object (task 11.158).
  ///
  /// **The one limit [NumericBound.violatedBy] never answers with**, because
  /// it is settled before there is a `double` to compare against anything. It
  /// is declared here anyway, beside the three that are comparisons, so that
  /// the code still falls out of a declaration rather than being typed at the
  /// site that refuses the row — the bound this type's whole design rests on.
  wrongType(RowIssueCode.numberWrongType),

  /// The value is not a real number — `NaN` or an infinity. **Every** numeric
  /// column has this limit, whether or not it declares a range, because it
  /// follows from the column's type rather than from anybody's judgement
  /// (finding M-1).
  notARealNumber(RowIssueCode.numberNotARealNumber),

  /// Below the declared minimum (or, for an exclusive minimum, not above it).
  belowMinimum(RowIssueCode.numberBelowMinimum),

  /// Above the declared maximum.
  aboveMaximum(RowIssueCode.numberAboveMaximum);

  const NumericLimit(this.violationCode);

  /// The code a value failing this limit is refused under. Read by
  /// `RowValidator`; never written out at a site that refuses a row.
  final RowIssueCode violationCode;
}

/// The bound a **numeric** column's value must satisfy — [TextBound]'s
/// counterpart, added by task 11.136.
///
/// ## Why the range moved out of the validator
///
/// These were twenty-nine `range(...)` and `positive(...)` column checks
/// written
/// inline in `RowValidator.validate`'s per-table switch. Nothing was wrong
/// with them as checks. What they could not do is **say why a row was
/// refused**: a code has to come from somewhere, and an inline call has no
/// declaration behind it, so a refused latitude reached the device with no
/// detail and landed on task 11.122's honest default. Declaring the bound at
/// the column gives the code a source, and gives `Tags` and `Tag_Versions` the
/// same frequency window by construction rather than by a shared helper
/// somebody has to remember to call from both arms.
///
/// ## [unbounded] is a decision, not an absence
///
/// A great many numeric columns have no honest range — nobody can say what
/// elevation is too high — and [assertEveryNumericColumnIsBounded] refuses to
/// let that be expressed by leaving the field off. Saying [unbounded] out loud
/// is the same discipline `assertEveryTextColumnIsBounded` applies to text: a
/// column in neither state is one nobody has looked at. Such a column is still
/// checked for [NumericLimit.notARealNumber], which is true of every number.
class NumericBound {
  const NumericBound({this.min, this.max, this.minIsExclusive = false})
    : assert(
        min != null || !minIsExclusive,
        'An exclusive minimum needs a minimum.',
      );

  /// The lowest accepted value, or null for no floor.
  final double? min;

  /// The highest accepted value, or null for no ceiling.
  final double? max;

  /// Whether [min] itself is refused — how "must be > 0" is said, as opposed
  /// to "must be ≥ 0".
  final bool minIsExclusive;

  /// The limit [value] fails, or null when it satisfies this bound.
  ///
  /// **`NaN` is answered first and explicitly** (finding M-1): it is
  /// *unordered*, so `NaN < min` and `NaN > max` are both false and a NaN
  /// sails through any comparison-based check. That is why the answer is
  /// derived here, once, rather than at each column.
  NumericLimit? violatedBy(double value) {
    if (!value.isFinite) return NumericLimit.notARealNumber;
    final min = this.min;
    if (min != null && (minIsExclusive ? value <= min : value < min)) {
      return NumericLimit.belowMinimum;
    }
    final max = this.max;
    if (max != null && value > max) return NumericLimit.aboveMaximum;
    return null;
  }

  /// The server-log wording for a failure of [limit] against this bound.
  ///
  /// **Server-side only**, like every `RowIssue.message`: what a person reads
  /// is written on the device from [NumericLimit.violationCode].
  String messageFor(NumericLimit limit) => switch (limit) {
    NumericLimit.wrongType => 'must be a number',
    NumericLimit.notARealNumber => 'must be a real number',
    NumericLimit.belowMinimum => 'must be ${minIsExclusive ? '>' : '≥'} $min',
    NumericLimit.aboveMaximum => 'must be ≤ $max',
  };

  /// **A number, with no range worth enforcing** — `elevation`,
  /// `altitude_agl`, `magnetic_declination`, `receiver_gain`. Bounding what
  /// these must not be is honest where bounding what they must be is not:
  /// nobody can say what elevation is too high, and everybody can say it is a
  /// number.
  ///
  /// `revision` and `triangulation_window_minutes` were here until task
  /// 11.158 re-read the claim and found it false in one direction for both.
  /// See [nonNegativeCounter] and [positiveMeasurement].
  static const unbounded = NumericBound();

  /// **A counter that starts at zero and only goes up** — `revision`, the
  /// merge clock every table carries (task 11.158).
  ///
  /// Zero is accepted because the app's own DDL defaults to it. Negative is
  /// refused because of what it does downstream: `MergeResolver` reads a
  /// missing or non-integer revision as 0, so a row arriving below zero loses
  /// last-write-wins against every copy of itself — **including the edits its
  /// own holder makes next**, which increment from a negative start and stay
  /// behind. The person's correction is discarded on the next sync with
  /// nothing said. No ceiling: a long-lived row keeps counting, and no number
  /// is too many edits.
  static const nonNegativeCounter = NumericBound(min: 0);

  /// Degrees of latitude.
  static const latitude = NumericBound(min: -90, max: 90);

  /// Degrees of longitude.
  static const longitude = NumericBound(min: -180, max: 180);

  /// A compass bearing or a rotation, in degrees. 360 is accepted as well as
  /// 0 — the bound this replaced did, and narrowing it here would refuse rows
  /// already stored on devices in the field.
  static const degrees = NumericBound(min: 0, max: 360);

  /// **The accepted transmitter frequency window.** The technical doc says
  /// "sane VHF range"; this band is generous enough to cover VHF wildlife
  /// telemetry and adjacent UHF collars while still refusing obvious garbage
  /// (0, negative, 99999). Not a hardware spec — a sanity gate.
  ///
  /// Declared once and carried by `_tagColumns`, so a frequency `Tags`
  /// refuses cannot become storable by arriving as a `Tag_Versions` row
  /// instead (task 11.32's rule, now structural rather than a shared call).
  static const frequencyMhz = NumericBound(min: 30, max: 1000);

  /// A measured quantity that must be greater than zero: an accuracy radius,
  /// an ellipse axis, an uncertainty, a pulse rate. Zero is refused because
  /// zero uncertainty is not a measurement, it is a missing one.
  ///
  /// Task 11.158 added `triangulation_window_minutes` — a configured span
  /// rather than a measured one, but the same floor for the same kind of
  /// reason: a window of zero minutes groups no observations, so it is not a
  /// window. **No ceiling is declared for it**, because the only writer's
  /// upper limit is one screen's choice rather than a fact about the data,
  /// and a bound on the wire that copies a screen's clamp starts refusing
  /// rows the day somebody widens the screen.
  static const positiveMeasurement = NumericBound(min: 0, minIsExclusive: true);

  /// **Which of a tag's pulse modes a bearing was heard on** —
  /// `Observations.pulse_mode`, task 11.187.
  ///
  /// A slot number, not a measurement: 1, 2 or 3, matching [pulseModeColumns].
  /// The ceiling is [maxPulseModes] rather than a number chosen here, so
  /// widening the maximum cannot leave a bound that refuses the fourth slot on
  /// the wire while the app happily offers it.
  static const pulseModeSlot = NumericBound(min: 1, max: maxPulseModes + 0.0);

  /// **A stored yes/no** — 0 or 1, and nothing else.
  ///
  /// SQLite has no boolean type and this schema's integer columns are its
  /// nearest thing, so the bound is what makes the column a flag rather than a
  /// counter that happens to hold small numbers. The first column to use it is
  /// `Observations.signal_irregular` (task 11.193).
  ///
  /// **NULL is not 0 and this bound says nothing about it.** A bound is only
  /// consulted for a value that is present; "nobody was asked" is the column's
  /// absent state and is argued where the column is declared.
  static const flag = NumericBound(min: 0, max: 1);
}

/// One column in the canonical schema.
class ColumnSpec {
  const ColumnSpec(
    this.name,
    this.type, {
    this.nullable = true,
    this.primaryKey = false,
    this.bound,
    this.numericBound,
  }) : assert(
         type == ColumnType.text || bound == null,
         'Only a text column takes a TextBound.',
       ),
       assert(
         type != ColumnType.text || numericBound == null,
         'Only a numeric column takes a NumericBound.',
       );

  final String name;
  final ColumnType type;

  /// The bound on a **text** column's value, and null for every other type.
  ///
  /// Null on a text column means nobody has decided, which
  /// `assertEveryTextColumnIsBounded` treats as a defect rather than as
  /// permission — see [TextBound].
  final TextBound? bound;

  /// The bound on a **real** or **integer** column's value, and null for a
  /// text column (task 11.136).
  ///
  /// Null on a numeric column means nobody has decided, which
  /// [assertEveryNumericColumnIsBounded] treats as a defect rather than as
  /// permission. A column with no honest range says [NumericBound.unbounded]
  /// out loud — see [NumericBound].
  final NumericBound? numericBound;

  /// Whether the column accepts NULL. Primary-key columns are always NOT NULL
  /// regardless of this flag — see [TableSpec.isNotNull].
  final bool nullable;

  /// Part of this table's primary key. Most tables are keyed
  /// `(<id>, project_id)` — see `syncTables` for why the id leads.
  final bool primaryKey;
}

/// One table's canonical column set, in declaration order.
class TableSpec {
  const TableSpec(this.name, this.columns);

  final String name;
  final List<ColumnSpec> columns;

  Iterable<String> get columnNames => columns.map((c) => c.name);

  List<ColumnSpec> get primaryKeyColumns =>
      columns.where((c) => c.primaryKey).toList();

  /// True if [column] may not hold NULL. A primary-key column is NOT NULL even
  /// where the app's SQLite DDL doesn't say so — SQLite quirk: a bare
  /// `TEXT PRIMARY KEY` column actually *does* accept NULL (only `INTEGER
  /// PRIMARY KEY`, the rowid alias, is implicitly NOT NULL). Postgres applies
  /// NOT NULL to every primary key. The canonical answer is Postgres's, since
  /// a NULL primary key is meaningless in both and only SQLite's leniency
  /// permits it.
  bool isNotNull(ColumnSpec column) => column.primaryKey || !column.nullable;
}

/// The six sync/merge columns every table carries (technical doc's "Global
/// Data Conventions"). Mirrors `_syncColumns` in the app's
/// `lib/data/db/schema.dart` — the app's DDL strings stay SQLite-specific, but
/// the *set* is declared once, here.
///
/// `server_seq` and `received_at` are deliberately **absent**: those are
/// server-only bookkeeping (task 10.5). Keeping them out of the shared spec is
/// what makes Phase 10's invariant 3 ("non-nullable server columns are
/// forbidden; a device that has never synced must still write rows fine")
/// structural rather than a promise — no client code can reference a column
/// that isn't in the shared declaration.
const List<ColumnSpec> syncColumns = [
  ColumnSpec(
    'created_at',
    ColumnType.text,
    nullable: false,
    bound: TextBound.timestamp,
  ),
  ColumnSpec(
    'updated_at',
    ColumnType.text,
    nullable: false,
    bound: TextBound.timestamp,
  ),
  ColumnSpec('deleted_at', ColumnType.text, bound: TextBound.timestamp),
  ColumnSpec(
    'revision',
    ColumnType.integer,
    nullable: false,
    numericBound: NumericBound.nonNegativeCounter,
  ),
  ColumnSpec('last_modified_by', ColumnType.text, bound: TextBound.identifier),
  ColumnSpec('origin_device_id', ColumnType.text, bound: TextBound.identifier),
];

/// The local + UTC + offset timestamp triple for a recorded domain time.
/// [offsetColumn] is named explicitly because the schema is not uniform about
/// it: the four domain-time tables use `timezone_offset`, while
/// `Triangulation_Sessions` uses `started_at_offset`.
List<ColumnSpec> _timeColumns(String prefix, String offsetColumn) => [
  ColumnSpec(
    '${prefix}_local',
    ColumnType.text,
    nullable: false,
    bound: TextBound.timestamp,
  ),
  ColumnSpec(
    '${prefix}_utc',
    ColumnType.text,
    nullable: false,
    bound: TextBound.timestamp,
  ),
  ColumnSpec(
    offsetColumn,
    ColumnType.text,
    nullable: false,
    bound: TextBound.timestamp,
  ),
];

/// `Tags`' own columns, named so `Tables.tagVersions` can be derived from them
/// rather than repeating a subset by hand (task 11.32).
const List<ColumnSpec> _tagColumns = [
  ColumnSpec(
    'tag_id',
    ColumnType.text,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  // Task 11.219 (schema v14, **schema major 3**): a tag belongs to exactly one
  // project. The id leads and the scope follows, for the reason schema v6
  // gives on `syncTables` — the leading key column is the one the index can be
  // searched on alone, and by-id lookup is the query this schema runs most.
  ColumnSpec(
    'project_id',
    ColumnType.text,
    nullable: false,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  ColumnSpec(
    'frequency_mhz',
    ColumnType.real,
    nullable: false,
    numericBound: NumericBound.frequencyMhz,
  ),
  ColumnSpec(
    'pulse_rate',
    ColumnType.real,
    numericBound: NumericBound.positiveMeasurement,
  ),
  ColumnSpec('pulse_pattern', ColumnType.text, bound: TextBound.name),
  ColumnSpec(
    'tag_name',
    ColumnType.text,
    nullable: false,
    bound: TextBound.name,
  ),
  // **`date_put_on`, `date_removed` and `capture_date` were here until schema
  // v17 (task 11.243, schema major 5).** They made a `Tags` row a
  // *deployment*; a tag is a piece of equipment now and the dates belong to
  // the link, which is `Tables.deployments`. `capture_date` was removed
  // rather than moved — design §5.
  //
  // **`status` stayed, and it means the equipment's state** — working,
  // failed, retired, lost. It is emphatically *not* "deployed": whether a
  // collar is currently on an animal is derived from `Deployments` and must
  // not be stored twice.
  ColumnSpec(
    'status',
    ColumnType.text,
    nullable: false,
    bound: TextBound.enumerated,
  ),
  ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
  ...syncColumns,
  // Added by schema v4 (tag colour coding). **Retired by schema v16 (task
  // 11.240)**: colour is the animal's, and it lives on
  // `Individuals.color_hex` and nowhere else. The column stays on the wire
  // because dropping one is a major bump and v16 was scoped additive; it is
  // nullable since v16, a v16 writer always sends null, and nothing reads
  // it — see `TagColumnKind.retired`, which is the declaration rather than
  // this comment. **Nullable was a major bump as well** (task 11.242 spent
  // major 4 on it; `wire_shape_freeze.dart` refuses the next one).
  ColumnSpec('color_hex', ColumnType.text, bound: TextBound.hexColor),
  // Added by schema v12 (task 11.187): the tag's pulse modes. Declared after
  // `color_hex` because that is where `ALTER TABLE ADD COLUMN` put them on
  // every existing device, and the app's schema test compares declaration
  // order.
  //
  // **Slot 1's rate is `pulse_rate` above, not a column here** — see
  // `pulse_modes.dart` for why renaming it was the one option not available.
  //
  // **Every one of them is nullable, including slot 1's name**, and that is a
  // wire-compatibility decision rather than a shrug. A `NOT NULL` column with
  // no default is refused by Postgres when a client that predates it pushes a
  // row, which would turn a *minor* schema difference into a device that
  // cannot sync — the exact thing `schemaMajorVersion`'s split exists to
  // avoid. A NULL slot-1 name reads as `defaultPulseModeNames[0]`, never as
  // "no modes": see `PulseModeSet.of`, which cannot return an empty list.
  ColumnSpec('pulse_mode_1_name', ColumnType.text, bound: TextBound.name),
  ColumnSpec('pulse_mode_2_name', ColumnType.text, bound: TextBound.name),
  ColumnSpec(
    'pulse_mode_2_rate_bpm',
    ColumnType.real,
    numericBound: NumericBound.positiveMeasurement,
  ),
  ColumnSpec('pulse_mode_3_name', ColumnType.text, bound: TextBound.name),
  ColumnSpec(
    'pulse_mode_3_rate_bpm',
    ColumnType.real,
    numericBound: NumericBound.positiveMeasurement,
  ),
  // Task 11.219 (schema v14): provenance. Two projects' tags are the same
  // physical collar exactly when their `lineage_id` values are equal.
  //
  // **`lineage_id` is NOT NULL and never null in practice**: a tag created in
  // place mints one, a copy carries its source's unchanged, and the v14
  // migration sets every existing tag's to its own `tag_id` — already unique,
  // already unguessable, and true, because nobody copied it.
  //
  // **`copied_at` is null on a tag created in place**, and that is the
  // information: a tag that was always in one project was not copied, and
  // stamping today's date on it would be a claim about a past nobody observed
  // (schema v9's rule, and v11's, and v12's).
  //
  // Neither is read by anything live — see `TagColumnKind.provenance` and
  // `assertSealedColumnsFeedNoReachability`, which is the mechanism rather
  // than the promise.
  ColumnSpec(
    'lineage_id',
    ColumnType.text,
    nullable: false,
    bound: TextBound.identifier,
  ),
  ColumnSpec('copied_at', ColumnType.text, bound: TextBound.timestamp),
  // **`individual_id` was here for exactly one schema version** — added by
  // task 11.240 at v16, removed by 11.243 at v17. A tag does not name its
  // animal; a `Deployments` row names both, and says *between which dates*.
  // See `Tables.deployments` §2 for the three things that bought.
];

/// `Deployments`' columns (task 11.243, schema v17). See
/// `Tables.deployments` for what the table is and why it exists.
const List<ColumnSpec> _deploymentColumns = [
  ColumnSpec(
    'deployment_id',
    ColumnType.text,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  // Project-scoped for the reason `Tags` and `Individuals` are (task 11.219):
  // the id leads and the scope follows, so by-id lookup can use the index
  // alone.
  ColumnSpec(
    'project_id',
    ColumnType.text,
    nullable: false,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  // Both ends are NOT NULL: a deployment with no tag or no animal is not a
  // deployment, it is a blank row. Both are same-project composite foreign
  // keys, the shape every reference into `Tags` has had since v14.
  ColumnSpec(
    'tag_id',
    ColumnType.text,
    nullable: false,
    bound: TextBound.identifier,
  ),
  ColumnSpec(
    'individual_id',
    ColumnType.text,
    nullable: false,
    bound: TextBound.identifier,
  ),
  // **Nullable, per Michael 2026-09-13** — *"It is okay to make the tag put on
  // date and tag off dates empty."* The consequence is stated on
  // `Tables.deployments` and it is counter-intuitive: a deployment with no
  // attached date covers no interval, so it attributes no bearings at all.
  // That is correct (nobody knows when it started, so nobody can say which
  // bearings it covers) and it is asserted rather than left to be discovered.
  ColumnSpec('attached_date', ColumnType.text, bound: TextBound.timestamp),
  // Null means **still on the animal**, not "unknown". An open-ended
  // deployment covers everything from `attached_date` onward.
  ColumnSpec('removed_date', ColumnType.text, bound: TextBound.timestamp),
  ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
  ...syncColumns,
  // **Task 11.331 (schema v20): the zone this row's days were written in** —
  // the project's zone at that moment, an IANA name. A bare day in
  // `attached_date` or `removed_date` is the start of that day *in this
  // zone*, so the row reads as the same day on every phone and on the
  // server (`deploymentDateFor`, `DeploymentInterlock`). After the sync
  // columns because that is where `ALTER TABLE ADD COLUMN` puts it.
  //
  // **Nullable because this is a minor**: a v19 device pushes no zone, and
  // `NOT NULL` would refuse its every deployment. Null means *written before
  // v20 (or by an older build since)*, read in the reader's own zone on a
  // phone and as instants on the server — the reading every build gave it
  // before this column existed.
  ColumnSpec('time_zone', ColumnType.text, bound: TextBound.timeZoneName),
];

/// `Individuals`' own columns (task 11.240, schema v16). See
/// `Tables.individuals` for what the table is.
const List<ColumnSpec> _individualColumns = [
  ColumnSpec(
    'individual_id',
    ColumnType.text,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  // Project-scoped for the reason `Tags` is (task 11.219): the id leads and
  // the scope follows.
  ColumnSpec(
    'project_id',
    ColumnType.text,
    nullable: false,
    primaryKey: true,
    bound: TextBound.identifier,
  ),
  // The animal's name — "Marie". NOT NULL because an individual is *named*
  // into existence: the backfill takes the collar's label, and a screen that
  // creates one asks for a name. Bounded as a name, like `tag_name`.
  ColumnSpec('name', ColumnType.text, nullable: false, bound: TextBound.name),
  // **The one home of colour.** NOT NULL: an animal with no colour would put
  // every screen back to inventing one.
  ColumnSpec(
    'color_hex',
    ColumnType.text,
    nullable: false,
    bound: TextBound.hexColor,
  ),
  // `IndividualStatus` — the animal's, never the collar's.
  ColumnSpec(
    'status',
    ColumnType.text,
    nullable: false,
    bound: TextBound.enumerated,
  ),
  // Optional, free text: "kiwi", "brown kiwi", a Latin binomial — whatever
  // the project writes. Not an enum, because no closed list would survive
  // the second study species.
  ColumnSpec('species', ColumnType.text, bound: TextBound.name),
  // `IndividualSex`, or null where nobody recorded it.
  ColumnSpec('sex', ColumnType.text, bound: TextBound.enumerated),
  ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
  // Provenance, with exactly the meaning the pair has on `Tags`: recorded,
  // exported, read by nothing live. Two projects' individuals are the same
  // animal exactly when their `lineage_id` values are equal — Ponui 2025 and
  // Ponui 2026 in one dataset — and nothing in the app resolves one, which
  // `assertSealedColumnsFeedNoReachability` enforces. `copied_at` is null on
  // an individual created in place, for schema v9's reason: a date invented
  // for it would be a claim about a past nobody observed.
  ColumnSpec(
    'lineage_id',
    ColumnType.text,
    nullable: false,
    bound: TextBound.identifier,
  ),
  ColumnSpec('copied_at', ColumnType.text, bound: TextBound.timestamp),
  ...syncColumns,
];

/// The columns `Tables.tagVersions` carries a historical copy of: exactly the
/// `Tags` columns [tagColumnKinds] declares [TagColumnKind.measurementContext],
/// with their own types and nullability, in `Tags` declaration order.
///
/// **This is the derivation task 11.32 turns on.** Write the four names out
/// here instead and they are a hand-maintained list of "the fields worth
/// copying" — the fifth instance of the drift defect the task exists to avoid.
/// Derived, declaring a new tag column `measurementContext` is the whole of
/// what it takes to make it travel with every bearing, and forgetting to add it
/// to the version table is not a thing that can happen.
///
/// It is checked from two directions. [assertEveryTagColumnDeclaresItsKind]
/// makes a column with no kind fail rather than default, and the app's
/// `schema_matches_shared_spec_test.dart` compares this derived spec against
/// the SQLite schema the migrations actually build — so adding a
/// `measurementContext` column without also writing the `Tag_Versions`
/// migration is a red test, not a silently missing field.
final List<ColumnSpec> _versionedTagColumns = [
  for (final column in _tagColumns)
    if (versionedTagColumnNames.contains(column.name)) column,
];

/// Every table's canonical column set, as of [latestSchemaVersion].
///
/// This is the schema *after* all migrations have run — it is not a history.
/// The app's SQLite migrations and the server's Postgres migrations are each
/// responsible for arriving at exactly this shape; tests on both sides assert
/// they do (`test/data/schema_matches_shared_spec_test.dart` in the app,
/// `test/schema/postgres_schema_test.dart` in the server). Adding a column
/// means: append it here, add a migration on each side, and bump
/// [latestSchemaVersion].
final List<TableSpec> tableSpecs = [
  TableSpec(Tables.users, [
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'first_name',
      ColumnType.text,
      nullable: false,
      bound: TextBound.personName,
    ),
    const ColumnSpec(
      'last_name',
      ColumnType.text,
      nullable: false,
      bound: TextBound.personName,
    ),
    const ColumnSpec(
      'email',
      ColumnType.text,
      nullable: false,
      bound: TextBound.email,
    ),
    ...syncColumns,
  ]),
  TableSpec(Tables.userEmails, [
    const ColumnSpec(
      'user_email_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'email',
      ColumnType.text,
      nullable: false,
      bound: TextBound.email,
    ),
    const ColumnSpec(
      'recorded_at',
      ColumnType.text,
      nullable: false,
      bound: TextBound.timestamp,
    ),
    ...syncColumns,
  ]),
  TableSpec(Tables.projects, [
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_name',
      ColumnType.text,
      nullable: false,
      bound: TextBound.name,
    ),
    const ColumnSpec('description', ColumnType.text, bound: TextBound.notes),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    const ColumnSpec(
      'owner_user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'creation_date',
      ColumnType.text,
      nullable: false,
      bound: TextBound.timestamp,
    ),
    const ColumnSpec(
      'bbox_min_lat',
      ColumnType.real,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'bbox_min_lon',
      ColumnType.real,
      numericBound: NumericBound.longitude,
    ),
    const ColumnSpec(
      'bbox_max_lat',
      ColumnType.real,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'bbox_max_lon',
      ColumnType.real,
      numericBound: NumericBound.longitude,
    ),
    const ColumnSpec(
      'datum',
      ColumnType.text,
      nullable: false,
      bound: TextBound.name,
    ),
    ...syncColumns,
    // Added by schema v2 — declared after the sync columns because that's
    // where `ALTER TABLE ADD COLUMN` put them on every existing device, and
    // the app's schema test compares declaration order.
    const ColumnSpec(
      'coordinate_format',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'triangulation_window_minutes',
      ColumnType.integer,
      nullable: false,
      numericBound: NumericBound.positiveMeasurement,
    ),
    // Task 11.56 (schema v18): provenance, with the meaning the pair has on
    // `Tags` and `Individuals` — two projects are seasons of one study
    // exactly when their `lineage_id` values are equal, and `copied_at` is
    // when the copy was made. Recorded, exported, read by nothing live
    // (`provenanceColumns` and `assertSealedColumnsFeedNoReachability`).
    //
    // **Nullable, unlike the tag's, because this arrived as a minor.** A
    // `NOT NULL` column with no default would refuse every `Projects` row a
    // v17 device pushes, which is the change `wire_shape_freeze.dart`'s
    // table says a minor may not make. So null is a legal value on the wire
    // and it means *this project was never copied*: every reader treats a
    // null lineage as the project's own id (`Project.effectiveLineageId`),
    // which is what the v14 migration wrote into every tag's for the same
    // reason — already unique, already unguessable, and true.
    const ColumnSpec('lineage_id', ColumnType.text, bound: TextBound.identifier),
    const ColumnSpec('copied_at', ColumnType.text, bound: TextBound.timestamp),
    // **Task 11.331 (schema v20): the project's time zone** — the field
    // site's, an IANA name, defaulting to the zone at the center of the
    // project's area and confirmed by its creator. New deployment days and
    // the deployment form's "today" are read in it; each deployment row
    // copies it into its own `time_zone` when written, so changing this later
    // rewrites nothing. **Nullable because this is a minor**: a v19 device's
    // project row carries none, and every reader then derives the zone from
    // the area's center the same way on every device (`Project.effectiveTimeZone`).
    const ColumnSpec(
      'time_zone',
      ColumnType.text,
      bound: TextBound.timeZoneName,
    ),
  ]),
  TableSpec(Tables.projectMemberships, [
    const ColumnSpec(
      'membership_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'join_date',
      ColumnType.text,
      nullable: false,
      bound: TextBound.timestamp,
    ),
    const ColumnSpec('end_date', ColumnType.text, bound: TextBound.timestamp),
    const ColumnSpec(
      'role',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    ...syncColumns,
  ]),
  // Task 11.240 (schema v16). Before `Tags` and `Deployments`, which name it.
  TableSpec(Tables.individuals, _individualColumns),
  TableSpec(Tables.tags, _tagColumns),
  // Task 11.243 (schema v17). After both tables it references.
  TableSpec(Tables.deployments, _deploymentColumns),
  // Task 11.32 (schema v9). Its measurement columns are **derived** from the
  // `Tags` spec above via [tagColumnKinds] — see [_versionedTagColumns].
  TableSpec(Tables.tagVersions, [
    const ColumnSpec(
      'tag_version_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    // Task 11.219 (schema v14): a version lives inside the project its tag
    // lives in. `TAG_COPY_ON_ADD_DESIGN.md` §2.2 answers the question this
    // raises — where a tag's history lives once the tag is project-local —
    // with "beside their tag, one chain per project copy". Task 11.32's design
    // is untouched: a bearing still points at the version row that was current
    // when it was taken.
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    // The tag this is a version of. Not part of the key: a tag has many
    // versions, and the version's own id is what an observation points at.
    const ColumnSpec(
      'tag_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    // When this version took effect (UTC ISO-8601). The first version of a tag
    // carries the tag's own creation time; a later one carries the moment the
    // person said the tag had *changed*. It is provenance, not a lookup key —
    // an observation names its version by id, never by "whichever version was
    // current at my timestamp", because the two disagree whenever a bearing is
    // entered after the fact.
    const ColumnSpec(
      'effective_from',
      ColumnType.text,
      nullable: false,
      bound: TextBound.timestamp,
    ),
    ..._versionedTagColumns,
    ...syncColumns,
  ]),
  TableSpec(Tables.triangulationSessions, [
    const ColumnSpec(
      'session_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'tag_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    const ColumnSpec('label', ColumnType.text, bound: TextBound.name),
    ..._timeColumns('started_at', 'started_at_offset'),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
  ]),
  TableSpec(Tables.observations, [
    const ColumnSpec(
      'observation_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    // Nullable since schema v3: a `note`-type observation needn't cite a tag.
    const ColumnSpec('tag_id', ColumnType.text, bound: TextBound.identifier),
    const ColumnSpec(
      'session_id',
      ColumnType.text,
      bound: TextBound.identifier,
    ),
    ..._timeColumns('timestamp', 'timezone_offset'),
    const ColumnSpec(
      'latitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'longitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.longitude,
    ),
    const ColumnSpec(
      'position_accuracy_m',
      ColumnType.real,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec(
      'position_source',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'elevation',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'altitude_agl',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'observation_type',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'magnetic_bearing',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'true_north_bearing',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'bearing_uncertainty',
      ColumnType.real,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec(
      'bearing_capture_method',
      ColumnType.text,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'bearing_method',
      ColumnType.text,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'magnetic_bearing_start',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'magnetic_bearing_end',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'true_north_bearing_start',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'true_north_bearing_end',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'magnetic_declination',
      ColumnType.real,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'wmm_model_version',
      ColumnType.text,
      bound: TextBound.name,
    ),
    const ColumnSpec('antenna_type', ColumnType.text, bound: TextBound.name),
    const ColumnSpec(
      'receiver_gain',
      ColumnType.real,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'signal_type',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'signal_strength',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'bearing_quality',
      ColumnType.text,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
    // Added by schema v9 (task 11.32): the `Tag_Versions` row this bearing was
    // recorded against, or NULL. Declared after the sync columns because that
    // is where `ALTER TABLE ADD COLUMN` put it on every existing device.
    //
    // **NULL means "not recorded", never "whatever the tag says now".** Every
    // row that predates schema v9 has it, and nothing backfills them: a bearing
    // taken last season genuinely does not know what the tag read at the time,
    // and inventing an answer from today's tag row is the exact falsehood this
    // task exists to remove. Imported and pasted records land the same way —
    // see `ObservationShare` and `SharedObservationImporter`.
    const ColumnSpec(
      'tag_version_id',
      ColumnType.text,
      bound: TextBound.identifier,
    ),
    // Added by schema v12 (task 11.187): **which of the tag's pulse modes the
    // receiver was hearing**, as a slot number — 1, 2 or 3.
    //
    // **The mode's identity, never its words.** The name and the rate at the
    // time live on the `Tag_Versions` row `tag_version_id` names, which is
    // where a fact about the tag belongs; copying the words here would make a
    // renamed mode disagree with itself between two bearings taken the same
    // afternoon.
    //
    // **NULL is an ordinary answer with three causes**, and no backfill turns
    // any of them into a number. A row written before v12 says nothing here
    // and is read through `signal_type` instead (see [SignalType], which maps
    // the two values that column has always had onto slots 1 and 2). A record
    // with no tag has no modes to number. And a pasted or imported replica
    // deliberately drops it, for the reason `ObservationShare.writableColumns`
    // gives about `tag_version_id`: a slot number names a mode in the
    // *sender's* tag, and the replica is relabelled onto whichever local tag
    // the receiver picked.
    const ColumnSpec(
      'pulse_mode',
      ColumnType.integer,
      numericBound: NumericBound.pulseModeSlot,
    ),
    // Added by schema v13 (task 11.193): **the person heard something wrong
    // with the signal itself.** Michael, 2026-09-07: *"a flag for all signal
    // recordings — not for a weak tag, but for one that seems to be
    // malfunctioning, such as when the inter-pulse duration is irregular."*
    //
    // **A fact about one listening moment, not about the collar.** It is not
    // `TagStatus.malfunction` and neither is derived from the other: the status
    // is the collar's current state and has only one useful answer, today's,
    // while this is *what I heard, at this time, from this spot.* Several of
    // these are the evidence that would later justify setting the status, and
    // that direction is a person deciding, never a query.
    //
    // **One bit, because that is what the person is sure of.** "It sounded
    // wrong" is a judgement somebody makes confidently in one second with a
    // receiver at their ear; a 1-to-5 scale of how wrong is a number they would
    // guess at, and a guessed number is indistinguishable from a measured one
    // once it is in a column. Degrees of *signal* already exist next to it
    // (`signal_strength`), and degrees of *bearing* trust too
    // (`bearing_quality`) — neither is this.
    //
    // **NULL means nobody was asked, and nothing backfills it.** Three causes,
    // exactly as `pulse_mode` above has three: a row written before v13 (the
    // control did not exist, and a bearing taken last season cannot be asked
    // now whether the pulses sounded even); a record type with no signal in it
    // at all — a note, a truth point, a no-signal sweep — where the question
    // has no meaning; and a payload from a build older than the one that added
    // it. **0 is a different answer from NULL and the more common one**: it
    // means somebody recorded a signal, had the control in front of them and
    // did not tick it.
    //
    // **It withdraws nothing.** Taking a bearing out of a position estimate is
    // its own act with its own row (`Tables.observationExclusions`, task 11.7)
    // and somebody's name on it. `AnalysisEligibility` does not read this
    // column, and `test/data/analysis/analysis_eligibility_test.dart` watches
    // that it does not.
    const ColumnSpec(
      'signal_irregular',
      ColumnType.integer,
      numericBound: NumericBound.flag,
    ),
  ]),
  // Task 11.7 (schema v7). See `Tables.observationExclusions` for why a mark
  // is a row of its own rather than two columns on `Observations`.
  TableSpec(Tables.observationExclusions, [
    const ColumnSpec(
      'exclusion_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    // The observation taken out of analysis.
    const ColumnSpec(
      'observation_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    // Who marked it — not the observation's author, who is untouched.
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'kind',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    // Set only when `kind` is 'superseded': the observation that replaces it.
    const ColumnSpec(
      'superseded_by_observation_id',
      ColumnType.text,
      bound: TextBound.identifier,
    ),
    const ColumnSpec('reason', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
  ]),
  TableSpec(Tables.nonDetections, [
    const ColumnSpec(
      'non_detection_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'user_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    ..._timeColumns('timestamp', 'timezone_offset'),
    const ColumnSpec(
      'latitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'longitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.longitude,
    ),
    const ColumnSpec(
      'position_accuracy_m',
      ColumnType.real,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec(
      'position_source',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'elevation',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'altitude_agl',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.unbounded,
    ),
    const ColumnSpec(
      'tag_ids_listened_for',
      ColumnType.text,
      nullable: false,
      bound: TextBound.idList,
    ),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
  ]),
  TableSpec(Tables.estimatedPositions, [
    const ColumnSpec(
      'position_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'tag_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    ..._timeColumns('timestamp', 'timezone_offset'),
    const ColumnSpec(
      'latitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'longitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.longitude,
    ),
    // **The ellipse: all three present, or all three empty** (task 11.323,
    // schema v19, major 6). Empty means *no ellipse* — two bearings cross
    // exactly, so there is no scatter to measure. Until v19 these were
    // `NOT NULL` and the app wrote 0 × 0, a perfectly precise position that
    // [NumericBound.positiveMeasurement] then refused, so the estimate never
    // left the phone. A present axis is still a measurement and still > 0.
    const ColumnSpec(
      'semi_major_axis',
      ColumnType.real,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec(
      'semi_minor_axis',
      ColumnType.real,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec(
      'rotation_angle',
      ColumnType.real,
      numericBound: NumericBound.degrees,
    ),
    const ColumnSpec(
      'method',
      ColumnType.text,
      nullable: false,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'observation_ids_used',
      ColumnType.text,
      nullable: false,
      bound: TextBound.idList,
    ),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
  ]),
  TableSpec(Tables.actualTagLocations, [
    const ColumnSpec(
      'location_id',
      ColumnType.text,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'project_id',
      ColumnType.text,
      nullable: false,
      primaryKey: true,
      bound: TextBound.identifier,
    ),
    const ColumnSpec(
      'tag_id',
      ColumnType.text,
      nullable: false,
      bound: TextBound.identifier,
    ),
    ..._timeColumns('timestamp', 'timezone_offset'),
    const ColumnSpec(
      'latitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.latitude,
    ),
    const ColumnSpec(
      'longitude',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.longitude,
    ),
    const ColumnSpec(
      'uncertainty_radius',
      ColumnType.real,
      nullable: false,
      numericBound: NumericBound.positiveMeasurement,
    ),
    const ColumnSpec('notes', ColumnType.text, bound: TextBound.notes),
    ...syncColumns,
    // Task 11.33 (schema v10), **after the sync columns on purpose** — that is
    // where `ALTER TABLE ADD COLUMN` put them on every existing device, and
    // `Observations.tag_version_id` is declared the same way for the same
    // reason.
    //
    // Both nullable, and null means "not recorded" on both. `found_kind` says
    // whether the animal, the collar, or both were found: only
    // `animal_and_collar` validates the triangulation of a live collared
    // animal, so nothing may collapse this to a boolean. `tag_version_id` is
    // task 11.32's rule applied to a truth point — what the tag read when
    // somebody stood in front of that collar — so an export made after a
    // rename can still be matched to the animal it describes. Neither is
    // backfilled: a point recorded before v10 genuinely does not know either
    // answer.
    const ColumnSpec(
      'found_kind',
      ColumnType.text,
      bound: TextBound.enumerated,
    ),
    const ColumnSpec(
      'tag_version_id',
      ColumnType.text,
      bound: TextBound.identifier,
    ),
    // Task 11.93 (schema v11), after v10's pair for the same reason they sit
    // after the sync columns: that is where `ALTER TABLE ADD COLUMN` put them
    // on every device that already ran v10.
    //
    // **`user_id` — who walked in and found it.** Nullable, and null means
    // "not recorded" on a row written before v11. It is deliberately *not*
    // backfilled from `last_modified_by`, which names whoever last touched the
    // row: the two are different facts and presenting the second as the first
    // is the defect class this project keeps finding.
    //
    // **It is a fact about the record, not a permission.** Michael settled
    // this on 2026-08-31: any contributor may still edit or delete a truth
    // point, because the person who saw the pride and the person driving the
    // truck may not be the same person. The rule stays `anyUser`; see
    // `SyncTable.vouchesForAForeignNameIn` for the one thing this column does
    // change at the boundary.
    const ColumnSpec('user_id', ColumnType.text, bound: TextBound.identifier),
    // **`position_source` — how the coordinate was got**, the same vocabulary
    // `Observations` has carried since v1. Nullable for the same reason as
    // above. It became necessary when the position became editable: a fix
    // somebody later nudged by hand is a third thing, and until v11 nothing
    // recorded which of the three a point was.
    const ColumnSpec(
      'position_source',
      ColumnType.text,
      bound: TextBound.enumerated,
    ),
  ]),
];

/// Lookup by table name.
final Map<String, TableSpec> tableSpecsByName = {
  for (final spec in tableSpecs) spec.name: spec,
};

/// Every `text` column declares a [TextBound], and no other column type does
/// (task 10.97, findings L-7 and N-7).
///
/// **This is the drift guard, and the reason the bound lives on the column
/// rather than in a list inside `RowValidator`.** The original scope for L-7
/// was seven named columns; by the time anyone came to fix it the schema had
/// moved on and the list was stale — `Observation_Exclusions` had been added
/// with three unbounded text columns nobody had thought to append. A list of
/// column names cannot notice a new column. A rule derived from the schema
/// itself can only be satisfied by deciding, which is the whole point: adding a
/// text column now forces somebody to say what bounds it, in the same commit.
///
/// Throws [StateError] naming every column that has not been decided. Called
/// from `table_columns_test.dart`.
void assertEveryTextColumnIsBounded() {
  final undecided = <String>[];
  final misapplied = <String>[];
  for (final spec in tableSpecs) {
    for (final column in spec.columns) {
      if (column.type == ColumnType.text && column.bound == null) {
        undecided.add('${spec.name}.${column.name}');
      }
      if (column.type != ColumnType.text && column.bound != null) {
        misapplied.add('${spec.name}.${column.name}');
      }
    }
  }
  if (undecided.isEmpty && misapplied.isEmpty) return;
  throw StateError(
    [
      if (undecided.isNotEmpty)
        'Text columns with no declared bound (pick one from TextBound, or add '
            'a new kind if none fits): ${undecided.join(', ')}',
      if (misapplied.isNotEmpty)
        'Non-text columns carrying a TextBound: ${misapplied.join(', ')}',
    ].join('\n'),
  );
}

/// Every `real` and `integer` column declares a [NumericBound], and no text
/// column does (task 11.136).
///
/// **The same drift guard [assertEveryTextColumnIsBounded] applies to text,
/// and it is here for a reason that guard learned the hard way.** The range
/// checks it replaced were twenty-nine column checks written inline in
/// `RowValidator.validate`, keyed by column name — a list that cannot notice a
/// new column, which is exactly how `Observation_Exclusions` arrived with
/// three unbounded text columns. A numeric column added tomorrow now has to
/// say what bounds it, in the same commit, and [NumericBound.unbounded] is how
/// "nothing, and I looked" is said.
///
/// Throws [StateError] naming every column that has not been decided. Called
/// from `numeric_bounds_test.dart`.
void assertEveryNumericColumnIsBounded() {
  bool isNumeric(ColumnSpec c) =>
      c.type == ColumnType.real || c.type == ColumnType.integer;
  final undecided = <String>[];
  final misapplied = <String>[];
  for (final spec in tableSpecs) {
    for (final column in spec.columns) {
      if (isNumeric(column) && column.numericBound == null) {
        undecided.add('${spec.name}.${column.name}');
      }
      if (!isNumeric(column) && column.numericBound != null) {
        misapplied.add('${spec.name}.${column.name}');
      }
    }
  }
  if (undecided.isEmpty && misapplied.isEmpty) return;
  throw StateError(
    [
      if (undecided.isNotEmpty)
        'Numeric columns with no declared bound (pick one from NumericBound, '
            'or say NumericBound.unbounded if none fits): '
            '${undecided.join(', ')}',
      if (misapplied.isNotEmpty)
        'Non-numeric columns carrying a NumericBound: '
            '${misapplied.join(', ')}',
    ].join('\n'),
  );
}
