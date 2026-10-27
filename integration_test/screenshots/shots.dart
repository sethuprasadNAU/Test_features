// **The list of images a run must produce, in one place both halves read.**
//
// `capture_test.dart` walks it to take the pictures; `review.dart` — a
// different process, on the host — checks that every name on it arrived as a
// file. That second half is the point of this file existing rather than the
// list living in the test: **a state that silently produces no image is
// exactly what the exit-2 discipline is for**, and before this the only thing
// that could notice a missing image was its own committed predecessor. A
// brand-new state had no predecessor, so on the run that introduced it,
// nothing could tell "captured" from "quietly skipped".
//
// **No Flutter import in this file, deliberately.** `review.dart` runs under
// plain `dart run`, so anything it reads has to be plain Dart.

/// A screen reached by navigating to a route.
///
/// **No duration here any more, and its absence is the point** (`/w-11`).
/// Each shot used to carry the number of seconds to sleep before the shutter,
/// and a sleep cannot tell a finished screen from an unfinished one — see the
/// `map` entry below for what that cost. What a capture waits on now is the
/// state's own readiness condition in `readiness.dart`, and the only number
/// left is a ceiling on patience, which lives beside those conditions.
class Shot {
  const Shot(this.name, this.route);

  final String name;
  final String route;
}

/// **The screens the site may illustrate, photographed on a device with no
/// server configured** — which is the app's default and fully supported state
/// (task 10.2), and the one `/w-02` captured.
///
/// Deliberately not every route in the app. `WEBSITE_PLAN.md` holds back the
/// flows that are still changing, and there is no point committing an image of
/// a screen the guide is forbidden to describe.
///
/// **`/more/projects/join` was dropped from this half by `/w-05`, and its two
/// committed images were deleted by hand.** On a device with no server the
/// projects screen offers no way to reach that route at all, so the picture
/// was of a screen nobody can open, showing the words *"Could not load
/// projects: SyncTransportException(not_configured)"*. A committed screenshot
/// of a state the app cannot produce is the same defect as copy describing a
/// mechanism the code does not have, in picture form. The joined half
/// photographs that screen in the state a person actually meets it in.
///
/// **The map used to carry a 90-second sleep, and `/w-11` deleted it.**
///
/// The sequence is worth keeping because it is this project's oldest defect
/// class wearing map tiles. `/w-09` enriched the fixture, the next run
/// photographed the map, the truth-point panel and everything behind them
/// with *"Downloading terrain… 12/72"* across the bottom and no viewshed
/// overlay at all, **and the run reported "26 of 26 states photographed; no
/// screen threw."** Nothing failed because nothing asserted that a screen had
/// finished. The wait was raised 12s → 90s, which made the pictures right and
/// left the instrument exactly as blind as before.
///
/// **And the reason given for it was wrong** (`/w-11`). The 72 tiles were
/// blamed on the fixture's eight bearings. They are not: the map fetches the
/// terrain disc around the *GPS fix*, sized by `ViewshedConfig.maxRangeMeters`
/// — a fixed 35 km — so at `seedLat`/`seedLon` that is 8 tile rows × 9 tile
/// columns = **72, whatever the fixture holds**. What actually varies is
/// whether the simulator's elevation cache is warm, which `README.md` item 8
/// had already written down. Bringing the fixture from eight bearings to five
/// therefore changes the tile count not at all — which is the clearest
/// possible demonstration that a smaller fixture was never the fix.
///
/// So: no waits in this list. `readiness.dart` holds one condition per state
/// and a ceiling on how long the run will keep asking.
const List<Shot> shots = [
  Shot('map', '/map'),
  Shot('record', '/record'),
  Shot('compass', '/compass'),
  Shot('position', '/position'),
  Shot('more', '/more'),
  Shot('projects', '/more/projects'),
  Shot('project-members', '/more/projects/seed-project-owyhee/members'),
  Shot('tags', '/more/tag-database'),
  Shot('log', '/more/log'),
  Shot('sync-status', '/more/sync-status'),
  Shot('data-export', '/more/data-export'),
  Shot('profile', '/more/profile'),
  Shot('checklist', '/more/checklist'),
  // Task 11.133's new screen, and the guide's answer to "which version are
  // you on?" — the one question a beta tester's report is keyed on. It also
  // carries the full map attributions, including the four words task 11.134
  // added, so a capture of it is what keeps the guide's attribution section
  // from being a hand-copied list.
  Shot('app-info', '/more/app-info'),
];

