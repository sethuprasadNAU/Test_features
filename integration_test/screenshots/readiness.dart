// **What "the screen had finished" means, screen by screen.**
//
// Until `/w-11` this harness had no idea what a finished screen was. It
// navigated, slept for a number somebody had typed, and fired the shutter.
// The number was 3 seconds for most screens, 12 for the map, and on
// 2026-09-02 the map needed longer than 12 — so the run photographed the map
// and the truth-point panel with *"Downloading terrain… 12/72"* across the
// bottom and no viewshed overlay at all, **and reported "26 of 26 states
// photographed; no screen threw."** Nothing failed, because "the screen had
// finished" was not part of what anything asserted. A person looking at the
// images is what caught it.
//
// The repair is not a bigger number. A duration is a guess about how long a
// machine will take; it is wrong on a slower connection, wrong on a colder
// cache, and wrong again the next time anything about the fixture or the app
// changes — and **it is wrong silently, which is the part that matters.**
// This file replaces the guess with a question each screen can answer about
// itself: *is the thing this picture is of actually on screen yet?*
//
// So a capture now has two numbers and one question:
//
//  * the **question** — a [ReadinessCheck] for that state, below;
//  * a **poll interval**, how often the question is asked;
//  * a **ceiling**, the longest the run will keep asking before it gives up
//    and records a capture error. **The ceiling is not a duration to wait.**
//    A state that is ready in 900 ms is photographed at 900 ms even though
//    its ceiling is two minutes; a state that is still not ready at the
//    ceiling produces a red rather than a photograph of a progress bar.
//
// **What a check must be.** It returns `null` when the state is ready, and
// otherwise a short phrase naming *what it is still waiting for* — that
// phrase is what the run prints when patience runs out, and it is the whole
// difference between "the map screen timed out" and "the map screen never
// drew a viewshed overlay; the status bar still said Downloading terrain".
//
// **Why the checks lean on the app's own loading affordances.** Every
// asynchronous screen in this app draws a `CircularProgressIndicator` while
// its data is in flight, and the two long computations (viewshed, position
// solve) drive `computationStatusProvider`, which is the bottom bar the bad
// pictures had across them. Those are the app's own statements that it is not
// finished, so the checks read them rather than inventing a parallel notion of
// busy. `test/support/app_shell_harness.dart` already settles the widget suite
// the same way; this is that idea on a real device.
//
// **Where the checks touch user-visible copy they use short fragments, on
// purpose.** A check keyed to a whole sentence would go red the next time
// somebody rewords it, which is a real cost paid for no information — the
// drift check and `/w-10` are what watch copy. A fragment is enough to tell
// "the card that says the download started is on screen" from "it is not".

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show FlutterMap, TileImage;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tritrack/core/providers/computation_status_provider.dart';
import 'package:tritrack/features/more/screens/project_members_screen.dart'
    show removalDisclosure;

import 'package:tritrack/core/text/tag_status_labels.dart'
    show tagStatusLabel;
import 'package:tritrack_sync/tritrack_sync.dart'
    show RecordType, TagStatus, formatJoinCode;

import 'harness.dart'
    show currentScreen, fakeMagneticHeadingDeg, isOnScreen, recordCaptureError, settle;
import 'joined.dart';
import 'seed.dart';
import 'shots.dart';
import 'take_on_map.dart' show sweepStartDeg, takeOnMapLineCount;

