import 'db_codec.dart';
import 'enums.dart';
import 'row_refusal.dart';
import 'schema_constants.dart';
import 'table_columns.dart';
import 'tag_color_palette.dart';

/// A single field-level problem found while validating an incoming row.
/// Carried in a `MergeReport` (app-side) and surfaced in the CSV import
/// preview, so the user sees exactly what was rejected and why. Shared by the
/// app's client-side validation and the server's server-side validation of
/// pushed rows so a hand-crafted request can't insert what the client's forms
/// would reject.
class RowIssue {
  const RowIssue({
    required this.table,
    required this.primaryKeyValue,
    required this.field,
    required this.message,
    this.code,
  });

  final String table;

  /// The offending row's primary-key value (or composite, joined) for display.
  final String primaryKeyValue;
  final String field;

  /// **Server-side only.** Written for a server log, never sent to a client:
  /// no server-supplied prose reaches a device's screen (security model
  /// §4.13), and this string can quote a column *value*. [code] is the part
  /// that crosses the wire.
  final String message;

  /// The closed-vocabulary reason, taken from the column's declared bound, or
  /// null when the check that failed has no bound to derive one from
  /// (task 11.124, widened to numbers by task 11.136).
  ///
  /// **Null on purpose for the checks a schema cannot supply.** A code is only
  /// honest where the declaration itself says what went wrong — [TextShape]
  /// and [NumericLimit] do; a closed enum's membership and `Users.email`'s
  /// presence rule are still written inline and still carry none. Inventing
  /// codes for those would mean typing them at each check, which is the
  /// hand-maintained list this design exists to avoid; a null code reaches
  /// task 11.122's honest default, which is correct for every case nobody has
  /// named yet.
  final RowIssueCode? code;

  @override
  String toString() => '$table[$primaryKeyValue].$field: $message';
}

/// Bound-checks the domain columns of an incoming row (technical doc: "Bound-
/// check every field on BOTH manual entry and CSV import: frequency (sane VHF
/// range), bearing (0–360), uncertainty (>0), lat/lon ranges, pulse rate").
///
/// It also checks that every closed-enum column holds a value this build
/// recognizes. This matters specifically because the merge path inserts raw
/// column-maps *without* going through a model's `fromDb` — an unrecognized
/// enum string would otherwise slip into the database and only blow up later
/// when a screen tries to read it. Validating here rejects it up front.
///
/// Returns the empty list for a valid row. Only the fields that are *present*
/// (non-null) are range/enum-checked; NOT NULL is left to SQLite's/Postgres's
/// own constraints on insert.
abstract final class RowValidator {
  /// Longest accepted length for a primary-key column's value.
  ///
  /// Every table's primary key becomes a Postgres btree index entry
  /// (`postgres_schema.dart`'s `CREATE TABLE ... PRIMARY KEY (...)`), and
  /// btree tuples top out at roughly a third of an 8 KB page. Past that, an
  /// `INSERT` does not draw a typed refusal — it throws mid-statement. Task
  /// 10.56 (finding I-5) found exactly this class on the sync envelope's
  /// `device_id`/`project_id`; a row's own primary-key columns reach the
  /// identical kind of index and had no bound at all, table-agnostically,
  /// until now. Same cap the envelope layer applies to `device_id` and
  /// `project_id`, so a value refused there is refused identically here.
  static const int maxPrimaryKeyLength = 200;

  /// Longest accepted `email` value on `Users`/`User_Emails`.
  ///
  /// Both columns are btree-indexed for cross-device dedup (`idx_users_email`,
  /// `idx_user_emails_email` in `postgres_schema.dart`) — the same crash class
  /// as [maxPrimaryKeyLength], on a column that is not itself a primary key.
  /// 320 matches RFC 5321's longest legal address and the bound
  /// `/auth/magic-link` already applies to a caller-supplied email.
  static const int maxEmailLength = 320;

