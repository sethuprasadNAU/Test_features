import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workflow_triggers.dart';

/// Task 11.40 — **the trigger's own guard.**
///
/// `scripts/verify_round8_broken_control.py` is the only thing proving the 152
/// gate checks in `verify_round8_server_surface.py` can fail at all. It takes
/// roughly ten minutes, so task 11.64 deliberately kept it out of
/// `gate_smoke_test.sh` and asked task 11.40 to choose a **trigger** instead.
/// The trigger is `.github/workflows/broken-control-check.yml`, which fires on
/// pushes touching the files the script patches.
///
/// **A hand-written list of paths in a workflow is the hand-maintained list
/// one layer up** — precisely the shape task 11.49 found three times in this
/// project's own instruments, most recently a wire-speaking instrument that
/// was in neither of two hand-written lists for a week and so had no automated
/// re-run at all. So the list is not trusted: this test reads the file
/// constants out of the Python script and requires each one to appear in the
/// workflow's `paths:` filter.
///
/// It runs in the plain offline suite, needs no Docker and no network, and it
/// fails on the commit that adds a fourth variant to the script — rather than
/// at whichever future gate notices the trigger has been silently narrower
/// than the thing it triggers on.
/// **Derived, not listed — task 11.85, 2026-08-31.**
///
/// This test named `verify_round8_broken_control.py` and only that file, and
/// so it was itself the hand-maintained list it was written to replace: by
/// 2026-08-29 `verify_11_49_broken_control.py` existed, patched five files
/// this workflow does not mention, and **had no trigger at all** — nothing
/// re-ran it when the routes it breaks were edited. That is the same defect
/// one layer up, found the same way, and the fix is the same one: read the set
/// off the filesystem so the next harness is covered by existing.
const _scriptDirectory = 'scripts';
const _scriptSuffix = '_broken_control.py';
const _workflowPath = '.github/workflows/broken-control-check.yml';

List<File> _brokenControlScripts() =>
    Directory(_scriptDirectory)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(_scriptSuffix))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

/// The script's own module-level constants naming the files it patches.
///
/// Matched by shape — a bare `NAME = "some/path.dart"` at the left margin —
/// rather than by naming the three constants, so a fourth is picked up
/// without this test being edited.
final _fileConstant = RegExp(
  r'''^[A-Z][A-Z0-9_]* = ["']([A-Za-z0-9_./-]+\.dart)["']''',
  multiLine: true,
);

/// Task 11.127 — **the other half of the coupling, and the half nothing
/// watched.**
///
/// A broken-control harness names the control it deletes by quoting the source
/// line that implements it. That couples the harness to code in another
/// package, **and the coupling is invisible from the owning side**: on
/// 2026-09-02 task 11.89 replaced the person-name denylist with an allowlist
/// and deleted a line `verify_11_85_broken_control.py` patches. Nothing said
/// so. The bidi-name detection proof simply stopped existing, while the
/// instrument it vouches for went on reporting clean.
///
/// The harnesses do verify their own patch text before trusting a run — but
/// **that check runs at harness time**, which is a ten-minute Docker job fired
/// by a path filter. This is the same question asked on every commit, with no
/// Docker: `scripts/check_broken_control_patch_targets.py` derives the harness
/// set from the same filename glob, imports each one's `VARIANTS`, and requires
/// every patch's text to appear exactly once in the file it names.
///
/// **The check is run rather than re-implemented here.** Restating its rules in
/// Dart would be a second copy of them, and the two would drift the way every
/// other pair of copies in this project has.
const _patchTargetCheck = 'scripts/check_broken_control_patch_targets.py';