/// **The three truth-point states** (`/w-07`).
///
/// A truth point is the record of where somebody physically walked in and
/// found the animal or the collar — the yardstick every position estimate is
/// measured against. The log listing already carried one (`log`), which is
/// why there are three names here and not four.
///
/// **None of them is a route**, which is why they are named here and driven
/// by taps in `capture_test.dart`: the Truth tab is a segment on the record
/// screen, the info panel opens by tapping the point on the map, and the
/// correction dialog is a modal over that panel.
///
/// **Photographed on the unconfigured device**, in the same half as `record`
/// and `map`, because nothing about a truth point needs a server — and
/// because the sync surface appearing on two of the guide's truth-point
/// pictures and not the third would read as an inconsistency in the app.
/// **Since task 11.189 that surface is a dot on the More tab and an icon on
/// the map rather than a strip above every screen** (`/w-14`); it is smaller,
/// and the reason is unchanged — the tab bar is on all three.
const List<String> truthPointShotNames = [
  // The form. Today's `record` image is the Directional tab, which has none
  // of these fields — including the precision entry a truth point cannot be
  // saved without.
  'record-truth',
  // The map info panel, whose header task 11.92 renamed and whose Navigate
  // action task 11.92 added. The guide is the first thing to quote that
  // wording.
  'truth-point-panel',
  // The correction dialog (task 11.93), and the one picture that carries the
  // sentence this section exists to correct: **a truth point's position can
  // be changed.** Until 2026-08-31 it could not.
  'truth-point-edit',
];

/// **The Note form** (`/w-16`).
///
/// A Note is the record type for something worth writing down at this place
/// and time that is not a detection at all, and task 11.197 gave it a layout
/// of its own: the notes box is `Expanded`, so it takes every pixel left
/// between the position row and the pinned SAVE NOTE bar instead of being the
/// one-line afterthought field the other record types carry. **That is a
/// different shape of screen, not a taller field**, and until this shot no
/// published picture showed it.
///
/// **Photographed at rest, and `/w-10` measured why the focused state cannot
/// be photographed here at all.** At rest the box fills whatever the screen
/// has left, which is the layout `/w-16`'s own justification describes —
/// *"the box now fills the screen above SAVE NOTE"*. Focused, it stops
/// filling and asks for eight lines while the form scrolls the record type
/// and the tag off the top.
///
/// **`/w-16` declined the focused shot; `/w-13`'s ask said the reason had
/// gone away; it has not, and it is not the reason anybody thought.** Three
/// attempts, three mechanisms, all measured on 2026-09-09 and all refuted:
///
///  1. Keeping Flutter's focus while telling the platform to hide the
///     keyboard **drops the focus too** — the run reported the resting
///     layout, and the two images came back byte-identical.
///  2. Disconnecting the simulator's hardware keyboard so a software one
///     would rise: **no keyboard, bottom view inset 0**.
///  3. The same, with the device shut down and cold-booted so it could not
///     be holding a stale keyboard connection: **inset 0 again**.
///
/// **And a focused picture without a keyboard is not the picture anyway.**
/// Eight lines is taller than what a keyboard leaves and *shorter* than a
/// screen without one, so with nothing taking the bottom of the viewport the
/// form does not scroll, the record type stays on screen and a gap opens
/// above the pinned save bar. That was photographed and looked at: it is a
/// state no person ever sees. **The readiness condition refused all three**,
/// which is the instrument working rather than a nuisance.
///
/// So there is one Note shot, the guide describes the focused layout in
/// words, and **the next task to be told this is now possible should ask what
/// changed about the keyboard rather than about the focus.**
///
/// **Not a route**, so it is driven by a tap in `capture_test.dart`, in half
/// one beside `record-truth`, on the same unconfigured device as `record`.
const List<String> noteShotNames = [
  'record-note',
];

