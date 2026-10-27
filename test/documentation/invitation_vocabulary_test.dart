import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Task 11.98 — **the guard for the vocabulary task 11.81 retired.**
///
/// Task 11.81 replaced per-address invitations with one shared project join
/// code and an owner's approval. Two sentences kept telling a removed person
/// to wait for "a new invitation from an owner" anyway — one in
/// `sync_status_screen.dart`, corrected by this task, and one in
/// `projects_screen.dart`'s leave dialog, corrected on 2026-08-31 by whoever
/// wrote task 11.81 and left a comment explaining why. **Nobody swept for a
/// third.** This is that sweep, kept running.
///
/// **What it does.** Every `.dart` file under `lib/` (the app; `server/` and
/// `website/` are out of scope — server text never reaches the UI by design,
/// §4.13, and the content stream owns `website/`) has its comments blanked
/// out — [stripComments] — and the rest is scanned for the word "invite",
/// "invited", "invites" or "invitation" inside a string literal. Any hit that
/// is not on [_knownSurvivors] fails the test.
///
/// **This is a checked vocabulary, not a rewrite ban.** The word is not
/// retired — `project_invites` stays the historical record of who was let in
/// and by whom, and a compatibility message for a build still running the
/// retired route legitimately says "Invite codes have been replaced by a
/// project join code." Both are real uses of the word for something that
/// still exists or still happened. What the word must never again do
/// unreviewed is tell a person that sending or receiving one is a live
/// action — because task 11.81 deleted the mechanism, and copy describing a
/// mechanism the code does not have is the defect task 11.54 exists to
/// catch.
///
/// **What this would and would not have caught.**
/// - It would have caught this task's own subject: "a new invitation from an
///   owner" contains "invitation", and before this task's fix that sentence
///   was in `sync_status_screen.dart` with no matching entry in
///   [_knownSurvivors].
/// - It would have caught the `projects_screen.dart` sentence too, had 11.81
///   not already fixed it — the corrected wording contains no invitation
///   vocabulary at all, so it does not need an entry.
/// - It would **not** catch a sentence that assumes invitations still exist
///   without using this vocabulary — "wait for someone to add you back",
///   say. That failure mode needs a human reader, not a grep; this closes the
///   one specific class that has now recurred twice.
/// - It would not catch the same defect in `website/` or in server-authored
///   text, both of which are out of scope here by design (see above).
/// - It would **not** catch a screen printing a raw database token at a
///   person, or a second hand-written mapping of an enum to display words.
///   **Two tasks have been pointed here for that and both were pointed
///   wrongly** (11.196, and 11.199's own brief). This file's subject is *one
///   removed feature's words*; that one is *any stored value reaching a
///   reader*, it needs the enum list derived from the shared package rather
///   than four words typed here, and it lives in
///   `stored_value_display_test.dart` (task 11.199). Nothing about the two
///   checks is shared but the idea of scanning `lib/`.
/// - Every entry in [_knownSurvivors] is read out of the file itself; a
///   survivor whose text is edited without updating this list is not a
///   loophole — the test fails and points at the file, because the exact
///   string it expected to find is no longer there.
/// **Empty since task 11.84, and that is the intended end state.** Its one
/// entry was the compatibility sentence answering the retired redemption
/// route; 11.84 deleted the route, so the sentence went with it. An empty
/// allowlist is the strongest form of this check, not a broken one — the
/// machinery below stays because the next survivor has to be argued for, and
/// an empty list is the argument that none is currently allowed.
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

final _invitationWord = RegExp(r'\binvit(e|ed|es|ing|ation|ations)\b');

void main() {
  test('no user-visible string in lib/ assumes invitations still exist, '
      'except the named, reasoned survivors', () {
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
            '${survivor.file} no longer contains the survivor text this '
            'test was told to allow ("${survivor.text}"). Either the '
            'sentence changed — update or remove this entry — or it was '
            'deleted, in which case remove the entry.',
      );
    }

    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final stripped = stripComments(source.readAsStringSync());
      if (!_invitationWord.hasMatch(stripped)) continue;

      final relative = _relative(source.path);
      final isKnown = _knownSurvivors.any((s) => s.file == relative);
      if (isKnown) continue;

      offenders.add(relative);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These files use invitation vocabulary ("invite", "invited", '
          '"invites", "inviting", or "invitation") in a string literal, '
          'and none of them is in _knownSurvivors:\n'
          '${offenders.map((f) => '  - $f').join('\n')}\n\n'
          'Task 11.81 replaced per-address invitations with a project join '
          'code and an owner\'s approval — there is nothing left to send or '
          'receive. If this is user-visible copy telling someone to obtain '
          'or wait for an invitation, that is false and must be rewritten '
          '(the working answer is: ask an owner for the project\'s join '
          'code, or ask an owner to put you back directly). If it is a '
          'legitimate use — historical record, or a compatibility message '
          'for a retired route — add it to _knownSurvivors in this test '
          'with a one-line reason. That list is empty (task 11.84 deleted '
          'the last entry along with the route it explained), so a new '
          'entry has to be argued for from scratch.',
    );
  });
}

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;