  /// Characters an identifier may never contain: C0 controls, `DEL`, and the
  /// C1 range.
  ///
  /// Task 10.75 (finding K-4). The length bound above answers *"can this
  /// value crash a btree insert"*; it does not answer *"is this value an
  /// identifier at all"*. A `user_id` of `a`, a NUL byte, then `b` is three
  /// characters and
  /// passes every check this class had: SQLite stores it, Postgres refuses it
  /// mid-`INSERT` (`22021`, untyped, on the sync push rather than here), and
  /// every log line, diagnostics page and `Sync_Conflicts` snapshot that
  /// renders it is now rendering an attacker-chosen control sequence. A
  /// newline is the same problem one step softer — it forges a line break in
  /// anything line-oriented.
  ///
  /// This is deliberately a *shape* rule and not a format rule. Every
  /// identifier this app mints is a UUID v4, but requiring that would refuse
  /// the ids Phase 6's file merges already carry and would bind the wire
  /// format to one generator's output forever. Refusing values that cannot be
  /// an identifier under any generator is the bound that stays true.
  static final RegExp _forbiddenInIdentifier = RegExp(
    '[\\u0000-\\u001f\\u007f-\\u009f]',
  );

  /// Whether [value] is shaped like an identifier this app may store in a
  /// primary key or an authorship column.
  ///
  /// Exposed because the identifier does not always arrive inside a row map:
  /// `ServerIdentityAdopter` is handed a bare `user_id` string by the server's
  /// redemption response and must answer this question *before* it builds the
  /// row it would otherwise validate — see security model §4.20.
  static bool isWellFormedIdentifier(Object? value) =>
      value is String &&
      value.trim().isNotEmpty &&
      value.length <= maxPrimaryKeyLength &&
      !_forbiddenInIdentifier.hasMatch(value);

  /// **What a person's name may contain** — stated as an allowlist, because a
  /// list of what it may not contain is already known to be wrong (task
  /// 11.89, finding R-1).
  ///
  /// ## Why this is an allowlist now
  ///
  /// Until this task the rule was two denylists: the C0/C1 control characters,
  /// and the bidirectional overrides, marks and isolates. Both were written
  /// deliberately, three days earlier, by somebody thinking about exactly the
  /// attack this rule exists to stop — **and they still missed `U+2028 LINE
  /// SEPARATOR` and `U+2029 PARAGRAPH SEPARATOR`**, which are line terminators
  /// rather than direction controls and which the text engine honours as hard
  /// breaks. A requester could therefore choose what the *second line* of the
  /// owner's approval tile said, and put an address-shaped string there.
  ///
  /// That is not an argument for adding two characters. It is the proof that
  /// **a denylist over Unicode cannot be finished**: it has to enumerate every
  /// way a glyph can misbehave, in a standard that gains characters every year,
  /// and it fails silently and invisibly when it is incomplete. An allowlist
  /// fails the other way — a character nobody considered is refused, and
  /// somebody says so — which is the direction this project wants to fail in.
  ///
  /// ## What is allowed, and why each one is here
  ///
  /// * `\p{L}` **letters** and `\p{M}` **combining marks**, in every script.
  ///   Together these are what a name is made of, whether it is written in
  ///   Latin, Cyrillic, Arabic, Devanagari or Han. Marks are not optional:
  ///   without them `Đặng Thị` and `नमस्ते` are refused.
  /// * `\p{Nd}` **decimal digits** — `Bill Gates 3rd`. Harmless: a digit
  ///   cannot reorder, break or hide anything.
  /// * `\p{Pd}` **dash punctuation** — every hyphen and dash, so
  ///   `Fernández-López` and the CJK dashes are all covered by one property
  ///   rather than by a list of hyphens somebody remembered.
  /// * `\p{Zs}` **space separators** — the ordinary space *and* `U+3000
  ///   IDEOGRAPHIC SPACE`, which is the normal word space in Japanese, and
  ///   `U+00A0 NO-BREAK SPACE`, which arrives on any paste from a web page.
  ///   **This is the cut that matters:** `Zs` is spaces, and the line and
  ///   paragraph separators are `Zl` and `Zp` — different categories. So
  ///   "a space is allowed, a line break is not" is expressed by Unicode's own
  ///   distinction rather than by naming two code points, and R-1 closes as a
  ///   class rather than as an instance.
  /// * `.` and `,` — initials and suffixes: `J. R. Smith`, `Smith, Jr.`
  /// * `'` (U+0027) and `U+2019` — `O'Brien` typed, and the curly-apostrophe
  ///   spelling a keyboard's autocorrect produces
  ///   instead. (The letter apostrophes U+02BB and U+02BC, used in
  ///   Hawaiian and Uzbek names, are already `\p{L}`.)
  /// * `·` and `・` — the middle dots, which are how Japanese writes
  ///   a foreign given and family name: `ジョン・スミス`.
  /// * `U+200C` **zero-width non-joiner** and `U+200D` **zero-width joiner**.
  ///   These two are format characters, so they are the one deliberate
  ///   exception, and it is argued rather than overlooked: several Persian and
  ///   Indic names do not render correctly without them. They are also the
  ///   only format characters that shape letters instead of relocating them —
  ///   they cannot break a line and cannot reverse a run, which is what every
  ///   other member of that category is refused for.
  ///
  /// ## What this newly refuses, said plainly
  ///
  /// Beyond the two line separators, this now refuses characters the old rule
  /// admitted: `@`, brackets, slashes, symbols and emoji. **That is wider than
  /// R-1 and deliberately so** — R-1's payload was an address on a second
  /// line, and `Alice michael@example.org` on *one* line is the same forgery
  /// with the line break removed. A name is letters, and the strings people
  /// use to decorate one are also the strings used to forge one.
  ///
  /// **The cost is real and is not hidden here:** somebody whose stored name
  /// is `Dana Reyes (PhD)` has a name this rule refuses. What happens to such
  /// a row is measured in
  /// `test/data/sync/name_rule_widened_existing_rows_test.dart` rather than
  /// discovered — see [isWellFormedPersonName].
  static final RegExp _disallowedInPersonName = RegExp(
    // Written with escapes for every character that is not plain ASCII, and
    // never as literals: a zero-width joiner sitting in a source file is
    // invisible in a diff and in a review, which is the same property that
    // makes these characters worth ruling on in the first place.
    '[^\\p{L}\\p{M}\\p{Nd}\\p{Pd}\\p{Zs}.,\''
    '\\u2019\\u00b7\\u30fb\\u200c\\u200d]',
    unicode: true,
  );

