/// Task 11.179 — **a sentence saying a decision is still owed, coupled to the
/// task that owes it.**
///
/// The shape this file is about: a document tells a person that some decision
/// has not been made yet. The decision then gets made, and the sentence does
/// not. `server/README.md` carried one for four days after the decision was
/// taken — **on the same day the sentence was written** (task 11.140).
///
/// ## The measurement, which came before any of this
///
/// The brief for this task said to find the shape before proposing anything,
/// and the measurement is why the file looks like this rather than like a
/// vocabulary sweep.
///
/// Nineteen candidate phrasings across the whole repository — *to be decided*,
/// *still owed*, *not yet chosen*, *TBD*, *undecided*, *needs a decision*,
/// *awaiting Michael*, *open question*, and the rest — return about **155
/// matches**. Almost all of them are in `CLAUDE_DOCS/`, which is narrative:
/// entries recording what was undecided at the time they were written, and
/// correctly so. Outside those documents there are **34 matches in 19 files**,
/// and reading every one of them gives the real number:
///
/// **The word "undecided" in this codebase is domain vocabulary.** An
/// *undecided join request* is a request the owner has not approved or
/// rejected — a row state, nothing to do with a project decision. That
/// accounts for the great majority. *"Still owed"* in
/// `two_device_convergence_e2e_test.dart` is a settling event. *"Needs a
/// decision"* in two tests is about what a person must choose at runtime.
/// `sync_schedule.dart` says the plan *"asked for this to be decided ... this
/// is the decision"* — the opposite of a pending one.
///
/// **After reading all 34: exactly one is a live claim that a decision is
/// still owed**, and it is in `server/backup/freshness.sh`, in the two places
/// checked below. It is currently **true** — task 11.80 is Partial, stopped at
/// exactly that line, and where the server's backups should be copied to is
/// Michael's to answer.
///
/// ## So this is a coupling, not a sweep
///
/// A population of one does not want a phrase sweep. `CLAUDE.md`'s own rule is
/// that a check keyed on a human-written description is a hand-maintained list
/// wearing a different hat, and a sweep over nineteen phrasings would flag
/// dozens of join requests forever.
///
/// What the one instance wants is the thing task 11.183 did with §4.21.4:
/// **write the exception as a coupling, so it cannot outlive its reason.** The
/// sentence is true *because* task 11.80's decision has not been made. So this
/// test reads task 11.80's status out of the plan and requires the two to
/// agree, in both directions:
///
/// - while 11.80 is outstanding, the sentences must be there — an operator
///   reading a backup report must not be left believing the archives go
///   somewhere;
/// - the moment 11.80 is recorded as finished, the sentences must be gone, and
///   until they are this test is red and names them.
///
/// **Why it matters more here than in a plan document.** `freshness.sh` prints
/// its sentence to whoever runs the backup health check. `CLAUDE.md` records
/// that a wrong cause on a screen sends one person to the wrong place while a
/// wrong cause in a status document sends every future reader; an operator
/// script is the second kind. And this particular claim is the one where being
/// wrong is worst in both directions — telling somebody backups are safely
/// off-host when they are not, or telling somebody they are not when they are.
///
/// ## What this does not do
///
/// It does not find the next such sentence. Nothing here scans for one, because
/// the measurement says there is no population to scan — and a sweep that
/// returns dozens of join requests would be turned off within a month. **If a
/// second live pending-decision claim ever appears, it gets a second entry
/// here, coupled to whatever makes it true.** That is a habit, and this file
/// says so rather than pretending to be the mechanism.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/plan_status.dart';

const String _freshnessPath = 'server/backup/freshness.sh';

/// The task whose unmade decision makes the sentences below true.
const String _owingTask = '11.80';

/// The two places `freshness.sh` says the destination has not been chosen: one
/// comment explaining why the check does not go red over it, and one line
/// printed to whoever runs it.
const List<String> _pendingDecisionClaims = [
  'is not made yet',
  'a destination has not been chosen',
];

void main() {
  late String freshness;
  late String? status;

  setUpAll(() {
    final file = File(_freshnessPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '$_freshnessPath is missing. It is the backup health check, and the '
          'claim this test is about is printed by it. If the script moved, '
          'move this test with it rather than deleting a check whose subject '
          'still exists.',
    );
    freshness = file.readAsStringSync();
    status = planStatusParagraph(readDevelopmentPlan(), _owingTask);
  });

  group('a pending-decision claim outlives its decision (task 11.179)', () {
    test('the plan still has an entry for task $_owingTask', () {
      expect(
        status,
        isNotNull,
        reason:
            'There is no `### Task $_owingTask` entry in $developmentPlanPath. '
            'That entry is the only thing that decides whether the sentences '
            'in $_freshnessPath are still true, so without it this test can '
            'say nothing — which is a failure and not a pass.',
      );
      expect(
        isFinishedStatus(status!),
        isNotNull,
        reason:
            "Task $_owingTask's status paragraph says neither that the work "
            'is outstanding nor that it is finished:\n  "$status"\n'
            'A status nobody can read cannot tell anybody whether '
            '$_freshnessPath is lying to an operator.',
      );
    });

    test('the claim and the decision agree', () {
      final finished = isFinishedStatus(status ?? '') ?? false;
      final present = _pendingDecisionClaims
          .where((claim) => freshness.contains(claim))
          .toList();
      final absent = _pendingDecisionClaims
          .where((claim) => !freshness.contains(claim))
          .toList();

      if (finished) {
        expect(
          present,
          isEmpty,
          reason:
              'Task $_owingTask is recorded as finished, and $_freshnessPath '
              'still says the decision is outstanding:\n'
              '${present.map((c) => '  "$c"').join('\n')}\n'
              'That sentence is printed to whoever runs the backup health '
              'check. Rewrite it to say where the archives actually go — and '
              'if the answer is still "nowhere off this host", then '
              "$_owingTask is not finished and the plan entry is what is "
              'wrong.',
        );
      } else {
        expect(
          absent,
          isEmpty,
          reason:
              'Task $_owingTask is still outstanding — the destination for '
              "the server's backups has not been chosen — and $_freshnessPath "
              'no longer says so:\n'
              '${absent.map((c) => '  "$c"').join('\n')}\n'
              'Somebody reading that report is now free to believe the '
              'archives are copied somewhere. If the decision HAS been made, '
              'record it in the plan entry first; if the wording changed, '
              'update the phrases in this test to the new wording, because '
              'the claim is what is being checked and not the exact letters.',
        );
      }
    });
  });
}
