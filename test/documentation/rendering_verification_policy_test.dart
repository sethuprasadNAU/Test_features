
/// Task 11.186 — **the decision that this project does not put goldens in
/// `test/`, kept from being re-opened at the next wall.**
///
/// Four rendering tasks in a row ended with *"I could not verify this without
/// a device; please look."* This file is the answer, and it is a **no** with
/// its reasoning attached, because a measured no is worth as much as a yes
/// and this question will be asked again.
///
/// ## Two facts the decision was made against, both measured rather than
/// assumed
///
/// **First, the network claim that has been repeated twice is wrong, and
/// correcting it matters because it points at the wrong obstacle.** Task
/// 11.185 reported that the widget harness *"hits real network tile requests
/// that time out unpredictably."* **No widget test in this repository reaches
/// the network at all.** `test/headline_offline_suite_test.dart` pins that
/// `TestWidgetsFlutterBinding` installs an `HttpOverrides` answering every
/// real request synthetically, and there is a test asserting exactly that.
/// The real obstacle is recorded in `map_screen_test.dart`'s own header and
/// is a different thing: the `TileLayer`'s image futures **never resolve**
/// under `flutter test`, which is why every map test uses plain `pump()` and
/// never `pumpAndSettle()`. **The screen renders. What `flutter test` cannot
/// produce is a picture of it.** An unresolved future and a timeout feel
/// identical from outside, which is why this was worth writing down rather
/// than left to be inherited a third time.
///
/// **Second, the project already has a picture machine, and it is better than
/// a golden in every dimension that decides this question.**
/// `integration_test/screenshots/` boots the real app on a real iOS simulator
/// at App Store device geometry, walks every state in [expectedScreenshotNames]
/// across every profile the harness captures, and `review.dart` compares each
/// new image against the committed one, writes a diff picture, names every
/// screen that moved, and **stops** —
/// `--accept` is a separate command a person types after looking. That is a
/// golden suite, with real fonts, real text metrics and real geometry, and it
/// has existed since before any of the four tasks that asked Michael to look.
///
/// ## Why a `matchesGoldenFile` golden in `test/` would be the wrong answer
///
/// **1. It would be a second, worse answer to a question already answered.**
/// `flutter test` renders in a fallback font about twice Roboto's width. A
/// golden taken in it is a picture of a phone nobody owns. The simulator
/// harness photographs the phone that exists.
///
/// **2. A golden answers "did this change". Not one of the outstanding
/// questions is that question.** The 20 device-look requests across Phase 11
/// (counted below) are all of the form *is this too crowded / does this fit /
/// is this trade right* — and **every one of them was asked about something
/// the same task had just changed on purpose.** A regression check is
/// re-blessed in that same commit by definition. Twenty of twenty would have
/// been answered "yes, it changed, you changed it."
///
/// **3. Every rendering defect this project has actually caught was caught by
/// a number, not a picture.** Task 11.126's three live overflows (pumping at
/// real phone geometry), 11.109's bearings list at 83.5 and then 42.5 logical
/// pixels, 11.149's zero-pixel viewport, 11.162's structural clear-band floor,
/// 11.166's overlay sets derived from the `Stack`'s own children, 11.177's
/// 10.5° needle and 20.5° markers, 11.178's wrap guard comparing a row against
/// itself at unbounded width. **Zero were found by anything picture-shaped.**
/// The measured-geometry habit is what works here, and it is what Michael
/// should keep asking for.
///
/// ## The honest claim, written next to the decision as task 11.186 required
///
/// **A test suite cannot close a rendering question.** Nothing in this
/// repository — not a golden, and not the simulator harness either — is
/// entitled to say *"this looks right."* The strongest claim available to an
/// image comparison here is **"this did not change"**, and for the simulator
/// harness that claim is worth having because it is made in the phone's own
/// fonts. *Looks right* is Michael's, on hardware, and no instrument replaces
/// it.
///
/// ## What this file checks
///
/// **(a) No golden appears under `test/`** unless somebody adds an argued
/// entry to [_argued] saying why this one is different. The list is empty
/// today. This is a checked decision in the shape of
/// `invitation_vocabulary_test.dart`'s checked vocabulary — not a ban nobody
/// can lift, but one nobody can lift by accident.
///
/// **(b) The reason the decision holds is still true.** The whole argument
/// above rests on the simulator harness existing and still refusing to
/// overwrite a committed image on its own. So this file reads that harness
/// rather than asserting it from memory: **if the harness is deleted or its
/// accept gate is removed, this goes red and the decision must be re-argued**,
/// rather than outliving the thing that justified it. That is the
/// write-an-exception-as-a-coupling rule from task 11.183.
///
/// ## Two gaps this task found and did not close, so they are not mistaken
/// for decided
///
/// - **Nothing runs the picture machine.** No CI workflow, no gate script and
///   no hook references `regenerate.sh` or `review.dart`. The images move only
///   when a website task happens to run it, so the *"did not change"* claim it
///   is capable of making is not being made on any schedule.
/// - **It photographs one text size.** There is no `TextScaler` or
///   `textScaleFactor` anywhere in `integration_test/screenshots/`, so every
///   committed image (counted below, rather than typed here — this file's own
///   count went stale twice) is at the default. The accessibility text sizes
///   are where nearly all of this project's open rendering questions live.
///
/// ## Task 11.211 — the state/profile/image counts are derived, not typed
///
/// This header used to say "33 states across two device profiles" and "all
/// 66 committed images", **the third time those numbers had been written down
/// by hand** — `/w-16` and `/w-10` both moved the harness and left this
/// header behind. `CLAUDE.md`'s own class: the measurements live in prose and
/// no test reads prose. The group below reads [expectedScreenshotNames] (the
/// harness's own manifest of what a run must produce) and the committed
/// `website/static/screens/` tree instead, and prints both counts on every
/// run so a stale number in this file shows up the next time somebody reads
/// the test output, not the next time somebody happens to notice the prose.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/screenshots/shots.dart';
import '../support/dart_source.dart';

