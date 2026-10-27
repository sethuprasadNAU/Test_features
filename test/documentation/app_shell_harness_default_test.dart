import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **The app-shell harness is the default for new screen tests (task 11.111,
/// carried by task 11.118).**
///
/// ## The finding
///
/// A widget test that pumps a screen bare — `MaterialApp(home: SomeScreen())`
/// — hands it roughly a `NavigationBar`'s worth of height, plus the shell's
/// two banner slots, that it never has in the running app. Several pump at
/// 1200×1600 or 1200×3000, where the error is far larger than that.
///
/// Task 11.109 found the Position screen's bearings list crowded down to
/// **one row, and to none whenever a caution was showing**, on a real phone,
/// while every test on that screen passed. Task 11.110 found the Main Map's
/// navigation banner painting over its north arrow, and a tag-wheel label
/// overflowing at phone width — `lib/widgets/wheel_picker.dart` still carries
/// the comment saying nothing noticed *"because every test that renders this
/// screen pumps it 1200 logical pixels wide."*
///
/// > **The instrument was honest and the input was not.** Every assertion in
/// > those tests was true of the screen it was given, and the screen it was
/// > given was one no device shows.
///
/// ## What this asserts
///
/// **The set of test files that pump an in-shell screen without the harness
/// is exactly [_bareToday].** Not a count — the files by name, each with the
/// number of `testWidgets` cases in it.
///
/// The in-shell screen set is **derived from `lib/routing/app_router.dart`**,
/// not written down here: every screen constructed inside the
/// `StatefulShellRoute(...)` block renders inside [TabShell] in
/// the real app, and everything before that block (`/splash`,
/// `/identity-setup`, `/record-preview`) genuinely does not. So a twentieth
/// screen added to the More branch is covered the day it lands, and a screen
/// promoted out of the shell stops being covered the same day.
///
/// **The parser takes the shell block as "the marker to the end of the
/// file", not "up to the next route."** Task 11.84 lost the last route in a
/// file to a delimiter of that shape, and the last element is the one nobody
/// pictures — here it would have been `SyncStatusScreen`.
///
/// ## Why this is a rule and a count rather than a mass edit
///
/// Task 11.111's brief says it outright: **do not convert all of them.** Most
/// of these tests are not testing layout. They pump a screen to tap a button
/// and check a provider changed, and extra height is harmless to that. The
/// ones that matter are the ones whose assertions rest on something being
/// visible or findable, because those can pass while the real app hides the
/// thing.
///
/// So this file does not require conversion. It requires **a decision**: a
/// new test file that pumps an in-shell screen bare is red until somebody
/// either uses `pumpInAppShell` or adds a line here saying it does not need
/// to. That is the half that stops the count growing back while nobody is
/// looking — which is what happened between task 11.110 counting them and
/// task 11.118 counting them again.
///
/// ## Does the per-file count earn its friction? Measured, task 11.180
///
/// **The guarantee — "a new test file that pumps a screen bare is red" — is
/// carried by the file set, not by the counts.** The counts add friction every
/// time anybody adds a test to a file that already has its exemption, where no
/// new decision is being made. That friction is real and frequent: in the four
/// days after this file was written, **every one of the five edits to
/// [_bareToday] was a count bump and none was a set change**, and the one time
/// a task did not make the edit, `flutter test` was red on `main` at commit
/// `1d4bfd5` for a screen with nothing wrong with it.
///
/// **It still earns it, and the one recorded case is the reason.** Between
/// task 11.110 counting these tests and task 11.118 counting them again, the
/// population went from **205 cases to 219 across the same 28 files** — the
/// growth was *inside* files that were already listed, which is precisely what
/// the set cannot see. (The ledger did not exist yet, so no per-file diff
/// survives; what is certain is that the file set was identical both times, so
/// whatever those 14 cases were, the set could not have reported them.)
///
/// **What was wrong at `1d4bfd5` was the moment, not the instrument.** Task
/// 11.178 ran the two test files it had written and said so in its report; the
/// guard is in this file, which only a full run reaches. Task 11.180's answer
/// is `scripts/pre_commit_suite.sh`, wired as a commit-time hook, so the
/// notification arrives while somebody is still holding the change.
///
/// **Removing a file from [_bareToday] by converting it is expected and
/// good**, and the test says so when it fails that way: the two failure
/// directions have different messages on purpose.
void main() {
  test('the in-shell screen set is derived from the router, not written here',
      () {
    expect(
      _inShellScreens(),
      contains('SyncStatusScreen'),
      reason:
          'the last screen in the shell block — the one a "delimit up to the '
          'next route" parser drops (task 11.84). If this is missing, the '
          'derivation below is silently measuring a short list.',
    );
    expect(
      _inShellScreens(),
      isNot(contains('SplashScreen')),
      reason:
          'Splash is a top-level route and really does run outside the tab '
          'shell; a derivation that swept it in would be over-reporting',
    );
  });

  test('every test that pumps an in-shell screen bare is named and counted',
      () {
    final inShell = _inShellScreens();
    final found = <String, int>{};
    for (final file in dartFilesUnder('test')) {
      final source = file.readAsStringSync();
      if (!source.contains('testWidgets')) continue;
      if (source.contains('pumpInAppShell')) continue;
      final body = stripComments(source);
      final pumpsAScreen = inShell.any(
        (s) => RegExp('\\b$s\\s*\\(').hasMatch(body),
      );
      if (!pumpsAScreen) continue;
      found[_relative(file.path)] =
          RegExp(r'testWidgets\s*\(').allMatches(body).length;
    }

    final expected = {for (final b in _bareToday) b.file: b.cases};

    final appeared = found.keys.toSet().difference(expected.keys.toSet());
    expect(
      appeared,
      isEmpty,
      reason:
          'A new test pumps a screen bare that the real app renders inside '
          'the tab shell, so it is being given height the screen never has. '
          'Either pump it with pumpInAppShell (test/support/'
          'app_shell_harness.dart) — do that if any assertion in it rests on '
          'something being visible, findable or tappable — or add it to '
          '_bareToday in this file with a reason. This is the check that '
          'exists so the count does not grow back.',
    );

    final converted = expected.keys.toSet().difference(found.keys.toSet());
    expect(
      converted,
      isEmpty,
      reason:
          'Good news, and it still has to be recorded: these files no longer '
          'pump bare. Delete their _bareToday entries — the list is a '
          'statement of what is not covered, and an entry that has been '
          'fixed makes it overstate the gap.',
    );

    for (final entry in found.entries) {
      expect(
        entry.value,
        expected[entry.key],
        reason:
            'The number of testWidgets cases in ${entry.key} changed while it '
            'is still pumping bare. Update its _bareToday count — the number '
            'is how this file reports the size of the gap, and a stale one '
            'reports the wrong size.',
      );
    }
  });
}

/// Screen classes constructed inside `app_router.dart`'s
/// `StatefulShellRoute(...)` — the ones [TabShell] wraps.
///
/// **The marker matches either constructor.** It used to be the literal
/// `StatefulShellRoute.indexedStack(`, and task 11.160 moved the app onto the
/// plain `StatefulShellRoute` constructor so it could supply its own branch
/// container — which turned this derivation red, correctly, because the guard
/// below refuses to read nothing. Matching the class name and letting the
/// named constructor be optional is what stops the *next* such change from
/// being a failure in a file that has nothing to do with it.
Set<String> _inShellScreens() {
  final source = stripComments(
    File('lib/routing/app_router.dart').readAsStringSync(),
  );
  final marker = RegExp(
    r'\bStatefulShellRoute(\.\w+)?\s*\(',
  ).firstMatch(source);
  expect(
    marker,
    isNotNull,
    reason:
        'app_router.dart no longer builds the tab shell with a '
        'StatefulShellRoute at all, so this derivation is reading nothing. '
        'Re-derive it against whatever replaced it rather than letting this '
        'test pass on an empty set.',
  );
  return RegExp(r'\b([A-Z]\w*Screen)\s*\(')
      .allMatches(source.substring(marker!.start))
      .map((m) => m.group(1)!)
      .toSet();
}

String _relative(String path) {
  final at = path.indexOf('/test/');
  return at == -1 ? path : path.substring(at + 1);
}

class _Bare {
  const _Bare(this.file, {required this.cases, required this.screen});

  final String file;
  final int cases;

  /// The in-shell screen it pumps — recorded so a reader can see at a glance
  /// which screens are least covered at real geometry.
  final String screen;
}

/// **28 files, 221 `testWidgets` cases** — 219 measured 2026-09-02 (task
/// 11.118), plus the two task 11.151 added to the project-setup file.
///
/// Against 3 files and 19 cases that do use the harness — so **8% of the
/// cases that pump a shell screen see it at a phone's geometry.**
///
/// Ranked by what task 11.118 judged most likely to be hiding something: the
/// screens with the most vertical furniture, whose tests assert that
/// something is visible. `map_screen_test.dart` and
/// `position_estimation_screen_test.dart` are the two screens whose real
/// defects (11.109, 11.110) were found by a person; both still have a bare
/// file alongside their harnessed space-budget sibling.
///
/// **This list is not a to-do.** Most of these cases tap a control and check
/// a provider changed, and height is irrelevant to them. It is a statement of
/// where the suite is measuring a screen larger than the app gives it, so
/// that the next person deciding whether a defect could hide has a list
/// instead of a search.
const _bareToday = <_Bare>[
  // -> 15 by task 11.207: one case asserting that the elevation profile is
  // drawn in the same colour as the line on the map it is a profile of. It
  // reads two colours out of the widget tree and is indifferent to height.
  // -> 16 by task 11.241: one case on the Layers & Filters sheet — an
  // animal's checkbox toggles every collar she has worn, read back from the
  // legend's rows. It pumps at the file's 1200x3200 so the sheet's whole
  // TAGS section is built; the legend is what it reads, not where the fold is.
  // -> 17 by task 11.248: one case that a bearing keeps the colour of the
  // animal it was actually about after its collar moves to another — reads
  // the legend and a `PolylineLayer`'s colour, neither a layout concern the
  // shell harness's extra height would mask.
  // -> 19 by task 11.251: two cases on a handover day — one with dates only
  // (a bearing on the day a collar came off keeps its animal; a bearing two
  // deployments cover is drawn neutral, named "Contested" in the legend and
  // hidden only when every candidate is) and one with a swap time. Both read
  // `PolylineLayer` colours by the ray's own latitude and the legend's rows;
  // height is not what they measure.
  // -> 21 by task 11.259: a carried-over estimate (season clone) says
  // "computed in an earlier season" instead of a false "0 bearings used",
  // and a partial carry counts only the bearing this device still holds.
  // -> 27 by task 11.319: six cases pumping the map with an estimate and a
  // truth point 13 or 8 points apart (two labels, four taps). They tap markers
  // and read which card opened, so height is irrelevant to them; counted, not
  // exempted.
  // -> 28 by task 11.318 item 5: one case that mounts the map and asserts only
  // that nothing from an earlier test's viewshed fails it. It measures no
  // layout, so height is irrelevant to it; counted, not exempted.
  // -> 32 by task 11.336: four cases that select an estimate and read whether
  // its card carries the few-bearings line (five and three bearings: yes; six,
  // and an estimate with no ellipse: no). Same shape as 11.259's cases above:
  // they tap the estimate marker and read the card's words, which the shell
  // harness's extra height would not change; counted, not exempted.
  // -> 33 by task 11.338: one looped case (one source line, seven text sizes)
  // that measures whether the same few-bearings line is clipped on the card at
  // the 6.1-inch phone's width. Width is what decides wrapping and it is the
  // phone's (393) here; what a bare pump lacks is the tab bar's height, which
  // a clipped line does not depend on. Counted, not exempted.
  _Bare('test/features/map/map_screen_test.dart',
      cases: 33, screen: 'MapScreen'),
  _Bare('test/features/map/map_with_no_position_test.dart',
      cases: 4, screen: 'MapScreen'),
  // 4 -> 7: task 10.87 added three cases pumping the consent dialog's body
  // at 1,000 rows, the L-5 padding case, and the not-on-this-device framing.
  // They pump `ConsentSummaryContent` in a bare `Scaffold`, like the receipt
  // cases beside them.
  _Bare('test/features/more/data_export_screen_test.dart',
      cases: 7, screen: 'DataExportScreen'),
  _Bare('test/features/more/join_request_name_rendering_test.dart',
      cases: 6, screen: 'ProjectMembersScreen'),
  _Bare('test/features/more/leave_project_control_test.dart',
      cases: 6, screen: 'ProjectsScreen'),
  _Bare('test/features/more/location_refused_test.dart',
      cases: 3, screen: 'ProjectSetupScreen'),
  // Task 11.313: the More menu's own door to Members. One case reads the
  // no-project sentence back, the other that the hand-off to
  // ProjectMembersScreen actually happened (its own furniture on screen);
  // neither is a layout concern, so it pumps bare like its sibling above.
  _Bare('test/features/more/members_screen_test.dart',
      cases: 2, screen: 'MembersScreen'),
  // 22 -> 24: task 11.194 added two cases for the Log row's new
  // irregular/malfunctioning mark.
  // 24 -> 25: task 11.211 added a case proving the supersede picker's
  // distinguishing field survives on the 6.1-inch profile.
  // 25 -> 29: task 11.252 added the "no signal" record's delete control and
  // four cases covering it (offered, viewer refused, non-author refused,
  // confirmation wording).
  _Bare('test/features/more/log_screen_test.dart',
      cases: 29, screen: 'LogScreen'),
  // Task 11.241: the Log's filter picker offers animals above collars, and an
  // animal filter admits every collar she has worn. Pumps bare like the file
  // above, for the same reason: it asserts which rows a filter keeps, not
  // where the fold falls.
  // 1 -> 3 by task 11.251: a handover day with dates only (a bearing on the
  // day a collar came off stays under its animal; a contested one is listed
  // under both) and with a swap time (resolved). Same shape, same reason.
  _Bare('test/features/more/log_screen_animal_filter_test.dart',
      cases: 3, screen: 'LogScreen'),
  // manage_offline_maps_screen_test.dart left this list on 2026-09-12: task
  // 11.230 moved its one case into the shell alongside the four it added.
  // 4 -> 7: task 11.189 moved the cloud-backup retirement notice here from
  // the app shell's banner strip, and these three cases are about where it
  // now lives, who sees it, and that dismissing it is permanent. -> 10 by
  // Michael's two notes of 2026-09-07: that the dot on the More tab needs a
  // matching dot on the Sync Status row to point at, and then that the dot
  // was on the leading icon and too small to see. **That is three call sites
  // and six cases** — one of them is a loop over four sync states asserting
  // the two dots agree — and this ledger counts `testWidgets(` call sites
  // rather than the cases they generate, which is the number the check reads
  // and the only one it can read from source.
  _Bare('test/features/more/more_screen_test.dart',
      cases: 10, screen: 'MoreScreen'),
  // -> 8 by task 11.193: one case proving the paste screen says what the
  // sender heard about the signal, and says nothing at all when the payload
  // does not carry an answer — a line that renders conditionally, which is the
  // shape that can quietly stop rendering with nobody watching.
  // -> 9 by task 11.199: one case proving the preview card shows words rather
  // than stored database tokens, and that the *legacy* mode field appears only
  // when the payload carries no mode name. Another conditional line; it uses
  // the same tall surface as the two above it.
  // -> 10 by task 11.218: one case proving a tag that matches by frequency,
  // name and pulse rate but is linked only to a *different* project is not
  // matched — the fix for the paste screen matching against the whole
  // device's tag list instead of the active project's.
  _Bare('test/features/more/observation_sharing_screen_test.dart',
      cases: 10, screen: 'ObservationSharingScreen'),
  _Bare('test/features/more/offline_data_map_screen_test.dart',
      cases: 6, screen: 'OfflineDataMapScreen'),
  // 2 -> 5: task 11.324's two new rows (this project's offline maps, and
  // published to the server) — they read each row's words and icon; none taps
  // anything or measures the fold.
  _Bare('test/features/more/pretrip_checklist_screen_test.dart',
      cases: 5, screen: 'PreTripChecklistScreen'),
  _Bare('test/features/more/profile_screen_test.dart',
      cases: 10, screen: 'ProfileScreen'),
  _Bare('test/features/more/project_members_screen_test.dart',
      cases: 19, screen: 'ProjectMembersScreen'),
  _Bare('test/features/more/project_row_actions_test.dart',
      // 7 -> 8: task 11.184 added a case for a non-owner's disabled-not-hidden
      // "Publish to server" entry. 8 -> 14: task 11.238 added six cases for
      // the adopted-but-unlinked project's "not syncing yet" line. Pumps
      // bare like the rest of the file.
      cases: 14, screen: 'ProjectsScreen'),
  // 20 → 22 in task 11.244: the custom-hex pair moved here from
  // `tag_database_screen_test.dart`, because a library entry no longer
  // has a colour anybody reads and a project's tag does.
  //
  // 22 → 8 in task 11.245: every case about the tag section itself — gating,
  // editing, unlinking, colour, the off-screen-link test — moved to
  // `tags_screen_test.dart` with the tag section, which is `More → Tags`
  // now and no longer part of this screen at all. What is left is the
  // settings-form coverage this file was always also carrying: the save
  // button, the ownership gate, and the roles-enforcement footnote.
  _Bare('test/features/more/project_setup_screen_test.dart',
      cases: 8, screen: 'ProjectSetupScreen'),
  // Task 11.331: the project form's time-zone section and its change
  // confirmation. Bare at 1200x2600 for the sibling file's reason — what
  // these assert is wording and what the database holds after Cancel, not
  // that anything fits a phone's height.
  _Bare('test/features/more/field_zone_screen_test.dart',
      cases: 3, screen: 'ProjectSetupScreen'),
  // Task 11.245: this project's tags, moved off Project Setup — gating,
  // editing, unlinking, colour, and the tag arriving off-screen without a
  // restart, carried over from `project_setup_screen_test.dart` unchanged in
  // substance. Pumps bare at the sibling file's 1200x2600 for the same
  // reason that file did: what these assert is order, wording and what the
  // database holds afterwards, not that anything fits a phone's height.
  // Task 11.233 is the sweep that would move this family into the shell.
  //
  // `project_animals_section_test.dart` — the grouping-by-animal coverage
  // that used to sit beside this file — is deleted rather than moved: the
  // grouping itself is gone (design §3a), and what replaced it (linking,
  // merging, viewing an animal) is proven on `animals_screen_test.dart`,
  // which covers both `AnimalsScreen` and `AnimalDetailScreen`.
  _Bare('test/features/more/tags_screen_test.dart',
      cases: 14, screen: 'TagsScreen'),
  // Task 11.244: More → Animals and the animal's own screen — the list, Add
  // animal, the tag rows, §5a's confirmation, unlink and delete. Task
  // 11.248 added the `+` FAB, the current-tag derivation and the attached
  // date edit.
  //
  // **Pumps bare, and the decision is a real one rather than the default.**
  // What these assert is which sentence a confirmation carries and what the
  // database holds afterwards — nothing rests on a control being visible
  // without scrolling, which is the failure the harness exists to catch. The
  // one thing on these screens that *is* a layout claim is the tag row's
  // date line, and it is a single `Text` in a `Card` rather than anything
  // competing for a fold.
  //
  // **The Record screen's fold is measured in
  // `record_screen_space_budget_test.dart`, in the shell, at phone width** —
  // that is where this task's layout claim lives, because that is the screen
  // Michael said must not move. Task 11.233 is the sweep that would move
  // this family into the shell together.
  // 14 -> 18 by task 11.251: the swap time on the §5a confirmation (shown,
  // prefilled, written to both ends), the tag's-swap case (a collar taken
  // off another animal today is offered and gets the time), and the removal
  // day's time picker accepted and dismissed. All read dialog text and rows
  // back from the database; none measures where the fold is.
  // 18 -> 22 after Michael's first device look, same task: Current after a
  // swap, the newest row on top, and the row's buttons measured *at phone
  // width* — that one sets `phoneSize` itself, which is the geometry this
  // list exists to move tests onto, so it is the exception that argues for
  // the sweep rather than against it.
  // 22 -> 23 by task 11.255: a contributor is refused "Delete animal" and the
  // control's disabled state and its reason sentence are read back — no
  // layout claim, same shape as every other case in this file.
  // 23 -> 29 by task 11.261: a removed date now has an editor and a clear
  // control, and the day-or-time choice replaced the old "Cancel for the
  // day only" time picker — six new cases, no layout claim in any of them.
  // 29 -> 33 by task 11.263: "Day only" is withheld where a bare day would
  // overlap (three cases: the dialog's shape and Cancel, Set a time then
  // OK, Set a time then the picker's Cancel), and a collar taken off
  // another animal today as a bare day is not offered (one case). All read
  // buttons and rows back; none measures the fold.
  // 34 -> 39 by task 11.265: a past day that already overlaps now offers a
  // time instead of a flat refusal (five new cases, across both the
  // removal and attached-date editors) — the old single "refused" case
  // split into "offers a time, still refused on a deep overlap" and "no
  // overlap, still a bare day" (net +1), plus four cases for the new
  // group proving a past-day swap can be recorded end to end. All read
  // buttons, dialogs and rows back; none measures the fold.
  // 39 -> 43: task 11.268 added four cases proving the unsaved-edit guard
  // (item 1, two cases) and that colour writes on tap without needing Save
  // and without saving an unrelated unsaved name draft (item 2, one case),
  // plus one case for the removed-date picker's new help text (item 5).
  // None measures the fold; all read buttons, dialogs and rows back.
  // 43 -> 45: task 11.271's clock-matrix group added two `testWidgets(`
  // source occurrences — one generated inside a `for` loop over three
  // fixed clocks (three cases at runtime, one source occurrence, since
  // this count is a static scan of the file's text) and one standalone.
  // Both pin `clock.now()` and pump this screen the same way the rest of
  // this file does; none measures the fold.
  // 45 -> 48: task 11.270 closed the deadlock two never-timed rows can hit
  // when a past-day handover is corrected on both ends — three new cases
  // proving the joint confirmation writes both rows, its symmetric case,
  // and that cancelling it writes neither. All read buttons, dialogs and
  // rows back; none measures the fold.
  // 48 -> 52: task 11.321's one-step link — the picker's order, a Tag
  // Library tag copied in and linked, cancelling copies nothing, and New
  // tag…. All read a dialog's text or the rows written; none measures the
  // fold.
  // 52 -> 58: task 11.322's link date — today by default, a refused
  // back-dated overlap, a back-dated link on a bare animal, a back-dated swap
  // with its time and bearings warning, cancelling that warning, and the date
  // floor. All read dialog text or the rows written; none measures the fold.
  // 58 -> 59: task 11.324's New tag… with a Tag ID the project already has —
  // reads the dialog's buttons and the rows written; none measures the fold.
  _Bare('test/features/more/animals_screen_test.dart',
      cases: 59, screen: 'AnimalsScreen'),
  _Bare('test/features/more/projects_screen_test.dart',
      cases: 9, screen: 'ProjectsScreen'),
  // Task 11.290: destroying a project on a visible schedule, from the
  // Projects list — the sentence under the name, the menu, the tint, and
  // the two dialogs' words. Every assertion reads text, a menu item's state
  // or a tile's color back; none measures whether anything fits a phone's
  // height, so it pumps bare like the sibling files.
  // Task 11.307 added the ninth: a 404 from the deletion route, read back
  // as a snackbar's words.
  _Bare('test/features/more/project_deletion_from_list_test.dart',
      cases: 9, screen: 'ProjectsScreen'),
  // Task 11.290: an owner deleting, from the join screen, a project this
  // device has never held. Reads the row's menu and sentence back; pumps
  // bare for the same reason.
  _Bare('test/features/more/join_screen_delete_from_server_test.dart',
      cases: 2, screen: 'JoinProjectScreen'),
  // Task 11.292, moved to the bottom of the Projects screen by task 11.313
  // (renamed with it): the "deleted from your devices" section. Reads rows,
  // menus and the section's presence or absence; layout is not the subject,
  // so it pumps bare for the same reason as the file above.
  _Bare('test/features/more/projects_screen_deleted_on_server_test.dart',
      cases: 5, screen: 'ProjectsScreen'),
  // Task 11.339: the Trash holding this phone's own projects — a project
  // moved there and restored, the permanent delete's dialog words and its
  // effect on the database, and a not-yet-sent deletion sitting under the
  // Trash heading. Reads text, rows written and one heading-above-row order;
  // nothing measures whether the section fits a phone's height, so it pumps
  // bare like the sibling Trash file above.
  _Bare('test/features/more/projects_screen_trash_test.dart',
      cases: 3, screen: 'ProjectsScreen'),
  _Bare('test/features/more/publish_ownership_warning_test.dart',
      cases: 4, screen: 'ProjectsScreen'),
  // 6 -> 5: task 11.189 turned the one case in this file that pumped the sync
  // bar into a plain `test` — the bar is gone, and what it asserted (the
  // sentence and the severity for a refused address) is now a property of
  // `SyncStatusPresentation`, which needs no widget at all. The rest of the
  // file still pumps bare.
  _Bare('test/features/more/server_address_refused_test.dart',
      cases: 5, screen: 'ServerConfigScreen'),
  _Bare('test/features/more/server_config_messages_test.dart',
      cases: 4, screen: 'ServerConfigScreen'),
  _Bare('test/features/more/server_config_screen_macos_test.dart',
      cases: 3, screen: 'ServerConfigScreen'),
  _Bare('test/features/more/server_config_screen_test.dart',
      cases: 20, screen: 'ServerConfigScreen'),
  // 14 -> 19: task 11.189 moved the "Dismiss until tomorrow morning" control
  // here from the app shell's sync bar, which that task deleted, and its five
  // cases came with it. Pumps bare like the rest of the file.
  // 19 -> 22: task 10.87 added three cases at import scale — 1,000 overwrites
  // as one card, 1,000 waiting records bounded to twenty with the total
  // stated, and the no-bound case. Pump bare like the rest of the file.
  // 22 -> 27 by task 11.303: five cases on the "Update needed" headline —
  // rate-limited, offline too long, a deleted project, a genuine version
  // skew, and the remembered-across-a-restart fallback. -> 30 by task 11.306:
  // three cases on the accessRefused sentence — no causal guess, both
  // remedies in order, and the reassurance kept. -> 33 by task 11.313: three
  // cases on the no-project sentence — the guarantee with nothing pending,
  // one pending deletion named, and several counted. Reads text back, not
  // layout; pumps bare like the rest of the file. -> 35 by task 11.58: the
  // replaced-server-database sentence, present with its date and absent
  // without one. Text read back by key, not layout. -> 37 by task 11.319: a
  // deleted project is not drawn in the error color and a version skew still
  // is. Color read back, not layout.
  _Bare('test/features/more/sync_status_screen_test.dart',
      cases: 37, screen: 'SyncStatusScreen'),
  // 15 -> 18 by task 11.178's sort-order group, which did **not** update this
  // line, so `flutter test` was red on `main` at commit 1d4bfd5 for a screen
  // that had nothing wrong with it. -> 23 by Michael's two notes of
  // 2026-09-06 on what a row says and in what order. -> 24 by his third the
  // same day, which took the row down to one line: two tests about the old
  // second line were replaced by four about the new one.
  // -> 27 by task 11.187, which put the tag's pulse modes on this form: what
  // the modes editor offers, that adding one asks about earlier records, and
  // that the rate field follows the seconds-per-pulse preference while the
  // stored number does not.
  // -> 28 by task 11.191, which put a second unit control on the app bar and
  // added one test proving the two stay in step with no restart.
  // -> 30 by task 11.198, which added two `testWidgets` call sites (each run
  // twice, once per theme, in a `for` loop — 4 registrations from 2 sites)
  // measuring the status badge's, the padlock's and the greyed-out line's
  // contrast against the Scaffold background.
  // 40 → 36 in task 11.244: two library-colour tests became one
  // (a library entry has no colour anybody reads), the row-swatch test
  // became an assertion that there is no swatch, and the custom-hex pair
  // moved to `project_setup_screen_test.dart` where the editor lives.
  _Bare('test/features/more/tag_database_screen_test.dart',
      // 30 -> 27 by task 11.219. The screen shows this device's own tag
      // *library* now, which no role governs, so the three role-aware cases
      // it carried moved to where the role question moved: two to
      // `project_setup_screen_test.dart` (the correction-or-change question,
      // which is about a project's tag) and one to
      // `refusal_messages_rendered_test.dart` (the read-only banner). The
      // gap this number reports shrank because the screen did, not because
      // anything stopped being covered.
      //
      // 27 -> 30, same task, later in it: two cases proving the library
      // screen says how many of this device's projects hold a copy of a
      // collar and never which ones (§2.5), and one proving the CSV import
      // preview says in words that importing mints new collars rather than
      // matching the ones already held (§2.8). The third pumps the import
      // preview, which is a pushed route rather than a tab, so the shell is
      // not the surface it belongs on — it is counted here because this
      // guard counts per file.
      //
      // 30 -> 39 by task 11.229: nine new cases, none about layout at a
      // surface no device has — they construct `TagEditDialog` directly (add,
      // edit, read-only) to check the name field's new position, the five
      // enlarged labels, the grey token, and no overflow at phone width and
      // through xxLarge. `TagDatabaseScreen` itself still only pumps bare via
      // the cases already counted above.
      //
      // 39 -> 40 by task 11.232: the text-scale ladder now runs all nine
      // upward sizes on all three dialog paths (27 cases in a loop, where
      // 11.229 had 7), plus two cases holding the `_DryLayoutFromIntrinsics`
      // shim to the Flutter defect it works around. All at phone geometry.
      //
      // 36 -> 38 by task 11.250: two cases covering the push that applies a
      // library edit to every project holding a copy of the same collar —
      // declining the offer leaves the project's copy untouched, and
      // applying it updates every copy and asks task 11.32's question once.
      //
      // 38 -> 48 by task 11.288: ten cases for the library's first delete —
      // one entry via a swipe, confirm/cancel/undo through the selection app
      // bar's delete button, entering and leaving multi-select, selecting
      // several and all, and the confirmation naming how many selected
      // entries a project still holds. None is about layout; the screen is
      // still only ever pumped bare for them.
      cases: 48, screen: 'TagDatabaseScreen'),
  _Bare('test/features/observations/ground_truth_entry_test.dart',
      cases: 6, screen: 'ObservationLoggingScreen'),
  // -> 8 by task 11.193, which added three tests proving the new
  // irregular-signal flag reaches the saved row: ticked, unticked, and a note,
  // where the question is never asked and the column stays NULL. All three are
  // about what is written rather than about layout, so a bare pump is the
  // right surface for them — the layout half of that task is measured in
  // `record_screen_space_budget_test.dart`, which pumps the real shell.
  // -> 11 by task 11.197, which turned the irregular-signal control from a
  // chip into a checkbox and added three tests for it: that it is off and
  // grey to start with, that it goes red when ticked with the word still
  // beside it, and that the whole row is a 44-point tap target. The first two
  // are about what is drawn in a given state rather than about where it
  // lands, so a bare pump is the right surface; the third is a minimum
  // height, which is a constraint the widget imposes rather than something
  // the surface decides. Where this control sits on the screen is measured in
  // `record_screen_space_budget_test.dart`, which pumps the real shell.
  // -> 13 by task 11.315, which added *Take on map* beside RANGE and two
  // tests for it: shown where there is a compass, hidden where there is not.
  // The first also asserts the button sits in RANGE's row, after it — a
  // position along the row, which the shell's height cannot change. That the
  // row itself stays above the fold is still the space-budget test's, which
  // pumps the real shell and measures the bearing block the button is in.
  // -> 14, task 11.317 item 3: a widget test that RANGE's hold survives a
  // sliding thumb (the same raw-pointer hold *Take on map* uses).
  _Bare('test/features/observations/observation_logging_screen_test.dart',
      cases: 14, screen: 'ObservationLoggingScreen'),
  _Bare(
      'test/features/position_estimation/screens/'
      'position_estimation_screen_test.dart',
      // -> 14 by the 2026-09-07 follow-up to task 11.193: five cases about
      // the bearing row a person decides on — the words it shows, the three
      // colours, the mark on a bearing flagged as sounding irregular, that the
      // mark costs the list no height, and that an excluded row gives its
      // colour up. All five are about what one row renders, which a bare pump
      // measures as well as the shell does; this screen's *space* budget is
      // `position_screen_space_budget_test.dart` and pumps the real shell.
      // -> 16 by task 11.259: the past-estimates sheet says "computed in an
      // earlier season" for a carried-over (season clone) estimate instead of
      // a false "0 observations", and a partial carry counts only the
      // bearing this device still holds. Both are about what the sheet's
      // list tile renders, which a bare pump measures as well as the shell.
      // -> 17 by task 11.268, item 7: one new case proving the default
      // selection's fixed 6-hour window never trips the "animal may have
      // moved" caution on its own — a property of the panel's own content,
      // which a bare pump measures as well as the shell.
      // -> 22 by task 11.274: one case opening the map-type card, which is
      // about a layout exception (`SegmentedToggle`'s `Row` with no width
      // constraint from its corner column) that a bare pump reproduces as
      // well as the shell does; one case on two observers whose badge
      // initials collide, about what the bearing row's title renders, not
      // where it sits; and three cases on the tag picker naming the
      // collar's current animal, all about what the bar's text says.
      cases: 22,
      screen: 'PositionEstimationScreen'),
  _Bare('test/routing/tab_shell_layout_test.dart',
      cases: 4, screen: 'MoreScreen'),
];