  /// Whether [value] is shaped like a person's name this app may store or
  /// display (task 11.81; made an allowlist by task 11.89).
  ///
  /// **Empty is allowed, deliberately.** The server mints a `Users` row for a
  /// newly-admitted member with both names empty, because it does not know
  /// their name and must not invent one — see `JoinService`. Refusing empty
  /// here would refuse the honest case and force a fabricated name onto the
  /// row that attributes field observations.
  ///
  /// Exposed because the name does not always arrive inside a row map: the
  /// join-request route is handed a bare claimed name and must answer this
  /// question before anything is written. **That route calls this, rather than
  /// restating the rule**, so the bound on a name is one declaration and not
  /// two (Michael's decision 1, 2026-08-31).
  ///
  /// Length is **not** checked here: it comes from
  /// `TextBound.personName.maxLength`, so there is exactly one number, and
  /// callers outside the row walk read it from there.
  ///
  /// **What happens to a `Users` row that was legal when it was written and is
  /// not legal now** (task 11.89, measured — not reasoned about). Widening this
  /// rule is a change to a *synced* column, so the blast radius is rows already
  /// sitting on devices in the field. There are two directions and they behave
  /// differently:
  ///
  /// * **Your own row, going out.** The push is refused once, the row is held
  ///   durably and shown on the sync status screen, and it is never re-offered
  ///   while it is unchanged — it is a reported rejection, not a retry loop
  ///   (measured by task 11.84). The row survives locally and untouched, and
  ///   correcting the name on the profile screen re-offers it automatically.
  ///   That screen refuses the name where it is typed (task 11.122), asking
  ///   *this* predicate, so the correction cannot be typed wrong twice.
  /// * **A colleague's row, coming in.** The pull refuses it, records the drop
  ///   durably and reports it — it is not silently swallowed. But **you cannot
  ///   fix it, because it is not your name**: their name is simply absent on
  ///   your device until they correct it, at which point it arrives on its own.
  ///   Their observations are unaffected; `Users` is a separate table, and
  ///   nothing else about them is refused.
  ///
  /// Both directions are covered by
  /// `test/data/sync/name_rule_widened_existing_rows_test.dart`.
  static bool isWellFormedPersonName(Object? value) =>
      value is String && !_disallowedInPersonName.hasMatch(value);

