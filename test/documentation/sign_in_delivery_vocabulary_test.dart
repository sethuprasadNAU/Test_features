import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **The guard for the promise task 11.119 found and Michael decided to
/// retire: that a sign-in code arrives by email.**
///
/// ## What was wrong
///
/// `server_config_screen.dart` said *"Check your email, then paste the code
/// below"*, offered a button reading `EMAIL ME A SIGN-IN CODE`, and labelled
/// the field *"Paste the code (or the whole link) from the email"*.
/// **No server this project can build sends an email.**
/// `resolveEmailSender` has exactly two branches: `FileEmailSender`, which
/// writes the link to a file and refuses to exist under
/// `TRITRACK_ENV=production`, and `NullEmailSender`, which accepts the message
/// and discards it. `/auth/magic-link` answers the identical `202` either way,
/// because §4.5 requires it to.
///
/// The *development* half of this was written down in `README.md` and
/// `server/README.md`. **The promise the app made to the person was written
/// down nowhere**, and it is the first thing a beta user does.
///
/// ## Why this is a phrase list and not the word "email"
///
/// The word is not retired and must not be. An `Email` field label, a stored
/// address, `normalizeEmail`, the sign-in address a person types — all of
/// those are real and staying. **A check on the word would be a
/// hand-maintained allowlist wearing a different hat**, which is the defect
/// task 11.89 named and the reason the invitation guard next door is scoped to
/// a vocabulary rather than a topic.
///
/// So this scans for the narrow thing that was actually false: **copy telling
/// somebody that a code or link will _arrive by_ email.** Measured on
/// 2026-09-01, the patterns below match **zero** string literals under `lib/`
/// after comments are stripped, which is what makes the empty allowlist an
/// argument rather than an accident.
///
/// ## What this would and would not have caught
///
/// - It **would** have caught all three of the strings above.
/// - It would **not** catch a sentence that promises delivery without this
///   vocabulary — "it should arrive shortly", say. That failure mode needs a
///   human reader. This closes the one class that shipped.
/// - It does not look at `server/` (server text never reaches the UI by
///   design, §4.13) or `website/` (the content stream owns it), matching the
///   scope of `invitation_vocabulary_test.dart`.
///
/// ## What the screen says instead, and why it is deliberately not specific
///
/// The app **cannot know** how a code reaches anybody — the server's answer is
/// the same either way. So the screen says so, and names an action. Task
/// 11.115 (item A) added the sentence about waiting itself: the app can't say
/// how long is normal either, for the same reason it can't say how delivery
/// works. As of that task the screen reads:
/// *"How the code reaches you depends on how this server is set up, and this
/// app cannot tell which way it uses — so it cannot say how long a normal
/// wait is either. If it has been longer than you would expect and nothing
/// has arrived, ask whoever runs the server for it."*
///
/// It deliberately does **not** say "this server does not send email", which is
/// true of every deployment today and would become false on every phone still
/// running this build the day somebody adds a mail sender. **That is the class
/// the survey this came from exists to stop** — correct when written, silently
/// falsified by a later task. An honest default does not have to be
/// re-verified when the mechanism under it changes (task 11.122's rule).
///
/// Named, reasoned survivors below. **Empty, and that is the intended end state** —
/// the same argument `invitation_vocabulary_test.dart` makes for its own empty
/// list. A new entry has to be argued for from scratch.
///
/// A legitimate future entry would be copy shown only when the server has told
/// the app it really does send email. That needs the server to say so first,
/// which is a protocol change nobody has made.
const List<_Survivor> _knownSurvivors = [];

class _Survivor {
  const _Survivor({
    required this.file,
    required this.text,
    required this.reason,
  });

  final String file;
  final String text;
  final String reason;
}

/// Phrases that promise delivery by email, rather than merely naming an
/// address. Case-insensitive.
final _deliveryPromise = RegExp(
  r'check your email'
  r'|in your (email|inbox)'
  r'|from the email'
  r'|your inbox'
  r'|emailed you'
  r"|we('ve| have)? sent you"
  r'|sent you an email'
  r'|email me a'
  r'|by email',
  caseSensitive: false,
);

void main() {
  test('no user-visible string in lib/ promises that a sign-in code arrives '
      'by email, except the named, reasoned survivors', () {
    for (final survivor in _knownSurvivors) {
      final file = File(survivor.file);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            '${survivor.file} no longer exists. Remove its entry from '
            '_knownSurvivors in this test, or restore the file.',
      );
      expect(
        file.readAsStringSync().contains(survivor.text),
        isTrue,
        reason:
            '${survivor.file} no longer contains the survivor text this test '
            'was told to allow ("${survivor.text}"). Either the sentence '
            'changed — update or remove this entry — or it was deleted, in '
            'which case remove the entry.',
      );
    }

    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final stripped = stripComments(source.readAsStringSync());
      if (!_deliveryPromise.hasMatch(stripped)) continue;

      final relative = _relative(source.path);
      if (_knownSurvivors.any((s) => s.file == relative)) continue;

      offenders.add(relative);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files tell somebody that something arrives by email, in a '
          'string literal:\n'
          '${offenders.map((f) => '  - $f').join('\n')}\n\n'
          'No server this project can build sends email — resolveEmailSender '
          'returns either a development file writer (which refuses to exist '
          'under TRITRACK_ENV=production) or a sender that discards the '
          'message. The app cannot tell which, because /auth/magic-link '
          'answers the same 202 either way.\n\n'
          'If this is copy about how a sign-in code reaches somebody, it is '
          'false and must be rewritten. The honest form is on '
          'server_config_screen.dart: say that delivery depends on how the '
          'server is set up, that this app cannot tell, and to contact '
          'TriTrack support. Do NOT write "this server does not send email" — that is '
          'true today and becomes false on every already-installed build the '
          'day a mail sender is added.\n\n'
          'If a server ever does report that it sends email, add an entry to '
          '_knownSurvivors with a one-line reason. That list is empty, so a '
          'new entry has to be argued for from scratch.',
    );
  });
}

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;
