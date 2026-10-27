// The screenshot run itself.
//
// Driven by `regenerate.sh`, never by a bare `flutter test` — a screenshot
// needs `flutter drive`, because `takeScreenshot` hands its bytes to the
// *host* through the driver (see `driver.dart`).
//
// **One boot, two devices' worth of states.** Booting once and walking the
// routes is both faster and more honest: the app is in one continuous session,
// exactly as a person's would be, rather than a cold start per image. The run
// has two halves and the order matters:
//
//  1. **No server configured** — the app's default and fully supported state,
//     the fourteen screens `/w-02` committed, followed by the three
//     truth-point states `/w-07` added. A device with no server shows no sync
//     bar at all, so this half has to come first or every one of those images
//     would move.
//  2. **Configured, signed in, and joining a project** (`/w-05`) — the states
//     the guide's flagship section needs, driven through the app's own fake
//     sync transport with no server anywhere. See `joined.dart`.
//
// **The route loop is not the whole of half one.** Everything reached by a tap
// rather than by a route — the record screen's Truth tab, a point selected on
// the map, a modal over it — lives after the loop, in the order the guide
// walks it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show FlutterMap, MapController;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart'
    show refreshTagViewsIn;
import 'package:tritrack/core/providers/project_link_provider.dart'
    show deletedOnServerListingProvider;
import 'package:tritrack/data/models/individual.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag_library_entry.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart'
    show removalDisclosure;
import 'package:tritrack_sync/tritrack_sync.dart';