  /// The first character of [value] this rule refuses, or `null` if it refuses
  /// none.
  ///
  /// Exposed so the screens that check a name where it is typed can say *which*
  /// character is the problem instead of asserting a cause they would have to
  /// guess at — `CLAUDE.md`'s standing rule, and the defect task 11.122 fixed
  /// one screen along. The caller decides how to describe it; this only reports
  /// the fact.
  static int? firstDisallowedPersonNameRune(String value) {
    for (final rune in value.runes) {
      if (_disallowedInPersonName.hasMatch(String.fromCharCode(rune))) {
        return rune;
      }
    }
    return null;
  }

  static List<RowIssue> validate(String table, Map<String, Object?> row) {
    final issues = <RowIssue>[];
    final pk = _pkValue(table, row);
    // The primary-key loop that used to stand here — length bound (task
    // 10.56), string-type check (task 10.67), identifier shape (task 10.75) —
    // is gone because the schema walk below now does all three, on every
    // primary-key column *and* on every other identifier column, from one
    // declaration. Nothing is dropped: each of those columns declares
    // `TextBound.identifier`, which is that same triple. What changes is that
    // the set is derived rather than listed, so it cannot fall behind the
    // schema, and a value refused as a primary key is refused identically as a
    // foreign key.
    // Task 10.67: identity/authorship columns (`user_id`/`owner_user_id`
    // where they aren't already part of the table's primary key, plus the
    // `SyncMeta` audit columns every synced table carries) had NO type check
    // at all here — `RowValidator` bound-checks range/enum columns but had
    // never been extended to cover these, even though it's the one gate
    // that runs on every write path (including the merge path, which
    // inserts raw column-maps without a model's `fromRow`). This is the
    // client-side sibling of the class task 10.64 fixed in
    // `RowAuthorizer._governingValue`: a malformed `owner_user_id`/`user_id`
    // reaching `base_repository.dart`'s advisory authorization check
    // unguarded, rather than being refused here before it is ever written.
    //
    // Task 10.75 added the *shape* half. A type check answers "is this a
    // string"; it does not answer "is this an identifier". These columns are
    // written into by the merge path, the archive path and — finding K-4 —
    // the magic-link adoption path, and every one of them names a row that
    // authorization, `Sync_Conflicts` snapshots and the diagnostics console
    // later read back. An unbounded or control-character-bearing
    // `owner_user_id` is refused here rather than at the Postgres insert that
    // would otherwise throw untyped.
    // `last_modified_by` and `origin_device_id` — every table's audit
    // columns — are checked by the schema walk below along with every other
    // identifier column, rather than by name here.

    void enumField(String field, Set<String> allowed) {
      final v = row[field];
      if (v == null) return;
      if (v is! String || !allowed.contains(v)) {
        issues.add(_issue(table, pk, field, 'unknown value "$v"'));
      }
    }

    // **The schema walk (task 10.97, widened to numbers by task 11.136).** One
    // pass over this table's declared columns, asking each one what its own
    // declaration makes answerable: a text column, its `TextBound`; a numeric
    // column, its `NumericBound`.
    //
    // **Derived from `tableSpecs`, not from a list here**, and that is the
    // whole fix. Findings L-7 and N-7 were not "seven columns lack a bound" —
    // they were "the set of columns that lack a bound is written down
    // somewhere that cannot notice a new column." `Observation_Exclusions`
    // proved it by arriving with three unbounded text columns after the list
    // was written. A walk cannot miss a column the schema has.
    //
    // **Task 11.136 moved the ranges in here for a second reason: a code.**
    // The twenty-nine `range(...)`/`positive(...)` column checks that used to
    // sit in the switch below were correct checks with nothing behind them to
    // name,
    // so a refused latitude reached the device carrying no detail. A judgement
    // written at a call site cannot be read back; one written on the column
    // can. The judgements themselves did not change — they are the same
    // numbers, now spelled `NumericBound.latitude`, `NumericBound.degrees`,
    // `NumericBound.frequencyMhz`, `NumericBound.positiveMeasurement`.
    //
    // **What the switch below still owns:** the checks a schema genuinely
    // cannot supply — which strings a closed enum admits, and that
    // `Users.email` is present. Those still carry no code, which is honest:
    // there is no declaration to read one off.
    _boundDeclaredColumns(table, row, pk, issues);

    switch (table) {
      case Tables.users:
        final email = row['email'];
        if (email is! String || email.trim().isEmpty) {
          issues.add(_issue(table, pk, 'email', 'must not be empty'));
        }
      case Tables.userEmails:
        // Task 11.22: `user_id` is `MutationRule.author`'s governing column
        // for this table, and — unlike `Users`, where `user_id` is the
        // primary key and so already caught by the pk loop above — it is not
        // this table's primary key (`user_email_id` is). Nothing checked its
        // type here until now; only `RowAuthorizer`'s own explicit guard
        // (task 10.64) was catching a malformed value, and only during
        // authorization, not at this earlier gate every write path runs
        // through (task 10.68 recorded the gap and left it, since the
        // authorization-layer backstop already made it safe).
        final email = row['email'];
        if (email is! String || email.trim().isEmpty) {
          issues.add(_issue(table, pk, 'email', 'must not be empty'));
        }
      case Tables.projects:
        enumField(
          'coordinate_format',
          _enumValues(CoordinateFormat.values.map((e) => e.db)),
        );
      case Tables.projectMemberships:
        enumField('role', _enumValues(ProjectRole.values.map((e) => e.db)));
      case Tables.individuals:
        // Task 11.240. Both closed sets; `sex` is nullable and null passes
        // (nobody recorded it), a value present must be one of the three.
        enumField(
          'status',
          _enumValues(IndividualStatus.values.map((e) => e.db)),
        );
        enumField('sex', _enumValues(IndividualSex.values.map((e) => e.db)));
      case Tables.tags:
        enumField('status', _enumValues(TagStatus.values.map((e) => e.db)));
      case Tables.deployments:
        // Task 11.243. **The one thing a schema cannot say about this row:
        // the collar cannot come off before it went on.** Both columns are
        // nullable timestamps and the column walk above has already bounded
        // each on its own; what it cannot see is the pair.
        //
        // Deliberately *not* the interlock. Whether this deployment overlaps
        // another is a fact about the project's other rows, and this
        // validator sees one row at a time by design — the same reason
        // `superseded_by_observation_id` is not resolved here. The interlock
        // is `DeploymentInterlock`, enforced on the device at the point of
        // the link and on the server in `SyncService.applyPush`, which is the
        // only place that can see the rest of the project.
        final attached = DbCodec.decodeUtcOrNull(row['attached_date']);
        final removed = DbCodec.decodeUtcOrNull(row['removed_date']);
        if (attached != null && removed != null && removed.isBefore(attached)) {
          issues.add(
            _issue(
              table,
              pk,
              'removed_date',
              'is before attached_date — a collar cannot come off before it '
                  'went on',
            ),
          );
        }
      // `Tables.tagVersions` has no case of its own any more, and its absence
      // is the point (task 11.136). Task 11.32's rule — a frequency the tag
      // table would refuse must not become storable by arriving as a *version*
      // of that tag — used to be held by both arms calling one helper, which
      // is a rule somebody has to remember. `Tag_Versions` is derived from
      // `_tagColumns`, so it now carries the identical `NumericBound` objects
      // by construction and the walk above applies them. There is nothing left
      // for an arm here to do, and nothing left to forget.
      // `tag_id` names the tag a version is of. Not this table's primary key,
      // so the pk loop does not reach it — the same gap task 11.22 found on
      // `User_Emails.user_id`, closed here as the table landed.
      case Tables.observations:
        enumField(
          'position_source',
          _enumValues(PositionSource.values.map((e) => e.db)),
        );
        enumField(
          'observation_type',
          _enumValues(ObservationType.values.map((e) => e.db)),
        );
        enumField(
          'bearing_capture_method',
          _enumValues(BearingCaptureMethod.values.map((e) => e.db)),
        );
        enumField(
          'bearing_method',
          _enumValues(BearingMethod.values.map((e) => e.db)),
        );
        enumField(
          'signal_type',
          _enumValues(SignalType.values.map((e) => e.db)),
        );
        enumField(
          'signal_strength',
          _enumValues(SignalStrength.values.map((e) => e.db)),
        );
        enumField(
          'bearing_quality',
          _enumValues(BearingQuality.values.map((e) => e.db)),
        );
      case Tables.observationExclusions:
        // Task 11.7. `identityColumn` is the reattribution guard: the marker's
        // id must be a well-formed identity, so a crafted archive cannot pin a
        // data-quality decision on somebody who never made one.
        enumField(
          'kind',
          _enumValues(ObservationExclusionKind.values.map((e) => e.db)),
        );
      // `superseded_by_observation_id` is deliberately not checked against
      // the Observations table here. The validator sees one row at a time,
      // and sync legitimately delivers a mark before the replacement it
      // names — see the schema comment on why this table carries no foreign
      // key to it either.
      case Tables.nonDetections:
        enumField(
          'position_source',
          _enumValues(PositionSource.values.map((e) => e.db)),
        );
      case Tables.estimatedPositions:
        enumField(
          'method',
          _enumValues(EstimationMethod.values.map((e) => e.db)),
        );
      case Tables.actualTagLocations:
        // Task 11.33. Null is permitted (a row from before schema v10 records
        // no kind); a value that is present must be one of the three, because
        // an unrecognised kind would be silently uncountable by whatever
        // computes accuracy statistics later.
        enumField(
          'found_kind',
          _enumValues(GroundTruthKind.values.map((e) => e.db)),
        );
        // Task 11.93. Null is permitted (a row from before schema v11
        // records no source); a value that is present must be one of the
        // four, so an unrecognised source cannot make a hand-moved point read
        // as a measured one.
        enumField(
          'position_source',
          _enumValues(PositionSource.values.map((e) => e.db)),
        );
      // `tag_version_id` is bounded as an identifier by the schema walk
      // above and deliberately not resolved against `Tag_Versions` here,
      // for the reason `Observations.tag_version_id` gives: sync can
      // legitimately deliver the point before the version it names.
      // `user_id` (task 11.93) is bounded as an identifier by the same walk;
      // *whose* name it may be is `RowAuthorizer._authorizeNaming`'s
      // question, not this one's.
      // Triangulation_Sessions' own columns are all text, and the schema walk
      // above bounds every one of them. (This comment used to read "nothing to
      // bound-check beyond NOT NULL" — which was true of *ranges* and false of
      // the table, whose `label` and `notes` were unbounded free text.)
    }
    return issues;
  }

