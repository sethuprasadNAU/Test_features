import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.124 — the refusal code, and the three bounds it exists to hold.
///
/// The single most important test in this file is
/// **"an unrecognised code reads as no code at all"**. Task 11.122 shipped an
/// honest default for a refusal this device cannot explain, and the whole
/// value of that default is that it is correct for reasons nobody has invented
/// yet. A parse that threw, or that guessed at a nearest match, would replace
/// it with a wrong specific answer the first time a server shipped a code this
/// build predates.
void main() {
  group('the code is derived from the column\'s declared bound', () {
    test('every text shape with a rule of its own declares a code, and the '
        'one shape with no rule declares none', () {
      // Derived from the enum rather than listed here: a shape added with the
      // wrong code is a defect this test can see, but a shape added and left
      // off a hand-written list here is one it could not.
      for (final shape in TextShape.values) {
        if (shape == TextShape.free) {
          expect(
            shape.violationCode,
            isNull,
            reason: 'free text has no shape rule, so no violation to name',
          );
        } else {
          expect(
            shape.violationCode,
            isNotNull,
            reason:
                '$shape has a rule, so a value failing it must be reportable',
          );
        }
      }
    });

    test('no two shapes share a code, so a message cannot be written for the '
        'wrong one', () {
      final codes = [
        for (final shape in TextShape.values)
          if (shape.violationCode != null) shape.violationCode!,
      ];
      expect(codes.toSet(), hasLength(codes.length));
    });

    test('a name the server will not store is refused under the name code, '
        'and the code comes off the column not the check', () {
      // U+202E RIGHT-TO-LEFT OVERRIDE — task 11.84's measured case, and the
      // one 11.122 could not name.
      final issues = RowValidator.validate(Tables.users, {
        'user_id': 'user-1',
        'first_name': 'Ann\u202ESmith',
        'last_name': 'Ranger',
        'email': 'ann@example.com',
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded, hasLength(1));
      expect(coded.single.field, 'first_name');
      expect(coded.single.code, RowIssueCode.textNotAName);
      // The same value the column's own bound declares, reached from the
      // schema rather than from this expectation.
      expect(
        coded.single.code,
        tableSpecsByName[Tables.users]!.columns
            .firstWhere((c) => c.name == 'first_name')
            .bound!
            .shape
            .violationCode,
      );
    });

    test('an over-length value is refused under the length code, once', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'x' * 5000,
        'frequency_mhz': 150.0,
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded, hasLength(1));
      expect(coded.single.code, RowIssueCode.textTooLong);
      expect(coded.single.field, 'tag_name');
    });

    test('a non-string in a text column is refused under the type code', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 42,
        'frequency_mhz': 150.0,
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded.single.code, RowIssueCode.textWrongType);
      expect(coded.single.field, 'tag_name');
    });

    /// **Task 11.136 replaced this test, and what it used to say is worth
    /// keeping.** It read *"a range failure carries no code, because no
    /// declared bound named it"* — and that was true and correct: the
    /// frequency window was written inline in `RowValidator`, so there was
    /// nothing to read a code off and the device fell back to task 11.122's
    /// honest default. The fix was to give the range a declaration, not to
    /// type a code at the check.
    test('a range failure is refused under the code its declared bound '
        'names, and the code comes off the column not the check', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'Coco',
        'frequency_mhz': 99999.0,
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded, hasLength(1));
      expect(coded.single.field, 'frequency_mhz');
      expect(coded.single.code, RowIssueCode.numberAboveMaximum);
      // Reached from the schema rather than from this expectation: the column
      // declares the bound, the bound says which limit was broken, and the
      // limit names the code.
      final declared = tableSpecsByName[Tables.tags]!.columns
          .firstWhere((c) => c.name == 'frequency_mhz')
          .numericBound!;
      expect(coded.single.code, declared.violatedBy(99999)!.violationCode);
    });

    test('a check with no declaration behind it still carries no code, and '
        'still reaches the honest default', () {
      // A closed enum's membership is not a bound the schema declares — the
      // allowed strings live in `enums.dart` and the check is written inline.
      // **That is the honest state, not an oversight**, and it is asserted so
      // that a later task widening the vocabulary has to come past it
      // deliberately.
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'Coco',
        'frequency_mhz': 150.0,
        'status': 'somewhat-active',
      });
      expect(issues, isNotEmpty);
      expect(issues.every((i) => i.code == null), isTrue);
    });

    test('every numeric limit is refused under its own code, from the '
        'declaration', () {
      // One row per limit, each on a column whose declared bound is the thing
      // being broken. Nothing here names a code that is written anywhere but
      // on `NumericLimit`.
      final cases = <String, (Object?, RowIssueCode)>{
        'latitude below the floor': (-999.0, RowIssueCode.numberBelowMinimum),
        'latitude above the ceiling': (999.0, RowIssueCode.numberAboveMaximum),
        'a latitude that is not a real number': (
          double.nan,
          RowIssueCode.numberNotARealNumber,
        ),
        // Finding M-1's string form: `double.tryParse` accepts "NaN", so a
        // hand-written JSON row could carry one as text.
        'the string NaN': ('NaN', RowIssueCode.numberNotARealNumber),
        'an infinity': (
          double.infinity,
          RowIssueCode.numberNotARealNumber,
        ),
      };
      cases.forEach((label, expected) {
        final issues = RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'project_id': 'proj-1',
          'latitude': expected.$1,
          'longitude': 10.0,
        });
        final coded = issues.where((i) => i.code != null).toList();
        expect(coded, hasLength(1), reason: label);
        expect(coded.single.field, 'latitude', reason: label);
        expect(coded.single.code, expected.$2, reason: label);
      });
    });

    test('an exclusive minimum is refused as below the minimum, so zero '
        'uncertainty is not a measurement', () {
      final issues = RowValidator.validate(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'bearing_uncertainty': 0.0,
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded.single.code, RowIssueCode.numberBelowMinimum);
      expect(coded.single.field, 'bearing_uncertainty');
    });

    test('a colour that is not #RRGGBB is refused under its shape code', () {
      final issues = RowValidator.validate(Tables.tags, {
        'tag_id': 'tag-1',
        'tag_name': 'Coco',
        'frequency_mhz': 150.0,
        'color_hex': 'not-a-colour',
      });
      final coded = issues.where((i) => i.code != null).toList();
      expect(coded.single.code, RowIssueCode.textNotAColor);
      expect(coded.single.field, 'color_hex');
    });

    test('a value inside every declared bound draws no issue at all', () {
      // The direction a bound test most often forgets. Every limit above is
      // asserted from the other side here, on one row, so a bound written
      // upside down fails something.
      expect(
        RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'project_id': 'proj-1',
          'latitude': -89.9,
          'longitude': 179.9,
          'magnetic_bearing': 0.0,
          'true_north_bearing': 360.0,
          'bearing_uncertainty': 0.1,
          'position_accuracy_m': 5.0,
          'elevation': -430.0,
        }),
        isEmpty,
      );
      expect(
        RowValidator.validate(Tables.tags, {
          'tag_id': 'tag-1',
          'tag_name': 'Coco',
          'frequency_mhz': 150.0,
          'pulse_rate': 40.0,
          'color_hex': '#1B9E77',
        }),
        isEmpty,
      );
    });
  });

  group('an unrecognised code reads as no code at all', () {
    test('a code this build has never seen parses to null, not an error and '
        'not a nearest match', () {
      expect(RowIssueCode.fromWire('text_not_a_haiku'), isNull);
      expect(RowIssueCode.fromWire(''), isNull);
      expect(RowIssueCode.fromWire(null), isNull);
      expect(RowIssueCode.fromWire(17), isNull);
      // Not case- or prefix-tolerant: a near miss is a different code, and
      // guessing is the thing this returns null to avoid.
      expect(RowIssueCode.fromWire('TEXT_NOT_A_NAME'), isNull);
      expect(RowIssueCode.fromWire('text_not_a_name '), isNull);
    });

    test('a detail whose code is unrecognised is dropped whole', () {
      expect(
        RowRefusal.fromJson({'code': 'text_not_a_haiku', 'field': 'notes'}),
        isNull,
      );
      expect(RowRefusal.fromJson('not a map'), isNull);
      expect(RowRefusal.fromJson(null), isNull);
    });

    test('every code round-trips through its wire string', () {
      for (final code in RowIssueCode.values) {
        expect(RowIssueCode.fromWire(code.wire), code);
      }
    });

    test('the wire strings are distinct, since they are stored on device and '
        'read back by a later build', () {
      final wires = RowIssueCode.values.map((c) => c.wire).toList();
      expect(wires.toSet(), hasLength(wires.length));
    });
  });

  group('the detail may ride only on an invalid outcome (§4.13)', () {
    test('a code beside an unauthorized outcome is dropped at construction, '
        'so a misbehaving server cannot reopen the existence oracle', () {
      final response = SyncPushResponse(
        applied: 0,
        outcomes: const {
          'Users/user-1': SyncRowOutcome.unauthorized,
          'Tags/tag-1': SyncRowOutcome.invalid,
        },
        highestServerSeq: null,
        refusals: const {
          'Users/user-1': RowRefusal(code: RowIssueCode.textNotAName),
          'Tags/tag-1': RowRefusal(code: RowIssueCode.textTooLong),
        },
      );
      expect(response.refusals.keys, ['Tags/tag-1']);
      expect(response.toJson()['refusals'], hasLength(1));
    });

    test('the same bound holds on parse, not only on build — the server is '
        'not the only thing that decides what a client renders', () {
      final parsed = SyncPushResponse.fromJson({
        ...const SyncEnvelope().toJson(),
        'applied': 0,
        'outcomes': {
          'Users/user-1': 'unauthorized',
          'Users/user-2': 'lost_to_server',
          'Tags/tag-1': 'invalid',
        },
        'refusals': {
          'Users/user-1': {'code': 'text_not_a_name', 'field': 'first_name'},
          'Users/user-2': {'code': 'text_too_long', 'field': 'last_name'},
          'Tags/tag-1': {'code': 'text_too_long', 'field': 'tag_name'},
        },
        'highest_server_seq': null,
      });
      expect(parsed.refusals.keys, ['Tags/tag-1']);
    });

    test('a detail on a row with no outcome at all is dropped', () {
      final response = SyncPushResponse(
        applied: 0,
        outcomes: const {},
        highestServerSeq: null,
        refusals: const {
          'Tags/tag-1': RowRefusal(code: RowIssueCode.textTooLong),
        },
      );
      expect(response.refusals, isEmpty);
    });
  });

  group('the wire', () {
    test('a detail survives a JSON round-trip, field and all', () {
      final json = SyncPushResponse(
        applied: 0,
        outcomes: const {'Users/user-1': SyncRowOutcome.invalid},
        highestServerSeq: 9,
        refusals: const {
          'Users/user-1': RowRefusal(
            code: RowIssueCode.textNotAName,
            field: 'first_name',
          ),
        },
      ).toJson();
      final parsed = SyncPushResponse.fromJson(json);
      expect(parsed.refusals['Users/user-1']!.code, RowIssueCode.textNotAName);
      expect(parsed.refusals['Users/user-1']!.field, 'first_name');
    });

    test('no refusals means the key is absent, so an older client sees the '
        'response it has always seen', () {
      final json = SyncPushResponse(
        applied: 1,
        outcomes: const {'Users/user-1': SyncRowOutcome.inserted},
        highestServerSeq: 3,
      ).toJson();
      expect(json.containsKey('refusals'), isFalse);
    });

    test('a response from a server that sends no refusals parses to none, '
        'rather than to a crash', () {
      final parsed = SyncPushResponse.fromJson({
        ...const SyncEnvelope().toJson(),
        'applied': 0,
        'outcomes': {'Users/user-1': 'invalid'},
        'highest_server_seq': null,
      });
      expect(parsed.refusals, isEmpty);
    });

    test('a malformed refusals block is ignored rather than failing the '
        'whole push', () {
      for (final malformed in <Object?>[
        'not a map',
        7,
        ['a', 'list'],
        {'Tags/tag-1': 'not a map either'},
        {17: 'a non-string key'},
      ]) {
        final parsed = SyncPushResponse.fromJson({
          ...const SyncEnvelope().toJson(),
          'applied': 0,
          'outcomes': {'Tags/tag-1': 'invalid'},
          'refusals': malformed,
          'highest_server_seq': null,
        });
        expect(parsed.refusals, isEmpty, reason: 'for $malformed');
        // The rest of the response still arrived: a bad detail must not cost
        // the client the outcomes it needs to hold its rows.
        expect(parsed.outcomes['Tags/tag-1'], SyncRowOutcome.invalid);
      }
    });

    test('a detail with no field is legal, and survives', () {
      final parsed = SyncPushResponse.fromJson({
        ...const SyncEnvelope().toJson(),
        'applied': 0,
        'outcomes': {'Tags/tag-1': 'invalid'},
        'refusals': {
          'Tags/tag-1': {'code': 'text_too_long'},
        },
        'highest_server_seq': null,
      });
      expect(parsed.refusals['Tags/tag-1']!.code, RowIssueCode.textTooLong);
      expect(parsed.refusals['Tags/tag-1']!.field, isNull);
    });
  });
}