/// **Four screens that print words where they printed database tokens**
/// (`/w-10`, for task 11.199).
///
/// Task 11.199 stopped four surfaces printing a storage spelling at a
/// biologist — `directional`, `omnidirectional`, `regular_pulse`, `lost` —
/// and replaced each with the word a person reads everywhere else in the app.
/// **No picture had ever existed of any of the four.** That is not the same
/// as a set of pictures that came back unchanged: with no baseline the
/// comparison cannot say a screen did not move, it can only fail to look. An
/// assertion by absence is exactly what `review.dart`'s MISSING check exists
/// to stop, and four states with no image at all slipped past it because a
/// state nothing captures is a state nothing misses.
///
/// Three of the four are in half one; the fourth needs a project this device
/// does not own, so it lives with the joined states below.
///
/// **None of them is a plain route.** The preview card appears only once a
/// payload has been parsed, the supersede picker is a dialog over a row menu,
/// and the project's tag list is below the fold on a phone — so all three
/// are driven by taps in `capture_test.dart`.
const List<String> plainWordsShotNames = [
  // **The paste screen's preview card.** `Type: directional` became
  // `Type: Bearing`, and `Signal: regular_pulse · medium · ✓ Good` lost the
  // mode token altogether — the pulse mode is named on its own line above,
  // and printing the legacy `signal_type` beside it was one fact described
  // twice with the wrong word available. The payload is encoded by the app's
  // own `ObservationShare.encode` from a seeded colleague's bearing, so this
  // picture cannot drift from the format the Log screen's Share writes.
  'paste-preview',
  // **The project's own tag list, `More → Tags`.** A tag whose status is not
  // `active` gets that status as its subtitle; it used to read `· lost` and
  // reads `· Lost`. `seedTagLost()` is the fixture row that makes this
  // reachable at all — every other seeded tag is active and draws no
  // subtitle.
  //
  // **Named `project-tags`, not `project-setup-tags` (`/w-13`, 2026-09-18).**
  // Task 11.245 moved a project's tags off Project Setup entirely, onto this
  // screen of their own; the old name described a screen that no longer
  // exists. `project-tags-viewer` below is the same screen seen by a
  // non-owner — this is the owner's own view.
  'project-tags',
  // **The Log screen's supersede picker, with the list of candidates open.**
  // A candidate with no bearing is labelled by its record type, and that
  // label used to be the stored `omnidirectional`. The dropdown has to be
  // *open* for the rows to be in the picture, which is why this is not simply
  // a shot of the dialog.
  'log-supersede',
];

/// **The bearing tip-drag gesture** (`/w-10`, for task 11.131).
///
/// Tap a bearing to select it, press and hold the handle at its tip, and drag
/// radially: the ray and its uncertainty wedge extend live and a readout names
/// the drawn length.
///
/// **These two images carry more weight than any others on this site.**
/// Nothing on the map says a bearing can be dragged, and the handle — the
/// whole of the discoverability — appears only once a bearing is selected.
/// That is a deliberate choice about the map's space budget, and its cost is
/// that a reader who does not learn the gesture from the guide does not learn
/// it. So there are two pictures rather than one: the handle, and the gesture
/// in progress with the readout showing.
///
/// **Photographed on the unconfigured device**, at the end of half one, for
/// the reason the truth-point states are: no sync surface at all, matching
/// the other map pictures. They are last in that half because a dragged length persists
/// until the map screen is left, and no later capture is of the map.
const List<String> bearingDragShotNames = [
  'bearing-selected',
  'bearing-dragged',
];