  /// The schema-derived half of [validate]: every declared column of [table],
  /// checked against what its own type makes checkable.
  ///
  /// A table absent from [tableSpecsByName] is skipped rather than refused —
  /// an unknown table is task 10.18's forward-compatibility case and is
  /// handled upstream, not here.
  static void _boundDeclaredColumns(
    String table,
    Map<String, Object?> row,
    String pk,
    List<RowIssue> issues,
  ) {
    final spec = tableSpecsByName[table];
    if (spec == null) return;

    for (final column in spec.columns) {
      final value = row[column.name];
      if (value == null) continue;

      switch (column.type) {
        case ColumnType.real:
        case ColumnType.integer:
          final numericBound = column.numericBound;
          // Null is impossible here for the same reason it is impossible on
          // the text arm: `assertEveryNumericColumnIsBounded` is a test, and a
          // numeric column with no declaration fails it. Skipping rather than
          // throwing keeps a schema mistake from taking down a sync.
          if (numericBound == null) continue;
          // A value that is not a number at all — task 11.158, and the text
          // arm's `textWrongType` one type over. Until then `_num` answered
          // null here and the column was simply skipped, so `latitude:
          // "north"` was refused by nothing and stored as it arrived. A
          // numeric *string* is not this case: `_num` parses `"42"` and the
          // declared range is applied to it below, exactly as if it had
          // arrived unquoted.
          final number = _num(value);
          if (number == null) {
            issues.add(
              _issue(
                table,
                pk,
                column.name,
                '${numericBound.messageFor(NumericLimit.wrongType)} '
                '(was ${value.runtimeType})',
                // Read off the limit, not written here — the same rule task
                // 11.136 established for the three limits that are
                // comparisons. See [NumericLimit.wrongType].
                code: NumericLimit.wrongType.violationCode,
              ),
            );
            continue;
          }
          final limit = numericBound.violatedBy(number);
          if (limit != null) {
            issues.add(
              _issue(
                table,
                pk,
                column.name,
                '${numericBound.messageFor(limit)} (was $number)',
                // Task 11.136: read off the bound the column declares, not
                // written here. See [NumericLimit.violationCode].
                code: limit.violationCode,
              ),
            );
          }

        case ColumnType.text:
          final bound = column.bound;
          // Null is impossible here: `assertEveryTextColumnIsBounded` is a
          // test, and a text column with no bound fails it. Skipping rather
          // than throwing keeps a schema mistake from taking down a sync.
          if (bound == null) continue;
          if (value is! String) {
            issues.add(
              _issue(
                table,
                pk,
                column.name,
                'must be a string (was ${value.runtimeType})',
                code: RowIssueCode.textWrongType,
              ),
            );
            continue;
          }
          if (value.length > bound.maxLength) {
            issues.add(
              _issue(
                table,
                pk,
                column.name,
                'must be ≤ ${bound.maxLength} characters '
                '(was ${value.length})',
                code: RowIssueCode.textTooLong,
              ),
            );
            // `else`, not a second `if`: `isWellFormedIdentifier` tests the
            // length bound too, so an oversize identifier would otherwise be
            // reported twice for one defect.
          } else {
            final failedShape = _violatedShape(bound.shape, value);
            if (failedShape != null) {
              issues.add(
                _issue(
                  table,
                  pk,
                  column.name,
                  _shapeMessage(failedShape),
                  // Task 11.124: read off the shape the column declares, not
                  // written here. See [TextShape.violationCode].
                  code: failedShape.violationCode,
                ),
              );
            }
          }
      }
    }
  }

