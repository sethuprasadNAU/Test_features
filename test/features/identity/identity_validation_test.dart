import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/identity/identity_validation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.122, item 1.** `validateRequiredName` used to ask one question —
/// is the field empty — while the server asked three. So a name carrying a
/// control character or a bidirectional override saved from either identity
/// screen without complaint, and the person found out one sync later, when
/// the server refused their whole `Users` row. That row is held once and
/// never retried (task 11.84 measured it), so "found out one sync later"
/// meant "found out from a screen that could not say why".
///
/// These tests are about **agreement with one declaration**, not about the
/// particular characters. Task 11.89 is about to widen
/// `RowValidator.isWellFormedPersonName`; the last group here is what makes
/// that widening reach these two screens without anybody having to remember
/// to come back to this file.
///
/// Every hostile character below is written as an escape on purpose: a
/// literal one is invisible in a diff and in a review, which is the entire
/// reason it is worth refusing.
void main() {
  group('validateRequiredName', () {
    test('an ordinary name is accepted', () {
      expect(validateRequiredName('Sam', 'First name'), isNull);
      expect(validateRequiredName('  Ranger  ', 'Last name'), isNull);
    });

    test('a name from a right-to-left script is accepted', () {
      // The point of refusing the *override* characters is that they are
      // never needed: the bidirectional algorithm lays these names out
      // correctly from the letters themselves. A check that refused them
      // would be a worse defect than the one it fixed.
      expect(validateRequiredName('نور', 'First name'), isNull);
      expect(
        validateRequiredName('אברהם', 'Last name'),
        isNull,
      );
    });

    test('empty and whitespace-only are still required', () {
      expect(validateRequiredName('', 'First name'), 'First name is required');
      expect(
        validateRequiredName(null, 'First name'),
        'First name is required',
      );
      expect(validateRequiredName('   ', 'Last name'), 'Last name is required');
    });

    test(
      'a bidirectional override is refused, and the message says what to do',
      () {
        // U+202E: the character that makes a stored name render as a
        // different name. See `RowValidator` and task 11.81.
        final message = validateRequiredName('Sam\u202ERanger', 'First name');
        expect(message, isNotNull);
        expect(message, contains('First name'));
        expect(
          message,
          contains('type it again'),
          reason:
              'The remedy has to be something a biologist can do. Naming the '
              'character class is not one.',
        );
      },
    );

    test('a visible character is quoted, not called hidden', () {
      // **Task 11.89.** Before this task every refusal said the name
      // "contains hidden formatting characters" and told the person to retype
      // rather than paste. That was true while the rule was two denylists of
      // invisible characters. It is not true now the rule is an allowlist: a
      // name can be refused for a bracket or an at-sign, which is neither
      // hidden nor the result of a paste, and "delete it and type it again"
      // produces the same rejection a second time.
      //
      // This is `CLAUDE.md`'s rule from the other side. The rule says a branch
      // that does not know the cause must not assert one; where the code *does*
      // know — and here it does, exactly — it should say which character, so
      // the person can act instead of guess.
      final message = validateRequiredName('Dana Reyes (PhD)', 'First name');
      expect(message, isNotNull);
      expect(
        message,
        contains('"("'),
        reason: 'quote the character, so they can find it and delete it',
      );
      expect(
        message,
        isNot(contains('hidden')),
        reason:
            'a bracket is not hidden, and telling somebody it is sends them '
            'looking for something that is not there',
      );
      expect(
        message,
        isNot(contains('type it again')),
        reason:
            'retyping is the remedy for a pasted invisible character and is '
            'no remedy at all for a bracket the person typed on purpose',
      );
    });

    test('an invisible character keeps the retype advice', () {
      // The other branch, and the reason both exist. A person cannot see
      // U+2028, so quoting it would print nothing and telling them to delete
      // "it" would be telling them to find something with no appearance.
      final message = validateRequiredName('Sam Ranger', 'First name');
      expect(message, isNotNull);
      expect(message, contains('hidden'));
      expect(message, contains('U+2028'));
      expect(message, contains('type it again'));
    });

    test('a control character is refused', () {
      expect(validateRequiredName('Sam\u0009Ranger', 'First name'), isNotNull);
      expect(validateRequiredName('Sam\u0000Ranger', 'Last name'), isNotNull);
    });

    test('a name past the shared length bound is refused, with the number', () {
      final tooLong = 'a' * (TextBound.personName.maxLength + 1);
      final message = validateRequiredName(tooLong, 'First name');
      expect(message, isNotNull);
      expect(message, contains('${TextBound.personName.maxLength}'));

      // Exactly at the bound is accepted — the server's check is `>`, and an
      // off-by-one here would refuse a name the server would have stored.
      expect(
        validateRequiredName(
          'a' * TextBound.personName.maxLength,
          'First name',
        ),
        isNull,
      );
    });
  });

  /// **The group that survives task 11.89.** It asserts that the screen and
  /// the server answer the same question, without restating what the answer
  /// is — so widening the rule in `RowValidator` cannot leave these two
  /// screens behind.
  group('the screen agrees with the declaration the server enforces', () {
    const candidates = <String>[
      'Sam',
      'نور',
      "O'Brien",
      'Sam\u202ERanger',
      'Sam\u202ARanger',
      'Sam\u200FRanger',
      'Sam\u061CRanger',
      'Sam\u2066Ranger',
      'Sam\u0009Ranger',
      'Sam\u0000Ranger',
      'Sam\u007FRanger',
      'Sam\u009FRanger',
    ];

    for (final candidate in candidates) {
      test('${candidate.codeUnits} is judged the same way on both sides', () {
        final screenAccepts =
            validateRequiredName(candidate, 'First name') == null;
        final trimmed = candidate.trim();
        final serverAccepts =
            RowValidator.isWellFormedPersonName(trimmed) &&
            trimmed.length <= TextBound.personName.maxLength;
        expect(
          screenAccepts,
          serverAccepts,
          reason:
              'A value the server will refuse must not be typeable, and a '
              'value the server accepts must not be refused at the screen.',
        );
      });
    }
  });
}