/// **The states of a configured, joined, syncing device** (`/w-05`).
///
/// Not routes: several of these are one route in different states, reached by
/// typing a code and tapping a button, so the sequence lives in
/// `capture_test.dart` and only the names live here. They are listed in the
/// order the run produces them, which is also the order the guide walks them.
///
/// **Why these are separate images rather than replacements.** A device with
/// no server shows no sync surface at all, so configuring one moves pixels on
/// every screen above — **still true after task 11.189 removed the bar, by a
/// different mechanism** (`/w-14`): the coloured dot goes on the More *tab*,
/// which is in the navigation bar of every screen in the shell. Recapturing the fourteen under a server would have
/// meant re-accepting all fourteen and losing the unconfigured state the guide
/// still needs — the app works with no server and the guide says so. So both
/// states are committed, and the `joined-` / `owner-` / `join-` prefixes say
/// which is which to somebody picking an image out of a directory.
const List<String> joinedShotNames = [
  // The requester's side, in the order a person meets it.
  'joined-projects',
  'join-code-entered',
  'join-waiting',
  'join-downloading',
  'join-arrived',
  // **The joined project's own tag list, as a non-owner sees it**
  // (`/w-13`, item 5, from task 11.198). The seeded fixture had no badged
  // tag and always photographed an owner, so a tag's status badge had never
  // appeared in any published picture — task 11.198 fixed its colour by
  // measurement, unable to look at it. This is a contributor's own view of
  // the *other* project's tags.
  //
  // **Named `project-tags-viewer`, not `tag-database-viewer`, since `/w-18`
  // (task 11.219).** It used to be photographed on the Tag Database screen,
  // with a padlock beside the row a non-owner could not edit. Task 11.219
  // removed the padlock and moved the row: the Tag Database screen shows
  // this device's own tag *library* now, which never held this tag at all —
  // it was created on a different device and arrived only as this project's
  // own copy.
  //
  // **Shot on `More → Tags`, not Project Setup, since `/w-13` (2026-09-18).**
  // Task 11.245 moved a project's own tags off Project Setup entirely; the
  // route this capture drove was never updated and threw on every profile
  // until it was. See the same-name entry in `plainWordsShotNames` above for
  // the owner's view of this screen.
  'project-tags-viewer',
  // **Tag details, read-only** (`/w-10`, for task 11.199 — the fourth of its
  // four screens, and the one that cannot be reached in half one). Tapping a
  // tag this account may not edit no longer refuses and stops: it opens the
  // details page with the refusal as its banner, and prints the tag's status
  // as a word where an owner gets a wheel. That printed word was
  // `TagStatus.db` — the SQLite spelling — until 2026-09-08. It needs a
  // project somebody else owns, so it is here rather than beside the other
  // three.
  'tag-details-readonly',
  // The owner's side. **Two images, not three, and the reason is a measured
  // one.** The members list, the three roles and the join code all fit above
  // the fold on both profiles, so a separate "here is the code" shot came out
  // byte-identical to this one — three names over two states, which is a
  // manifest that lies about what was photographed.
  'owner-members-and-code',
  'owner-pending-request',
  // **What an owner is asked when they say yes** (`/w-03`). Added after
  // `/w-05` named it the biggest remaining hole in the join story: the run
  // could show *that* an owner approves and not *what they are asked* — the
  // role, and the disclosure that removing somebody later cannot take back
  // what their device already holds. It is a modal, not a route, which is
  // why it is reached by a tap in `capture_test.dart` rather than listed
  // among `shots` above.
  'owner-approval-sheet',
  // Sync, configured rather than unconfigured.
  //
  // **`joined-sync-indicator`, renamed from `joined-sync-bar` by `/w-14`.**
  // Task 11.189 deleted the coloured strip above every tab, so a picture of
  // the Record screen is now a picture of a screen with no sync surface on it
  // at all. The surface that replaced it is a 28-pixel icon above the "+" on
  // the Main Map, so that is the screen this shoots. The name changed with
  // the subject rather than being left to describe a thing the app no longer
  // draws — a committed image whose name says "bar" is the picture-shaped
  // version of copy describing a mechanism the code does not have.
  'joined-sync-indicator',
  'joined-sync-status',
];

/// **What the app says when sync has gone wrong** (`/w-10`, `/w-12`, `/w-14`).
///
/// **These four are captures of `/more/sync-status`, not of `/record`, since
/// `/w-14`.** They were pictures of the sync bar, and the bar is gone (task
/// 11.189). The sentence each of them exists to show now reaches a sighted
/// person in exactly one place — the Sync Status screen, one tap from the
/// icon on the map — so that is the screen photographed. The icon itself is
/// shown once, healthy, by `joined-sync-indicator` above; four full-screen
/// maps with a differently-coloured 28-pixel disc on each would teach a
/// reader nothing the caption did not already say.
///
/// Task 11.97 made four of the bar's failure states drivable from a
/// substituted server. `/w-10` drove all four but could photograph none of
/// them, because completing a `SyncEngine` round tripped a debug-build
/// assertion that ended the run. Task 11.144 fixed that — a provider deriving
/// from another provider, not the mechanism either report guessed — and
/// `/w-12` photographs the four with the fix in place.
///
/// **Listed in the order their `SyncHealth` ranking requires**, so a later
/// round's picture replaces an earlier one's without having to undo it: a
/// held record outranks a merely-missing one, and losing this project
/// outranks everything. See `joined.dart` for the driving code and why this
/// order is load-bearing rather than cosmetic.
const List<String> syncFailureShotNames = [
  'sync-offline',
  'sync-records-missing',
  'sync-records-held',
  'sync-removed',
];