  static Set<String> _enumValues(Iterable<String> values) => values.toSet();

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  // Mirror the sync_tables PKs without importing them (validator stays
  // dependency-light); fall back to a best-effort id-ish column.
  static const Map<String, List<String>> _pkByTable = {
    Tables.users: ['user_id'],
    Tables.userEmails: ['user_email_id'],
    Tables.projects: ['project_id'],
    Tables.projectMemberships: ['membership_id', 'project_id'],
    Tables.individuals: ['individual_id', 'project_id'],
    Tables.tags: ['tag_id', 'project_id'],
    Tables.deployments: ['deployment_id', 'project_id'],
    Tables.tagVersions: ['tag_version_id', 'project_id'],
    Tables.triangulationSessions: ['session_id', 'project_id'],
    Tables.observations: ['observation_id', 'project_id'],
    Tables.observationExclusions: ['exclusion_id', 'project_id'],
    Tables.nonDetections: ['non_detection_id', 'project_id'],
    Tables.estimatedPositions: ['position_id', 'project_id'],
    Tables.actualTagLocations: ['location_id', 'project_id'],
  };

  static List<String> _pkColumns(String table) => _pkByTable[table] ?? const [];

  static String _pkValue(String table, Map<String, Object?> row) =>
      _pkColumns(table).map((c) => row[c]?.toString() ?? '?').join('/');