void main() {
  test('every broken-control script has a trigger, and it covers every file '
      'that script patches', () {
    final scripts = _brokenControlScripts();
    expect(
      scripts,
      isNotEmpty,
      reason:
          'No $_scriptSuffix script was found under $_scriptDirectory/. Either '
          'they were all removed — in which case hundreds of gate checks that '
          'always come back "refused" are indistinguishable from checks that '
          'are blind — or this derivation has stopped matching, and a '
          'derivation that matches nothing reports full coverage of nothing.',
    );

    final workflow = File(_workflowPath);
    expect(
      workflow.existsSync(),
      isTrue,
      reason:
          '$_workflowPath is missing, so nothing re-runs the broken-control '
          'scripts when the controls they break change. Task 11.64 asked for a '
          'trigger rather than a schedule precisely because a ten-minute check '
          'that only runs when somebody remembers is a check that stops '
          'running.',
    );
    final workflowText = workflow.readAsStringSync();
    // **Task 11.325: the triggers are read the way a runner reads them, and a
    // declared pause is read through its saved copy.** This used to count
    // `'$path'` over the whole file's text, so a comment that merely *mentions*
    // a path satisfied it — and a pause keeps the old triggers as exactly such a
    // comment. While the workflow is paused the question that still has an
    // answer is whether restoring it would cover every patched file, so that is
    // what is asked; while it is live, the live `on:` block is.
    final paused = pauseNotice.firstMatch(workflowText)?.group(1) == 'PAUSED';
    final triggerText = paused
        ? (savedTriggers(workflowText) ?? '')
        : onBlock(workflowText);
    final runnableText = withoutComments(workflowText);
    expect(
      triggerText,
      isNotEmpty,
      reason:
          '$_workflowPath has no readable triggers (live or saved), so the '
          'checks below would have nothing to look at.',
    );

    // Both event blocks, not just whichever one happens to be first: a filter
    // present on `push` and missing on `pull_request` covers a branch and not
    // the merge, which is the half that matters on a shared repository.
    for (final event in const ['push:', 'pull_request:']) {
      expect(
        triggerText.contains(event),
        isTrue,
        reason:
            '$_workflowPath has no `$event` trigger, so it does not fire on '
            'that event at all.',
      );
    }

    for (final script in scripts) {
      final relative = script.path.replaceFirst(RegExp(r'^\./'), '');
      // The workflow has to actually RUN it. A path filter that fires a
      // workflow which never invokes the script is a trigger for nothing —
      // and that is not a hypothetical: this test's own predecessor checked
      // the paths and never checked the run.
      expect(
        runnableText.contains(relative),
        isTrue,
        reason:
            '$relative is a broken-control harness and $_workflowPath never '
            'mentions it, so nothing runs it. Add a `run:` step for it, and '
            'add the files it patches to both path lists.',
      );

      final patched = _fileConstant
          .allMatches(script.readAsStringSync())
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        patched,
        isNotEmpty,
        reason:
            'No patched-file constant was parsed out of $relative. Either it '
            'no longer names the files it breaks, or this pattern has stopped '
            'matching — and a derivation that matches nothing reports full '
            'coverage of nothing, which is the exact defect this test guards '
            'against elsewhere.',
      );

      for (final path in patched) {
        expect(
          "'$path'".allMatches(triggerText).length,
          greaterThanOrEqualTo(2),
          reason:
              '$relative breaks $path on purpose, and $_workflowPath does not '
              'list it under BOTH `paths:` filters. Editing that file would '
              'change a control without re-running the one check that proves '
              'the instrument watching it can still notice.\n\n'
              'A filter on only `push:` or only `pull_request:` covers the '
              'branch or the merge, never both.',
        );
      }

      // The script itself must be a trigger for its own re-run: editing a
      // harness is exactly when you want to find out it still works.
      expect(
        "'$relative'".allMatches(triggerText).length,
        greaterThanOrEqualTo(2),
        reason:
            '$relative is not in both path lists in $_workflowPath, so editing '
            'the harness does not re-run it.',
      );
    }
  });

  test('every broken-control variant can still find the text it patches', () {
    final result = Process.runSync('python3', [_patchTargetCheck]);
    final output = '${result.stdout}${result.stderr}'.trim();

    // A missing interpreter must not read as a pass. `run_offline_suite.sh`
    // already requires python3 for the scope check, and so does this.
    expect(
      output,
      isNotEmpty,
      reason:
          'python3 $_patchTargetCheck produced no output at all, so this test '
          'has no idea whether it ran. Exit code ${result.exitCode}.',
    );

    expect(
      result.exitCode,
      0,
      reason:
          'A broken-control harness can no longer apply one of its own '
          'sabotages, so whatever that variant proved is no longer being '
          'proved — and the instrument it vouches for is still running and '
          'still reporting clean.\n\n'
          'This usually means an ordinary, correct refactor deleted or moved '
          'the control a harness quotes. Re-author that variant against the '
          'new code; it is a judgement about which control to delete, not a '
          'text substitution.\n\n$output',
    );

    // The instrument's last words are a finding, not a name: the counts belong
    // in the log whether it passed or failed, because a run that checked zero
    // patch targets and a run that checked nineteen both print "passed".
    printOnFailure(output);
    expect(
      output,
      contains('Checked '),
      reason:
          '$_patchTargetCheck exited 0 without saying how many patch targets '
          'it checked. A check that does not say what it looked at cannot be '
          'told from one that looked at nothing.\n\n$output',
    );
  });
}
