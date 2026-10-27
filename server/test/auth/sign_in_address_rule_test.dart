import 'dart:math';

import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart' show normalizeEmail;

/// The HTTP boundary's address rule and the SMTP sender's address rule must
/// be the same rule (task 11.298).
///
/// **Why a test that looks tautological.** Today `isAcceptableSignInAddress`
/// is *defined as* `isDeliverableAddress(normalizeEmail(s))`, so this file
/// cannot fail. That is the point: it is here for the day somebody rewrites
/// the boundary as its own regex — which is what it was until 2026-09-21, a
/// deliberately permissive shape check whose comment said a stricter one
/// *"would lock real collaborators out"*, sitting in front of a strict-ASCII
/// sender that refused everything the boundary let through and told nobody.
/// `üser@example.com` got a `202`, no message, and an audit row only an
/// operator could read. Two checks that are each right and never reconciled
/// is the trapdoor; this corpus is what reconciles them once the definition
/// stops doing it.
///
/// **Both directions, on purpose.** A boundary looser than the sender is the
/// silent lock-out above. A boundary *stricter* than the sender refuses
/// somebody the mail path would have served, with a `400` — better than
/// silence and still wrong. Either divergence goes red here, and the failure
/// names the string it found it on.
///
/// **The corpus is generated, seeded, and large**, because the interesting
/// strings are the ones nobody lists by hand: a Kelvin sign that lowercases to
/// ASCII, a dotless-I that lowercases to two code units, an `@` at position
/// 64, a DEL byte. The named cases below are the ones this project has
/// already argued about; the generated ones are the rest of the space around
/// them.
void main() {
  /// Every string the sender's own tests accept or refuse, plus the four the
  /// plan entry named, plus the case-folding edges that make `normalizeEmail`
  /// part of the question.
  const named = <String>[
    // Accepted by the sender's tests.
    'sam@example.com',
    'first.last+tag@sub.example.edu',
    "o'neil@example.org",
    'a@b',
    'x_y-z@host-1.example',
    // Refused by the sender's tests.
    'a@b.com\r\nBcc: attacker@example.org',
    'a@b.com\nBcc: attacker@example.org',
    'a@b.com>\r\nRCPT TO:<attacker@example.org',
    'a@b.com>',
    '<a@b.com>',
    'a b@example.com',
    'a@b.com,c@d.com',
    'a@b.com;c@d.com',
    'a@b.com\u0000',
    '"quoted local"@example.com',
    'a@[10.0.0.1]',
    'ünïcode@example.com',
    'a@',
    '@b.com',
    'a@@b.com',
    'a@b.com@c.com',
    '',
    // The plan entry's four — the people in the gap.
    'üser@example.com',
    'josé@universidad.mx',
    '"odd name"@example.com',
    'user@[192.168.1.1]',
    // Case folding: the Kelvin sign (U+212A) lowercases to ASCII `k`, so the
    // *normalized* string is deliverable while the raw one is not. Dotless
    // capital I (U+0130) lowercases to `i` plus a combining dot — still
    // non-ASCII, still refused. Both are why the boundary judges the
    // normalized string and not the raw one.
    '\u212Aelvin@example.com',
    '\u0130stanbul@example.com',
    // Surrounding whitespace is trimmed by normalization, not refused.
    '  sam@example.com  ',
    '\tsam@example.com',
    'SAM@EXAMPLE.COM',
  ];

  // Characters chosen to cover every class the two rules care about: the
  // sender's allowed local-part punctuation, the characters it refuses (angle
  // brackets, quotes, square brackets, colon, space, comma, semicolon), C0
  // controls and DEL, and non-ASCII from three scripts plus the two
  // case-folding edges above.
  const alphabet = <String>[
    'a', 'Z', 'm', '0', '9',
    '.', '-', '_', '+', '!', '#', "'", '/', '=', '?', '^', '`', '{', '|', '}',
    '~', '@', '@',
    '"', '[', ']', '<', '>', ':', ' ', ',', ';',
    '\r', '\n', '\t', '\u0000', '\u007f',
    'ü', 'é', '中', 'я', '\u212A', '\u0130',
  ];

  List<String> generated() {
    final random = Random(11298);
    String pick() => alphabet[random.nextInt(alphabet.length)];
    final out = <String>[];
    // Unstructured: uniformly random strings, most of which are refused by
    // both rules — the check that neither rule accepts garbage.
    for (var i = 0; i < 20000; i++) {
      final length = random.nextInt(15);
      out.add(List.generate(length, (_) => pick()).join());
    }
    // Structured: `local@domain` with each part drawn from the alphabet.
    // Almost all of these are refused too — the full alphabet is mostly
    // characters one rule or the other rejects — which is why the next block
    // exists.
    for (var i = 0; i < 10000; i++) {
      final local = List.generate(1 + random.nextInt(8), (_) => pick()).join();
      final domain = List.generate(1 + random.nextInt(8), (_) => pick()).join();
      out.add('$local@$domain');
    }
    // Near misses: a plausible address with, one time in three, a single
    // character from the full alphabet dropped into it. This is where the
    // accepted side of the space and the edge of the rule actually get
    // exercised; the first draft of this file generated 123 accepted strings
    // out of 40,000 and its own vacuity check below refused to pass.
    const plainLocal = ['a', 'Z', 'm', '0', '9', '.', '-', '_', '+', "'"];
    const plainDomain = ['a', 'Z', 'm', '0', '9', '.', '-'];
    String plain(List<String> from, int max) => List.generate(
      1 + random.nextInt(max),
      (_) => from[random.nextInt(from.length)],
    ).join();
    for (var i = 0; i < 20000; i++) {
      var local = plain(plainLocal, 12);
      var domain = plain(plainDomain, 12);
      switch (random.nextInt(3)) {
        case 0:
          final at = random.nextInt(local.length + 1);
          local = local.substring(0, at) + pick() + local.substring(at);
        case 1:
          final at = random.nextInt(domain.length + 1);
          domain = domain.substring(0, at) + pick() + domain.substring(at);
        default:
          break;
      }
      out.add('$local@$domain');
    }
    // Length edges around the sender's 64-character local part and 320 total.
    for (final n in [63, 64, 65]) {
      out.add('${'a' * n}@example.com');
    }
    for (final n in [318, 319, 320, 321]) {
      final domainLength = n - 2; // 'a' + '@' + domain
      out.add('a@${'b' * domainLength}');
    }
    return out;
  }

  test('the boundary and the sender agree on every named address', () {
    for (final address in named) {
      expect(
        isAcceptableSignInAddress(address),
        isDeliverableAddress(normalizeEmail(address)),
        reason: 'the boundary and the sender disagree on ${_show(address)}',
      );
    }
  });

  test('the four the plan named are refused at the boundary, by name', () {
    // The whole defect: these used to pass here and fail in the sender.
    for (final locked in [
      'üser@example.com',
      'josé@universidad.mx',
      '"odd name"@example.com',
      'user@[192.168.1.1]',
    ]) {
      expect(isAcceptableSignInAddress(locked), isFalse, reason: locked);
    }
    // And the ordinary ones still pass, so the tightening did not overshoot.
    for (final fine in [
      'sam@example.com',
      'first.last+tag@sub.example.edu',
      "o'neil@example.org",
      '\u212Aelvin@example.com', // Kelvin sign folds to ASCII — carried.
    ]) {
      expect(isAcceptableSignInAddress(fine), isTrue, reason: fine);
    }
  });

  test('the boundary and the sender agree on a generated corpus, both ways', () {
    final corpus = generated();
    var accepted = 0;
    var refused = 0;
    final boundaryOnly = <String>[];
    final senderOnly = <String>[];
    for (final s in corpus) {
      final boundary = isAcceptableSignInAddress(s);
      final sender = isDeliverableAddress(normalizeEmail(s));
      if (boundary && !sender) boundaryOnly.add(s);
      if (sender && !boundary) senderOnly.add(s);
      if (sender) {
        accepted++;
      } else {
        refused++;
      }
    }
    // A corpus that lands entirely on one side is measuring nothing about the
    // other (defect vocabulary 28: a derivation must refuse an empty result).
    expect(accepted, greaterThan(1000), reason: 'corpus has too few accepted');
    expect(refused, greaterThan(1000), reason: 'corpus has too few refused');
    expect(
      boundaryOnly,
      isEmpty,
      reason:
          'the boundary accepts what the sender refuses — the silent lock-out '
          'task 11.298 closed is back. First: ${_first(boundaryOnly)}',
    );
    expect(
      senderOnly,
      isEmpty,
      reason:
          'the boundary refuses what the sender would carry — a person is '
          'told no for an address the mail path could serve. First: '
          '${_first(senderOnly)}',
    );
    // The finding, not just a pass (defect vocabulary 1).
    // ignore: avoid_print
    print(
      'sign-in address rule: corpus ${corpus.length}, $accepted accepted, '
      '$refused refused, ${boundaryOnly.length} boundary-only, '
      '${senderOnly.length} sender-only',
    );
  });
}

/// The first divergent string, readable, or a marker when there is none —
/// evaluated eagerly inside a `reason:`, so it must not throw on the pass.
String _first(List<String> divergent) =>
    divergent.isEmpty ? '(none)' : _show(divergent.first);

/// Makes a string with control characters or non-ASCII readable in a failure.
String _show(String s) => s.runes
    .map(
      (r) => r < 0x20 || r == 0x7f || r > 0x7e
          ? '\\u{${r.toRadixString(16)}}'
          : String.fromCharCode(r),
    )
    .join();