  /// The shape [value] fails, or null when it satisfies the one its column
  /// declares (task 11.124).
  ///
  /// **An exhaustive switch with no `default`.** Adding a value to
  /// [TextShape] is then a compile error here rather than a shape that is
  /// silently never checked — the same discipline `HeldRowReason.forOutcome`
  /// applies to [SyncRowOutcome], and for the same reason: the failure of a
  /// missing case is invisible, because it looks exactly like a valid row.
  static TextShape? _violatedShape(TextShape shape, String value) =>
      switch (shape) {
        TextShape.free => null,
        TextShape.identifier => isWellFormedIdentifier(value) ? null : shape,
        TextShape.personName => isWellFormedPersonName(value) ? null : shape,
        TextShape.hexColor =>
          TagColorPalette.isValidHex(value) ? null : shape,
      };

  /// The server-log wording for a shape violation. Exhaustive for the same
  /// reason [_violatedShape] is; [TextShape.free] cannot reach here, because
  /// it has no rule to fail.
  static String _shapeMessage(TextShape shape) => switch (shape) {
    TextShape.free => 'is not a usable value',
    TextShape.identifier => 'is not a usable identifier',
    TextShape.personName =>
      'is not a usable name (control or bidirectional-override characters)',
    TextShape.hexColor => 'is not a hex color like #RRGGBB',
  };

  static RowIssue _issue(
    String table,
    String pk,
    String field,
    String msg, {
    RowIssueCode? code,
  }) => RowIssue(
    table: table,
    primaryKeyValue: pk,
    field: field,
    message: msg,
    code: code,
  );
}