/// **The three sheets over the Position tab** (`/w-32`, asked for by `/w-31`).
///
/// The cautions sheet, the legend card and the past-estimates sheet. None is a
/// route; each is one tap on the Position screen the route loop has already
/// photographed. They are in half one because nothing about them needs a
/// server. **Nothing is saved or changed**: the seeded Sage estimate is what
/// the past-estimates sheet lists, and each sheet is closed again.
const List<String> positionSheetShotNames = [
  'position-cautions',
  'position-legend',
  'position-past-estimates',
];

/// **Tags, animals and Quick add** (`/w-32`, from tasks 11.321 and 11.322).
///
/// *Link a tag* gained a picker (this project's free tags, the Tag Library's
/// tags the project does not hold, *New tag…*) and a confirmation carrying the
/// *Tag went on* date card; Animals gained *Quick add*, a form of rows and a
/// review of what each row would do. **Nothing is saved**: both flows are
/// walked to the screen that asks, photographed, and backed out of, and the
/// animal, library tag and today's date they need are written for the run and
/// removed after.
const List<String> tagFlowShotNames = [
  'link-tag-picker',
  'link-tag-confirm',
  'quick-add',
  'quick-add-review',
];

/// **Take on map** (`/w-32`, the guide's newest feature and the one Michael
/// singled out): the screen with today's earlier bearings drawn to the edge and
/// the phone's pointing line, and the same screen after a sweep is released,
/// with Cancel, Retake and Confirm. The Record screen with the round map button
/// beside RANGE is the ordinary `record` shot.
///
/// **A simulator has no compass, so the harness scripts one**: see
/// `take_on_map.dart`.
const List<String> takeOnMapShotNames = [
  'take-on-map',
  'take-on-map-released',
];

/// **Deleting a project, from the owner's side and the member's** (`/w-32`, for
/// `/w-27`). The first *Delete permanently…* dialog, a Projects row counting
/// down, the *Trash* section, and the
/// Sync Status screen of a project the server has destroyed.
///
/// All four are driven against the in-memory fake server's own deletion
/// states, which already existed: nothing was added under `test/`.
const List<String> deletionShotNames = [
  'delete-project-dialog',
  'projects-countdown',
  'projects-deleted-section',
  // The ⋮ menu on a Trash row (`/w-35`, for task 11.324's re-shoot list): the
  // one place *Delete permanently…* is offered once a project is in the Trash.
  'projects-trash-menu',
  'sync-project-deleted',
];

/// **App Info's *TriTrack support* section** (`/w-35`, for task 11.324's
/// re-shoot list). The section is below the fold on every profile, so the
/// `app-info` route shot shows only its heading; this is the same screen
/// scrolled to *Contact TriTrack support*, the link every "tell TriTrack
/// support" sentence in the app leads to. In half one, beside `app-info`.
const List<String> appInfoShotNames = [
  'app-info-support',
];

/// **Setting up a project** (`/w-35`, for the guide's *Setting up a project*
/// page). The Offline Data Map with a selection drawn; the *New Project* form
/// with its extent and time zone (task 11.331); and the *Finish setting up*
/// sheet that follows *SAVE PROJECT* on a new project (task 11.324).
///
/// **Last in the run, in the joined half, on purpose.** Saving the form really
/// creates a project, which every later picture of Projects would show; at the
/// end there is no later picture. Signed in, the sheet shows both of its
/// choices (publish and maps), which is the version a crew lead meets.
/// *Later* is tapped, so nothing is published or downloaded.
const List<String> setupShotNames = [
  'offline-data-selection',
  'new-project-form',
  'finish-setting-up',
];

/// Every image a complete run must produce.
List<String> get expectedScreenshotNames => [
      for (final shot in shots) shot.name,
      ...appInfoShotNames,
      ...truthPointShotNames,
      ...noteShotNames,
      ...plainWordsShotNames,
      ...bearingDragShotNames,
      ...joinedShotNames,
      ...syncFailureShotNames,
      ...positionSheetShotNames,
      ...tagFlowShotNames,
      ...takeOnMapShotNames,
      ...deletionShotNames,
      ...setupShotNames,
    ];

/// The first name that appears twice, or null.
///
/// **A duplicate is a hard error, not a last-write-wins.** Two shots sharing a
/// name would have the second silently overwrite the first's file, and the
/// review would report one image where two states were photographed —
/// the same shape as the defect task 11.91 found in `attack()`, where two
/// unrelated checks keyed on the same typed description and one erased the
/// other's result.
String? duplicateShotName() {
  final seen = <String>{};
  for (final name in expectedScreenshotNames) {
    if (!seen.add(name)) return name;
  }
  return null;
}
