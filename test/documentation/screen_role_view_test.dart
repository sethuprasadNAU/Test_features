import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **Task 11.183 — for each screen that branches on a permission, what an
/// owner sees and what a non-owner sees.**
///
/// **Why this file exists.** `screen_permission_branches_test.dart` (task
/// 11.181) is a census: it says *which* files branch on a permission, and it
/// goes red when a file joins or leaves that class. It says so itself, in its
/// own header, that it would have caught **neither** known instance of the
/// defect it was built for — task 11.99's owner-only members screen and
/// 11.181's own read-only tag details page — because **both were files already
/// on the list that changed what they showed.** This file is the artefact that
/// header said was missing.
///
/// The rule being checked is `TriTrack_Security_Model.md` **§4.21.4**: within a
/// project a person belongs to, **every role reads everything the project
/// holds.** The gradient decides what they may *change*, never what they may
/// *see*. So a screen that shows a `viewer` less information than an `owner` is
/// a defect against the model, and a screen that merely disables a control they
/// may not use is not.
///
/// ## Derived, written, or both — the choice, and the risk being taken
///
/// **Both, split on purpose, because the two halves rot for different reasons.**
///
/// - **What a person sees is written.** No derivation can read a Flutter widget
///   tree and say "a viewer can read the tag's pulse rate here"; that is a
///   judgement about meaning. A dozen screens is a small enough number for a
///   written record somebody actually reads, which this project's history says
///   beats a derivation nobody trusts.
/// - **Whether the code still does what the record says is derived**, in two
///   nets of different mesh:
///   1. **[conditionalRenderSites]** — every line in these files that puts a
///      permission inside an `if (…)`. That is the set of places where a
///      permission decides *what is in the widget tree* rather than whether a
///      control is enabled, so it is exactly the §4.21.4 surface. Each site
///      carries one sentence saying what the non-owner branch does. A site
///      appearing, disappearing, or having its condition reworded fails the
///      run.
///   2. **[permissionLineCounts]** — how many lines in each screen mention a
///      permission at all, control gates and plumbing included. Coarser and
///      easily defeated by a swap (one line out, one line in), which is said
///      here rather than left to be discovered; it is the net that catches a
///      ternary or a helper argument changing, which net 1 does not see.
///
/// **The risk being taken, stated so it can be disagreed with.** The written
/// half can go stale while both nets stay green: somebody can change the *text*
/// inside an `if (!mayWrite)` branch without touching the condition. What that
/// costs is bounded — the branch is still declared, still points at a line
/// number a reader can open, and 21 sites is a re-readable amount of work. What
/// it buys is that the two changes this class has actually produced, both of
/// which added or removed a branch, cannot happen silently again.
///
/// **Both known instances would have failed this file.** Task 11.99 removed an
/// `if (isOwner)` wrapper from the projects list; task 11.181 took
/// `_TagEditDialog` from no `readOnly` branch at all to five of them. Each is a
/// change to net 1.
///
/// ## The result of the survey, 2026-09-06
///
/// **No screen hides project data from a member because of their role.** That
/// is a finding rather than an empty answer: it means §4.21.4 is satisfied
/// today by all of them, and the record below is what a future reader compares
/// against. Two things that are *not* §4.21.4 violations are recorded anyway
/// because they read like ones — see [notViolationsButLookLikeThem].
void main() {
  /// The tokens that mean "this line's behaviour depends on a permission".
  /// Deliberately the same idea as 11.181's list, widened by `readOnly` —
  /// which is how `tag_database_screen.dart` carries the permission answer the
  /// last few frames into the widget that renders it, and is therefore the
  /// exact variable the 2026-09-06 change turned on.
  const signals = <String>[
    'mayCreateTag',
    'mayEditTag',
    'mayWriteProjectData',
    'isProjectOwner',
    'myProjectRole',
    'ownedProjectIds',
    'mayWrite',
    'mayEdit',
    'mayCreate',
    'isOwner',
    'readOnly',
    // Task 11.237: the screens read a `ProjectStanding` now — the role, or
    // *not a member*, or *cannot say* — and pick a sentence from it with
    // `writeRefusal`. Same permission, one more token in the plumbing.
    'ProjectStanding',
    'myProjectStanding',
    'standing',
    'writeRefusal',
  ];

  /// **The record. One entry per screen, and the two roles side by side.**
  ///
  /// "Non-owner" is a `viewer` or a `contributor` — where the two differ, the
  /// entry says so. The question each answers is the §4.21.4 one: **is there
  /// anything here an owner can read and they cannot?**
  const roleView = <String, String>{
    'features/more/screens/project_members_screen.dart':
        'OWNER: the whole member list with every role and joining date, the '
        '"Your role" card, every past stint, a role dropdown and a remove '
        'button per member, a re-admit button per past member, the join-code '
        'section (the code itself, the joining switch, the team-size limit) '
        'and the pending-request list.\n'
        'NON-OWNER: everything above except the join-code section and the '
        'pending-request list, plus a line the owner does not get — "Only an '
        'owner can change a role or remove somebody. You can see who is on the '
        'project." The dropdown and the remove and re-admit buttons are '
        'present and inert.\n'
        'SNAPSHOT HOLDER (task 11.237 — somebody the rows say is not on the '
        'project): the same list, and the "Your role" card reads "Not on this '
        'project" with the snapshot description and the join-code directions '
        'where a member reads their rights. Nothing withheld; a different '
        'sentence.\n'
        '§4.21.4: COMPLIES, and the two absences are the model\'s named '
        'exception. They are not a screen hiding project data: the server '
        'refuses both to a non-owner (see the join-code test below), a join '
        'code is a credential rather than information, and the pending list '
        'carries the email addresses of people who are not project members at '
        'all.',
    'features/more/screens/project_setup_screen.dart':
        'OWNER: an editable form — name, description, notes, the map extent '
        'with its pick-on-map and use-GPS buttons, the coordinate format, and '
        '(task 11.331) the time zone with its Change and Use buttons.\n'
        'NON-OWNER, time zone: the zone in words, where it came from and the '
        "area's suggestion are all shown; the two buttons are greyed.\n"
        'NON-OWNER: the identical form with the name/description/notes fields '
        '`readOnly: true` (task 11.184 — changed from `enabled: false`, which '
        'also made the text unselectable; nothing here is withheld, so '
        'read-only-but-selectable is the honest rendering), plus two lines '
        'the owner does not get: a banner saying "Only a project owner can '
        'edit these settings. You can still view them", and a note under the '
        'pinned SAVE PROJECT button saying the same.\n'
        'TASK 11.245 took the tag list off this screen entirely — Project '
        'Setup is settings again (design §3, Michael, 2026-09-14). It moved '
        'to `features/more/screens/tags_screen.dart`, which carries its own '
        'entry below.\n'
        'TASK 11.268 (item 7) took the triangulation-window field off this '
        'screen entirely — one line, one role-conditioned mode, gone with it '
        'rather than moved. Position Estimation now uses a fixed 6-hour '
        'default instead of a per-project setting nobody could find.\n'
        '§4.21.4: COMPLIES. Every field a non-owner cannot edit is still '
        'legible and, since task 11.184, selectable.',
    'features/more/screens/tags_screen.dart':
        'OWNER: this project\'s tags — every one, active or removed, with the '
        'linked animal\'s name as a subtitle where there is one — plus '
        'unlink/add-back controls per row and a Copy from library button.\n'
        'NON-OWNER: the identical flat list — a tag is project data, and '
        '§4.21.4 says every member reads all of it, active or removed. A '
        'contributor may copy one in and open any row to read it, but the '
        'unlink icon and the Add back button are greyed (owner-only, task '
        '11.221) with one sentence under the section rather than a tooltip '
        'nobody can open on a touchscreen; a viewer additionally sees a '
        'banner saying viewers cannot change a project\'s tags; a snapshot '
        'holder (task 11.237) sees the same list under the shared '
        'not-on-this-project refusal instead.\n'
        'Tapping a row opens the project\'s own copy of the collar in the '
        'shared tag form — read-only for a non-owner, under the '
        '`tag_edit_not_permitted` banner, showing every field.'
        ' `lib/widgets/tag_form.dart` carries those branches and '
        '`screen_permission_branches_test.dart` carries their verdict.\n'
        '§4.21.4: COMPLIES. The list itself, and every field on an open '
        'row, renders identically for every role; the permission only '
        'decides whether a control is live and which sentence explains it '
        'when it is not.',
    'features/more/screens/tag_database_screen.dart':
        'EVERY ROLE, IDENTICALLY: this device\'s own tag library — one line '
        'per transmitter (frequency and name, sorted), a status icon, a '
        'chevron, sort and export and bulk-import buttons, a create FAB, and '
        'Tag details opening editable on every field, including the '
        'one-to-three pulse modes with their names and rates and the buttons '
        'that add or remove one.\n'
        'THE ONLY THING A ROLE DECIDES HERE is which projects the create '
        'form offers to put a copy of the new collar into: a project the '
        'person may only read is not on that menu. A control, not content — '
        'the project list itself is on the Projects screen for everybody.\n'
        'Task 11.321 added the second control of the same kind: a tag '
        'dragged onto a project\'s heading is added there only if the person '
        'may write to that project; a viewer is told why and nothing is '
        'written. Every role sees the same headings and the same rows.\n'
        '§4.21.4: COMPLIES, and since task 11.219 it complies by '
        'construction. A library entry is in no project, so there is no '
        'project data here to withhold and no role that could withhold it. '
        'The owner-only tag rule did not go away — it is about a *project\'s* '
        'copy of a collar, which is edited on `More → Tags` (task 11.245, '
        'moved off Project Setup), and the `tag_edit_not_permitted` banner '
        'moved there with it.\n'
        'Before 2026-09-06 this screen was the model\'s only violation: a '
        'non-owner\'s tap was refused outright, so the one person who could '
        'not edit a tag was also the only one who could not read it. Michael '
        'ratified the fix 2026-09-07; task 11.219 then made the question '
        'unaskable here.',
    'features/map/screens/map_screen.dart':
        'OWNER: the map with every bearing, estimate, truth point, tag name, '
        'frequency and colour the project holds, and an Edit control on a '
        'selected observation.\n'
        'NON-OWNER: byte for byte the same map. The standing (task 11.237: '
        'the role, or *not a member*, or *cannot say*) reaches only '
        '`authorEditVerdict` and `truthPointEditVerdict`, which decide whether '
        'the Edit button is enabled and what sentence sits under it — a '
        'viewer\'s, or the snapshot refusal. Nothing drawn on the map depends '
        'on a role.\n'
        '§4.21.4: COMPLIES. There is no conditional-render site in this file '
        'at all.',
    'features/more/screens/animals_screen.dart':
        'OWNER: every animal on the project, with its status and how many '
        'collars it has worn, and a live **Add animal** button.\n'
        'NON-OWNER: the identical list — an animal is project data, and '
        '§4.21.4 says every member reads all of it. A contributor may add '
        'one; a viewer gets the button greyed with the reason under it '
        '(`DisabledReasonNote`), never hidden, and a snapshot holder gets the '
        'same button under the shared snapshot refusal.\n'
        '§4.21.4: COMPLIES. Nothing is withheld from any role; the permission '
        'picks whether one button is live.',
    'features/more/screens/animal_detail_screen.dart':
        'OWNER: the animal\'s fields (name, status, sex, species, notes) and '
        'colour, every tag it has worn with attached and removed dates, and '
        'the writes — Save, Link a tag, Edit/Set attached date, Set removed '
        'date, Remove record, Same animal as…, Delete animal.\n'
        'NON-OWNER: every field and every tag row, identical, readable and '
        'selectable — which is what a viewer on a project most wants from '
        'this screen. A viewer\'s fields are `readOnly`, the per-tag actions '
        'are not rendered at all (there is nothing to read in a button that '
        'does nothing), and Save, Link a tag and Delete are greyed, with the '
        'reason at the top of the form. A contributor gets all of those '
        'live. **Same animal as… is owner-only for both**, with the '
        'sentence under it saying which of the two reasons applies — it '
        're-points deployments, which changes what "this animal\'s track" '
        'means for bearings already recorded.\n'
        '§4.21.4: COMPLIES. The one conditional render is the per-tag '
        'action row, and what it hides is buttons a viewer cannot press — '
        'no fact about the project is withheld from anybody.',
    'features/more/screens/log_screen.dart':
        'OWNER: both tabs in full — every observation, non-detection and truth '
        'point, with observer, distance, marks and withdrawn marks — an '
        'observation row menu offering edit, delete, share, supersede, '
        'exclude and restore, a truth point row menu offering edit and '
        'delete, and (task 11.252) a "no signal" row menu offering delete.\n'
        'NON-OWNER: the identical log, identical filters, identical rows. The '
        'same menu entries appear on every row kind; the ones they may not '
        'use are shown disabled with the reason on the entry '
        '(`reasonedMenuItem`), never hidden. Excluding is owner-only, '
        'superseding is contributor-level, withdrawing a mark also depends on '
        'whose mark it is, and deleting a "no signal" record is author-only '
        'like deleting an observation (`nonDetectionEditVerdict`, the same '
        'two-gate shape as `authorEditVerdict`) — all differences are in what '
        'the entry does, not in what the log says. A snapshot holder (task '
        '11.237) gets the same rows with every write entry disabled under the '
        'one shared refusal.\n'
        '§4.21.4: COMPLIES. No conditional-render site.',
    'features/more/screens/observation_sharing_screen.dart':
        'OWNER: the paste box, the parsed preview of the shared observation, '
        'the "Show on map" button, "Create tag" when the tag is unknown, and '
        '"Save observation".\n'
        'NON-OWNER: the same paste box and the same parsed preview — the '
        'entire content of what is being shared is rendered before any '
        'permission is consulted. A viewer gets "Create tag" and "Save '
        'observation" greyed, each with its reason in a `DisabledReasonNote` '
        'under it; "Show on map" works for everybody. A snapshot holder (task '
        '11.237) gets the same two controls greyed under the shared refusal, '
        'and a paste that reaches the importer anyway is refused with it.\n'
        '§4.21.4: COMPLIES. The permission picks which sentence to print, '
        'not what to render; since 11.237 that choice is `writeRefusal` on the '
        'standing rather than an `if`, so there is no conditional-render site '
        'left in this file.',
    'features/more/screens/projects_screen.dart':
        'OWNER: every project on the device, the active marker, and a row menu '
        'with Publish to server (when the project is unlinked and a server is '
        'configured), Members, Edit project, Leave and Delete.\n'
        'NON-OWNER: the same list and the same rows, including Publish to '
        'server — task 11.184 stopped removing it for a non-owner and shows it '
        'disabled instead, with "Only a project owner can publish this '
        'project." on the item, the same pattern every other entry in this '
        'menu already used. The Members entry\'s note differs — "Who is on the '
        'project, the join code, and who is waiting" for an owner, "Who is on '
        'the project, and what role you hold" for everybody else — and both '
        'sentences are true of what that person will find there. Delete is '
        'offered to an owner and to somebody who has left.\n'
        'SNAPSHOT HOLDER (task 11.237): the same row with one more line under '
        'the name — "A copy of someone else\'s project — read-only on this '
        'device until you join it." More, not less; derived on every read, so '
        'it disappears the moment their membership row arrives.\n'
        'DELETION FROM THE SERVER (task 11.290): every member sees the same '
        'tinted row and the same countdown sentence — the days left and the '
        'date — and the same Export records item. The owner\'s sentence ends '
        '"or cancel from ⋮" and a member\'s does not, because a member cannot; '
        'the menu offers Delete permanently… / Cancel scheduled deletion to '
        'everybody on a published project, enabled for an owner and greyed '
        'with "Only a project owner can…" for everybody else. After the '
        'deletion has run, every role\'s row says it was deleted from the '
        'server and that the records here are kept, and Publish to server is '
        'greyed with "its identifier cannot be published again".\n'
        'TRASH (tasks 11.292/11.302, moved to the bottom of this screen by '
        'task 11.313 and named Trash by task 11.324): a section '
        'listing the projects this person deleted in the app that the server '
        'still holds as tombstones, each with the date they deleted it, the '
        'countdown once scheduled, a ⋮ offering Delete permanently… / Cancel '
        'scheduled deletion, and a Restore button. The screen reads no role '
        'for any of it: the server lists a project there only when it '
        'records the caller as its owner and as the sender of the tombstone '
        '(§4.28.1), and restores it for exactly the same people, so a '
        'non-owner\'s section is empty and therefore absent. No Join control '
        'on those rows — this screen only ever offers Join from its own '
        'tile, never from a row. Since task 11.339 the same section also '
        'holds this phone\'s own Trash rows — projects this person moved to '
        'the Trash that are not sent yet, or that this phone does not sync — '
        'each with Restore, and the second kind with a ⋮ offering Delete '
        'permanently… from this phone. Those are decided by who wrote the '
        'tombstone, not by a role, and are the same for every role.\n'
        '§4.21.4: COMPLIES — a project list is not project data hidden by '
        'role, and nothing about any project is withheld.',
    'features/more/screens/join_project_screen.dart':
        'OWNER: the join-code card, the requests card, and one row per '
        'project the server holds that this device is not syncing — the '
        'name, a Join or Restore button, and (task 11.290) a ⋮ menu offering '
        'Delete permanently… or, once scheduled, Cancel scheduled deletion. '
        'A scheduled project\'s row is tinted and says the date, with "You '
        'can cancel it from ⋮."\n'
        'NON-OWNER: the identical cards and rows, with the same Join or '
        'Restore button and the same tinted row and date on a scheduled '
        'project — without the "you can cancel" clause, and with no ⋮ menu '
        'at all: it would hold one greyed item that could never do anything, '
        'and a control that can never act is clutter rather than an '
        'explanation. The information on the row is the same for every '
        'role.\n'
        '**The Trash section (then called "Deleted from your devices") '
        'moved to `projects_screen.dart` by task 11.313** — "nobody looks '
        'for a deleted thing on a join screen" — and its entry moved with '
        'it. This screen is only about joining again now.\n'
        '§4.21.4: COMPLIES — what the server holds for this person is listed '
        'for every role; only the owner\'s destructive control differs.',
    'features/observations/screens/observation_logging_screen.dart':
        'OWNER: the record form — record type, the tag wheel showing every tag '
        'with frequency, pulse rate, name and colour, bearing capture, GPS '
        'readout, precision, notes, and SAVE. (Tasks 11.260 and 11.262 put a '
        'line above the wheel here on an untimed same-day handover; task '
        '11.263 deleted it — the interlock no longer lets this app write that '
        'state, design §6a.)\n'
        'NON-OWNER: the identical form with the identical tag wheel, plus a '
        'line the owner does not get: "Viewers cannot record observations — '
        'ask an owner to change your role", above the pinned save bar. SAVE '
        'is inert. Choosing "Add new tag" in the wheel opens an explanation '
        'instead of the quick-add form, because a wheel entry cannot be '
        'greyed. On a project with no tags at all, the empty state offers the '
        'same create button with its reason under it. A snapshot holder (task '
        '11.237) gets the identical form and wheel with the shared '
        'not-on-this-project refusal in each of those three places.\n'
        '§4.21.4: COMPLIES.',
    'features/position_estimation/screens/position_estimation_screen.dart':
        'OWNER: the map with the rays and the estimate, the bearing list, the '
        'select-all/none controls, COMPUTE, SAVE POSITION, past estimates with '
        'their ellipse and observation counts, and a delete button on each.\n'
        'NON-OWNER: the same map, the same rays, the same computed estimate '
        'and the same past estimates with the same numbers. SAVE POSITION is '
        'inert under a reason line the owner does not get, and the delete '
        'button on a past estimate stays tappable and explains itself. A '
        'snapshot holder (task 11.237) reads the shared refusal in both '
        'places; it is longer, and the save row is measured for whichever '
        'sentence it carries.\n'
        '§4.21.4: COMPLIES. One consequence worth knowing rather than fixing '
        'is in `notViolationsButLookLikeThem`.',
  };

  /// **One thing that reads like a §4.21.4 violation and is not.** Recorded
  /// because the next person to notice it should meet the reasoning rather
  /// than re-derive it as a defect.
  ///
  /// **Down from three, 2026-09-06 (task 11.184).** The other two entries here
  /// were consistency findings against task 11.12's "explain, don't hide"
  /// rule, not against §4.21.4, and both are fixed: `projects_screen.dart` no
  /// longer removes "Publish to server" for a non-owner (it is shown disabled,
  /// like every other entry in that menu), and `project_setup_screen.dart`'s
  /// text fields are `readOnly` rather than `enabled: false`, so a non-owner
  /// can select and copy them like an owner can. Neither was ever a §4.21.4
  /// defect — nothing was withheld either way — which is why fixing them
  /// changed this list's length rather than the roleView COMPLIES verdicts
  /// above.
  const notViolationsButLookLikeThem = <String>[
    'NOT a violation. On `position_estimation_screen.dart` a viewer\'s '
    'reason line takes height out of the bottom panel, so **fewer bearing '
    'rows are visible at once** than an owner sees. The list scrolls and every '
    'bearing is reachable, so no information is withheld — but the panel is a '
    'measured budget (task 11.139/11.148) and a role now moves it, which is '
    'worth knowing the next time that budget is priced.',
  ];

  /// **Every place a permission decides what is in the widget tree.**
  ///
  /// Keyed by path under `lib/`; the value is one entry per occurrence, in the
  /// order they appear in the file, each pairing the condition as written with
  /// what the branch does. Derived and compared below: this is the net that
  /// fails when a screen already on the list changes what it shows.
  const conditionalRenderSites = <String, List<List<String>>>{
    'features/more/screens/project_members_screen.dart': [
      [
        'if (isOwner == null) {',
        'A spinner until ownership is known, for everybody. Not a role '
            'difference — it is the refusal to flicker a provisional answer at '
            'the person who came here to read exactly that.',
      ],
      [
        'if (!isOwner)',
        'ADDS a line for the non-owner saying an owner is needed to change a '
            'role or remove somebody. The non-owner sees more here, not less.',
      ],
      [
        'if (isOwner) ...[',
        'The join-code section and the pending-request list, owner only. **The '
            'model\'s named exception**, and the only place in these '
            'screens where a role decides whether something is rendered at '
            'all. Held to a condition rather than exempted — see the '
            'join-code test below.',
      ],
      [
        'if (!standingAsync.hasValue) return const SizedBox.shrink();',
        'The "Your role" card waits for the standing before it says anything, '
            'for everybody — the same refusal to flicker a provisional answer '
            'as the spinner above. Not a role difference.',
      ],
    ],
    'features/more/screens/project_setup_screen.dart': [
      [
        'if (project == null) return _buildForm(context, isOwner: true);',
        'A project being created has no ownership row yet and the person '
            'creating it is its owner. Not a role difference.',
      ],
      [
        'if (isOwner) return child;',
        '`_gatedToOwner`. The non-owner branch returns the same child, at most '
            'wrapped in `IgnorePointer`/`Opacity`. Nothing is removed.',
      ],
      [
        'if (!isOwner)',
        'ADDS the banner: only an owner can edit these settings, you can still '
            'view them.',
      ],
      [
        'if (!isOwner)',
        'ADDS the reason note above the pinned SAVE PROJECT button, which '
            'outruns the banner when the form is scrolled.',
      ],
    ],
    // Task 11.245: this project's tags, moved off Project Setup.
    'features/more/screens/tags_screen.dart': [
      [
        'if (writeRefusal != null)',
        'ADDS the tag-section banner for a viewer or a snapshot holder (task '
            '11.237) — the standing chose the sentence. The tag list itself '
            'renders identically for every role.',
      ],
      [
        'if (!mayWrite) return null;',
        'Inside `tagsSectionDisabledReason`, which returns a sentence. Chooses '
            'wording, renders nothing.',
      ],
      [
        'if (!isOwner) {',
        'Same function, the contributor case: removing a tag and adding one '
            'back are owner-only (the latter since task 11.221) while '
            'copying one in is not, so the sentence differs. Wording, not '
            'content.',
      ],
    ],
    // **Task 11.219 emptied this list, and where its seven sites went is
    // the point rather than a footnote.** They were all inside the tag form,
    // and the form moved to `lib/widgets/tag_form.dart` so that Project
    // Setup could open it on a project's copy of a tag. That is where every
    // `readOnly` branch now lives, and where the read-only rendering is
    // declared: see `screen_permission_branches_test.dart`, which scans
    // wider than this file's `*_screen.dart` derivation and carries the
    // verdict for it.
    //
    // What is left on this screen is two lines mentioning
    // `mayWriteProjectDataProvider`, and neither renders anything
    // conditionally: they filter which projects the create form offers to
    // put a copy into. A project a viewer may not write to is not on that
    // menu — a control, not content, and the list of projects is on the
    // Projects screen for everybody.
    'features/more/screens/tag_database_screen.dart': [],
    // Task 11.184: the publish item's precondition
    // (`if (widget.canUseServer && linked == false)`) no longer mentions
    // `isOwner` — ownership now decides only `enabled`/`note` on the item
    // itself, plain assignments rather than a conditional-render site, so
    // there is nothing left in this file for that net to catch. It still
    // shows up in `permissionLineCounts` below.
    'features/more/screens/projects_screen.dart': [],
    // Task 11.290: the ⋮ menu on a joinable row is built only for an owner
    // (`if (isOwner) PopupMenuButton(...)`) — a control, and a menu that
    // would hold one permanently greyed item for anybody else. The row's
    // information is the same for every role.
    'features/more/screens/join_project_screen.dart': [
      [
        'if (isOwner)',
        'ADDS the ⋮ menu (Delete permanently… / Cancel scheduled deletion) '
            'to an owner\'s row. A control, and for anybody else it would '
            'hold one permanently greyed item. The row\'s name, button and '
            'scheduled-deletion date render identically for every role.',
      ],
    ],
    // Task 11.237: `_saveDisabledReason` asks the standing for its sentence
    // with `writeRefusal` rather than an `if (!mayWrite)`, so the one site
    // this file had is gone. The preview of the shared observation is still
    // rendered before any permission is consulted.
    'features/more/screens/observation_sharing_screen.dart': [],
    'features/observations/screens/observation_logging_screen.dart': [
      [
        'if (writeRefusal != null) ...[',
        'ADDS the "viewers cannot record observations" line — or, for a '
            'snapshot holder, the shared refusal (task 11.237) — above the '
            'pinned save bar. The form and the tag wheel are identical for '
            'every role.',
      ],
      [
        'if (!standing.mayWriteProjectData) {',
        'In `quickAddTagDialog`: a viewer or a snapshot holder gets an '
            'explanation instead of the create form, because a scroll-wheel '
            'entry cannot be greyed out. The form creates a tag; it displays '
            'none.',
      ],
    ],
    'features/position_estimation/screens/position_estimation_screen.dart': [
      [
        'if (!mayWrite)',
        'ADDS the reason line above SAVE POSITION. Everything the panel '
            'computes and lists is the same for every role.',
      ],
    ],
  };

  /// **How many lines in each screen mention a permission at all.**
  ///
  /// The coarse net. Control gates and plumbing included, comment lines
  /// excluded. It moves when a ternary or a helper argument changes, which the
  /// conditional-render net cannot see; it can be defeated by a swap, which
  /// that net can. Neither is sufficient alone and that is why there are two.
  ///
  /// **Why a number in a file is allowed here.** It is not a hand-kept list:
  /// the run recomputes it every time and compares. And it cannot be edited by
  /// accident during ordinary work — the only edit that moves it is an edit to
  /// a line that mentions a permission, which is precisely the edit that should
  /// oblige somebody to re-read the record above.
  const permissionLineCounts = <String, int>{
    // Task 11.237 moved every screen from the write bool to the standing and
    // added the snapshot sentences; each count below moved with it, and the
    // record above was re-read against each screen.
    'features/map/screens/map_screen.dart': 8,
    // 22 -> 24: task 11.252 added the "no signal" delete control's two
    // permission-conditioned lines (`canEdit`/`disabledReason` computed from
    // `nonDetectionEditVerdict`).
    'features/more/screens/log_screen.dart': 24,
    'features/more/screens/observation_sharing_screen.dart': 13,
    'features/more/screens/project_members_screen.dart': 16,
    // 42 → 39 in task 11.221: the tag row stopped taking `mayWrite` at all
    // (three lines — the field, its constructor parameter and the argument),
    // because "Add back" is gated on `isOwner` now.
    // 42 → 52 in task 11.241: the animal header row takes `mayWrite` (the
    // dialog is read-only for a viewer) and `isOwner` (the merge button), the
    // Assign button on a collar with no animal is owner-only like every change
    // to an existing tag, and `_mergeDisabledReason` chooses a sentence on
    // `isOwner`. Nothing is hidden from any role; every line is a field, an
    // argument, an `onPressed: isOwner ? ... : null`, or a sentence.
    // 56 → 19 in task 11.245: every tag-related line left with the tag
    // section — the whole of what is left is the settings form's own
    // `isOwner` gating (extent, coordinate format, notes, SAVE PROJECT).
    // 19 → 18 in task 11.268 (item 7): the triangulation-window field's own
    // `readOnly: !isOwner` line left with the field — off this screen
    // entirely, not moved. Position Estimation's default is now a fixed
    // 6 hours.
    // 18 → 24 in task 11.331: the TIME ZONE section. Six lines, all the
    // same `_gatedToOwner` / `onPressed: isOwner ? … : null` gating as the
    // extent buttons — *Change time zone* and *Use that time zone*. The
    // zone in words, where it came from, and the area's suggestion are
    // shown to every role.
    'features/more/screens/project_setup_screen.dart': 24,
    // 10 -> 11 in task 11.238: the "not syncing yet" line's
    // `isOwner ? notSyncingYetOwnerDescription : notSyncingYetMemberDescription`
    // — the one line on the row that chooses its wording by role. Nothing is
    // hidden; a snapshot holder and a current member both see the sentence
    // that fits them.
    // 11 -> 22 in task 11.290: the row menu's Delete permanently… / Cancel
    // scheduled deletion items (enabled and note both read `isOwner`), the
    // countdown sentence's owner-only closing clause, and the export item's
    // wording. Every one of them chooses a sentence or an enabled state, and
    // none hides a row.
    // 22 -> 24 in task 11.313: the deleted-on-server section's delete-from-
    // server handler moved here unchanged from `join_project_screen.dart`,
    // bringing its own `notices.standing(projectId)` call and the local
    // variable it is assigned to — two more `standing` lines, neither a
    // conditional-render site: the handler is an action, and every control
    // on that section's rows was already unconditional (see the entry
    // above).
    'features/more/screens/projects_screen.dart': 24,
    // Task 11.290: the owner-only ⋮ menu on a joinable row, and the
    // scheduled-row sentence's "you can cancel it" clause.
    'features/more/screens/join_project_screen.dart': 5,
    // 28 -> 2 by task 11.219: the tag form moved to lib/widgets/, and
    // this screen's list is the device's own tag library, which no role
    // governs. The two lines left choose which projects the create form
    // offers to copy into.
    // 2 -> 5 by task 11.321: dropping a dragged tag on a project reads
    // that project's standing and its writeRefusal (a control, as above).
    'features/more/screens/tag_database_screen.dart': 5,
    // Task 11.245: the project-tags section, moved here from Project Setup
    // with its role gradient unchanged — copying one in is contributor-level,
    // changing one the project already holds is owner-only.
    'features/more/screens/tags_screen.dart': 25,
    // 19 -> 20 in task 11.260: the untimed-handover prompt's
    // `if (handover != null && mayWrite)`. 20 -> 19 in task 11.263, which
    // deleted the prompt and the chooser (design §6a).
    'features/observations/screens/observation_logging_screen.dart': 19,
    'features/position_estimation/screens/position_estimation_screen.dart': 20,
  };

  // ---- The derivation -------------------------------------------------------

  /// Non-comment lines of [path] that mention a permission, trimmed.
  List<String> permissionLinesOf(String relative) {
    final lines = File('lib/$relative').readAsLinesSync();
    final out = <String>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('//')) continue;
      // An import names a file, not a permission; `project_standing.dart`
      // would otherwise put every importer of the type on this list.
      if (line.startsWith('import ')) continue;
      if (!signals.any(line.contains)) continue;
      out.add(line);
    }
    return out;
  }

  /// Which screens branch on a permission at all — derived the same way
  /// `screen_permission_branches_test.dart` derives its census, so the two
  /// files cannot disagree about the population without both going red.
  List<String> screensThatBranch() {
    final out = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('_screen.dart')) continue;
      final relative = entity.path.substring('lib/'.length);
      if (permissionLinesOf(relative).isNotEmpty) out.add(relative);
    }
    return out..sort();
  }

  test('every screen that branches on a permission has a per-role record', () {
    expect(
      Directory('lib').existsSync(),
      isTrue,
      reason: 'Run this from the repository root; lib/ was not found.',
    );

    final screens = screensThatBranch();

    // A search that finds nothing and a subject that contains nothing are
    // indistinguishable from the inside (`CLAUDE.md`, 2026-09-04). This
    // derivation refuses an empty result rather than agreeing with itself.
    expect(
      screens,
      isNotEmpty,
      reason:
          'No screen under lib/ mentions a permission. That is not this app — '
          'the scan is looking at the wrong tree, or every signal token has '
          'been renamed at once.',
    );

    // ignore: avoid_print
    print(
      'Derived ${screens.length} screens branching on a permission; the record '
      'below covers ${roleView.length}, with '
      '${conditionalRenderSites.values.fold<int>(0, (n, v) => n + v.length)} '
      'conditional-render sites declared across '
      '${conditionalRenderSites.length} of them.',
    );

    expect(
      screens,
      equals(roleView.keys.toList()..sort()),
      reason:
          'The set of screens that branch on a permission has changed. Write '
          'the missing per-role record — what does an owner see here, what '
          'does a non-owner see, and is there anything an owner can read that '
          'they cannot? — or delete the record for a screen that has stopped '
          'branching. §4.21.4 of TriTrack_Security_Model.md is the rule to '
          'compare against.',
    );
  });

  test('the conditional-render sites are the ones declared', () {
    for (final screen in permissionLineCounts.keys) {
      final derived = [
        for (final line in permissionLinesOf(screen))
          if (line.startsWith('if (')) line,
      ];
      final declared = [
        for (final site in conditionalRenderSites[screen] ?? const <List<String>>[])
          site.first,
      ];
      expect(
        derived,
        equals(declared),
        reason:
            'The places where a permission decides what is rendered on '
            'lib/$screen no longer match what this file declares. This is the '
            'check that exists because task 11.99 and task 11.181 each changed '
            'what a screen showed a non-owner with nothing able to notice. '
            'Open the screen, decide what a non-owner now sees there, and say '
            'so both in the site list and in the per-role record above. If the '
            'branch withholds information a member could otherwise read, that '
            'is a §4.21.4 defect and needs a decision, not a declaration.',
      );
    }
  });

  test('the number of permission-conditioned lines per screen is unchanged', () {
    final actual = {
      for (final screen in permissionLineCounts.keys)
        screen: permissionLinesOf(screen).length,
    };
    expect(
      actual,
      equals(permissionLineCounts),
      reason:
          'A screen\'s permission-conditioned line count moved. This is the '
          'coarse net — it catches a ternary or a helper argument that the '
          'conditional-render check cannot see. Re-read that screen\'s entry '
          'in this file, confirm it still describes what each role sees, and '
          'update the number.',
    );
  });

  /// **The join-code exception, held to a condition instead of exempted.**
  ///
  /// The members screen is the one place a role decides whether something is
  /// rendered. The reason it is not a §4.21.4 defect is **not** that this file
  /// says so: it is that the data is not the non-owner's to read in the first
  /// place — the server refuses both requests, so the screen is reflecting the
  /// boundary rather than inventing one.
  ///
  /// **This is the general rule, applied, rather than a special case.** A
  /// screen may withhold something from a member only when the server would
  /// withhold it too. The day either route stops requiring an owner, this test
  /// goes red and the screen becomes a real §4.21.4 violation that has to be
  /// fixed rather than explained.
  test('the join code and the pending list are owner-gated on the server too', () {
    final source = File('server/lib/src/projects/project_routes.dart');
    expect(
      source.existsSync(),
      isTrue,
      reason: 'server/lib/src/projects/project_routes.dart was not found.',
    );

    // Comment lines are dropped **before** splitting. A delimiter that does not
    // know what a comment is attaches every route's preamble to its
    // predecessor, and a preamble is exactly where the words being hunted for
    // are written (`CLAUDE.md`, tasks 11.84 and 11.173).
    final code = [
      for (final raw in source.readAsLinesSync())
        if (!raw.trimLeft().startsWith('//')) raw,
    ].join('\n');

    /// The body of one route: from its declaration to the next one, or to the
    /// end of the file for the last route in it — which is the element nobody
    /// pictures and the one a "up to the next" split gets wrong.
    String bodyOf(String declaration) {
      final start = code.indexOf(declaration);
      expect(
        start,
        isNot(-1),
        reason:
            'The route `$declaration` is gone from project_routes.dart. The '
            'members screen hides the join code and the pending list from a '
            'non-owner on the strength of these two routes refusing them; if '
            'the route moved, re-derive that before editing this test.',
      );
      final next = code.indexOf('router.', start + declaration.length);
      return next == -1 ? code.substring(start) : code.substring(start, next);
    }

    for (final declaration in [
      "router.get('/projects/<projectId>/join-settings'",
      "router.get('/projects/<projectId>/join-requests'",
    ]) {
      expect(
        bodyOf(declaration),
        contains('_requireOwner'),
        reason:
            'The route `$declaration` no longer requires an owner, and '
            'project_members_screen.dart hides what it returns from every '
            'non-owner. That was the whole reason the members screen is not a '
            '§4.21.4 violation: the data was not theirs to read. Either put '
            'the owner check back, or open that section of the members screen '
            'to every member and rewrite its entry in this file.',
      );
    }
  });

  test('the not-a-violation list is not empty and stays argued', () {
    // Not a threshold somebody picked: each of these is a specific observation
    // this survey made, and the list losing one silently is how a reasoned
    // exception becomes an undocumented difference again.
    expect(notViolationsButLookLikeThem.length, 1);
    for (final entry in notViolationsButLookLikeThem) {
      expect(
        entry.startsWith('FINDING') || entry.startsWith('NOT a violation'),
        isTrue,
        reason:
            'Every entry here says up front which it is: a FINDING (something '
            'that should change) or NOT a violation (something that reads like '
            'one and is not). An entry that says neither is the shape this '
            'list exists to prevent.',
      );
    }
  });
}
