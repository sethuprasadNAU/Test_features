import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  test('every text column declares what bounds it', () {
    assertEveryTextColumnIsBounded();
  });

  /// **Task 11.81 — a person's name is identity text, and is bounded as such.**
  ///
  /// ## What was actually true before this task, said plainly
  ///
  /// The brief for this task said the requester's claimed name must carry
  /// *"exactly the bounds `Users.first_name` already has — length, control
  /// characters, and bidirectional-override characters"*, and asked that they
  /// be reused rather than copied.
  ///
  /// **`Users.first_name` had one of those three.** It declared
  /// `TextBound.name`, which is a length cap of 200 and nothing else; the
  /// control-character and bidi rules did not exist anywhere in this codebase,
  /// for names or for anything else. So "reuse them" could not be done as
  /// written.
  ///
  /// What was done instead is what the brief's next sentence asked for:
  /// **centralise rather than copy.** `TextShape.personName` was added, and
  /// `Users.first_name` and `Users.last_name` now carry it, so the join-request
  /// route can call the same `RowValidator.isWellFormedPersonName` the synced
  /// column is checked against. There is one declaration of what a name may be,
  /// and it is the stricter one.
  ///
  /// **The behaviour change that follows, recorded because it is real:** a
  /// `Users` row whose name contains a control character or a bidi override is
  /// now refused on the sync path, where it was previously accepted. No honest
  /// name contains either.
  group("a person's name is bounded as identity, not as data", () {
    test('the two name columns carry the person-name shape', () {
      final users = tableSpecs.firstWhere((spec) => spec.name == Tables.users);
      for (final column in ['first_name', 'last_name']) {
        final spec = users.columns.firstWhere((c) => c.name == column);
        expect(
          spec.bound?.shape,
          TextShape.personName,
          reason:
              '$column is read by a person deciding whether to trust somebody, '
              'so it needs a shape and not only a length',
        );
      }
    });

    test('the join-request route reuses this bound rather than restating it', () {
      // The route reads `TextBound.personName.maxLength` and calls
      // `RowValidator.isWellFormedPersonName`. This pins that there is one
      // number and one predicate to read, so a second set cannot appear and
      // then disagree.
      expect(TextBound.personName.maxLength, TextBound.name.maxLength);
      expect(TextBound.personName.shape, TextShape.personName);
    });

    test('an ordinary name is accepted, in any script', () {
      for (final name in [
        'Dana Reyes',
        "O'Brien",
        'Ana María Fernández-López',
        'Иван Петров',
        'محمد الأحمد',
        '田中 花子',
        // Task 11.89 turned this rule into an allowlist, and an allowlist's
        // whole risk is refusing a real person. Every entry below is a name
        // shape the allowlist had to be *widened* to keep, and each one is
        // here because leaving it out was a live possibility while the rule
        // was being written.
        //
        // U+3000 IDEOGRAPHIC SPACE is the sharpest of them: it is the ordinary
        // word space in Japanese, and a rule allowing only U+0020 would have
        // refused a great many Japanese names while looking entirely
        // reasonable to somebody writing it in English. It is allowed because
        // Unicode itself separates spaces (Zs) from line and paragraph
        // separators (Zl, Zp) — which is the same distinction that closes R-1.
        '田中　花子',
        // U+00A0 NO-BREAK SPACE: what a paste from a web page leaves behind.
        'Dana Reyes',
        // U+30FB KATAKANA MIDDLE DOT: how Japanese separates a foreign given
        // name from a family name.
        'ジョン・スミス',
        // Combining marks. Without \p{M} these two are refused outright.
        'Đặng Thị',
        'नमस्ते',
        // U+200C ZERO WIDTH NON-JOINER: required for correct rendering of a
        // range of Persian and Indic names. The one format character let in,
        // argued rather than overlooked.
        'Ali‌Reza',
        // U+2019: the apostrophe a phone keyboard actually produces.
        'O’Brien',
        'Jean—Luc',
        'Bill Gates 3rd',
        'J. R. Smith',
        'Smith, Jr.',
        // Empty is allowed on purpose: the server mints a nameless `Users` row
        // for a newly-admitted member because it does not know their name and
        // must not invent one.
        '',
      ]) {
        expect(
          RowValidator.isWellFormedPersonName(name),
          isTrue,
          reason: '"$name" is a name somebody actually has',
        );
      }
    });

    test('a bidirectional override is refused', () {
      // **The attack the owner's pending-request screen is uniquely exposed
      // to.** It is the one place in this app where somebody decides whether
      // to trust a person by reading a string, and a right-to-left override
      // makes a stranger's name render as a colleague's with nothing on screen
      // to show that anything happened.
      //
      // The whole explicit set plus the implicit marks: a legitimate name never
      // needs one, because the bidirectional algorithm lays out Arabic, Hebrew
      // and mixed-script names correctly from the letters themselves. These
      // characters exist to *override* that, which is the capability refused.
      for (final code in [
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // embeddings and overrides
        0x2066, 0x2067, 0x2068, 0x2069, // isolates
        0x200E, 0x200F, 0x061C, // marks
      ]) {
        final name = 'Ann${String.fromCharCode(code)}Smith';
        expect(
          RowValidator.isWellFormedPersonName(name),
          isFalse,
          reason:
              'U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')} can '
              "make one person's name render as another's",
        );
      }
    });

    test('a control character is refused, and NUL especially', () {
      // NUL matters most: every value here reaches a Postgres `TEXT` column,
      // and Postgres refuses a NUL mid-statement rather than returning a typed
      // refusal — which is a bare 500 seen from outside. A newline is the same
      // problem one step softer: it forges a line break in anything
      // line-oriented, including the screen an owner is reading.
      // Written as escapes, never as literals. A NUL or a DEL sitting in a
      // source file is invisible in a diff and in a review — which is exactly
      // the property that makes it worth refusing in the first place.
      for (final name in [
        'Ann\u0000Smith',
        'Ann\nSmith',
        'Ann\u007FSmith',
        'Ann\u0007Smith',
      ]) {
        expect(RowValidator.isWellFormedPersonName(name), isFalse);
      }
    });

    test('the row walk refuses such a name on a real Users row', () {
      // Asserted through `validate` and not only through the predicate,
      // because a predicate nothing calls bounds nothing.
      final issues = RowValidator.validate(Tables.users, {
        'user_id': 'user-1',
        // U+202E RIGHT-TO-LEFT OVERRIDE, written as an escape because a literal
        // one is invisible in a diff — which is the whole reason it is refused.
        'first_name': 'Ann\u202EeciovSmith',
        'last_name': 'Smith',
        'email': 'ann@example.org',
        'created_at': '2026-08-31T00:00:00.000Z',
        'updated_at': '2026-08-31T00:00:00.000Z',
        'deleted_at': null,
        'revision': 0,
        'last_modified_by': 'user-1',
        'origin_device_id': null,
      });
      expect(issues, isNotEmpty);
      expect(issues.map((i) => i.field), contains('first_name'));
    });
  });

  /// **Task 11.89 — the rule is an allowlist now, and this is what that buys.**
  ///
  /// Finding R-1 was that the previous rule — two denylists, written three days
  /// earlier by somebody thinking about exactly this attack — missed `U+2028
  /// LINE SEPARATOR` and `U+2029 PARAGRAPH SEPARATOR`. **Adding two characters
  /// would have closed the instance and left the class open**, so the rule is
  /// now stated as what a name may contain.
  ///
  /// The cases below are deliberately not a list of forbidden characters, which
  /// is the thing this task removed. They are *witnesses*: each is a character
  /// the old denylists admitted and the allowlist refuses without ever having
  /// been told about it.
  group('a person name is bounded by what it may contain', () {
    test('the two line separators are refused — finding R-1', () {
      for (final code in [0x2028, 0x2029]) {
        expect(
          RowValidator.isWellFormedPersonName(
            'Ann${String.fromCharCode(code)}michael@example.org',
          ),
          isFalse,
          reason:
              'U+${code.toRadixString(16).toUpperCase()} is a hard line break '
              'to the text engine, so it let a stranger write the second line '
              "of the owner's approval tile",
        );
      }
    });

    test('characters nobody wrote a rule about are refused too', () {
      // **The test that could not exist under a denylist**, because under one
      // every entry here would first have had to be thought of. None of them
      // was; they fall out of the allowlist for free.
      //
      // Written as escapes throughout. A zero-width character sitting in a
      // source file as a literal is invisible in a diff and in a review, which
      // is the same property that makes it worth ruling on.
      const witnesses = <String, String>{
        'U+2060 WORD JOINER': 'Ann⁠Smith',
        'U+00AD SOFT HYPHEN': 'Ann­Smith',
        'U+FEFF ZERO WIDTH NO-BREAK SPACE': 'Ann﻿Smith',
        'an emoji': 'Dana \u{1F985}',
        // R-1's payload with its line break taken out. Refusing this on one
        // line is the reason the allowlist goes wider than the finding did.
        'an email address': 'Alice michael@example.org',
        'a parenthesised claim': 'Dana Reyes (project owner)',
        'a slash': 'Ann/Smith',
        'an underscore': 'Ann_Smith',
      };
      witnesses.forEach((label, name) {
        expect(
          RowValidator.isWellFormedPersonName(name),
          isFalse,
          reason: '$label is not something a name is made of',
        );
      });
    });

    test('every character the old denylists named is still refused', () {
      // The regression bar. Replacing a rule is the moment its previous
      // coverage can quietly narrow, so both old lists are asserted in full
      // here rather than assumed to be implied by the new one.
      const oldControls = [
        0x0000, 0x0007, 0x000a, 0x000d, 0x001f, 0x007f, 0x0085, 0x009f,
      ];
      const oldBidi = [
        0x061c, 0x200e, 0x200f,
        0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
        0x2066, 0x2067, 0x2068, 0x2069,
      ];
      for (final code in [...oldControls, ...oldBidi]) {
        expect(
          RowValidator.isWellFormedPersonName(
            'Ann${String.fromCharCode(code)}Smith',
          ),
          isFalse,
          reason:
              'U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')} was '
              'refused before task 11.89 and must still be',
        );
      }
    });

    test('it reports which character it refused, so a caller need not guess', () {
      // `CLAUDE.md`'s standing rule: the branch reached when the code does not
      // know why must not assert a cause. Here the code *does* know which
      // character it objected to, so it says — and the screens that check a
      // name where it is typed read this instead of describing a cause they
      // would be guessing at.
      expect(RowValidator.firstDisallowedPersonNameRune('Dana Reyes'), isNull);
      expect(
        RowValidator.firstDisallowedPersonNameRune('Ann Smith'),
        0x2028,
      );
      expect(
        RowValidator.firstDisallowedPersonNameRune('Dana (PhD)'),
        0x28,
        reason: 'the first refused character, not the last',
      );
      expect(
        RowValidator.firstDisallowedPersonNameRune('Dana \u{1F985}'),
        0x1F985,
        reason:
            'a character outside the basic plane is one rune, not two halves '
            'of a surrogate pair — a caller reporting 0xD83E would be naming a '
            'character that is not there',
      );
    });

    test('the row walk refuses a line separator on a real Users row', () {
      // Through `validate` and not only through the predicate: a predicate
      // nothing calls bounds nothing, and this is the path both the sync push
      // and the pull take.
      final issues = RowValidator.validate(Tables.users, {
        'user_id': 'user-1',
        'first_name': 'Ann michael@example.org',
        'last_name': 'Smith',
        'email': 'ann@example.org',
        'created_at': '2026-08-31T00:00:00.000Z',
        'updated_at': '2026-08-31T00:00:00.000Z',
        'deleted_at': null,
        'revision': 0,
        'last_modified_by': 'user-1',
        'origin_device_id': null,
      });
      expect(issues.map((i) => i.field), contains('first_name'));
    });
  });
}