import 'harness.dart';
import 'joined.dart';
import 'map_framing.dart';
import 'readiness.dart';
import 'seed.dart';
import 'shots.dart';
import 'take_on_map.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // **Every screen gets photographed even if one of them throws.**
  //
  // Set once, here, outside any test — the framework deliberately fails a test
  // that leaves this changed, and rightly. Two debug assertions fired on the
  // map screen until task 11.95 closed them, and left to the ordinary
  // behaviour the first of them ended the run with no images at all. It stays
  // switched on because the next screen to throw should cost one image's
  // honesty rather than the whole set.
  //
  // **What it costs, stated rather than implied:** a genuine failure of this
  // harness no longer fails the test either. Three things stand in for that —
  // `reportErrors` below prints every one against the screen it happened on,
  // `review.dart` refuses to call a run that skipped a state green, and the
  // comparison treats a short capture as MISSING screens.
  reportTestException = (details, description) {
    final summary = details.exceptionAsString().split('\n').first;
    // **A build-phase assertion names a rule, not a culprit** (`/w-10`). Its
    // message is *"setState() or markNeedsBuild() called during build."* and
    // nothing else; who broke the rule is in the stack. Filing the message on
    // its own gave the code lane a finding it could not act on, twice. So for
    // this one class the app's own frames are kept — `package:tritrack` only,
    // because the framework's frames are the same every time and are not the
    // answer.
    if (!summary.contains('markNeedsBuild') && !summary.contains('setState')) {
      recordCaptureError(summary);
      return;
    }
    final ours = details.stack
        .toString()
        .split('\n')
        .where((line) => line.contains('package:tritrack'))
        .take(8)
        .map((line) => line.trim())
        .toList();
    recordCaptureError('$summary  ← ${ours.isEmpty ? 'no package:tritrack '
        'frame in the stack, so this came from the framework or a package' : ours.join(' | ')}');
  };

  /// Every name this run actually called the shutter for.
  final taken = <String>[];

  /// **The instrument's last words are a finding, not a name.**
  ///
  /// Continuous integration and a scrolled-past terminal both keep only the
  /// tail, so the last thing this run says is which states it failed to
  /// photograph and which screens threw — not "capture complete".
  void reportErrors() {
    // **The denominator, printed on every run including when it is zero.**
    // A sweep with no denominator is a claim nobody can check, and "each state
    // asserts that it had finished" is exactly the kind of claim that decays
    // silently — a state added to `shots.dart` with no entry in
    // `readiness.dart` is photographed by a shutter with nothing watching it.
    final unchecked = statesWithoutReadiness;
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: ${unchecked.length} of '
        '${expectedScreenshotNames.length} states have no readiness condition'
        '${unchecked.isEmpty ? '.' : ': ${unchecked.join(', ')}. A picture of '
            'an unfinished one of those would still be reported as a '
            'success.'}');
    final missed = [
      for (final name in expectedScreenshotNames)
        if (!taken.contains(name)) name,
    ];
    // ignore: avoid_print
    print('');
    if (missed.isNotEmpty) {
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: ${missed.length} state(s) were never '
          'photographed: ${missed.join(', ')}. The review will refuse this '
          'run.');
    }
    if (capturedErrors.isEmpty) {
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: ${taken.length} of '
          '${expectedScreenshotNames.length} states photographed; no screen '
          'threw while being photographed.');
      return;
    }
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: ${taken.length} of '
        '${expectedScreenshotNames.length} states photographed. '
        '${capturedErrors.length} screen(s) threw while being photographed. '
        'Their images were still captured and may show a debug-build artefact '
        'a shipped build never draws:');
    capturedErrors.forEach((screen, errors) {
      for (final error in errors.toSet()) {
        // ignore: avoid_print
        print('  $screen — $error');
      }
    });
  }

  // **An explicit timeout, because the default one was ending the run.**
  //
  // Three consecutive runs on 2026-09-03 stopped at 3:30, 3:47 and 3:54
  // elapsed — at three *different* points in the sequence, which is the shape
  // of a clock running out rather than of a step failing. Each time the body
  // simply stopped, the container was torn down, and the pump after it
  // asserted `inTest: is not true`; the run still printed "All tests passed",
  // because a test that has finished has finished. The states after the stop
  // were reported as never photographed and the review refused the run, which
  // is the discipline working — but the reason it gave was the last thing that
  // happened rather than the thing that was wrong.
  //
  // This run has always been minutes long: the map alone waits up to three for
  // a cold terrain fetch. `/w-10` added eight states and pushed it past
  // whatever the default allows. The number below is a ceiling nobody should
  // ever reach, not a duration — same rule as the readiness ceilings.
  testWidgets('every state the guide may show', timeout: const Timeout(Duration(minutes: 30)), (tester) async {
    // **A name typed twice would silently overwrite an image**, and the review
    // would then report one state where two were photographed. Checked before
    // anything is captured, so the run stops rather than producing a set that
    // looks complete.
    final duplicate = duplicateShotName();
    expect(duplicate, isNull, reason: 'two shots share the name "$duplicate"');
    // **A readiness condition keyed to a name nothing captures is a condition
    // that never runs**, and the map in `readiness.dart` would still look
    // full. Checked here rather than trusted, for the same reason the line
    // above is: a typo that makes an instrument quietly smaller is the defect
    // this harness keeps finding in itself.
    expect(
      unknownReadinessKeys,
      isEmpty,
      reason: 'readiness.dart has conditions for states no run captures: '
          '${unknownReadinessKeys.join(', ')}',
    );
    // `shots.dart` cannot import `seed.dart` — the review runs it under plain
    // `dart run`, with no Flutter — so the members route carries the project
    // id as a literal. This is the check that keeps the two in step.
    expect(
      shots.any((s) => s.route.contains(seedProjectId)),
      isTrue,
      reason: 'no shot names the seeded project id "$seedProjectId"; the '
          'literal in shots.dart has drifted from seed.dart',
    );

    final container = await bootApp(tester);
    addTearDown(container.dispose);

    // **The GPS fix, switched on by `/w-06`, and this line is also task
    // 11.95's outstanding confirmation.**
    //
    // It was held back because the moment the app had a fix the map screen
    // started an automatic viewshed from inside `build`, and the resulting
    // unhandled asynchronous error ended the test while this loop carried on
    // against a disposed container — "all tests passed" over an empty
    // directory. 11.95 identified that error as the provider write itself and
    // removed it, and fixed the attribution overflow that was throwing beside
    // it. That task's own evidence was a widget test, because this harness
    // deliberately withheld the fix; **this run is the confirmation it asked
    // for.**
    //
    // Delivered before the loop rather than inside it so every screen is
    // photographed in the same state: with a fix, which is the state a person
    // outdoors is in. It changes what several screens show — a position on
    // the map, a prefilled position on the record form, a declination on the
    // compass — and those image changes were looked at and accepted
    // deliberately.
    enableGpsFix();
    await settle(tester);

    // **Every shutter in this run goes through here, and that is what makes
    // the readiness conditions worth having** (`/w-11`). One funnel means a
    // state cannot be photographed without its own condition being asked
    // first — or, if it has none, without the run saying so out loud.
    //
    // **`/w-10` looked for an exception here and did not need one.** The one
    // state that would have wanted focus at the shutter — the notes box being
    // written — turned out not to be photographable on this harness at all;
    // see `noteShotNames` in `shots.dart` for the three measurements. So this
    // stays unconditional, which is the version that is easiest to keep true.
    Future<void> shoot(String name) async {
      await awaitReady(tester, container, name);
      // **The keyboard-state fix (`/w-13`).** Two fields elsewhere in the app
      // carry `autofocus: true` — the truth-point correction dialog's
      // Precision field (`lib/features/observations/widgets/`
      // `truth_point_edit_dialog.dart`) and the compass screen's declination
      // control (`lib/features/compass/widgets/declination_control.dart`) —
      // and this harness runs against a simulator with a hardware keyboard
      // attached. A field left focused there draws no software keyboard;
      // instead iOS floats its keyboard-dismiss pill over the app's own
      // chrome, and the keyboard inset it opens shifts everything below it.
      // That inset was found riding along past the screen that caused it,
      // into `truth-point-edit` itself (`/w-12`'s 13.24% `ipad-13` drift) and
      // — from the compass screen's field — into every screen shot
      // afterwards until something else stole focus: `map`,
      // `joined-sync-indicator`, `truth-point-panel`, `bearing-selected`,
      // `bearing-dragged` and `position`, the seven screens task 11.200
      // measured moving 20-47% with nothing touching them. One cause, two
      // source fields.
      //
      // Unfocusing here, at the one funnel every shutter already goes
      // through, is the class-level fix rather than patching the two known
      // call sites: it holds even if a future field somewhere else gains
      // `autofocus: true`. Watched failing: reverting this call and
      // re-running reproduces both the visible keyboard pill on
      // `truth-point-edit` and the 20-47% drift on the other six screens.
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester);
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: capturing $name');
      await binding.takeScreenshot(name);
      taken.add(name);
    }

    /// **Runs one block of new states so that its failure costs only its own
    /// pictures** (`/w-32`). A block that throws (a finder that matches nothing
    /// is a `StateError`) used to end the whole test body, and the run then
    /// reported 24 states never photographed behind the one that broke. The
    /// error is recorded against the block, loudly, and any modal the block
    /// left open is popped so the next block starts on a screen and not under
    /// a dialog.
    Future<void> guarded(String what, Future<void> Function() body) async {
      try {
        await body();
      } catch (error) {
        recordCaptureError('$what stopped early — '
            '${error.toString().split('\n').first}');
      }
      final scaffolds = find.byType(Scaffold);
      if (scaffolds.evaluate().isNotEmpty) {
        Navigator.of(tester.element(scaffolds.first), rootNavigator: true)
            .popUntil((route) => route is! PopupRoute);
      }
      await settle(tester);
    }

    // ---- Half one: no server configured -----------------------------------
    for (final shot in shots) {
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: going to ${shot.route}');
      await goTo(tester, container, shot.route);
      // **The one route shot that is a Main Map picture** (`/w-30`): waits for
      // the viewshed, switches it off, and frames the day's bearings clear of
      // the map's own controls. See `map_framing.dart`.
      if (shot.name == 'map') {
        await prepareMapShot(tester, container, shot.name);
      }
      await shoot(shot.name);
    }

    // ---- App Info, scrolled to TriTrack support (`/w-35`) ------------------
    await goTo(tester, container, '/more/app-info');
    currentScreen = "App Info's TriTrack support section";
    await scrollTo(tester, find.text('Contact TriTrack support'),
        describedAs: 'the support link');
    await shoot('app-info-support');


    // ---- The sheets over the Position tab (`/w-32`) ------------------------
    //
    // Asked for by `/w-31`: the cautions sheet, the legend card and the
    // past-estimates sheet. Each is one tap on the screen the route loop has
    // just photographed, and none changes anything — the past-estimates sheet
    // lists the seeded Sage estimate, and every sheet is closed again.
    await goTo(tester, container, '/position');
    currentScreen = 'the position screen, before its sheets';
    // The sheets are drawn over this screen, and a sheet over a half-drawn map
    // is the picture `/w-09` shipped; the screen's own condition is asked first.
    await awaitReady(tester, container, 'position');

    Future<void> closeSheetShowing(String fragment) async {
      final anchor = find.textContaining(fragment);
      if (anchor.evaluate().isEmpty) return;
      Navigator.of(tester.element(anchor.first)).pop();
      await settle(tester);
    }

    currentScreen = 'the cautions sheet';
    final cautionButton = find.textContaining(' caution');
    if (cautionButton.evaluate().isEmpty) {
      recordCaptureError('the Position screen shows no cautions button, so '
          'position-cautions would be a picture of the screen without a sheet');
    } else {
      await tester.tap(cautionButton.first);
      await settle(tester);
    }
    await shoot('position-cautions');
    await closeSheetShowing('They do not stop you saving');

    currentScreen = 'the legend card';
    final legendButton = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'MapLegendButton',
        description: 'the map legend button');
    if (legendButton.evaluate().isEmpty) {
      recordCaptureError('the Position screen has no legend button');
    } else {
      await tester.tap(legendButton.first);
      await settle(tester);
    }
    await shoot('position-legend');
    // Closed by the same button, and the next picture's readiness would notice
    // a card left open.
    if (legendButton.evaluate().isNotEmpty) {
      await tester.tap(legendButton.first);
      await settle(tester);
    }

    currentScreen = 'the past-estimates sheet';
    final pastButton = find.byTooltip('Past estimates for this tag');
    if (pastButton.evaluate().isEmpty) {
      recordCaptureError('the Position screen has no past-estimates button');
    } else {
      await tester.tap(pastButton.first);
      await settle(tester);
    }
    await shoot('position-past-estimates');
    await closeSheetShowing('Past estimates ·');

    // ---- Words where there were database tokens (`/w-10`, task 11.199) ----
    //
    // Three of the four screens task 11.199 stopped printing storage
    // spellings on. **None of the four had ever been photographed**, which is
    // not the same as four pictures that came back unchanged: with no
    // baseline the comparison cannot say a screen did not move, only fail to
    // look at it. See `plainWordsShotNames` in `shots.dart`.
    //
    // They are here, immediately after the route loop, because all three are
    // More-tab screens reached from a route plus one or two taps, and because
    // none of them touches the map — the map states at the end of this half
    // are the expensive ones and nothing here should disturb the camera.

    // 1. The paste screen's preview card. The payload is built by the app's
    //    own share encoder from a colleague's seeded bearing (see
    //    `sharedObservationPayload`), so this picture cannot drift from what
    //    the Log screen's *Share observation…* actually writes.
    await goTo(tester, container, '/more/observation-sharing');
    currentScreen = 'the paste screen';
    final payload = await sharedObservationPayload(container);
    final pasteField = find.byType(TextField);
    if (pasteField.evaluate().isEmpty) {
      recordCaptureError('there is no paste field on the observation-sharing '
          'screen, so paste-preview would be a picture of an empty form');
    } else {
      await tester.enterText(pasteField.first, payload);
      await settle(tester);
      final parse = find.widgetWithText(FilledButton, 'Parse');
      if (parse.evaluate().isEmpty) {
        recordCaptureError('there is no Parse button on the paste screen, so '
            'the payload was never turned into a preview card');
      } else {
        await tester.tap(parse.first);
        await settle(tester);
      }
    }
    // **Whether a card actually appeared is this state's readiness
    // condition**, and it waits for the record-type line specifically —
    // the line task 11.199 changed — rather than for the screen.
    await shoot('paste-preview');

    // 2. `More → Tags` — the project's own tag list (task 11.245 moved it off
    //    Project Setup). A tag whose status is not `active` carries that
    //    status as its subtitle. `seedTagLost()` is the only row in the
    //    fixture that draws one at all.
    //
    //    **A fragment, not the whole subtitle, since schema v17 (task
    //    11.243).** Every seeded tag has been deployed on an animal of its
    //    own name since the animals-and-deployments seed landed, so
    //    Ridgeline's row now reads "Worn by Ridgeline · Lost" — one `Text`
    //    joining both facts — and `find.text('Lost')` stopped matching
    //    anything. Found by `/w-13` (2026-09-18): this capture threw on
    //    every profile, run after run, with nothing about task 11.245
    //    responsible for it.
    await goTo(tester, container, '/more/tags');
    currentScreen = "the project's tag list";
    await scrollTo(
      tester,
      find.textContaining('Lost'),
      describedAs: "the lost tag's status subtitle",
    );
    await shoot('project-tags');

    // 3. The Log screen's supersede picker, **with its candidate list open**.
    //    The rows are the subject and they exist only while the dropdown menu
    //    is showing, so this is three taps rather than one: the row menu, the
    //    supersede entry, and the dropdown itself.
    //
    //    **Juniper, because Juniper is the tag with a candidate that has no
    //    bearing.** A candidate without one is labelled by its record type,
    //    which is the line 11.199 changed; every other tag in the fixture
    //    would offer nothing but angles, and a picture of that would cover
    //    the changed line with nothing at all. See `seed-obs-juniper-omni`.
    await goTo(tester, container, '/more/log');
    currentScreen = 'the log row menu';
    // **Which row, and why it is not simply the first Juniper one.** The Log
    // lists every record newest first, and the omni record is newer than both
    // Juniper bearings — so `find.byTooltip(...).first` would open the menu on
    // the omni row itself, whose candidates are the two bearings and contain
    // no record-type label at all. The picture would then be of a picker with
    // the word this shot exists for nowhere in it, and nothing about it would
    // look wrong.
    //
    // So the run walks the Juniper rows and takes the first that is *not* the
    // omni one. The lower-cased comparison is deliberate: the Log row spells
    // this record type `omni` where `RecordType.omnidirectional.label` spells
    // it `Omni` (reported to the code lane), and a check that broke on that
    // being repaired would break silently.
    Finder? juniperBearingMenu() {
      final tiles = find.ancestor(
        of: find.textContaining('Juniper'),
        matching: find.byType(ListTile),
      );
      for (final element in tiles.evaluate()) {
        final tile = find.byWidget(element.widget);
        final isOmniRow = find
            .descendant(
              of: tile,
              matching: find.byWidgetPredicate((w) =>
                  w is Text &&
                  (w.data ?? '').toLowerCase().contains(' · omni · ')),
            )
            .evaluate()
            .isNotEmpty;
        if (isOmniRow) continue;
        final menu = find.descendant(
          of: tile,
          matching: find.byTooltip('Observation actions'),
        );
        if (menu.evaluate().isNotEmpty) return menu;
      }
      return null;
    }

    final rowMenu = juniperBearingMenu();
    if (rowMenu == null) {
      recordCaptureError('no Juniper bearing row with an actions menu is on '
          'the Log screen, so log-supersede would be a picture of the log');
    } else {
      await tester.tap(rowMenu.first);
      await settle(tester);
      final supersede = find.textContaining('Superseded by another record');
      if (supersede.evaluate().isEmpty) {
        recordCaptureError('the row menu has no supersede entry — either this '
            'account may not supersede, or the entry has been renamed');
      } else {
        await tester.tap(supersede.first);
        await settle(tester);
        currentScreen = 'the supersede picker';
        // Opening the dropdown is what puts the candidate rows on screen.
        // Without this the dialog photographs with an empty "Replacement"
        // field and the word this shot exists for is nowhere in it.
        final replacement = find.byType(DropdownButtonFormField<String>);
        if (replacement.evaluate().isEmpty) {
          recordCaptureError('the supersede dialog has no replacement picker, '
              'which means it found no candidate records to offer');
        } else {
          await tester.tap(replacement.first);
          await settle(tester);
        }
      }
    }
    await shoot('log-supersede');

    // **Dismissed through the app, and checked.** An open dropdown over an
    // open dialog is state every later capture in this half would inherit,
    // and the map states after it are the expensive ones to get wrong.
    await tester.tapAt(const Offset(8, 8));
    await settle(tester);
    final stillOpen = find.text('Superseded by which record?');
    if (stillOpen.evaluate().isNotEmpty) {
      final cancelSupersede = find.widgetWithText(TextButton, 'Cancel');
      if (cancelSupersede.evaluate().isNotEmpty) {
        await tester.tap(cancelSupersede.first);
        await settle(tester);
      }
    }
    if (find.text('Superseded by which record?').evaluate().isNotEmpty) {
      recordCaptureError('the supersede dialog is still open, so everything '
          'photographed after this has a modal over it');
    }

    // ---- The three truth-point states (`/w-07`) ---------------------------
    //
    // A truth point is where somebody physically found the animal or the
    // collar. The log listing already photographs one; these are the three
    // surfaces it does not reach, and each is driven by a tap rather than by
    // a route. See `truthPointShotNames` in `shots.dart`.
    //
    // **Every one of them asserts what it is a picture of before the
    // shutter**, which is the discipline `/w-03`'s approval sheet
    // established: a shutter that fires on the wrong thing still produces a
    // file, and that file goes on a page captioned as something it is not.
    //
    // They sit here, at the end of half one, so they are of the same
    // unconfigured device as `record` and `map` — nothing about a truth point
    // needs a server, and a sync bar on two of the section's three pictures
    // would read as an inconsistency in the app rather than as a difference
    // between two devices.

    // 1. The record screen's Truth tab: the form somebody fills in.
    await goTo(tester, container, '/record');
    currentScreen = 'the record screen, Truth tab';
    // **Found by key, not by its word** (task 11.197). The record-type
    // control now draws the four types a person is *not* recording as icons
    // only, so `find.text('Truth')` matches nothing until Truth is already
    // selected — which is the state this is trying to reach. The key is
    // built from the same `RecordType.label` the segment is built from, so a
    // rename moves both.
    final truthTab =
        find.byKey(ValueKey('segment:${RecordType.groundTruth.label}'));
    if (truthTab.evaluate().isEmpty) {
      recordCaptureError('there is no "${RecordType.groundTruth.label}" '
          'record-type button on the record screen, so record-truth would be '
          'a picture of whichever tab was already selected');
    } else {
      await tester.tap(truthTab.first);
      await settle(tester);
    }
    // **The two assertions this shot has always carried now live in
    // `readiness.dart`** (`/w-11`), unchanged in substance: the section label
    // is the field a truth point cannot be saved without, and the save button
    // is what says the record being written is a truth point and not an
    // observation. Either alone would also be true of a screen that had only
    // half switched. Moving them means the run *waits* for them rather than
    // asking once at whatever moment a sleep happened to end — and a check
    // left here as well would fire before that wait and report a red on a
    // screen that was merely a frame behind.
    await shoot('record-truth');

    // ---- The Note form (`/w-16`) ------------------------------------------
    //
    // **A different shape of screen, not a taller field.** On a Note the
    // notes box is `Expanded` (task 11.197): it takes every pixel left
    // between the position row and the pinned SAVE NOTE bar, because on this
    // record type the box *is* the record. Nothing published showed it.
    //
    // **At rest, with nothing focused**, and `shots.dart`'s `noteShotNames`
    // holds the argument for that departure from `/w-16`'s brief — the short
    // version is that the simulator runs with a hardware keyboard, so a
    // focused field is photographed with iOS's floating-keyboard control
    // where a keyboard should be, which is the open contamination `/w-13`
    // holds against `ipad-13/truth-point-edit`.
    //
    // Found by key for the same reason the Truth segment is: the record-type
    // control draws the four types a person is *not* recording as icons only,
    // so `find.text('Note')` matches nothing until Note is already selected.
    currentScreen = 'the record screen, ${RecordType.note.label} tab';
    final noteTab = find.byKey(ValueKey('segment:${RecordType.note.label}'));
    if (noteTab.evaluate().isEmpty) {
      recordCaptureError('there is no "${RecordType.note.label}" record-type '
          'button on the record screen, so record-note would be a picture of '
          'whichever tab was already selected');
    } else {
      await tester.tap(noteTab.first);
      await settle(tester);
    }
    // **That the box actually fills the screen is `record-note`'s readiness
    // condition**, measured rather than assumed — see `readiness.dart`. A
    // check repeated here would fire before that wait and report a red on a
    // screen that was one frame behind.
    await shoot('record-note');

    // **Put the tab back, and check that it went.** The draft autosaves and
    // outlives this test, so a record screen left on Truth is a piece of
    // state every later capture inherits.
    //
    // **Its original reason has expired and the check is kept deliberately**
    // (`/w-14`). It was written because `joined-sync-bar` re-photographed
    // `/record` under a server and would have caught the wrong tab; that shot
    // is now `joined-sync-indicator` and is of the map. Nothing downstream
    // photographs this screen today — but "nothing photographs it *today*" is
    // the assumption a future shot silently falsifies, and restoring the tab
    // costs one tap.
    currentScreen =
        'the record screen, back on ${RecordType.directional.label}';
    await tester.tap(
        find.byKey(ValueKey('segment:${RecordType.directional.label}')).first);
    await settle(tester);
    if (!showsText(tester, 'SAVE OBSERVATION')) {
      recordCaptureError('the record screen did not go back to '
          '"${RecordType.directional.label}", so the autosaved draft every '
          'later capture inherits is on the wrong tab');
    }

    // 2. The map info panel for a truth point.
    //
    // **This used to carry a 45-second sleep and no longer carries any**
    // (`/w-11`). The panel is photographed over the map, so a short wait here
    // put a progress bar across the guide's truth-point picture — which is
    // precisely what happened. `truth-point-panel`'s readiness condition
    // inherits the map's: the viewshed overlay has to be drawn and the status
    // bar quiet before the panel is a picture of anything.
    await goTo(tester, container, '/map');
    currentScreen = 'the truth point on the map';
    // `/w-30`: viewshed off and the day's bearings framed *before* the marker
    // is found and tapped, so the tap lands on a marker that is in the clear.
    await prepareMapShot(tester, container, 'truth-point-panel',
        truthPointOnly: true);
    // **Wait for the camera before finding a marker** (`/w-32`, task 11.319):
    // the first frame is drawn at the opening zoom and the camera then moves.
    await awaitCameraSettled(tester, 'truth-point-panel');
    // Found by run-time type because the marker class is private to
    // `map_screen.dart`. Exactly one is expected: the seed holds one truth
    // point, and two would mean the tap below could open either.
    final marker = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_TagLocationMarker',
      description: 'the truth point marker',
    );
    if (marker.evaluate().length != 1) {
      recordCaptureError('the map is drawing ${marker.evaluate().length} '
          'truth-point markers and this run expects exactly one; '
          'truth-point-panel is not a picture of a chosen point');
    }
    if (marker.evaluate().isNotEmpty) {
      final box = tester.getRect(marker.first);
      // **The square is tapped first, and the run says whether that worked.**
      //
      // This began as a measurement of a defect. flutter_map's marker
      // `alignment` decides where a marker's box sits relative to its
      // coordinate, and this one was plain `Alignment.topCenter`, which put
      // the box's *bottom* on the point — so the little square at the top of
      // the box was drawn about 28 logical pixels above the position it stood
      // for, while the map's own hit test measured from the position and
      // accepted 24. Tapping the thing you can see selected nothing. `/w-07`
      // found it by trying to write the sentence "tap the truth point", filed
      // it for the code stream, and made this run **measure** the defect on
      // every capture rather than assert a reading of the code.
      //
      // **Task 11.100 fixed it and this line is what said so**, printing
      // *opened* for the first time on 2026-08-31. The measurement stays: it
      // is now the thing that would notice the anchor regressing, and it costs
      // one tap.
      //
      // The geometry it prints is corrected with it (`/w-08`, 11.100's item
      // 4): the marker's 16-pixel square is now centred on the coordinate, so
      // `box.bottom` is 20 pixels *below* the point rather than on it, and a
      // line calling it the coordinate would be this harness describing a
      // mechanism the code no longer has.
      const header = 'Truth point · Sage · 150.284 MHz';
      final tapY = box.top + 8;
      await tester.tapAt(Offset(box.center.dx, tapY));
      await settle(tester, wait: const Duration(seconds: 1));
      // **The card by its widget, not its title as text** (`/w-32`, task
      // 11.319): a marker label can never satisfy this now.
      final squareWorked = find
              .byWidgetPredicate(
                  (w) => w.runtimeType.toString() == '_SelectionInfoPanel')
              .evaluate()
              .isNotEmpty &&
          showsText(tester, header);
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: tapping the drawn truth-point marker '
          '${squareWorked ? 'opened' : 'did NOT open'} its info panel '
          '(tapped the middle of the square at y=${tapY.round()}; '
          'marker box y=${box.top.round()}..${box.bottom.round()})');
      if (!squareWorked) {
        // **Not "the coordinate" — the bottom of the box, which is where the
        // point used to be.** Kept only so the shutter still catches the info
        // panel if the anchor regresses; the line above is what reports it,
        // and this fallback must never be read as the tap having worked.
        await tester.tapAt(Offset(box.center.dx, box.bottom - 1));
        await settle(tester, wait: const Duration(seconds: 1));
      }
      // Whether the panel actually opened is `truth-point-panel`'s readiness
      // condition (`/w-11`), which also waits for the map underneath it to
      // have finished drawing its viewshed — the half of this picture that
      // `/w-09` got wrong.
    }
    // **Framed again now the card is up** (`/w-30`). The camera moves and the
    // selection does not; the card's real height is read off the screen, so
    // the bearings and the truth point stay above it whatever the card holds.
    await frameMapOnBearings(tester, 'truth-point-panel',
        truthPointOnly: true);
    // Kept for the bearing pictures below, which frame the map before their
    // own card exists and need to know how much of the bottom edge a card of
    // this kind takes. Measured here, from a real card, not a constant.
    final infoCardPx = selectionCardHeight(tester);
    await shoot('truth-point-panel');

    // 3. The correction dialog, reached from that panel.
    currentScreen = 'the truth point correction dialog';
    final editButton = find.widgetWithText(OutlinedButton, 'Edit');
    if (editButton.evaluate().isEmpty) {
      recordCaptureError('there is no Edit button on the info panel, so the '
          'correction dialog was never opened and truth-point-edit is a '
          'picture of the map');
    } else {
      await tester.tap(editButton.first);
      await settle(tester);
    }
    // **A picture of this dialog has to contain the move-on-map control**,
    // because that control is the whole of what task 11.93 added and the
    // sentence the guide's section exists to correct: until 2026-08-31 a
    // truth point's position could not be changed. A dialog offering only a
    // precision box would be a picture of the app as it was. That is
    // `truth-point-edit`'s readiness condition in `readiness.dart` (`/w-11`).
    await shoot('truth-point-edit');

    // **Cancelled, not saved.** This run changes no field data: the precision
    // box is untouched, the pin is not moved, and the dialog is dismissed
    // through its own Cancel button so the map underneath is left exactly as
    // the picture above it shows.
    final cancel = find.widgetWithText(TextButton, 'Cancel');
    if (cancel.evaluate().isNotEmpty) {
      await tester.tap(cancel.first);
      await settle(tester);
    }
    if (showsText(tester, 'Edit truth point')) {
      recordCaptureError('the correction dialog is still open after Cancel; '
          'everything photographed after this has a modal over it');
    }

    // ---- The bearing tip-drag gesture (`/w-10`, for task 11.131) ----------
    //
    // Tap a bearing to select it, press and hold the handle at its tip, drag
    // radially, and the ray and its uncertainty wedge extend live with a
    // readout naming the drawn length.
    //
    // **This is the one feature in the app whose discoverability is entirely
    // the guide's.** Nothing on the map says a bearing can be dragged, and the
    // handle appears only once a bearing is selected — a deliberate choice
    // about the map's space budget, whose cost is that a reader who does not
    // learn the gesture here does not learn it. So both halves are
    // photographed: the handle, and the gesture in progress.
    //
    // **Last in half one**, because a dragged length lives on the map screen's
    // `State` until the map is left, and nothing photographed after this is of
    // the map.
    await goTo(tester, container, '/map');
    currentScreen = 'selecting a bearing on the map';
    // `/w-30`. If the truth point's card is still up the furniture measurement
    // already includes it; if the map was rebuilt and no card is up, the
    // height measured on that card is held back for the one that is coming.
    // Whatever is framed here is verified again below, once the bearing's own
    // card is up.
    await prepareMapShot(tester, container, 'bearing-selected',
        reservePanelPx: infoCardPx);

    // A bearing's origin dot: the 14-logical-pixel circle drawn at the
    // position a reading was taken from. Found by shape *and size* rather than
    // by a key, because it has none — and the size is what separates it from
    // every other circle on this map. **The render object is asked directly**
    // rather than going back through a `Finder`, because several of these are
    // identical widgets and `find.byWidget` cannot tell them apart.
    List<RenderBox> originDotsOnScreen() => <RenderBox>[
          for (final element in find
              .byWidgetPredicate((widget) =>
                  widget is DecoratedBox &&
                  widget.decoration is BoxDecoration &&
                  (widget.decoration as BoxDecoration).shape == BoxShape.circle)
              .evaluate())
            if (element.renderObject case final RenderBox box
                when box.hasSize &&
                    box.size.width == 14 &&
                    box.size.height == 14)
              box,
        ];

    /// Where the finger would end up if this bearing were dragged.
    ///
    /// **The first run of this section failed here and the failure is worth
    /// keeping.** It took the first origin dot it found, which happened to be
    /// the one nearest the top right; that bearing points off the right edge,
    /// so its handle was *clamped* to the edge and landed underneath the
    /// map's own button column. The gesture went to a button, no drag
    /// happened, and the readiness condition correctly reported that the
    /// drawn-length readout never appeared. **A bearing is only usable for
    /// this picture if the drag has somewhere to go**, so that is asked
    /// rather than assumed.
    //
    // **The margins are logical points, and the first version of this check
    // wrote them as if they were pixels.** On a 6.9-inch iPhone the window is
    // 440 points wide, not 1320, so a 220-point margin off the right edge
    // excluded the right *half* of the map — and the run correctly reported
    // that no bearing could be dragged, naming both candidates and where each
    // would have finished. The numbers below clear the map's own furniture:
    // the button column on the right is about 60 points wide, the map-type
    // selector across the top about 100 deep, and the info panel opens over
    // the bottom third.
    bool dragHasRoom(Offset tip, Offset finish) {
      // **The measured clear area, not margins written for one phone**
      // (`/w-30`). This used to be four numbers — 40 in from the left, 80 from
      // the right, 130 down from the top, and the top 55% — chosen to clear
      // "the button column, the selector and the info panel". They were
      // right for an unframed map and wrong for one framed on the bearings:
      // the framing puts the bearings in the space *between* that furniture
      // and the card, and 55% of the height is above the card's top on some
      // phones and below it on others. The card is up by the time this is
      // asked (the candidate was just tapped), so its real top is in the
      // measurement.
      final furniture = measureMapFurniture(tester);
      if (furniture == null) return false;
      return furniture.clear.contains(tip) && furniture.clear.contains(finish);
    }

    const dragPixels = 132.0;
    final handleFinder = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_BearingTipHandle',
      description: "the bearing's tip handle",
    );

    // **The map's own controller, so the search can widen its view** (`/w-16`).
    //
    // `map_screen.dart` hands its `MapController` to `FlutterMap`, so the
    // widget on screen is where the harness gets it from rather than reaching
    // into a private `State`. Null only if the map is not built, which the
    // loop below reports rather than throwing on.
    MapController? mapControllerOnScreen() {
      final maps = find.byType(FlutterMap).evaluate();
      if (maps.isEmpty) return null;
      return (maps.first.widget as FlutterMap).mapController;
    }

    Offset? chosenOrigin;
    Offset? chosenTip;
    final rejected = <String>[];
    var dotsSeen = 0;

    // **The default view is not guaranteed to contain a draggable bearing,
    // and on the 6.1-inch phone it does not** (`/w-16`).
    //
    // The first run of that profile found **one** origin dot where the
    // 6.9-inch phone finds two, and the bearing it selected pointed 346° —
    // its tip was off the top of a pane 112 logical pixels shorter, so
    // flutter_map never built the handle and the run correctly reported that
    // `bearing-selected` and `bearing-dragged` were pictures of an ordinary
    // map. **Nothing was wrong with the app or with the fixture: the picture
    // simply does not exist at that zoom on that screen.**
    //
    // So the search widens the view rather than giving up. Each pass zooms
    // out one level and asks again, which brings more origins onto the pane
    // and shortens every ray in logical pixels, so a tip that was off the top
    // comes back onto it. **A profile that finds a candidate on the first
    // pass never zooms at all**, which is why the two existing profiles'
    // images are untouched by this.
    //
    // Bounded at three passes because this is a search, not a hunt: a map
    // with no draggable bearing three levels out is telling the run something
    // about the fixture, and spending the whole zoom range to find that out
    // would leave the picture unrecognisable anyway.
    final startCamera = mapControllerOnScreen()?.camera;
    var zoomedOutBy = 0;
    for (var pass = 0; pass < 3 && chosenOrigin == null; pass++) {
      if (pass > 0) {
        final controller = mapControllerOnScreen();
        if (controller == null) break;
        final camera = controller.camera;
        controller.move(camera.center, camera.zoom - 1);
        zoomedOutBy = pass;
        await settle(tester, wait: const Duration(seconds: 1));
        rejected.add('— zoomed out to ${(camera.zoom - 1).toStringAsFixed(1)} '
            'and looked again —');
      }
      final originDots = originDotsOnScreen();
      dotsSeen = originDots.length;
      for (final dot in originDots) {
        final origin = dot.localToGlobal(dot.size.center(Offset.zero));
        // **A dot under the map's own controls is not tapped** (`/w-30`): the
        // tap would land on the control. The framing keeps the day's
        // bearings clear of them, but the other tags' origins can still be
        // anywhere on the pane.
        final clearNow = measureMapFurniture(tester)?.clear;
        if (clearNow == null || !clearNow.contains(origin)) {
          rejected.add('${origin.dx.round()},${origin.dy.round()} is under '
              "the map's own controls or its card");
          continue;
        }
        await tester.tapAt(origin);
        await settle(tester, wait: const Duration(milliseconds: 600));
        if (handleFinder.evaluate().isEmpty) {
          rejected.add('${origin.dx.round()},${origin.dy.round()} selected '
              'nothing, or its tip is off the pane so no handle was built');
          continue;
        }
        final handleBox =
            handleFinder.evaluate().first.renderObject! as RenderBox;
        final tip = handleBox.localToGlobal(handleBox.size.center(Offset.zero));
        final along = tip - origin;
        if (along.distance < 1) {
          rejected.add('${origin.dx.round()},${origin.dy.round()} has its '
              'handle on top of its origin, so there is no direction to drag '
              'along');
          continue;
        }
        final finish = tip + (along / along.distance) * dragPixels;
        if (!dragHasRoom(tip, finish)) {
          rejected.add('${origin.dx.round()},${origin.dy.round()} would drag '
              'its tip from ${tip.dx.round()},${tip.dy.round()} to '
              '${finish.dx.round()},${finish.dy.round()}, which is off the map '
              'or under the button column');
          continue;
        }
        chosenOrigin = origin;
        chosenTip = tip;
        break;
      }
    }

    // ignore: avoid_print
    print('SCREENSHOT HARNESS: $dotsSeen bearing origin dot(s) on screen after '
        '${zoomedOutBy == 0 ? 'no zooming' : 'zooming out $zoomedOutBy '
            'level(s)'}; ${rejected.isEmpty ? 'the first was usable' : 'rejected '
            '${rejected.length}: ${rejected.join('; ')}'}');

    if (chosenOrigin == null || chosenTip == null) {
      recordCaptureError('no bearing on this map can be dragged without its '
          'tip leaving the window, so bearing-selected and bearing-dragged '
          'are pictures of an ordinary map');
      await shoot('bearing-selected');
      await shoot('bearing-dragged');
    } else {
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: dragging the bearing whose origin is at '
          '${chosenOrigin.dx.round()},${chosenOrigin.dy.round()} and whose '
          'handle is at ${chosenTip.dx.round()},${chosenTip.dy.round()}');
      // **Verified with this bearing's own card up** (`/w-30`): the framing
      // above was chosen before a card of this kind existed, so this is where
      // it is checked against the real one. A card taller than the one it was
      // framed for is a capture error here, not a bearing under a card in the
      // guide.
      await frameMapOnBearings(tester, 'bearing-selected', moveCamera: false);
      await shoot('bearing-selected');

      // **Radial**: the app projects the drag onto the bearing's own
      // direction, so a drag along the line from the origin through the
      // handle lengthens the ray and a drag across it does nothing. The
      // direction is computed from the two things already on screen rather
      // than from the seeded bearing, so it stays right if the fixture
      // changes.
      final along = chosenTip - chosenOrigin;
      final unit = along / along.distance;
      final gesture = await tester.startGesture(chosenTip);
      // **Held still first, and that is what makes the drag take.** The handle
      // offers both a pan and a long press; the map underneath offers a pan of
      // its own, and on a plain press-and-move the two pans go into the same
      // gesture arena. Two runs moved the finger immediately and the readout
      // never appeared, which is the run reporting that the map won. Holding
      // still past the long-press threshold lets the handle's own recogniser
      // declare victory before anything moves — which is also exactly what the
      // app's copy tells a person to do: press and hold the tip, then drag.
      await settle(tester, wait: const Duration(milliseconds: 900));
      // In slices, because one large jump is a fling rather than a drag and
      // the app tracks the total offset since the press.
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(unit * (dragPixels / 6));
        await settle(tester, wait: const Duration(milliseconds: 150));
      }
      // **The finger stays down through the shutter.** The readout exists
      // only while a drag is in progress — that is what makes the gesture a
      // measurement rather than a fidget — so releasing before the photograph
      // would take the picture the section exists for out of the frame.
      await shoot('bearing-dragged');
      await gesture.up();
      await settle(tester);
    }

    // **The camera is put back where it was found** (`/w-16`).
    //
    // Same rule as the record screen's tab and the map's selected bearing:
    // **state one capture leaves behind is state the next one inherits**, and
    // `joined-sync-indicator` in half two is another picture of this map. A
    // profile that zoomed out to find a draggable bearing would otherwise
    // photograph that shot at a different scale from every other profile, for
    // a reason that has nothing to do with what that picture is of.
    if (zoomedOutBy > 0 && startCamera != null) {
      mapControllerOnScreen()?.move(startCamera.center, startCamera.zoom);
      await settle(tester, wait: const Duration(seconds: 1));
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: map camera put back to zoom '
          '${startCamera.zoom.toStringAsFixed(1)} after the bearing drag');
    }


    // ---- Tags, animals and Quick add (`/w-32`) -----------------------------
    //
    // *Link a tag* offers this project's free tags, the Tag Library's tags the
    // project does not hold, and *New tag…*; every seeded tag is already worn
    // by an animal and every library entry is already on the project, so the
    // picker would offer only *New tag…*. **So the run writes an animal with no
    // collar ("Cedar") and a library-only tag ("Aspen") for these pictures and
    // removes both afterwards, completely** — a soft delete would leave rows
    // the sync-status pictures later in the run count as waiting to be sent.
    // Nothing here is saved: both flows stop at the screen that asks.
    currentScreen = 'writing the animal and library tag these pictures need';
    const cedarId = 'screenshot-animal-cedar';
    const aspenId = 'screenshot-library-aspen';
    final sampleSync = SyncMeta.initial(
      now: seedUtc,
      modifiedBy: ownerUserId,
      originDeviceId: seedDeviceId,
    );
    final animalsRepo = await container.read(individualRepositoryProvider.future);
    await animalsRepo.insert(Individual(
      individualId: cedarId,
      projectId: seedProjectId,
      name: 'Cedar',
      colorHex: TagColorPalette.colorForIndex(6),
      status: IndividualStatus.alive,
      lineageId: cedarId,
      sync: sampleSync,
    ));
    final libraryRepo = await container.read(tagLibraryRepositoryProvider.future);
    await libraryRepo.insert(TagLibraryEntry(
      tagId: aspenId,
      lineageId: aspenId,
      frequencyMhz: 150.580,
      pulseRate: 44,
      pulsePattern: 'steady',
      tagName: 'Aspen',
      status: TagStatus.active,
      colorHex: TagColorPalette.colorForIndex(7),
      sync: sampleSync,
    ));
    // The animal page reads the Tag Library through a cached provider; a row
    // written straight into the repository is not seen until it is told.
    refreshTagViewsIn(container, projectId: seedProjectId);

    await guarded('the link picker pictures', () async {
      // 1. The link picker and its confirmation, from the new animal's page.
      await goTo(tester, container, '/more/animals');
      currentScreen = 'the Animals list';
      final cedarRow = find.text('Cedar');
      if (cedarRow.evaluate().isEmpty) {
        recordCaptureError('the animal written for the link picker is not on '
            'the Animals list');
      } else {
        await tester.tap(cedarRow.first);
        await settle(tester);
        currentScreen = "Cedar's page";
        await scrollTo(tester, find.byKey(const ValueKey('link_tag')),
            describedAs: 'the Link a tag button');
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await settle(tester);
      }
      await shoot('link-tag-picker');
      // Choosing the library tag opens the confirmation, with the date card.
      final aspenChoice = find.descendant(
          of: find.byType(Dialog), matching: find.textContaining('Aspen'));
      if (aspenChoice.evaluate().isEmpty) {
        recordCaptureError('the link picker does not offer the library tag, so '
            'link-tag-confirm would be a picture of the picker');
      } else {
        await tester.tap(aspenChoice.first);
        await settle(tester, wait: const Duration(seconds: 2));
      }
      await shoot('link-tag-confirm');
      final cancelLink = find.widgetWithText(TextButton, 'Cancel');
      if (cancelLink.evaluate().isNotEmpty) {
        await tester.tap(cancelLink.first);
        await settle(tester);
      }
      if (find.textContaining('Link to Cedar').evaluate().isNotEmpty) {
        recordCaptureError('the link confirmation is still open after Cancel');
      }

    });

    await guarded('the Quick add pictures', () async {
      // 2. Quick add: three rows typed in, then the review of what each would do.
      //    **Alder's frequency is Aspen's**, so the review shows a row coming
      //    from the Tag Library as well as two new tags — which is the whole of
      //    what the review explains.
      await goTo(tester, container, '/more/animals');
      currentScreen = 'Quick add';
      final quickAdd = find.byKey(const ValueKey('quick_add'));
      if (quickAdd.evaluate().isEmpty) {
        recordCaptureError('there is no Quick add button on the Animals screen');
      } else {
        await tester.tap(quickAdd.first);
        await settle(tester);
        Future<void> fillRow(int i, String name, String mhz) async {
          if (i > 0) {
            await tester.tap(find.byKey(const ValueKey('quick_add_add_row')));
            await settle(tester, wait: const Duration(milliseconds: 600));
          }
          await tester.enterText(
              find.byKey(ValueKey('quick_add_name_$i')), name);
          await tester.enterText(find.byKey(ValueKey('quick_add_freq_$i')), mhz);
          await settle(tester, wait: const Duration(milliseconds: 400));
        }

        await tester.enterText(
            find.byKey(const ValueKey('quick_add_species')), 'Vulpes macrotis');
        await fillRow(0, 'Alder', '150.580');
        await fillRow(1, 'Mesquite', '150.520');
        await fillRow(2, 'Willow', '150.601');
      }
      await shoot('quick-add');
      final review = find.byKey(const ValueKey('quick_add_review'));
      if (review.evaluate().isNotEmpty) {
        await scrollTo(tester, review, describedAs: 'the Review button');
        await tester.tap(review.first);
        await settle(tester, wait: const Duration(seconds: 2));
      }
      await shoot('quick-add-review');
      // Backed out twice, saving nothing, and checked.
      for (var i = 0; i < 2; i++) {
        if (find.byType(BackButton).evaluate().isNotEmpty) {
          await tester.pageBack();
          await settle(tester);
        }
      }
      if (find.text('Quick add').evaluate().length > 1 ||
          find.text('Review').evaluate().isNotEmpty) {
        recordCaptureError('Quick add is still open, so something after it is '
            'photographed with its screen over it');
      }
    });

    // Everything written for these four pictures goes, and the run says so.
    final tagFlowDb = await container.read(appDatabaseProvider.future);
    final removedAnimal = await tagFlowDb.raw.delete('Individuals',
        where: 'individual_id = ?', whereArgs: [cedarId]);
    final removedLibrary = await tagFlowDb.raw
        .delete('Tag_Library', where: 'tag_id = ?', whereArgs: [aspenId]);
    refreshTagViewsIn(container, projectId: seedProjectId);
    final leftover = await tagFlowDb.raw.query('Individuals',
        where: 'name IN (?, ?, ?)', whereArgs: ['Alder', 'Mesquite', 'Willow']);
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: removed $removedAnimal animal and '
        '$removedLibrary library tag written for the tag-flow pictures; '
        '${leftover.length} animal(s) from Quick add were saved (expected 0)');
    if (leftover.isNotEmpty) {
      recordCaptureError('Quick add saved ${leftover.length} animal(s); the '
          'run was meant to stop at the review');
    }

    // ---- Take on map (`/w-32`) ---------------------------------------------
    //
    // The guide's newest feature. **A simulator has no compass**, so the
    // harness's faked heading is moved on a script (`take_on_map.dart`), and
    // two bearings dated today are written for the sweep to cross and removed
    // afterwards. The Record screen with the round map button is the ordinary
    // `record` shot; these are the screen the button opens, before a sweep and
    // after one is released.
    // **The More tab is left on its menu first.** A screen with a floating
    // button still open under it (the Animals screen, from the pictures above)
    // plus the Map tab's own "+" is two buttons sharing Flutter's default hero
    // tag in one subtree, and pushing *Take on map* over that raises a debug-only
    // assertion. A release build does not assert. Reported for the code lane in
    // the `/w-32` comms entry rather than hidden here.
    await goTo(tester, container, '/more');
    currentScreen = 'writing the bearings Take on map draws';
    await addTodaysBearings(container);
    final tagBeforeTakeOnMap = await selectSageOnRecord(container);
    await goTo(tester, container, '/record');
    await guarded('the Take on map pictures', () async {
      currentScreen = 'Take on map';
      if (await openTakeOnMap(tester)) {
        setFakeHeading(sweepStartDeg);
        await settle(tester, wait: const Duration(seconds: 1));
        await shoot('take-on-map');
        final sweep = await startSweep(tester);
        if (sweep != null) {
          await sweep.up();
          await settle(tester, wait: const Duration(milliseconds: 800));
        }
        await shoot('take-on-map-released');
        final cancelSweep = find.byKey(const ValueKey('bearing-map-cancel'));
        if (cancelSweep.evaluate().isNotEmpty) {
          await tester.tap(cancelSweep.first);
          await settle(tester);
        }
        if (find.byKey(const ValueKey('bearing-map-hold')).evaluate().isNotEmpty ||
            find.text('Take on map').evaluate().length > 1) {
          recordCaptureError('Take on map is still open after Cancel');
        }
      } else {
        await shoot('take-on-map');
        await shoot('take-on-map-released');
      }
    });

    // **Put back everything the sweep touched**: the compass to its one fixed
    // number, the record draft to the tag it had, and the bearings gone.
    restoreHeading();
    restoreRecordDraft(container, tagBeforeTakeOnMap);
    await removeTodaysBearings(container);
    await settle(tester);

    // ---- Half two: configured, signed in, joining a project ----------------
    currentScreen = 'activating the joined device';
    await activateJoinedDevice(container);
    // **Before anything in this half is photographed** (`/w-14`). The
    // fixture's last successful sync is stamped in February so the pictures
    // do not drift, and a seven-month-old stamp is a *fault* — every joined
    // capture was drawing "not synced in over 24 hours" rather than the state
    // it was taken for, and the map's status icon came out red in the picture
    // whose subject is the calm one. See `dismissStaleWarning` for why this
    // is a dismissal rather than a fresh timestamp.
    await dismissStaleWarning(container);
    await settle(tester);

    // **The sixty-second poll is suspended for the whole of this half.** A
    // tick landing between the navigation and the shutter would change the
    // screen under the camera, and an image that is sometimes of a different
    // state is worse than no image, because nobody can tell which run they
    // are looking at.
    final watcher = container.read(joinRequestWatcherProvider.notifier);
    watcher.suspend();

    // The projects screen now offers "Join a project", because there is a
    // server and somebody signed in.
    await goTo(tester, container, '/more/projects');
    await shoot('joined-projects');

    // A code typed in, ready to send. The name field pre-fills from this
    // device's own profile and stays editable — the guide has to explain that,
    // so the picture has to show it.
    await goTo(tester, container, '/more/projects/join');
    watcher.suspend();
    currentScreen = 'join code entry';
    await tester.enterText(
      find.byType(TextField).first,
      formatJoinCode(steensJoinCode),
    );
    await settle(tester, wait: const Duration(seconds: 1));
    await shoot('join-code-entered');

    // Asking is not joining, and the screen says so.
    currentScreen = 'waiting for approval';
    await tester.tap(find.text('Ask to join'));
    await settle(tester);
    await shoot('join-waiting');

    // The owner, on their own device, says yes.
    currentScreen = 'approved and downloading';
    final requestId = screenshotTransport.serverJoinRequests
        .lastWhere((r) => r.projectId == steensProjectId)
        .requestId;
    await screenshotTransport.approveJoinRequest(
      projectId: steensProjectId,
      requestId: requestId,
      role: ProjectRole.contributor,
    );
    // **Held open on purpose.** An in-memory download finishes in under a
    // frame, so the "you're in, downloading now" state — the one a person on a
    // real connection actually sits and looks at — cannot otherwise be
    // photographed at all.
    final hold = Completer<void>();
    screenshotTransport.holdPull = hold;
    unawaited(watcher.refresh());
    await settle(tester);
    await shoot('join-downloading');

    hold.complete();
    await settle(tester, wait: const Duration(seconds: 6));
    watcher.suspend();
    currentScreen = 'joined and on the device';
    // **Did the project actually arrive?** The watcher catches a failed
    // download and says so on the card rather than throwing, which is right
    // for a person in a dead zone and wrong for an instrument: without this,
    // the picture of "the download hasn't started" would be committed under
    // the name `join-arrived`. Repeating the join is how the reason gets
    // printed at all — the watcher's own copy of it is discarded.
    if (!await joinedProjectIsOnDevice(container)) {
      try {
        await container
            .read(membershipControllerProvider.notifier)
            .joinApprovedProject(steensProjectId);
      } catch (error) {
        recordCaptureError('the approved project never downloaded — $error');
      }
      if (!await joinedProjectIsOnDevice(container)) {
        recordCaptureError('join-arrived is a picture of a join that did not '
            'happen; do not accept it');
      }
      await settle(tester);
    }
    await goTo(tester, container, '/more/projects');
    await shoot('join-arrived');

    // ---- The joined project's own tag list, as a non-owner (`/w-13`, item 5;
    // moved here by `/w-18` after task 11.219; route corrected by `/w-13`,
    // 2026-09-18, after task 11.245) -----------------------------------------
    //
    // This device only contributes to Steens; the tag seeded on it
    // (`joined.dart`'s `steensTagId`) carries a status badge, and this row
    // used to be photographed on the Tag Database screen with a padlock
    // beside it. **Task 11.219 removed the padlock and moved the row
    // entirely**: the Tag Database screen shows this device's own tag
    // *library* now, which no role governs and which never held this tag —
    // `steensTagId` was created on a different device and arrived only as
    // this project's own copy. A project's tags, and the owner-only rule
    // that still governs them, moved again with task 11.245, off Project
    // Setup onto their own screen, `More → Tags`, which is what this shoots
    // now. **The old `/more/project-setup/$steensProjectId` route stopped
    // showing a project's tags at all** — this capture threw on every
    // profile until the route was corrected, and this state and
    // `tag-details-readonly` below had collapsed into two names for one
    // broken picture.
    currentScreen = "the joined project's tag list, as a contributor";
    await setActiveProject(container, steensProjectId);
    await goTo(tester, container, '/more/tags');
    await scrollTo(
      tester,
      find.textContaining('East Rim'),
      describedAs: "the joined project's own tag, below the fold",
    );
    await shoot('project-tags-viewer');

    // **Tag details, read-only** (`/w-10`, task 11.199's fourth screen).
    //
    // Tapping a tag this account may not edit used to show the refusal and
    // stop; since 2026-09-06 it opens the details page with that refusal as
    // its banner, and the tag's status is printed as a word where an owner
    // gets a wheel. That printed word was the SQLite spelling until task
    // 11.199. **It cannot be reached in half one** — every tag there belongs
    // to a project this device owns — which is why it is here rather than
    // beside the other three.
    currentScreen = "the joined project's tag, read-only";
    // **A fragment, not the whole title.** The tag row is one line since task
    // 11.178 — the sort field, then the rest — so the name shares a `Text`
    // with the frequency and `find.text('East Rim')` matches nothing, which is
    // how the first run of this state reported it.
    final viewerRow = find.textContaining('East Rim');
    if (viewerRow.evaluate().isEmpty) {
      recordCaptureError("the joined project's tag row is not on More → "
          'Tags, so tag-details-readonly would be a picture of a list');
    } else {
      await tester.tap(viewerRow.first);
      await settle(tester);
    }
    // **Scrolled to the status, and the reason is the same one that makes
    // `log-supersede` only half a baseline.** The word this screen is here
    // for is the tag's status, printed as plain text where an owner gets a
    // wheel — and on both phone profiles it is below the fold behind the
    // refusal banner, so a picture of the dialog as it opens covers the
    // banner and not the word.
    //
    // **What that costs, measured rather than implied.** On the phones the
    // banner's heading scrolls off and its last two lines stay; on the iPad
    // the whole dialog fits and nothing is lost. The banner is still what the
    // readiness condition identifies this dialog by — existence, not
    // visibility, precisely because the run scrolls past it. No guide page
    // uses this image; it exists so the comparison has something to notice.
    await scrollTo(
      tester,
      find.text('Status'),
      describedAs: "the tag's status, which is the word task 11.199 changed",
    );
    await shoot('tag-details-readonly');

    // Closed through the dialog's own button, so the tag list underneath is
    // left as the picture above it shows.
    final closeDetails = find.widgetWithText(TextButton, 'Close');
    if (closeDetails.evaluate().isNotEmpty) {
      await tester.tap(closeDetails.first);
    } else {
      final cancelDetails = find.widgetWithText(TextButton, 'Cancel');
      if (cancelDetails.evaluate().isNotEmpty) {
        await tester.tap(cancelDetails.first);
      }
    }
    await settle(tester);
    if (find.text('Tag details').evaluate().isNotEmpty) {
      recordCaptureError('the Tag details dialog is still open, so everything '
          'photographed after this has a modal over it');
    }

    // **Put back before anything else in this half runs.** Every shot after
    // this one is of the Owyhee project, and the screens ahead — the map,
    // the sync surfaces — read the active project rather than "whichever
    // project this device happens to hold".
    await setActiveProject(container, seedProjectId);

    // ---- The owner's side of the same project ------------------------------
    await goTo(tester, container, '/more/projects/$seedProjectId/members');
    watcher.suspend();
    // Everything an owner manages about who is on the project, in one screen:
    // the three members with their roles, and the code that lets somebody ask.
    await shoot('owner-members-and-code');

    // The pending request: the server-authenticated address as the heading,
    // the name that person typed about themselves below it and labelled as a
    // claim. Two different kinds of fact, and the guide has to show them as
    // two.
    await scrollTo(
      tester,
      find.text(pendingRequesterEmail),
      describedAs: 'the pending request',
    );
    await shoot('owner-pending-request');

    // ---- What the owner is asked when they say yes -------------------------
    //
    // **The one hole `/w-05` left in the join story.** Everything above shows
    // *that* an owner approves; without this the guide cannot show *what they
    // are asked* — the role, and the sentence saying that removing somebody
    // later cannot take back what their device already downloaded. It is a
    // modal rather than a route, so it is reached by a tap.
    currentScreen = 'the approval sheet';
    final approve = find.widgetWithText(FilledButton, 'Approve');
    // **Scrolled to before it is tapped** (`/w-08`). Task 11.99 added the
    // "Your role" card above the member list, which on the phone pushes the
    // pending section past the point a `ListView` bothers to build — so this
    // button was not merely off screen, it did not exist, and the run
    // correctly recorded that `owner-approval-sheet` was a picture of the
    // members screen. The repair is the same `scrollTo` the shot above uses,
    // which now drags a list to build what is below it. The assertion under
    // it stays: reaching for the button is not evidence that it was there.
    //
    // **`.first`, not the bare finder** (`/w-13`, item 3). `scrollTo` calls
    // Flutter's own `ensureVisible`, which requires exactly one match; the
    // five filler pending requests seeded so `owner-pending-request` needs a
    // scroll on every profile also gave this row five siblings named
    // "Approve", and the bare finder threw "Too many elements" — caught by
    // running with the fix reverted, which is what watching this fail
    // looked like.
    await scrollTo(tester, approve.first, describedAs: 'the Approve button');
    if (approve.evaluate().isEmpty) {
      recordCaptureError('there is no Approve button on the members screen, '
          'so the approval sheet was never opened and owner-approval-sheet '
          'is a picture of the members screen');
    } else {
      await tester.tap(approve.first);
      await settle(tester);
    }
    // **A picture of this sheet has to contain the disclosure**, because the
    // disclosure is the reason the sheet exists at all. That is
    // `owner-approval-sheet`'s readiness condition (`/w-11`) — waited for
    // rather than asked once. The finder is still needed here to pop the
    // sheet afterwards.
    final disclosure = find.text(removalDisclosure);
    await shoot('owner-approval-sheet');

    // **Backed out, not accepted.** Nothing is approved by this run — the
    // acknowledgement is left unticked and the sheet is popped — so the two
    // sync images below are of the same project state everything above them
    // was photographed in, with no modal standing over it.
    if (disclosure.evaluate().isNotEmpty) {
      Navigator.of(tester.element(disclosure)).pop();
      await settle(tester);
    }


    // ---- Deleting a project, from the owner's side (`/w-32`, for `/w-27`) ----
    //
    // Three pictures on the Projects screen, all against the in-memory server's
    // own deletion states — **nothing was added under `test/`**. The dialog is
    // the real one, reached through the row's ⋮ menu; *Schedule delete* is
    // really pressed, so the countdown row is drawn from the notice the app
    // itself wrote; and **the schedule is then withdrawn on the server** and
    // the notice refreshed away, so the sync-status pictures that follow are of
    // a project that is not counting down.
    //
    // **The date in the countdown row is the run's own** (the server's grace
    // period from today), because the app reads `DateTime.now()` and nothing
    // here can hold it still. The row will move a little on every
    // regeneration; the review reports that as a changed screen.
    await guarded('the deletion pictures', () async {
      currentScreen = 'the Projects list, as the owner of Owyhee';
      await goTo(tester, container, '/more/projects');
      watcher.suspend();
      await settle(tester, wait: const Duration(seconds: 2));

      /// The ⋮ on the row whose title contains [namePart]: the closest one to it.
      Finder? menuOnRowOf(String namePart) {
        final title = find.textContaining(namePart);
        if (title.evaluate().isEmpty) return null;
        final y = tester.getCenter(title.first).dy;
        Element? best;
        var bestGap = double.infinity;
        for (final element in find.byTooltip('Project actions').evaluate()) {
          final gap = (tester.getCenter(find.byWidget(element.widget)).dy - y).abs();
          if (gap < bestGap) {
            bestGap = gap;
            best = element;
          }
        }
        return best == null ? null : find.byWidget(best.widget);
      }

      final owyheeMenu = menuOnRowOf('Owyhee Uplands Kit Fox');
      if (owyheeMenu == null) {
        recordCaptureError("no ⋮ menu on the Owyhee project's row");
      } else {
        await tester.tap(owyheeMenu);
        await settle(tester);
        final deleteFromServer = find.text('Delete permanently…');
        if (deleteFromServer.evaluate().isEmpty) {
          recordCaptureError('the row menu has no "Delete permanently…" entry');
        } else {
          await tester.tap(deleteFromServer.first);
          await settle(tester, wait: const Duration(seconds: 2));
        }
      }
      await shoot('delete-project-dialog');

      final scheduleDelete = find.text('Schedule delete');
      if (scheduleDelete.evaluate().isNotEmpty) {
        await tester.tap(scheduleDelete.first);
        await settle(tester, wait: const Duration(seconds: 2));
      }
      // The confirmation snackbar floats over the bottom of the list.
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .clearSnackBars();
      await settle(tester);
      await shoot('projects-countdown');

      // Withdrawn on the server, and the notice refreshed away.
      screenshotTransport.scheduledDeletions.remove(seedProjectId);
      await container
          .read(projectDeletionNoticesProvider.notifier)
          .refreshFromServer();
      await settle(tester);

      // The section at the bottom of Projects: a project this person deleted on
      // their devices that the server still holds, with Restore.
      screenshotTransport.serverDeletedProjects.add(DeletedProjectSummary(
        projectId: 'seed-project-alkali',
        projectName: 'Alkali Flat Pilot Season, 2025',
        deletedAt: seedUtc.subtract(const Duration(days: 2)),
      ));
      container.invalidate(deletedOnServerListingProvider);
      await goTo(tester, container, '/more/projects');
      watcher.suspend();
      await settle(tester, wait: const Duration(seconds: 2));
      currentScreen = 'the deleted-from-your-devices section';
      await scrollTo(tester, find.textContaining('Alkali Flat').first,
          describedAs: 'the deleted project row');
      await shoot('projects-deleted-section');

      // The same row's ⋮ (`/w-35`): *Delete permanently…* with its note.
      currentScreen = "the Trash row's menu";
      final trashMenu = menuOnRowOf('Alkali Flat');
      if (trashMenu == null) {
        recordCaptureError('no ⋮ menu on the Trash row');
      } else {
        await tester.tap(trashMenu);
        await settle(tester);
      }
      await shoot('projects-trash-menu');
      Navigator.of(tester.element(find.byType(Scaffold).first),
              rootNavigator: true)
          .popUntil((route) => route is! PopupRoute);
      await settle(tester);
      screenshotTransport.serverDeletedProjects.clear();
      container.invalidate(deletedOnServerListingProvider);

    });

    // ---- Sync, configured rather than unconfigured -------------------------
    //
    // **The Main Map, not the Record screen** (`/w-14`). Task 11.189 removed
    // the coloured strip above every tab and replaced it with a 28-pixel icon
    // above the "+" on the map, so the Record screen now shows no sync
    // surface at all and a picture of it filed as `joined-sync-bar` would
    // have been a picture of nothing.
    currentScreen = 'the map, with the sync status icon on it';
    await goTo(tester, container, '/map');
    // **The bearing selected in half one is still selected** (`/w-14`). The
    // map keeps its selection across a tab change, so the first version of
    // this capture came out with the info card for *"Bearing · Sage · 150.284
    // MHz"* filling the bottom third — a picture of something the previous
    // section already has its own two pictures of, in the shot whose subject
    // is a 28-pixel icon at the other end of the screen.
    //
    // The same class as the record screen's tab, restored above: **state one
    // capture leaves behind is state the next one inherits**, and the map is
    // the screen with the most of it.
    final closePanel = find.byTooltip('Close');
    if (closePanel.evaluate().isNotEmpty) {
      await tester.tap(closePanel.first);
      await settle(tester);
    }
    if (find.textContaining('Bearing · ').evaluate().isNotEmpty) {
      recordCaptureError('the map still has a bearing selected, so '
          'joined-sync-indicator is a picture of the info card rather than '
          'of the sync status icon above the "+"');
    }
    // `/w-30`: the same framing as the other Map-tab pictures, viewshed off.
    // A map that kept its state from half one is recognised as already handled.
    await prepareMapShot(tester, container, 'joined-sync-indicator');
    await shoot('joined-sync-indicator');

    await goTo(tester, container, '/more/sync-status');
    await shoot('joined-sync-status');

    // ---- What the app says when sync has gone wrong (`/w-10`, `/w-12`, `/w-14`) ----
    //
    // Task 11.97 gave the app one construction of its connection to the
    // server, so a substituted server can drive eleven of the fourteen things
    // the sync surface can say. `/w-10` drove all four of the states this
    // guide needs — *offline*, *records refused*, *records the server sent
    // that this build could not read*, and *no longer on this project* — but
    // could photograph none of them: completing a round that changed the bar
    // tripped *"setState() or markNeedsBuild() called during build"* and
    // ended the run. Task 11.144 found and fixed the actual cause — a
    // provider deriving from another provider on the Position screen — so
    // this run drives and photographs all four.
    //
    // **Captured on `/more/sync-status` since `/w-14`, not on `/record`.**
    // The strip these were framed on is gone (task 11.189). Each state's
    // sentence now reaches a sighted person only on this screen, so this is
    // where the four are photographed; the icon that leads to it is shown
    // once, healthy, by `joined-sync-indicator` above.
    //
    // **The round is driven and *then* the screen is opened.** A sync round
    // is run against the container rather than through the UI, so which route
    // is showing while it runs makes no difference to the outcome — and
    // navigating afterwards is what guarantees the card is built from the
    // finished state rather than rebuilt mid-round.
    //
    // **The order is the one `SyncHealth`'s ranking requires** (see
    // `joined.dart`): each later state outranks the ones before it, so a
    // later round's picture is correct without undoing anything the round
    // before it left behind.

    currentScreen = 'the sync status screen, offline';
    breakEveryCall();
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: sync round (offline) — '
        '${await runSyncRound(container)}');
    restoreTheServer();
    await goTo(tester, container, '/more/sync-status');
    await shoot('sync-offline');

    currentScreen = 'the sync status screen, records the server sent that '
        'this build could not read';
    seedUnreadableServerRecord();
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: sync round (unreadable record) — '
        '${await runSyncRound(container)}');
    // **The round that just ran overwrote three fixed stamps with today's
    // date** — `/w-13`, item 2. Put back before every shot from here on.
    await pinLiveSyncStamps(container);
    await goTo(tester, container, '/more/sync-status');
    await shoot('sync-records-missing');

    currentScreen = 'the sync status screen, records this device holds that '
        'the server refused';
    await seedRefusedObservation(container);
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: sync round (refused record) — '
        '${await runSyncRound(container)}');
    await pinLiveSyncStamps(container);
    await goTo(tester, container, '/more/sync-status');
    await shoot('sync-records-held');

    currentScreen = 'the sync status screen, no longer on this project';
    closeOwnerMembership();
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: sync round (membership ended) — '
        '${await runSyncRound(container)}');
    await pinLiveSyncStamps(container);
    await goTo(tester, container, '/more/sync-status');
    await shoot('sync-removed');

    // ---- A project the server has destroyed (`/w-32`, for `/w-27`) ----------
    //
    // **Steens, not Owyhee.** Owyhee's membership was just closed for the
    // picture above and its sync is spent; Steens is the project this device
    // joined earlier in the run, so it is the one a member would find destroyed
    // behind them. The fake server's own `destroyProject` makes every sync route
    // refuse it by name, one real round meets the refusal, and the app writes
    // down what it learned and unlinks the project — the records on the device
    // are untouched, which the screen says.
    await guarded('the project-deleted picture', () async {
      currentScreen = 'the sync status screen, project deleted';
      await openProjectForRound(container, steensProjectId);
      screenshotTransport.destroyProject(steensProjectId,
          at: seedUtc.add(const Duration(days: 7)));
      // ignore: avoid_print
      print('SCREENSHOT HARNESS: sync round (project destroyed) — '
          '${await runSyncRound(container)}');
      await pinLiveSyncStamps(container);
      await goTo(tester, container, '/more/sync-status');
      await shoot('sync-project-deleted');
    });

    // ---- Setting up a project (`/w-35`) --------------------------------------
    //
    // **Last, because it changes what Projects would show.** *SAVE PROJECT*
    // really creates the project, so any picture of the project list taken
    // after this block would carry it. See `setupShotNames` in `shots.dart`.
    await guarded('the offline data selection', () async {
      currentScreen = 'the Offline Data Map, with a selection drawn';
      await goTo(tester, container, '/more/offline-data-map');
      await settle(tester, wait: const Duration(seconds: 2));
      final newSelection = find.text('New selection');
      if (newSelection.evaluate().isEmpty) {
        recordCaptureError('the Offline Data Map has no "New selection" button');
      } else {
        await tester.tap(newSelection.first);
        await settle(tester, wait: const Duration(seconds: 2));
      }
      await shoot('offline-data-selection');
    });

    await guarded('the new project pictures', () async {
      currentScreen = 'the New Project form';
      await goTo(tester, container, '/more/project-setup/new');
      await settle(tester, wait: const Duration(seconds: 2));
      await tester.enterText(
          find.widgetWithText(TextField, 'Name'), 'Bruneau Canyon Kit Fox, 2026');
      await settle(tester);
      final useLocation = find.text('Use current location');
      if (useLocation.evaluate().isEmpty) {
        recordCaptureError('the New Project form has no "Use current location"');
      } else {
        await scrollTo(tester, useLocation, describedAs: 'Use current location');
        await tester.tap(useLocation.first);
        // The extent arrives with the GPS fix; the time zone is then looked
        // up from the extent's center.
        await settle(tester, wait: const Duration(seconds: 3));
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await scrollTo(tester, find.text('PROJECT EXTENT'),
          describedAs: 'the extent section');
      await shoot('new-project-form');

      currentScreen = 'the Finish setting up sheet';
      final save = find.text('SAVE PROJECT');
      if (save.evaluate().isEmpty) {
        recordCaptureError('the New Project form has no SAVE PROJECT');
      } else {
        await tester.tap(save.first);
        await settle(tester, wait: const Duration(seconds: 3));
      }
      ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
          .clearSnackBars();
      await settle(tester);
      await shoot('finish-setting-up');
      // *Later*: nothing is published and nothing is downloaded.
      final later = find.text('Later');
      if (later.evaluate().isNotEmpty) {
        await tester.tap(later.first);
        await settle(tester);
      }
    });

  });

  // **The first-launch identity screen is not captured, and this is where it
  // would go.** A second boot inside the same run hangs: the app's database
  // is a real file on the device and the second `AppDatabase.open` never
  // returns after the first one's file has been deleted underneath it. It is
  // left out rather than left flaky — an image that is sometimes produced is
  // worse than one that never is, because nobody can tell which run they are
  // looking at. Written up in `CLAUDE_DOCS/WEBSITE_COMMS.md`.

  tearDownAll(reportErrors);
}