/// What a check is handed: the live tree, and the app's own providers.
class ReadinessProbe {
  ReadinessProbe(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  /// [text] is wholly inside the visible window — not merely in the tree.
  /// A `ListView` builds children below the fold, and a check satisfied by
  /// one of those would call a screen ready on the strength of something
  /// nobody can see in the picture.
  bool showsText(String text) => isOnScreen(tester, find.text(text));

  /// A short fragment of a longer string, anywhere in the tree.
  ///
  /// Existence rather than visibility, deliberately: these are used to
  /// identify *which state* a card or panel is in, and the card is what the
  /// shot is framed on.
  bool hasTextContaining(String fragment) =>
      find.textContaining(fragment).evaluate().isNotEmpty;

  /// A widget by the name of its run-time type.
  ///
  /// By name because several of the interesting ones are private to their own
  /// library — `capture_test.dart` already finds the truth-point marker this
  /// way — and because it costs no import for the public ones.
  int countWidgets(String runtimeTypeName) => find
      .byWidgetPredicate((w) => w.runtimeType.toString() == runtimeTypeName)
      .evaluate()
      .length;

  bool hasWidget(String runtimeTypeName) => countWidgets(runtimeTypeName) > 0;

  /// The app's own "I am loading" affordance, anywhere a tap could reach.
  bool get isSpinning =>
      find.byType(CircularProgressIndicator).hitTestable().evaluate().isNotEmpty;

  /// The shared bottom progress bar's state — the one that read
  /// "Downloading terrain… 12/72" in the pictures this file exists to stop.
  ComputationStatus get computation =>
      container.read(computationStatusProvider);

  /// The label of whatever long computation is running, or null.
  String? get runningComputation {
    final status = computation;
    return status is ComputationRunning ? status.label : null;
  }
}

/// Null when the state is ready; otherwise what it is still waiting for.
typedef ReadinessCheck = String? Function(ReadinessProbe probe);

/// The first unmet condition, or null when they are all met.
///
/// Ordered on purpose: the phrase the run prints is the *first* thing missing,
/// which is nearly always the most informative one.
ReadinessCheck allOf(List<ReadinessCheck> checks) => (probe) {
      for (final check in checks) {
        final unmet = check(probe);
        if (unmet != null) return unmet;
      }
      return null;
    };

/// Nothing on this screen is still loading.
String? _notSpinning(ReadinessProbe probe) =>
    probe.isSpinning ? 'a loading spinner is still on screen' : null;

/// No long computation is running — the bottom progress bar is not showing.
String? _notComputing(ReadinessProbe probe) {
  final label = probe.runningComputation;
  return label == null ? null : 'the status bar still says "$label"';
}

/// Nothing anywhere in the app is still decoding an image.
///
/// **The map found this one, and it is the same defect one layer in.** The
/// first version of this file called the map ready when flutter_map's
/// `OverlayImageLayer` was in the widget tree and the status bar was quiet —
/// and photographed a map with no viewshed on it, twice, byte-identically.
/// The layer was there; its `MemoryImage` had not finished decoding. **A
/// widget existing is not a widget drawn**, which is exactly the distinction
/// `isOnScreen` was written for a month earlier, one level up.
///
/// `pendingImageCount` is the framework's own answer, and it covers the map
/// tiles as well as the overlay: every one of them goes through the shared
/// image cache. So this is not "wait a bit longer for the picture to appear",
/// it is "the picture has appeared".
String? _noImagesDecoding(ReadinessProbe probe) {
  final pending = PaintingBinding.instance.imageCache.pendingImageCount;
  return pending == 0
      ? null
      : '$pending image(s) are still being decoded, so what is on screen is '
          'not yet what this screen draws';
}

/// **Every basemap tile the map pane covers has arrived and been drawn.**
///
/// **`_noImagesDecoding` is not this check and cannot stand in for it.**
/// `pendingImageCount == 0` is true when every requested image has finished —
/// and it is equally true **before the first tile has been requested**, which
/// is the state a freshly-built map pane is in for its first few hundred
/// milliseconds. Bolting that condition onto a screen whose map has not
/// started fetching passes immediately and files a photograph of an empty
/// grey rectangle under a green readiness line. That is exactly what `'map'`
/// avoids by *also* requiring `OverlayImageLayer` to be in the tree: a widget
/// that only exists once there is something to draw.
///
/// The Position screen has no overlay, so it needs the tiles themselves as
/// its evidence. flutter_map builds one `Tile` widget per tile the camera
/// covers, each holding a [TileImage] that is a model of that tile's
/// progress: `imageInfo` is non-null once the bytes are decoded, and
/// `loadError` is set when the fetch failed and never will be.
///
/// **What is asserted is coverage, not a count, and the first version of this
/// check got that wrong.** Counting drawn tiles against tiles *asked for*
/// took the Position shot's run-to-run difference from 15.61% to 0.21% and
/// left it there: two runs came back pixel-identical and a third was short a
/// sliver of one tile at the top right corner, because the set of `Tile`
/// widgets is itself something the map grows — a tile the camera has not
/// asked for yet is not an undrawn tile, it is not a tile at all, and no
/// arithmetic over the tiles present can see the one that is missing. **A
/// check that reads only what exists cannot notice what does not.**
///
/// So this measures the thing the picture is actually about: the union of the
/// rectangles the drawn tiles occupy, against the rectangle `FlutterMap`
/// occupies. Every logical pixel of the pane has a drawn tile behind it, or
/// the check says how many are short and on which edge.
///
/// **It cannot pass vacuously**, and that is the whole design. No map is a
/// named failure; no tiles is a named failure; tiles that do not reach the
/// edges is a named failure. The three ways this could be satisfied by
/// measuring nothing are the three phrases it returns.
///
/// `Tile` is private to flutter_map's own library — only [TileImage] is
/// exported — so the widget is found by the name of its run-time type, the
/// way this file already finds `OverlayImageLayer` and `_PanelHeaderRow`, and
/// its `tileImage` is read dynamically. If flutter_map ever renames that
/// class the count goes to zero, which is a refusal and not a silent pass.
String? _basemapTilesDrawn(ReadinessProbe probe) {
  final map = find.byType(FlutterMap);
  if (map.evaluate().isEmpty) return 'there is no map on this screen at all';
  final pane = probe.tester.getRect(map.first);

  var total = 0;
  var failed = 0;
  Rect? covered;
  for (final element in find
      .byWidgetPredicate((widget) => widget.runtimeType.toString() == 'Tile')
      .evaluate()) {
    total++;
    final image = (element.widget as dynamic).tileImage as TileImage;
    if (image.imageInfo == null) {
      if (image.loadError) failed++;
      continue;
    }
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    covered = covered == null ? rect : covered.expandToInclude(rect);
  }

  if (total == 0) {
    return 'the map pane has not asked for a single basemap tile yet, so it '
        'is an empty grey rectangle';
  }
  if (covered == null) {
    return 'none of the $total basemap tiles the map pane asked for has been '
        'drawn'
        '${failed == 0 ? '' : ', and $failed of them failed to load'};'
        ' the pane is empty grey';
  }
  // Half a logical pixel, because a tile grid lands on fractional offsets and
  // an exact comparison would fail on rounding rather than on a gap.
  const slack = 0.5;
  final short = <String>[
    if (covered.left > pane.left + slack)
      '${(covered.left - pane.left).round()} on the left',
    if (covered.top > pane.top + slack)
      '${(covered.top - pane.top).round()} on the top',
    if (covered.right < pane.right - slack)
      '${(pane.right - covered.right).round()} on the right',
    if (covered.bottom < pane.bottom - slack)
      '${(pane.bottom - covered.bottom).round()} on the bottom',
  ];
  if (short.isNotEmpty) {
    return 'the basemap tiles drawn so far leave ${short.join(', ')} logical '
        'pixels of the map pane uncovered'
        '${failed == 0 ? '' : ' ($failed tile(s) failed to load)'}';
  }
  // **Said out loud on success, not only on failure.** The count is the
  // denominator behind "the map pane is finished", and a number that only
  // appears when something is wrong is a number nobody can watch change.
  // ignore: avoid_print
  print('SCREENSHOT HARNESS: $total basemap tile(s) cover the '
      '${pane.width.round()}x${pane.height.round()} map pane');
  return null;
}

/// **The viewshed is deliberately absent from this picture** (`/w-30`).
///
/// The purple "visible from here" overlay covered most of the map in every
/// Map-tab picture and competed with the bearings those pictures exist to
/// show, so `map_framing.dart` waits for it to finish computing and then
/// switches it off. **This is the other half of that decision, and it is here
/// so the decision cannot rot into an accident:** a picture filed under one of
/// these names with the overlay back in it is a picture whose framing was
/// chosen for a map without one. `OverlayImageLayer` is flutter_map's own
/// widget, and the app builds it only while the viewshed is being drawn.
String? _viewshedOut(ReadinessProbe probe) => probe.hasWidget('OverlayImageLayer')
    ? 'the viewshed overlay is still drawn, in a picture that leaves it out'
    : null;

ReadinessCheck _showing(String text, {String? describedAs}) => (probe) =>
    probe.showsText(text) ? null : '${describedAs ?? '"$text"'} is not visible';

ReadinessCheck _containing(String fragment, {required String describedAs}) =>
    (probe) => probe.hasTextContaining(fragment)
        ? null
        : '$describedAs is not on screen';

/// Like [_containing], but the match has to be **wholly inside the window**.
///
/// The difference matters wherever the subject of a picture is a card or a
/// list that can run off the bottom: existence says the app built it, and only
/// visibility says the camera will see it. Used where the framing is part of
/// what the shot claims.
ReadinessCheck _visibleContaining(String fragment,
        {required String describedAs}) =>
    (probe) => isOnScreen(probe.tester, find.textContaining(fragment).last)
        ? null
        : '$describedAs is not in frame';

ReadinessCheck _widget(String runtimeTypeName, {required String describedAs}) =>
    (probe) =>
        probe.hasWidget(runtimeTypeName) ? null : '$describedAs is not drawn';

/// The owner's own name, as `displayName` composes it for the members list.
final String _ownerDisplayName =
    '${seedOwner().firstName} ${seedOwner().lastName}';

/// **One readiness condition per captured state.**
///
/// Keyed by the same names `shots.dart` publishes, so `capture_test.dart` can
/// look one up by the name it is about to file the image under. A key that
/// matches no state is a hard error — see [unknownReadinessKeys] — because a
/// typo here would silently leave a screen with no condition at all, which is
/// the state this whole file exists to make impossible to have by accident.
final Map<String, ReadinessCheck> readinessByState = {
  // ---- The thirteen route screens ---------------------------------------

  // **The one that started this.** With a GPS fix the map computes a viewshed
  // on open; on a cold elevation cache that means fetching the 72 terrain
  // tiles covering the viewshed's 35 km disc, at roughly one a second. The
  // committed image shows the finished overlay, so the finished overlay is
  // what "ready" means — `OverlayImageLayer` is flutter_map's own widget and
  // the map only builds it when `_viewshedIsRendered()` is true.
  //
  // **Since `/w-30` the overlay is the thing the run waits for and then
  // switches off** — see `map_framing.dart`. Waiting for it to *finish* is
  // still the evidence the terrain download is over; what the picture shows
  // is the map without it, framed on the day's bearings.
  'map': allOf([
    _notComputing,
    _viewshedOut,
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),

  // The record form, on its Directional tab: the save button names the record
  // type, so it is also what says which tab is showing.
  'record': allOf([_notSpinning, _showing('SAVE OBSERVATION')]),

  // The compass has no data to load — what it waits for is the *sensor
  // stream*. `fakeMagneticHeadingDeg` is 47, and the magnetic readout shows
  // "—" until the first sample arrives, so the number appearing is the exact
  // moment the dial means anything.
  'compass': _showing('${fakeMagneticHeadingDeg.round()}°',
      describedAs: 'the magnetic heading readout'),

  // Position estimation: the bearings panel is inside the branch that only
  // builds once this tag's observations have loaded, and the solve drives the
  // same status bar the map does.
  //
  // **The tile conditions are `/w-16`'s, and the two runs that asked for them
  // are the argument.** `/w-15` measured this shot moving **16.15%** of its
  // pixels on one run and **5.61%** on the next with nothing in between
  // touching the screen, and the map pane was nearly all blank grey in both:
  // what varied was how many basemap tiles had arrived before the shutter.
  // The three conditions above are all satisfied within a second of the
  // screen being built, long before the map has fetched anything, so this
  // shot's number could not be read as how much the Position screen had
  // changed. **The iPad's Position map draws completely and its diff was a
  // stable 0.13% twice**, which is what said the defect was the capture and
  // not the screen.
  'position': allOf([
    _notSpinning,
    _notComputing,
    _widget('_PanelHeaderRow', describedAs: 'the bearings panel'),
    // **Ordered so the tile count is asked last**, once nothing is still
    // decoding — a tile whose bytes are in flight is reported by the line
    // above rather than counted as undrawn by the one below, and the count
    // that gets printed is therefore the settled one.
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),

  // A static menu, but it is drawn inside the same shell as everything else;
  // the spinner check is what says the shell above it has resolved.
  'more': _notSpinning,

  // The project list, with the seeded project's real name on it. The name is
  // long enough to be ellipsised on a phone — `find.text` reads the string the
  // widget was given, not the pixels, so that is fine and is the point.
  'projects': allOf([
    _notSpinning,
    _containing('Owyhee Uplands Kit Fox',
        describedAs: 'the seeded project'),
  ]),

  // The members list, populated: the owner's name is the row that is always
  // there.
  //
  // **The spinner check is back, and the reason it was ever off was wrong**
  // (`/w-10`, from task 11.142). `/w-11` took it out saying this screen's
  // "Join code" and "Waiting to join" sections *"spin forever — their
  // providers never resolve"*. They resolve immediately: both fail with
  // `not_configured` the moment they are read on a device with no server.
  // What span twenty seconds was **this harness**, whose `ProviderContainer`
  // was built with no `retry:` and so ran Riverpod's default of ten attempts
  // over 38.2 seconds where the app runs `appRetryPolicy` and gives up in
  // 1.6. The container now takes the app's policy (see `harness.dart`), the
  // two sections render their own explanation well inside a shutter's
  // patience, and this screen can be asked the same question as every other:
  // is anything still loading?
  //
  // Task 11.142 also gave those two sections a sentence saying *why* they are
  // empty rather than a bare failure, which is what makes the picture worth
  // publishing at all.
  'project-members': allOf([_notSpinning, _showing(_ownerDisplayName)]),

  'tags': allOf([_notSpinning, _containing('Sage', describedAs: 'a tag row')]),

  'log': allOf([_notSpinning, _containing('Sage', describedAs: 'a log row')]),

  'sync-status': _notSpinning,

  'data-export': _notSpinning,

  // The profile form fills its fields from the loaded user; the address is
  // what it is filled *with*, so it is the evidence the load finished.
  'profile': allOf([
    _notSpinning,
    _containing(seedOwner().email, describedAs: "this device's own address"),
  ]),

  'checklist': _notSpinning,

  // App Info reads its version from the platform rather than from a constant
  // (task 11.133), so there is a moment where it honestly says it is still
  // reading. **That moment is what this check is for**: the whole point of the
  // screen is a version somebody pastes into a bug report, and a picture of
  // the word before the number would be a guide showing an empty field.
  'app-info': allOf([
    _notSpinning,
    (probe) => probe.hasTextContaining('Reading…')
        ? 'the version is still being read from the platform'
        : null,
    _containing('Map data and imagery',
        describedAs: 'the map attributions'),
  ]),

  // ---- The three truth-point states --------------------------------------
  //
  // These carry the assertions `capture_test.dart` already made just before
  // each shutter. They were right and they stay — moved here so that they are
  // *waited for* rather than checked once at whatever moment the sleep ended.

  'record-truth': allOf([
    _notSpinning,
    _showing('PRECISION'),
    _showing('SAVE TRUTH POINT'),
  ]),

  // ---- The Note form (`/w-16`) -------------------------------------------
  //
  // **The condition is the height, because the height is the whole subject.**
  // On a Note the notes box is not a taller version of the field the other
  // record types carry — it is `Expanded`, so it takes every logical pixel
  // left between the position row and the pinned SAVE NOTE bar (task 11.197).
  // A picture of this screen taken one frame early, or on a form that has not
  // switched record type yet, is a picture of the ordinary one-line box with
  // the wrong caption under it.
  //
  // **A ratio rather than a pixel count, so the same condition is true on all
  // three profiles.** The box the other record types draw is one line at rest
  // and four while it is being written; none of those is anywhere near a
  // quarter of the window on any phone this harness photographs, and the
  // filling box is far past it. The measured height goes into the phrase this
  // check returns, so a failure says what it found rather than only that it
  // was unhappy.
  'record-note': allOf([
    _notSpinning,
    _showing('SAVE NOTE'),
    (probe) {
      final field = find.byKey(const ValueKey('record-notes-field'));
      if (field.evaluate().isEmpty) return 'there is no notes box on screen';
      final box = probe.tester.getRect(field.first);
      final window = probe.tester.view.physicalSize.height /
          probe.tester.view.devicePixelRatio;
      if (box.height < window * 0.25) {
        return 'the notes box is ${box.height.round()} logical pixels tall in '
            'a ${window.round()}-pixel window, which is the ordinary field '
            'every other record type draws rather than the one that fills the '
            'screen';
      }
      return null;
    },
  ]),

  // ---- Words where there were database tokens (`/w-10`, task 11.199) -----
  //
  // Each of these waits for **the word the task changed**, not merely for the
  // screen. A condition satisfied by the surrounding furniture would be
  // satisfied just as well by the token these three exist to show the end of,
  // which is the comparison-between-two-things-that-fail-identically shape.

  // The card the paste screen draws once a payload parses. `Type: Bearing` is
  // built from `RecordType.directional.label` at the call site, and read from
  // the same place here, so a rename moves both rather than reddening this.
  'paste-preview': allOf([
    _notSpinning,
    _containing('Observer:', describedAs: 'the pasted record preview card'),
    _containing('Type: ${RecordType.directional.label}',
        describedAs: "the preview card's record-type line"),
    // **The last line of the card, and visibility rather than existence.**
    // The card is the bottom of a `ListView`; a picture of its top half under
    // this name would be a picture of a preview that had not been read. The
    // `Signal:` line is the card's final row for a record with no notes,
    // which is what the seeded payload is.
    _visibleContaining('Signal:',
        describedAs: "the bottom of the preview card"),
  ]),

  // `More → Tags`, the project's own tag list (`/w-13`, 2026-09-18: renamed
  // from `project-setup-tags` when task 11.245 moved this list off Project
  // Setup). `Lost` is the subtitle `seedTagLost()` exists to put on screen.
  // Visibility rather than existence throughout: the row is below the fold
  // on a phone until the run scrolls to it, and a check that accepted its
  // mere existence would pass on a picture of the top of the screen.
  'project-tags': allOf([
    _notSpinning,
    // **A fragment, because the row's title is one `Text`** holding the
    // frequency and the name together — `find.text('Ridgeline')` matches
    // nothing on this screen, which is how the first run of this state
    // reported it.
    _visibleContaining('Ridgeline',
        describedAs: "the lost tag's row"),
    // **A fragment here too, since schema v17's animals-and-deployments seed
    // (`/w-13`, 2026-09-18).** Every seeded tag is now worn by an animal of
    // its own name, so this row's subtitle is one `Text` reading "Worn by
    // Ridgeline · Lost" — `_showing` (exact match) stopped matching the bare
    // word and this condition could never become true, on any profile.
    _visibleContaining(tagStatusLabel(TagStatus.lost),
        describedAs: "the lost tag's status subtitle"),
  ]),

  // The supersede dialog **with its candidate list open** — the rows are the
  // subject, and they exist only while the dropdown menu is showing. `Omni`
  // is the label a candidate with no bearing gets, read from the same
  // `RecordType` the screen reads.
  'log-supersede': allOf([
    _showing('Superseded by which record?'),
    // **Not "is the word `Omni` in the tree"** — a `DropdownButton` builds
    // every one of its items inside the closed field in order to size itself,
    // so that question is answered yes with the list shut. What is only ever
    // true while the menu is open is the menu's own item buttons, which live
    // in the route it pushes. Matched by prefix because the type is generic
    // and its full name carries the argument.
    (probe) => find
            .byWidgetPredicate((w) => w.runtimeType
                .toString()
                .startsWith('_DropdownMenuItemButton'))
            .evaluate()
            .isEmpty
        ? 'the replacement list is not open, so the candidate rows this shot '
            'is of are not on screen'
        : null,
    // **Existence, and the reason is a defect this shot found on its first
    // run.** A candidate row reads `<when> · <who> · <bearing or record
    // type>`, ellipsised — and on a phone the first two fields use the whole
    // width, so the third is drawn as a single letter and a dot. The word is
    // in the tree; it is not on the glass. Asserting visibility here would
    // spend the ceiling on something the app cannot currently show, and
    // asserting it as though it were legible would be this file claiming a
    // coverage it does not have.
    //
    // **So this baseline does not cover task 11.199's record-type label**,
    // and saying so is the point: if that word changed, these pixels would
    // not. The truncation is reported to the code lane — the field that
    // distinguishes one candidate from another is the one being cut.
    _containing(RecordType.omnidirectional.label,
        describedAs: 'a candidate row for the record with no bearing'),
  ]),

  // Photographed over the map, so it inherits the map's own condition: a
  // panel drawn over a half-downloaded map is the picture `/w-09` shipped.
  'truth-point-panel': allOf([
    _notComputing,
    _viewshedOut,
    _noImagesDecoding,
    _basemapTilesDrawn,
    // **The card itself, then its title** (`/w-32`, from task 11.319). This
    // used to be the title as text alone, and task 11.319 put a kind word in
    // front of the map's marker labels ("Truth · Sage · …") precisely so a
    // label could never satisfy it — but a check that finds a card by what it
    // says is one rewording from being satisfied by something else. The widget
    // is `_SelectionInfoPanel`, private to `map_screen.dart`, so it is found by
    // the name of its run-time type like every other private widget here, and
    // the title stays as the evidence that it is the *truth point's* card.
    _widget('_SelectionInfoPanel', describedAs: 'the selection info card'),
    _containing('Truth point · Sage',
        describedAs: 'the truth point info panel'),
  ]),

  'truth-point-edit': allOf([
    _viewshedOut,
    _showing('Edit truth point'),
    _showing('Move on map…'),
  ]),

  // ---- The bearing tip-drag gesture (`/w-10`) -----------------------------
  //
  // **The handle is the whole of the discoverability**, so the picture has to
  // contain it and not merely be of a map with a bearing selected. It is
  // keyed in `map_screen.dart` and found by that key rather than by its
  // private type, because the key is what the app promises and the type is an
  // implementation detail this file would be reading over the fence.
  //
  // **The tile conditions are `/w-16`'s, and they are here because this shot
  // is the one that may have moved the camera.** On a profile where no
  // bearing is draggable at the default view, `capture_test.dart` zooms out
  // and looks again — which throws away the tiles the map had and asks for a
  // fresh set. Without these two, the picture that teaches the app's least
  // discoverable gesture would be taken over a half-drawn map.
  'bearing-selected': allOf([
    _notComputing,
    _viewshedOut,
    _widget('_BearingTipHandle',
        describedAs: "the grab handle at the selected bearing's tip"),
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),

  // Mid-drag, with the finger still down. **The readout is the condition, not
  // the handle**: a longer ray with no number beside it is a fidget, and the
  // sentence the guide has to be able to write is that the gesture *measures*
  // something. `_BearingLengthReadout` exists only while a drag is in
  // progress, so its presence is also the evidence that the gesture took.
  'bearing-dragged': allOf([
    _viewshedOut,
    _containing('Drawn to',
        describedAs: 'the drawn-length readout, which shows only mid-drag'),
  ]),

  // ---- The joined half ----------------------------------------------------

  'joined-projects': allOf([
    _notSpinning,
    _containing('Owyhee Uplands Kit Fox', describedAs: 'the project list'),
  ]),

  // The typed code, as the field formats it.
  'join-code-entered': allOf([
    _notSpinning,
    _containing(formatJoinCode(steensJoinCode),
        describedAs: 'the typed join code'),
  ]),

  'join-waiting':
      allOf([_notSpinning, _showing('Waiting for approval')]),

  // **Ready does not mean idle here.** The download is held open on purpose so
  // this state can be photographed at all; what the run waits for is the card
  // that says it started.
  'join-downloading': _containing("You're in. Downloading",
      describedAs: 'the "download started" card'),

  'join-arrived': allOf([
    _notSpinning,
    _containing('Steens Rim Raptor Survey',
        describedAs: 'the project that was just joined'),
  ]),

  'project-tags-viewer': allOf([
    _notSpinning,
    _containing('East Rim', describedAs: "the joined project's own tag"),
  ]),

  // **The read-only Tag details page** (`/w-10`, task 11.199's fourth
  // screen). Two conditions, because either alone would also be true of
  // something else: the page's own title is true of the editable page too,
  // and the refusal banner's heading is what says this is the read-only one.
  // The status *word* is the thing the task changed, and it is on that page
  // as a plain `Text` only in this mode — an owner gets a wheel — so the
  // banner is what the check keys on and the word is what the picture is of.
  'tag-details-readonly': allOf([
    _showing('Tag details'),
    // Existence, because the run scrolls past it: the banner is what says
    // this is the read-only page rather than the editable one, and the page's
    // own title is true of both.
    _containing('Only an owner can change this tag',
        describedAs: 'the read-only banner'),
    // **And the word the shot is for has to be in frame.** `Status` is
    // printed as plain text here and offered as a wheel to an owner, so the
    // printed form only exists in this mode — and it was `TagStatus.db`, the
    // SQLite spelling, until task 11.199. Visibility rather than existence,
    // because it starts below the fold on both phones and a baseline that
    // covered the banner and not this would be a picture of the wrong half.
    _showing('Status'),
    _showing(tagStatusLabel(TagStatus.active),
        describedAs: "the tag's status, printed as a word"),
  ]),

  'owner-members-and-code': allOf([
    _notSpinning,
    _showing(_ownerDisplayName),
    _containing(formatJoinCode(owyheeJoinCode),
        describedAs: "this project's join code"),
  ]),

  // Scrolled to before the shutter, so visibility rather than existence is
  // the question — that is the whole reason this shot is separate.
  'owner-pending-request':
      allOf([_notSpinning, _showing(pendingRequesterEmail)]),

  'owner-approval-sheet': _showing(removalDisclosure,
      describedAs: 'the removal disclosure'),

  // **The Main Map, because that is where the sync surface now is** (`/w-14`).
  //
  // Until task 11.189 this was the Record screen and the condition was
  // `_showing('SAVE OBSERVATION')`, which said the Record screen had
  // finished. The bar it was framed on is gone; the icon that replaced it
  // floats over the map, so this waits for the map to have finished drawing —
  // the same three conditions `map` uses — **and then for the icon itself to
  // be in the tree**. That last one is the whole point of the shot: without
  // it the run would photograph a perfectly finished map with nothing on it
  // and file the picture under a name promising a status indicator.
  'joined-sync-indicator': allOf([
    _notComputing,
    _viewshedOut,
    _noImagesDecoding,
    _widget('SyncStatusIcon', describedAs: "the map's sync status icon"),
    // **And the basemap under it** (`/w-16`). The bearing-drag section may
    // have moved this map's camera and put it back; a restored camera has to
    // re-fetch its tiles, and this is the next picture of the same map.
    _basemapTilesDrawn,
  ]),

  'joined-sync-status': _notSpinning,

  // ---- The four failure states (`/w-10`, `/w-12`, `/w-14`) ----------------
  //
  // **Captured on `/more/sync-status` since `/w-14`, not on `/record`.** Task
  // 11.189 removed the sync bar, so the four conditions here waited on
  // sentences that are nowhere on the Record screen any more — and a
  // readiness check that is never satisfied does not fail, it spends its
  // ceiling and then files a picture of the wrong thing. Each now waits for
  // the **headline on the status card**, which is this screen's own name for
  // the state and is what a reader is looking at in the picture.
  //
  // The headlines are `SyncStatusScreen._headline()`'s exhaustive switch, so
  // a state renamed there and not here fails visibly rather than quietly.
  //
  // **The card's "last synced …" line is not asserted**, and since `/w-14`
  // it is a fixed February date rather than a wall-clock one — see
  // `dismissStaleWarning` in `joined.dart` for why that had to change when
  // these captures moved onto this screen.
  'sync-offline': allOf([_notSpinning, _showing('Offline')]),

  'sync-records-missing':
      allOf([_notSpinning, _showing('Some records did not arrive')]),

  'sync-records-held':
      allOf([_notSpinning, _showing('Some records not synced')]),

  'sync-removed':
      allOf([_notSpinning, _showing("You're not on this project")]),

  // ---- The sheets over the Position tab (`/w-32`) -------------------------
  //
  // Each waits for the sheet's own words, and the two that sit over the map
  // wait for the map under them: a sheet over a half-drawn basemap is the
  // Position picture `/w-16` spent a task on.
  'position-cautions': allOf([
    _containing('They do not stop you saving the estimate',
        describedAs: 'the cautions sheet'),
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),
  'position-legend': allOf([
    _showing('Included bearing'),
    _showing('Excluded bearing'),
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),
  // The estimate's own row, not just the sheet's title: the seeded estimate is
  // 145 by 78 metres, and a sheet that had not loaded would say "No saved
  // estimates for this tag yet." instead.
  'position-past-estimates': allOf([
    _notSpinning,
    _containing('Past estimates · Sage', describedAs: 'the sheet'),
    _containing('ellipse 145×78m', describedAs: "the seeded estimate's row"),
  ]),

  // ---- Tags, animals and Quick add (`/w-32`) -----------------------------
  'link-tag-picker': allOf([
    _showing('Which tag goes on Cedar?'),
    _containing('Aspen', describedAs: 'the Tag Library tag the picker offers'),
    _containing('New tag…', describedAs: 'the New tag option'),
  ]),
  // The confirmation, **with the "Tag went on" card** — the card is the part
  // task 11.322 added and the picture is for.
  'link-tag-confirm': allOf([
    _showing('Link to Cedar?'),
    _containing('Tag went on', describedAs: 'the date card'),
  ]),
  'quick-add': allOf([
    _notSpinning,
    _showing('Same for all'),
    _containing('Tags went on', describedAs: 'the date card'),
    _containing('Willow', describedAs: 'the third typed row'),
  ]),
  'quick-add-review': allOf([
    _notSpinning,
    _showing('Review'),
    (probe) => find.byKey(const ValueKey('quick_add_preview_3')).evaluate().isEmpty
        ? 'the review has not listed the third row'
        : null,
    _containing('from your Tag Library',
        describedAs: 'the row that comes from the Tag Library'),
  ]),

  // ---- Take on map (`/w-32`) ----------------------------------------------
  //
  // **The lines, not just the screen.** The picture is of earlier bearings
  // crossing a sweep; a screen that had drawn the basemap and none of the
  // lines would pass every check a screen-level condition could make. The
  // layer's own count is asked: the two earlier bearings and the pointing
  // line before a sweep, the two and the swept line after one.
  'take-on-map': allOf([
    _notSpinning,
    _showing('HOLD TO SWEEP'),
    _showing('${sweepStartDeg.round()}°',
        describedAs: 'the live heading readout'),
    (probe) => takeOnMapLineCount() == 3
        ? null
        : 'the map has ${takeOnMapLineCount()} line(s), not the two earlier '
            'bearings and the pointing line',
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),
  'take-on-map-released': allOf([
    _showing('Confirm'),
    _showing('Retake'),
    _showing('Cancel'),
    _containing('±', describedAs: 'the swept bearing readout'),
    (probe) => takeOnMapLineCount() == 3
        ? null
        : 'the map has ${takeOnMapLineCount()} line(s), not the two earlier '
            'bearings and the swept line',
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),

  // ---- Deleting a project (`/w-32`, for `/w-27`) --------------------------
  // **The title, by its end** (`/w-35`): task 11.324 renamed it from
  // *Delete "X" from the server?* to *Delete "X" permanently?*, and the old
  // fragment kept this capture waiting for a dialog that was already open.
  'delete-project-dialog': allOf([
    _containing('permanently?', describedAs: 'the first dialog'),
    _showing('Schedule delete'),
    _showing('Delete immediately…'),
  ]),
  'projects-countdown': allOf([
    _notSpinning,
    _visibleContaining('days left', describedAs: 'the countdown row'),
  ]),
  'projects-deleted-section': allOf([
    _notSpinning,
    _visibleContaining('Trash',
        describedAs: 'the section heading'),
    _visibleContaining('Alkali Flat', describedAs: 'the deleted project'),
    _showing('Restore'),
  ]),
  'app-info-support': allOf([
    _notSpinning,
    _visibleContaining('Contact TriTrack support',
        describedAs: 'the support link'),
  ]),
  'projects-trash-menu': allOf([
    _visibleContaining('Alkali Flat', describedAs: 'the project in the Trash'),
    _showing('Delete permanently…'),
  ]),
  'sync-project-deleted':
      allOf([_notSpinning, _showing('Project deleted')]),

  // ---- Setting up a project (`/w-35`) -------------------------------------
  //
  // The selection's summary (its area and tile count) is what says a
  // selection has been drawn; the basemap under it is the rest of the picture.
  'offline-data-selection': allOf([
    _notSpinning,
    _showing('Download'),
    _containing('km²', describedAs: "the selection's summary"),
    _noImagesDecoding,
    _basemapTilesDrawn,
  ]),
  // **The time zone's source line, not just its heading** (task 11.331): the
  // zone is worked out from the extent after it is set, and until then the
  // section says "Working it out…" or names this phone's zone instead.
  'new-project-form': allOf([
    _showing('New Project'),
    _visibleContaining('PROJECT EXTENT', describedAs: 'the extent section'),
    _visibleContaining('Chosen from the center of your project area.',
        describedAs: "the time zone's source line"),
  ]),
  'finish-setting-up': allOf([
    _showing('Finish setting up'),
    _showing('Publish to the server now'),
    _containing('MB)', describedAs: "the maps line's size"),
    _showing('Start'),
  ]),
};

/// **How long the run keeps asking, per state.**
///
/// A ceiling on patience, not a duration to wait: a state ready sooner is
/// photographed sooner, and this number's only job is to decide when to stop
/// asking and record a red.
///
/// Two states get a much larger one, and the reason is measured. On a
/// simulator whose elevation cache is empty the map fetches the 72 DEM tiles
/// covering the viewshed's fixed 35 km disc at roughly one a second before it
/// can draw an overlay. **That count does not depend on the fixture** — the
/// disc is centred on `seedFix()` and sized by `ViewshedConfig.maxRangeMeters`
/// (35 km), so 8 tile rows × 9 tile columns = 72 whether the seed holds three
/// bearings or eighty. What varies is whether the cache is warm, and
/// `README.md` item 8 already said so. Three minutes is comfortably past a
/// cold fetch and still short enough that a genuinely stuck screen is reported
/// within one coffee.
const Duration _mapCeiling = Duration(minutes: 3);

/// Everything else. Nothing here loads from a network; a screen that has not
/// answered in twenty seconds is stuck, not slow.
const Duration _defaultCeiling = Duration(seconds: 20);

/// **The Position screen's map pane, which fetches basemap tiles and nothing
/// else** (`/w-16`).
///
/// Not the map's three minutes: there is no terrain fetch here, only the
/// basemap tiles covering one small pane. Not the ordinary twenty either —
/// twenty seconds is a fine answer to "is this screen stuck?" for a screen
/// that loads from a database, and it is a guess about a network for a screen
/// that loads from one. Sixty is comfortably past a warm fetch of a pane's
/// worth of tiles and still short enough to report a genuinely dead map pane
/// within the same run.
const Duration _positionCeiling = Duration(seconds: 60);

const Map<String, Duration> _ceilings = {
  'map': _mapCeiling,
  'position': _positionCeiling,
  // Waits on a basemap the run may have just asked to be redrawn at a
  // different zoom, so it gets the same patience the Position pane does
  // rather than the twenty seconds meant for a screen that loads from a
  // database.
  'bearing-selected': _positionCeiling,
  'truth-point-panel': _mapCeiling,
  // A third map capture, so it waits on the same terrain fetch the other two
  // do (`/w-14`). Warm by the time the joined half runs, in the ordinary
  // case; a cold cache is what this ceiling is for.
  'joined-sync-indicator': _mapCeiling,
  // Take on map's map pane fetches zoom-14 basemap tiles the run has not asked
  // for before (`/w-32`); the Position pane's patience.
  'take-on-map': _positionCeiling,
  'take-on-map-released': _positionCeiling,
  'position-cautions': _positionCeiling,
  'position-legend': _positionCeiling,
  // A map pane at a zoom the run has not fetched before (`/w-35`).
  'offline-data-selection': _positionCeiling,
};

Duration ceilingFor(String state) => _ceilings[state] ?? _defaultCeiling;

/// Keys in [readinessByState] naming no state this run captures.
///
/// A typo here would leave a real state silently unchecked while the map still
/// looked full, so the run refuses to start on one.
List<String> get unknownReadinessKeys => [
      for (final key in readinessByState.keys)
        if (!expectedScreenshotNames.contains(key)) key,
    ];

/// States with nothing that would notice an unfinished screen.
///
/// **Reported on every run, including when it is zero**, because a sweep
/// without a denominator is a claim nobody can check.
List<String> get statesWithoutReadiness => [
      for (final name in expectedScreenshotNames)
        if (!readinessByState.containsKey(name)) name,
    ];


/// How often the question is asked while waiting.
///
/// Short enough that a screen ready at 900 ms is not photographed at 3
/// seconds, long enough that the polling itself is not what the run spends
/// its time on.
const Duration _pollInterval = Duration(milliseconds: 250);

/// **Waits until [state] is actually the state it is about to be filed as.**
///
/// Returns when its [ReadinessCheck] is satisfied, and records a capture error
/// naming the unmet condition if [ceilingFor] expires first. Either way the
/// shutter still fires afterwards — this harness deliberately photographs a
/// screen it is unhappy with rather than losing the rest of the run (see
/// `capturedErrors` in `harness.dart`) — but a run that reaches a ceiling is
/// no longer a run that reported itself green.
///
/// **Says how long it took, every time, not only when it fails.** "map: ready
/// after 61.4 s" is how somebody finds out that the elevation cache went cold,
/// or that a screen has picked up a load it did not used to have. A ceiling
/// reached in silence would be this file repeating the defect it replaced.
Future<void> awaitReady(
  WidgetTester tester,
  ProviderContainer container,
  String state,
) async {
  final check = readinessByState[state];
  if (check == null) {
    // Counted and named at the end of the run as well; said here too, because
    // the order matters when something goes wrong mid-run.
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: $state has no readiness condition, so nothing '
        'would notice if this picture were of an unfinished screen');
    return;
  }
  await _awaitCheck(tester, container, state, check, ceilingFor(state));
}

/// **The map has finished computing its viewshed, and it is on screen.**
///
/// The first half of every Map-tab picture since `/w-30`: the overlay is
/// waited for exactly as `/w-11` required — the status bar quiet, the overlay
/// in the tree, no image still decoding — and only then does
/// `map_framing.dart` switch it off. **Skipping the wait would be the defect
/// `/w-09` shipped in reverse:** the run would hide an overlay that had not
/// been computed yet, the download would finish behind the picture, and the
/// status bar would read "Downloading terrain" in a shot that has no terrain
/// in it.
Future<void> awaitViewshedComputed(
  WidgetTester tester,
  ProviderContainer container,
  String state,
) =>
    _awaitCheck(
      tester,
      container,
      '$state (viewshed computing, before it is switched off)',
      allOf([
        _notComputing,
        _widget('OverlayImageLayer',
            describedAs: 'the computed viewshed overlay'),
        _noImagesDecoding,
      ]),
      _mapCeiling,
    );

Future<void> _awaitCheck(
  WidgetTester tester,
  ProviderContainer container,
  String state,
  ReadinessCheck check,
  Duration ceiling,
) async {
  final probe = ReadinessProbe(tester, container);
  final clock = Stopwatch()..start();
  String? unmet = check(probe);
  while (unmet != null && clock.elapsed < ceiling) {
    await settle(tester, wait: _pollInterval);
    unmet = check(probe);
  }
  clock.stop();
  final seconds = (clock.elapsedMilliseconds / 1000).toStringAsFixed(1);
  if (unmet == null) {
    // ignore: avoid_print
    print('SCREENSHOT HARNESS: $state ready after ${seconds}s '
        '(ceiling ${ceiling.inSeconds}s)');
    return;
  }
  final was = currentScreen;
  currentScreen = state;
  recordCaptureError('still not ready after ${seconds}s — $unmet; the image '
      'filed as $state is of a screen that had not finished');
  currentScreen = was;
}
