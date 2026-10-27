import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Task 11.181 — every screen and dialog that changes what it shows or
/// offers because of a permission, and what a person without that permission
/// sees there.**
///
/// **Why this file exists.** `PERMISSIONS_MATRIX.md` §4.2 and
/// `TriTrack_Security_Model.md` §4.21.2 are derived from **routes** — the
/// server's `router.<method>('<path>', …)` declarations. That derivation is
/// worth what task 11.123 proved it was worth, and it is answering a different
/// question from this one. **A route decides what the server returns. A screen
/// decides what it renders.** Nothing in this repository read the second
/// question until this file, so on 2026-09-06 a screen changed what a
/// non-owner may read and **no instrument here could have noticed** — not the
/// route matrices, not `refusal_messages_rendered_test.dart` (which checks
/// that a refusal is worded well, not that a refusal is the right answer), not
/// `disabled_reason_geometry_test.dart` (which checks that a disabled control
/// says why, not what is behind it).
///
/// **This is a declaration, not a derivation, and the difference is the whole
/// honest limit of it.** It can tell you a *file* has joined or left the class.
/// It cannot tell you a declared verdict has gone stale — a screen already on
/// this list can change what it shows a viewer and stay green. Both instances
/// of that this project has seen are named below (`project_members_screen.dart`
/// and `tag_database_screen.dart`), and **this file would have caught
/// neither.** It is said here rather than discovered later: what would catch
/// them is a per-role record of what each screen renders, which is real work
/// and needs its own task. **Task 11.183 did it:
/// `test/documentation/screen_role_view_test.dart` holds that record — what an
/// owner sees and what a non-owner sees on each of these screens — and it
/// fails when a screen already on this list changes what it renders. The
/// sentence above stands as the reason it exists; the gap it names is closed.**
///
/// What it is worth anyway: **a screen that newly starts branching on a
/// permission cannot do so silently**, and the reason has to be written down
/// beside its neighbours before the suite goes green again. Measured when
/// written: 13 files, of which 9 are screens out of the 24 under
/// `lib/features/**/screens/`. **Task 11.245 moved this from 13/9/24 to
/// 18/12/28** — the tag section left `project_setup_screen.dart` for its
/// own screen, and both sides of that move are declared below.
void main() {
  /// The tokens that mean "this file's behaviour depends on a permission".
  /// Three shapes: the `may*`/role providers a widget watches, the refusal a
  /// write throws, and the two helpers that render a reason for a control the
  /// person may not use.
  const signals = <String>[
    'mayCreateTagProvider',
    'mayEditTagProvider',
    'mayWriteProjectDataProvider',
    'isProjectOwnerProvider',
    'myProjectRoleProvider',
    'ownedProjectIdsProvider',
    'UnauthorizedMutation',
    'assertMay',
    'ProjectRole',
    'reasonedMenuItem',
    'runGuardedWrite',
  ];

  /// Keyed by path under `lib/`. Each verdict answers one question: **what
  /// does a person who lacks the permission see here?** Not "is the write
  /// refused" — the server answers that (§4.23), and it is not what this file
  /// is about.
  const declared = <String, String>{
    // ---- Renders differently: what is on the screen depends on the role ----
    'features/more/screens/project_members_screen.dart':
        'READ BRANCH, deliberate. Every member may open this screen (task '
        '11.99 — it used to be behind `if (isOwner)` on the projects list, so '
        'the one person who most needed to know their own role could not find '
        'it). A non-owner sees the whole member list, every role and every '
        'past stint, plus a line saying an owner is needed to change one. '
        'What an owner sees and a non-owner does not is the join-code section '
        'and the pending-request list — **a join code is a credential, not '
        'information about the project**, which is why that one is a read '
        'restriction on purpose.',
    'features/more/screens/animals_screen.dart':
        'CONTROL ONLY (task 11.244). Every role sees the identical list of '
        'animals with the identical counts — an animal is project data and '
        '§4.21.4 says every member of a project reads all of it. The one '
        'thing a permission decides is whether **Add animal** is live, and a '
        'viewer gets the greyed button with the sentence under it rather '
        'than no button at all. Task 11.321\'s **Quick add** button is '
        'gated the same way, by the same standing, under the same sentence.',
    'features/more/screens/animal_detail_screen.dart':
        'CONTROL ONLY (task 11.244), and the same shape the tag details page '
        'uses. A viewer reads every field of the animal — name, status, sex, '
        'species, notes, colour — and the whole list of collars it has worn '
        'with their dates, which is exactly what a viewer on a project most '
        'wants to read. What a permission gates is the writes: Save, Link a '
        'tag, Set removed date, Remove record and Delete animal are hidden '
        'or greyed for a viewer, with the reason above the form. '
        '**Same animal as… is owner-only** on top of that, and says which of '
        'the two it is — merging re-points deployments, which changes what '
        '"this animal\'s track" means for every bearing already recorded.',
    'features/more/screens/new_season_screen.dart':
        'CONTROL ONLY (task 11.56), and the branch is a formality: there is '
        'no role that lacks the permission. Starting a season from a project '
        'reads what every member may read and writes only into a new project '
        'the person creates and owns, so every role sees the identical '
        'screen — the counts, the dead-animal switch, the one button. The '
        'guarded write is there so an unexpected refusal is reported as one '
        'rather than as a crash; its `refused` sentence is deliberately null '
        'because no honest sentence names a role that would be refused.',
    'features/more/screens/project_setup_screen.dart':
        'READ BRANCH. A non-owner gets the whole form with `readOnly: '
        '!isOwner` on its text fields (task 11.184 — was `enabled: isOwner`, '
        'which also made the text unselectable) — every project setting is '
        'readable and selectable, none is editable — plus a line saying so. '
        '**Task 11.245 took the tag section off this screen entirely** — it '
        'is settings again, and the project\'s tags have their own screen, '
        'declared below.',
    'features/more/screens/tags_screen.dart':
        'READ BRANCH, and the same shape the tag details page uses — moved '
        'here from Project Setup by task 11.245. A non-owner reads the '
        'identical flat list of this project\'s tags, active or removed, '
        'with the linked animal\'s name where there is one; only the unlink '
        'and add-back controls, and editing a tag the project already holds, '
        'are gated. Tapping a row opens `widgets/tag_form.dart`, declared '
        'below, which is where the field-level `readOnly` branches live.',
    'features/more/screens/tag_database_screen.dart':
        'CONTROL ONLY since task 11.219, and the change is a narrowing. This '
        'screen shows the device\'s own tag **library** — device-local, in no '
        'project, reaching no server — so there is no project data here for a '
        'role to withhold and every role sees the identical list, the '
        'identical form and the identical controls. The one thing a '
        'permission decides is which projects the create form offers to put '
        'a copy of the new collar into: a project the person may only read is '
        'not on that menu. The project list itself is on the Projects screen '
        'for everybody.\n'
        'It was a READ BRANCH until then — 2026-09-06, ratified by Michael '
        '2026-09-07 (security model §4.21.4): a viewer tapping a tag they '
        'could not edit used to get a refusal and nothing else, and now gets '
        'the details read-only under that refusal. That behaviour did not go '
        'away; it moved with the thing it was about, to '
        '`widgets/tag_form.dart` opened from `More \u2192 Tags` (task '
        '11.245, moved off Project Setup).',

    // ---- Gates a control, shows the same information ----
    'features/map/screens/map_screen.dart':
        'CONTROL ONLY. `mayWrite` gates the Edit affordance on an observation, '
        'defaulting to not-permitted while unresolved. Everything the map '
        'draws — tag names, frequencies, colours, bearings, estimates — is the '
        'same for every role.',
    'features/more/screens/log_screen.dart':
        'CONTROL ONLY. `isOwner` and `mayWrite` decide which row menu entries '
        'are offered, through `reasonedMenuItem` so a refused one still says '
        'why. The log itself, both tabs, is the same for every role.',
    'features/more/screens/observation_sharing_screen.dart':
        'CONTROL ONLY. Gates the create-tag and save paths on import; the '
        'preview of what is being shared is the same for every role. The '
        '`ProjectRole` use here is wording — naming the receiver\'s role in a '
        'sentence.',
    'features/more/screens/projects_screen.dart':
        'CONTROL ONLY. Delete, leave, link, restore and — task 11.290 — '
        'delete-from-server and cancel-scheduled-deletion are gated per '
        'project through `reasonedMenuItem`; the list of projects and what '
        'each one says, the deletion countdown included, is the same for '
        'every role.',
    'features/more/screens/join_project_screen.dart':
        'CONTROL ONLY. Task 11.290: an owner\'s row gets a ⋮ menu with '
        'Delete permanently… / Cancel scheduled deletion; a non-owner gets no '
        'menu, because it would hold one permanently greyed item. The '
        'project\'s name, the Join/Restore button and the scheduled-deletion '
        'date on the row are the same for every role.',
    'features/observations/screens/observation_logging_screen.dart':
        'CONTROL ONLY. `mayWrite` gates saving. The tag picker shows every tag '
        'with its frequency, pulse rate, name and colour to every role.',
    'features/position_estimation/screens/position_estimation_screen.dart':
        'CONTROL ONLY. Gates computing, saving and deleting an estimate. The '
        'estimates already on the project are readable by every role.',

    // ---- Refusal handling only: no branch on what is rendered ----
    'features/observations/widgets/observation_edit_dialog.dart':
        'REFUSAL ONLY. One `runGuardedWrite` around the save. The dialog does '
        'not ask anything about the role before it opens.',
    'features/observations/widgets/truth_point_edit_dialog.dart':
        'REFUSAL ONLY. `runGuardedWrite` around save, delete and the undo '
        'restore. Nothing here renders differently by role.',
    'widgets/near_duplicate_tag_dialog.dart':
        'REFUSAL ONLY. One `runGuardedWrite` around the duplicate check that '
        'runs before a tag is created.',
    'features/more/screens/quick_add_screen.dart':
        'REFUSAL ONLY (task 11.321). The screen asks nothing about the role: '
        'More → Animals only opens it for somebody who may add an animal, '
        'and Save turns a refused write (a role changed meanwhile) into '
        '"Nothing was saved" plus the refusal sentence. Every row it shows '
        'is what the person typed or pasted.',
    'widgets/tag_form.dart':
        'READ BRANCH, and it is the one that moved here in task 11.219. This '
        'is the tag form, shared by the Tag Library screen (editing a '
        'library entry, which no role governs) and `More \u2192 Tags` '
        '(editing a project\'s copy of a collar, which is owner-only; moved '
        'there from Project Setup by task 11.245). `readOnly` is the '
        'caller\'s answer, and a non-owner gets **the whole form**: '
        'frequency, the pulse modes with their names and rates, pulse '
        'pattern, name, status, date put on, notes and colour are all on '
        'screen and readable. What they do not get is the controls — "Add '
        'mode", the per-mode remove buttons, the date picker\'s Change '
        'button, the selectable colour grid and the custom-hex editor — each '
        'of which is a way to change a value that is already displayed. The '
        'bpm/seconds-per-pulse toggle is offered to both, because it is a '
        'preference on this device and changes no tag. §4.21.4: COMPLIES.',
    'widgets/tag_view_only_banner.dart':
        'REFUSAL ONLY. The `tag_edit_not_permitted` sentence itself, lifted '
        'out of `tag_database_screen.dart` in task 11.219 so a project\'s '
        'own tag screen (`More \u2192 Tags` since task 11.245) can show it '
        'above a project\'s tag. It renders one explanation and '
        'decides nothing: whether it appears at all is the caller\'s '
        '`readOnly`, declared on `widgets/tag_form.dart` above.',

    // ---- The mechanism itself ----
    'widgets/disabled_reason.dart':
        'NOT A SCREEN. This is `reasonedMenuItem` and `DisabledReasonNote` — '
        'the shared way a disabled control states its reason where a person '
        'can actually read it (task 11.94/11.101/11.138). It decides nothing; '
        'it is what the screens above decide *with*.',
  };

  test('every screen that branches on a permission is declared here', () {
    final lib = Directory('lib');
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'Run this from the repository root; lib/ was not found.',
    );

    final scanned = <String>[];
    final found = <String, List<String>>{};
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.dart')) continue;
      if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) continue;
      // The subject is what a person is shown, so the corpus is the widget
      // tree — not the repositories and providers underneath it, which are
      // §4.21's and §4.23's subject and have their own tests.
      final relative = path.substring('lib/'.length);
      if (!relative.startsWith('features/') && !relative.startsWith('widgets/')) {
        continue;
      }
      scanned.add(relative);
      final text = entity.readAsStringSync();
      final hits = signals.where(text.contains).toList();
      if (hits.isNotEmpty) found[relative] = hits;
    }

    // A search that finds nothing and a subject that contains nothing are
    // indistinguishable from the inside, and only one of them is true
    // (`CLAUDE.md`, 2026-09-04). The corpus is asserted here; that the scan
    // reached this *class* within it is asserted by `gone`, below.
    expect(
      scanned.length,
      greaterThan(20),
      reason:
          'The scan reached only ${scanned.length} files under lib/features '
          'and lib/widgets. That is not this app; the scan is looking at the '
          'wrong tree.',
    );
    // Vacuity is ruled out by the `gone` check below rather than by a floor
    // somebody picked: a scan that silently matched nothing fails there,
    // naming all ${declared.length} declared files at once. A threshold here
    // would fire first and say less.

    // ignore: avoid_print
    print(
      'Scanned ${scanned.length} widget-tree source files under lib/; '
      '${found.length} branch on a permission, of which '
      '${found.keys.where((k) => k.endsWith('_screen.dart')).length} are '
      'screens out of '
      '${scanned.where((f) => f.endsWith('_screen.dart')).length}.',
    );

    final undeclared = found.keys.where((k) => !declared.containsKey(k)).toList()
      ..sort();
    expect(
      undeclared,
      isEmpty,
      reason:
          'These files branch on a permission and are not declared in this '
          'file: '
          '${undeclared.map((k) => '$k (${found[k]!.join(', ')})').join('; ')}. '
          'Write a verdict here answering one question: **what does a person '
          'who lacks the permission see on this screen?** Say READ BRANCH if '
          'the screen shows them something different, CONTROL ONLY if it gates '
          'an action and shows the same information, or REFUSAL ONLY if it '
          'merely handles a write being refused. A READ BRANCH is a change to '
          'the security model\'s §4.21.4 and needs a sentence there too.',
    );

    final gone = declared.keys.where((k) => !found.containsKey(k)).toList()
      ..sort();
    expect(
      gone,
      isEmpty,
      reason:
          'These files are declared here and no longer branch on a permission '
          '(or no longer exist): $gone. A declaration that outlives the code '
          'it describes sends every future reader to the wrong place; delete '
          'the entry along with the branch.',
    );
  });
}