/// Files under `test/` allowed to contain a golden, each with the argument for
/// why it is different from the twenty cases the decision above covers.
///
/// **Empty, and an entry is an argument rather than a name.** A golden is
/// admissible here only where the subject is a single widget with fixed
/// inputs whose *shape* is the thing under test and whose text metrics are
/// not — and where "did not change" is genuinely the question being asked,
/// not a stand-in for "looks right". If that case turns up, write the
/// reasoning here beside the path.
const Map<String, String> _argued = <String, String>{};

/// The literal a golden call site contains. Assembled rather than written
/// whole so that this file, which is itself under `test/`, does not match its
/// own guard.
final String _goldenCall = 'matchesGolden${'File'}';

void main() {
  group('no golden is added under test/ without an argument', () {
    test('every golden call site is on the argued list', () {
      final files = dartFilesUnder('test');
      expect(
        files.length,
        greaterThan(50),
        reason:
            'The scan found almost nothing under test/, which means the scan '
            'is broken rather than that the repository is clean — a search '
            'that finds nothing and a subject that contains nothing are '
            'indistinguishable from the inside.',
      );

      final unargued = <String>[];
      for (final file in files) {
        final path = file.path.replaceAll(r'\', '/');
        if (path.endsWith('rendering_verification_policy_test.dart')) continue;
        if (!stripComments(file.readAsStringSync()).contains(_goldenCall)) {
          continue;
        }
        if (_argued.containsKey(path)) continue;
        unargued.add(path);
      }

      expect(
        unargued,
        isEmpty,
        reason:
            'These files call $_goldenCall, and task 11.186 decided this '
            'project does not take goldens under test/. The reasoning is in '
            "this file's header and the short form is: flutter_test renders "
            'in a font about twice Roboto\'s width, so a golden taken here is '
            'a picture of a phone nobody owns, and it can only ever claim '
            '"this did not change" — never "this looks right". The picture '
            'machine that does run in real fonts at real device geometry is '
            'integration_test/screenshots/, driven by its regenerate.sh. '
            'If one of these really is the argued exception — a single widget '
            'with fixed inputs whose shape is the subject and whose text '
            'metrics are not — add it to _argued in this file with the '
            'argument, so the next reader meets the reasoning rather than '
            'the ban.',
      );
    });
  });

  group('the reason that decision holds is still true', () {
    // The decision above is only correct while the simulator harness exists
    // and still makes a person acknowledge a moved image. Reading it here
    // means the exception cannot outlive its justification.
    const harness = 'integration_test/screenshots';

    test('the simulator screenshot harness is still present', () {
      for (final name in const [
        'capture_test.dart',
        'review.dart',
        'shots.dart',
        'regenerate.sh',
      ]) {
        expect(
          File('$harness/$name').existsSync(),
          isTrue,
          reason:
              '$harness/$name is gone. Task 11.186 declined to build goldens '
              'under test/ specifically because this harness photographs the '
              'real app on a real simulator in real fonts, which a golden '
              'here cannot. If the harness has been retired, that decision no '
              'longer has its reason and must be made again rather than '
              'inherited.',
        );
      }
    });

    test('the harness still refuses to overwrite a baseline on its own', () {
      final review = File('$harness/review.dart').readAsStringSync();
      expect(
        review.contains('--accept'),
        isTrue,
        reason:
            'review.dart no longer mentions --accept. Its value in the 11.186 '
            'argument is precisely that it compares, names what moved, writes '
            'a diff and then stops, leaving a person to acknowledge it. A '
            'comparison that silently rewrites its own baseline is not a '
            'check, and without it the reasoning that ruled out goldens here '
            'does not hold.',
      );
    });
  });

  group(
      "the state/profile/image counts this file's header describes "
      '(task 11.211)', () {
    const committedRoot = 'website/static/screens';

    test(
      'every state in expectedScreenshotNames has a committed image in '
      'every profile, and the true totals are printed rather than typed',
      () {
        final root = Directory(committedRoot);
        expect(
          root.existsSync(),
          isTrue,
          reason:
              '$committedRoot is gone — this test can no longer count what '
              'the picture machine has committed.',
        );

        final profiles = root
            .listSync()
            .whereType<Directory>()
            .map((d) => d.path.split(Platform.pathSeparator).last)
            .toList()
          ..sort();
        expect(
          profiles,
          isNotEmpty,
          reason:
              'No profile directories found under $committedRoot. A search '
              'that finds nothing and a subject with nothing in it are '
              'indistinguishable from the inside — either the picture '
              'machine has never run, or this test is looking in the wrong '
              'place.',
        );

        final states = expectedScreenshotNames;
        var totalImages = 0;
        for (final profile in profiles) {
          final committedNames = Directory('$committedRoot/$profile')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.png'))
              .map(
                (f) => f.path
                    .split(Platform.pathSeparator)
                    .last
                    .replaceAll('.png', ''),
              )
              .toSet();
          totalImages += committedNames.length;

          final missing = states
              .where((s) => !committedNames.contains(s))
              .toList();
          expect(
            missing,
            isEmpty,
            reason:
                '$profile is missing a committed image for: '
                '${missing.join(', ')}. Every name in shots.dart\'s '
                'expectedScreenshotNames is supposed to have one in every '
                'captured profile.',
          );
        }

        // Printed, not asserted to a literal number: the point of this test
        // is that nobody has to keep a number in this file's header in sync
        // with the harness by hand ever again. If the header above disagrees
        // with what a run of this test prints, the header is the one that is
        // wrong — update it from this line, not the other way around.
        // ignore: avoid_print
        print(
          'rendering_verification_policy_test: ${states.length} states '
          'across ${profiles.length} profiles (${profiles.join(', ')}) = '
          '$totalImages committed images.',
        );
      },
    );
  });
}
