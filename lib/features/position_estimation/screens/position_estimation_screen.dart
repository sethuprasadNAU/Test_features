import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:uuid/uuid.dart';

import '../../../core/errors/guarded_write.dart';

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../core/format/observation_quality_display.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/estimate_bearing_resolution.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/analysis/analysis_eligibility.dart';
import '../../../data/models/estimated_position.dart';
import '../../../data/models/observation.dart';
import '../../../data/models/project.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/user.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../localization/few_bearings_caution.dart';
import '../../../localization/localization_geographic.dart';
import '../../../localization/localization_types.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/tag_color_swatch.dart';
import '../../../widgets/wheel_picker.dart';
import '../../map/map_camera_target.dart';
import '../../map/services/cached_tile_provider.dart';
import '../../map/services/desktop_map_gestures.dart';
import '../../map/services/geo_math.dart';
import '../../map/services/tile_sources.dart';
import '../../map/widgets/map_furniture.dart';
import '../../../data/repositories/mutation_authorization.dart';

/// # SPACE BUDGET — read this before adding anything to this screen
///
/// **The bearings list is the subject of this screen. Everything else is
/// furniture.** A position estimate is computed *from* bearings; a screen
/// that shows the statistics of the estimate while hiding the observations
/// behind it has the priority exactly inverted.
///
/// Task 11.109 found this screen with **no bearing row visible at all** on a
/// 6.1-inch phone. Nothing was wrong with any single widget: a sort bar, a
/// selection row, a summary line, a cautions banner and a save button had
/// each been added by a task that justified it, and the lower panel was a
/// fixed 5/11 of the screen, so every addition came straight out of the
/// list's own height. **The defect was the total, and no task's acceptance
/// had ever been "and the screen still works with all of this on it."**
///
/// So it is one now. `test/features/position_estimation/screens/
/// position_screen_space_budget_test.dart` renders this screen inside the
/// real app shell at real phone geometry and fails unless whole bearing rows
/// are visible. **If you add something here, that test is what will tell
/// you.** The five rules it enforces:
///
/// 1. **The list's height is a floor, not a remainder.** The panel sizes
///    itself to show whole bearing rows first; furniture takes what is left.
///    Never the other way round.
///    **OVERRIDDEN above the ordinary text-size slider — task 11.147, by
///    Michael's decision of 2026-09-04. Read this before you trust rule 1.**
///    At the five Larger Accessibility Sizes this rule and the map's clear
///    band (rule 1 of the MAP SPACE BUDGET below) are **jointly
///    unsatisfiable** on a 6.1-inch phone: the panel's furniture plus one
///    scaled bearing row is about 470 logical pixels at AX3, and the surface
///    does not hold that and a readable map at once. Both rules have written
///    reasons and neither is wrong; they simply cannot both be obeyed there.
///    **The map's floor wins, and this rule yields — narrowly.** Above the
///    ordinary slider, and only there, the panel stops being a fixed frame
///    with a scrolling list inside it and becomes **one scrolling column**:
///    header, controls, every bearing and the save row together
///    ([_ObservationSheet.scrollAsOne]). The list's height is then neither a
///    floor nor a remainder, because there is no split left to argue about.
///    **What that yields and what it does not.** It yields the *pinning* of
///    the furniture, not the priority of the subject: every bearing is still
///    there and still reachable, a person scrolls to one instead of not
///    having it. It does **not** yield the map's floor, and it does not apply
///    at any size on the ordinary slider — at Large and below, this panel is
///    exactly the one task 11.109 built, to the pixel.
///    **Why the other two options were rejected**, so nobody re-opens this
///    cheaply: letting the map shrink was rejected because the clear band
///    exists precisely for the screen whose job is judging a position
///    estimate; telling somebody their accessibility setting is unsupported
///    was rejected because the people who turn those sizes on are the people
///    who need them.
/// 2. **Permanent space is earned by being an input you act on while
///    choosing bearings** — the selection controls, the sort, the list.
///    Output (the ellipse, the span) and one-shot terminal actions (save)
///    are not inputs and get one compact line each, at most.
/// 3. **A condition occupies space only while it holds, and never pushes the
///    subject.** The geometry/time cautions are a condition: they appear as
///    a button in the panel's header row, which exists anyway, and open a
///    sheet. They are not allowed to grow a row above the list.
/// 4. **Anything new goes on the map layer, into an existing header row, or
///    into a sheet.** Not a new permanent row in the panel. If it fits none
///    of those three, the answer is that it does not go on this screen.
/// 5. **Do not buy space by shrinking type or touch targets.** This is a
///    field app used in gloves; 11pt text and 44pt targets are the floor,
///    not the starting point.
///
/// The map/panel split is draggable ([_EstimationContentState._panelFraction])
/// so the user can go further in either direction than the default, but the
/// default must be correct on its own — a default that needs a drag to be
/// usable is the defect this file's rule exists to prevent.
///
/// **Below the panel's floor there is one more state (task 11.204): closed.**
/// Dragged past the snap point the panel becomes a grab-handle strip and the
/// map takes the whole body; dragging or tapping the strip restores the
/// height the panel had, not a default. See [_CollapsedPanelHandle] for the
/// three things about that state that were not asked for and are not
/// optional — the label, the accessible button, and the caution glyph.
///
/// **It does not soften any rule above.** The panel's own floor still holds
/// while the panel is open: a person cannot drag it to *nearly* nothing, only
/// to something or to nothing. And **closing is offered only where it buys
/// map** — above the ordinary text-size slider the open panel is already
/// smaller than the closed strip would be (47.5 logical pixels at AX4), and a
/// control whose only effect is to make the subject smaller is not a control,
/// so the screen declines. Measured across the ladder in
/// `position_screen_space_budget_test.dart`.
///
/// ## MAP SPACE BUDGET — the other half, added by task 11.110
///
/// Task 11.109 fixed the panel and deliberately left the map alone. The map
/// half had accreted the same way and nothing measured it either: a basemap
/// toggle across the top, a north arrow and two buttons down the sides, and
/// a four-item column along the bottom (an onboarding hint, the scale bar,
/// the coordinate readout, the map-source credit), on a map area 11.109 had
/// just made *smaller*.
///
/// **On this half the subject is the map itself — specifically the rays and
/// where they cross.** The thing a person is trying to see is a crossing
/// somewhere near the middle of the view, and every overlay eats the view
/// from an edge inward. So the number that matters is not "how much overlay
/// is there" but **how tall the band across the full width of the map is
/// that has nothing drawn over it.** That is what
/// `position_screen_space_budget_test.dart` measures and asserts.
///
/// The rules, which are the panel's rules restated for an overlay:
///
/// 1. **The clear band is a floor, not a remainder.** Overlays get the
///    edges; if a new overlay would push the clear band below the floor,
///    the new overlay does not go on.
///    **True through AX1 — one stop above the ordinary text-size slider —
///    since task 11.148, and false above that for a reason no layout on this
///    screen can reach.**
///    Task 11.147 measured the rule failing at the *first notch up*: the
///    floor is enforced against a *reserved* number of pixels, that
///    reservation was the constant 94, and the overlays inside it are text
///    that grows. With both shell banners live the band came out at 101
///    logical pixels at the default, **93 at xLarge**, 67 at xxLarge, 62 at
///    xxxLarge and 13 at AX1 — while the map's own height never moved.
///    Nothing had been added to the map; the bottom readout column simply
///    got taller and the reservation did not know.
///    **Task 11.148's remedy is that the reservation asks instead of
///    predicting** — see [_mapReadoutColumnHeightFor] — so the band now
///    measures **96 at every stop from the default through AX1**, with the
///    map taking 241 pixels at the default and 329 at AX1 to hold it.
///    **Task 11.149 moved that to AX2, and it did so from outside this
///    screen.** The shell's two banners used to wrap without bound and take
///    the body with them, leaving map and panel together 323 logical pixels
///    at AX2 and 143 at AX3; holding the banners to a quarter of the shell
///    made the same two numbers **455 and 423**, and the band held at 96
///    through AX2 with nothing on this screen changed. **Task 11.189 then
///    deleted the banners outright** — sync is one icon on the map and a dot
///    on the More tab now — so the shell gives this screen the whole body at
///    every text size. That is headroom above the numbers quoted here, not a
///    reason to re-argue the floor.
///    **Above AX2 nothing on this screen can help, and it is no longer the
///    shell either.** The map's own floor grows with the text too — 457
///    logical pixels at AX3 and 545 at AX5 — so it outruns a body the shell
///    cannot make any larger, because it is already handing over all of it.
///    What this screen does there is a stated decision rather than a
///    fallback: see
///    [_panelFractionWhenNothingFits], which also says what a person sees at
///    each of those sizes.
///    (Every number above is measured in the test font, about twice Roboto's
///    width, so a real phone has at least this much band and probably more.
///    **Nobody has yet looked at one.**)
///    **Every number in this rule was measured with the pre-task-11.204
///    instrument, which charged each overlay the map's full width whatever
///    its own width.** They are correct as history and they understate the
///    map: see rule 4 for what changed and by how much. The floor itself is
///    unchanged, and so is every conclusion drawn from these numbers about
///    what the *panel* was doing to the map.
/// 2. **Onboarding copy never occupies permanent space.** A sentence
///    teaching a gesture is read once and paid for on every subsequent
///    launch, forever. "Tap a ray to include/exclude" was such a band; it
///    now lives as the legend card's footnote, behind the legend button —
///    the control a person presses to ask what they are looking at. **Any
///    future "did you know you can…" copy goes there too.**
/// 3. **A mode's own readout belongs to the mode.** The legend card
///    appears only when asked for and may not become permanent. (Task
///    11.202 removed this screen's measure tool along with the measure
///    card that used to be this rule's other example; the rule is
///    unchanged and the legend card is still what it governs.)
/// 4. **Corners before edges, edges before bands — and the clear region is
///    floored in both directions, which is what makes that safe.** A
///    control that fits in a corner cluster (the two side columns) costs
///    the clear band little or nothing; a new full-width band costs it in
///    full. Prefer joining an existing cluster.
///    **Rewritten by task 11.204, and the old wording is worth keeping in
///    view because it was wrong in a way nothing could detect.** It said a
///    corner control costs the clear band *nothing extra*, flatly, with no
///    condition attached — while `clearBandHeight` in
///    `test/support/app_shell_harness.dart` said, in its own doc comment and
///    equally deliberately, that every overlay is charged the map's full
///    width whatever its own width, *because* a budget that lets furniture
///    accumulate along one edge for free is the budget that produced the
///    defect it measures.
///    **Both were written on purpose. Neither had gone stale. Nothing in
///    this repository could tell them apart until task 11.203 built the
///    first overlay on this screen that was not full width** — two 48-pixel
///    squares stacked in a corner, charged as a full-width band of their
///    combined height, which took the clear band from 96 to **49.8**.
///    The settlement is one measurement that holds both reasons: an overlay
///    is charged **the width it actually covers**, and the clear region must
///    be at least [kClearRegionMinWidth] **wide** as well as
///    [_mapClearBandFloor] **tall**. A 48-pixel square in a corner leaves a
///    rectangle nearly the map's full width and full height and costs
///    nothing, which is this rule; furniture accumulating along an edge eats
///    the width until no such rectangle survives, which is the harness's.
///    **The width floor is stated with its reason in
///    `app_shell_harness.dart`, beside the measurement it constrains.**
///    **What that revealed, and it is a finding rather than a bonus:** the
///    north arrow and both side columns were never full width either, so
///    this map has always had more clear band than the old arithmetic
///    credited it with. Measured with the sync surface live, it is **161.8
///    logical pixels at the default text size**, against 96 before task
///    11.203 and 49.8 after it. **The map did not gain a pixel; the
///    arithmetic stopped charging for pixels that were never covered.** Rule
///    1 is unchanged: that is headroom to spend deliberately, not a reason
///    to stop measuring.
/// 5. **Attribution is not negotiable** — the map-source credit is a
///    licence condition and wraps to as many lines as it needs (task
///    11.95). It is counted as furniture, not exempted from the budget:
///    everything else has to fit around it.
///
/// ### The tile-health band (task 11.135, declined; added by task 11.205)
///
/// Every other live map in the app shows a band reading **"New map tiles are
/// not arriving"** when the tile service stops answering — the Main Map, the
/// Offline Data Map, the project-extent picker and both maps on the
/// record-position screen. **This screen went without one for four tasks,
/// and the reason each time was a measurement rather than an oversight.**
///
/// The verdict flipped once, from "does not fit" to "would fit but was not
/// spent," before it was actually added:
///
/// * Tasks 11.135, 11.139 and 11.148 each measured the clear band at **96
///   logical pixels against a floor of 96** — no headroom — while
///   `TilesNotLoadingBand` needs 48. Placed under the top row it would have
///   cut the largest remaining strip in half. Declined each time on rule 1:
///   the floor is a floor.
/// * Task 11.204's clear-band rewrite — an overlay is now charged the width
///   it actually covers, not the map's full width — found the band had
///   actually been **161.8** all along; the old arithmetic had been
///   charging for pixels the north arrow and the side columns never
///   covered. That is headroom that was always there and nothing had been
///   able to see, which is a finding rather than a bonus (see rule 4).
///
/// **Task 11.205 spent it.** The band now joins the north arrow's corner
/// (rule 4 — corners before edges) rather than taking an anchor of its own,
/// so it costs the ordinary day nothing: it is conditional, and a screen
/// where somebody is deciding where an animal is is the worst place in the
/// app to be reading a basemap that has quietly stopped updating. See the
/// `TilesNotLoadingBand` in the `build` method below.
///
/// ## TEXT SIZE — the third variable, added by task 11.139
///
/// Every number above was measured at **one system text size, the default**,
/// and nothing in this app or its screenshot harness had ever been rendered
/// at another. A person who turns their phone's text up — a field biologist
/// reading a screen in bright sun, or anybody over about forty — was getting
/// a panel whose boxes had been sized against a measurement taken on
/// somebody else's phone.
///
/// **What that looked like.** A viewer's save row struck the yellow-and-black
/// overflow stripe at **xLarge, the first stop above the default**, because
/// task 11.138 had measured its sentence once and written 52 into a
/// fixed-height box — and a sentence that wraps gains a whole line at a width
/// nobody can predict. The tag selector bar cut the bottom off the frequency
/// and the tag name from **xxLarge**, with no stripe and no ellipsis: the
/// worse of the two failures, because nobody reports what they cannot see.
///
/// The rules, which are the panel's rules restated for text:
///
/// 1. **A box that holds text takes a minimum height, never a fixed one.**
///    `ConstrainedBox(minHeight:)`, not `SizedBox(height:)`. A fixed box has
///    exactly one way to be wrong and it is the loud one — or, worse, the
///    silent one.
/// 2. **A panel whose height is computed must compute it at the ambient text
///    scale.** [_headerRowHeightFor], [_controlsRowHeightFor] and
///    [_saveRowHeightFor] take a `TextScaler` and each returns exactly the
///    constant it replaced at scale 1.0, so the budget above is untouched for
///    a phone at the default size.
/// 3. **Do not predict a wrapping sentence — measure it.**
///    [DisabledReasonNote.heightFor] lays the real words out at the real
///    width and scale. This is the one that was actually wrong, and no amount
///    of arithmetic on 52 would have got it right.
/// 4. **An icon that happens to be a character does not scale.** A glyph
///    inside a fixed tap target is an icon; give it
///    `textScaler: TextScaler.noScaling`, as `Icon` already has.
///
/// **Where it stopped, and how task 11.147 unstopped it.** Task 11.139 left
/// this panel clean — no stripe, nothing silently cut — through **AX2 for
/// somebody who can save and xxxLarge for a viewer**, and above those the
/// furniture plus one bearing row no longer fitted above the map's own floor.
/// It deliberately did not choose which floor gave way; Michael did, on
/// 2026-09-04, and the answer is written into rule 1 of the panel budget
/// above. **The panel is now clean at every stop on the ladder, for both
/// roles**, because at the accessibility sizes it scrolls as one instead of
/// being clamped.
///
/// 5. **Removing a failure is not the same as fixing it, and the check has to
///    change with the remedy.** A scrolling panel *cannot* show the
///    yellow-and-black stripe — so an assertion that nothing overflowed would
///    have gone green because the failure mode was deleted, not because the
///    screen became usable. That is the shape task 11.139 named on the Main
///    Map. `position_screen_space_budget_test.dart` therefore asserts, at
///    every stop on the ladder, that **the last bearing row and SAVE POSITION
///    can each be brought fully inside the panel**, and that the map's clear
///    band is still 96 logical pixels. **What it still cannot see** is
///    whether anybody would find the scroll, and how many bearings are
///    legible at once — at AX5 that is fewer than one. Those want a device.
///
/// ---
///
/// **The default bearing selection's time window** — task 11.268, item 7,
/// replacing the per-project `Projects.triangulationWindowMinutes` setting
/// Project Setup used to expose and nobody knew existed.
///
/// Michael, 2026-09-17: *"All projects should just auto select the bearings
/// for the last 6 hours and allow the user to manually change which bearings
/// are selected. The current time windowing and warning are a bit
/// overkill — human intelligence first."* Fixed rather than per-project,
/// because a person who wants a different window can always select bearings
/// by hand — that is what "human intelligence first" means here — and a
/// setting nobody could find is not a setting anybody was using.
///
/// **Answers a different question from [_defaultRangeMeters]**, and the
/// default selection needs both: this window catches "the animal may have
/// moved between these" — distance cannot tell that a bearing an hour ago and
/// one six hours ago are of the same still animal or two different
/// positions — and the 50 km range catches "these cannot be about the same
/// animal in the same place" — time cannot tell that two bearings a minute
/// apart came from 80 km away from each other only because the person moved.
///
/// Also the window [_ObservationSheet.warningMessagesFor]'s caution compares
/// against, so the default selection can never trip it on its own — the
/// caution now fires **only when a person manually adds a bearing older than
/// this**, which is "human intelligence first" implemented rather than
/// merely asserted.
const kTriangulationDefaultWindow = Duration(hours: 6);

/// Position Estimation: tag-first Position Estimation flow surfacing the
/// Phase 2 Lenth MLE solver. All observations contributing to one estimate
/// share the same `tag_id` — enforced by the tag selector gating everything
/// below it. Real basemap tiles are Phase 5; the map area here is a to-scale
/// schematic plot of the actual solved geometry (see
/// [EstimationMapPainter]), not a placeholder.
class PositionEstimationScreen extends ConsumerWidget {
  const PositionEstimationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return Scaffold(
      body: SafeArea(
        child: projectAsync.when(
          data: (project) => project == null
              ? const _NoProjectEmptyState()
              : _PositionEstimationBody(project: project),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure('this project', error: e),
        ),
      ),
    );
  }
}

class _NoProjectEmptyState extends StatelessWidget {
  const _NoProjectEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Set up a project first (see Log or More tab).'));
  }
}

class _PositionEstimationBody extends ConsumerStatefulWidget {
  const _PositionEstimationBody({required this.project});
  final Project project;

  @override
  ConsumerState<_PositionEstimationBody> createState() => _PositionEstimationBodyState();
}

class _PositionEstimationBodyState extends ConsumerState<_PositionEstimationBody> {
  String? _selectedTagId;
  final Set<String> _excludedIds = {};
  bool _saving = false;

  /// How much of the body below the tag selector the bearings panel occupies,
  /// as a fraction. Null until the first layout, which computes the default
  /// from the real available height (see [_EstimationContentState]).
  ///
  /// Held *here* rather than in `_EstimationContent` on purpose: that widget
  /// is re-created via `ValueKey(tag.tagId)` on every tag change, and a
  /// resize the user has deliberately made should survive switching tags.
  double? _panelFraction;

  /// Whether the panel has been dragged all the way down, leaving the map the
  /// whole body and the panel a grab-handle strip (task 11.204).
  ///
  /// **Held here, beside [_panelFraction], for the same reason and with the
  /// same lifetime**: `_EstimationContent` is re-created via
  /// `ValueKey(tag.tagId)` on every tag change, and closing the panel is a
  /// thing the user did on purpose. It is transient — nothing writes it to
  /// preferences, so a restart opens the panel again. **That is a decision,
  /// not an omission:** a person who closed the panel to read one crossing
  /// should not find the screen's default changed a week later, and the
  /// bearing list is where this screen's actual work is done.
  ///
  /// The fraction is deliberately *not* cleared when this is set, which is
  /// what makes re-opening restore the height the panel had rather than a
  /// default.
  bool _panelCollapsed = false;

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(projectActiveTagsProvider(widget.project.projectId));

    return tagsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure('the tag list', error: e),
      data: (tags) {
        if (tags.isEmpty) {
          return const Center(child: Text('No tags in this project yet.'));
        }
        final selected = tags.firstWhere(
          (t) => t.tagId == _selectedTagId,
          orElse: () => tags.first,
        );
        _selectedTagId = selected.tagId;

        return Column(
          children: [
            _TagSelectorBar(
              tags: tags,
              selected: selected,
              onChanged: (t) => setState(() {
                _selectedTagId = t.tagId;
                _excludedIds.clear();
              }),
            ),
            Expanded(
              child: _EstimationContent(
                // Re-create (and refit the map) when the tag changes;
                // exclusions are already cleared in onChanged.
                key: ValueKey(selected.tagId),
                project: widget.project,
                tag: selected,
                excludedIds: _excludedIds,
                onToggleExcluded: (id) => setState(() {
                  if (!_excludedIds.remove(id)) _excludedIds.add(id);
                }),
                onSelectAll: () => setState(_excludedIds.clear),
                onDeselectAll: (ids) => setState(() => _excludedIds.addAll(ids)),
                saving: _saving,
                onSave: (result, includedIds) => _save(context, selected, result, includedIds),
                panelFraction: _panelFraction,
                onPanelFractionChanged: (f) => setState(() => _panelFraction = f),
                panelCollapsed: _panelCollapsed,
                onPanelCollapsedChanged: (c) => setState(() => _panelCollapsed = c),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _save(
    BuildContext context,
    Tag tag,
    GeographicLocalizationResult result,
    List<String> includedIds,
  ) async {
    if (!result.hasEstimate) return;
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final deviceId = await ref.read(deviceIdProvider.future);
      final user = await ref.read(currentUserProvider.future);
      final repo = await ref.read(estimatedPositionRepositoryProvider.future);
      final estimate = EstimatedPosition(
        positionId: const Uuid().v4(),
        projectId: widget.project.projectId,
        tagId: tag.tagId,
        timestampLocal: now,
        timestampUtc: now.toUtc(),
        timezoneOffset: DbCodec.encodeOffset(now.timeZoneOffset),
        latitude: result.latitude!,
        longitude: result.longitude!,
        // **No ellipse is saved as none, never 0 × 0** (task 11.323): all
        // three are null together when the solve had no covariance.
        semiMajorAxis: result.ellipseSemiMajorMeters,
        semiMinorAxis: result.ellipseSemiMajorMeters == null
            ? null
            : result.ellipseSemiMinorMeters,
        rotationAngle: result.ellipseSemiMajorMeters == null
            ? null
            : result.ellipseRotationDegrees,
        method: EstimationMethod.lenthMle,
        observationIdsUsed: includedIds,
        sync: SyncMeta.initial(now: now, modifiedBy: user.userId, originDeviceId: deviceId),
      );
      await repo.insert(estimate);
      ref.read(recordingsRevisionProvider.notifier).bump();
      if (context.mounted) {
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Position saved')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// **The tag picker's line: the animal first, ahead of the collar and the
/// frequency** — task 11.274, matching the order task 11.272's follow-up
/// settled on for the Log.
///
/// Michael: *"the animal it was mounted to isn't listed so you don't know
/// who you are taking a position on … the animal name has to be in the
/// list too."* [Tag.individualName] already answers *"whose collar is this
/// right now"* — the same current-owner join the Tag Database and the
/// Record wheel read — so this is display only, not a new derivation.
///
/// **Where a collar has been on more than one animal, this says which**:
/// [Tag.individualName] is always the *current* owner, so a reassigned
/// collar reads as the animal wearing it now, not whichever one it started
/// with — the collar's own name alone cannot say that, which is Michael's
/// point. **A collar on nobody keeps today's line** (no prefix) rather than
/// a new "no animal" placeholder — nothing asked for a third state here,
/// and this list's tags already had no animal named at all before this
/// task.
///
/// **Two tags can read identically** — a collar with no name difference and
/// the same frequency and animal as another, e.g. two spares mounted on the
/// same animal one after another — and that is accepted, not resolved,
/// the same tradeoff [observerShortName] already makes for two observers
/// sharing an initial: nothing here promises the wheel's rows are unique,
/// only that each names its own animal correctly.
String _tagPickerLine(Tag t) {
  final collar = '${t.tagName} · ${t.frequencyMhz.toStringAsFixed(3)} MHz';
  final animal = t.individualName;
  return animal == null ? collar : '$animal · $collar';
}

class _TagSelectorBar extends StatelessWidget {
  const _TagSelectorBar({required this.tags, required this.selected, required this.onChanged});

  final List<Tag> tags;
  final Tag selected;
  final ValueChanged<Tag> onChanged;

  @override
  Widget build(BuildContext context) {
    // A **minimum** height, not a fixed one (task 11.139). At two notches
    // above the default text size this bar was cutting the bottom off the
    // frequency and the tag name — silently, with no stripe and no ellipsis,
    // so the person reading it had no way to know a digit was missing. That
    // is the worse of the two failures, because nobody reports it.
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).colorScheme.outline, width: 1.5)),
      ),
      child: TextButton(
        onPressed: () => _pickTag(context),
        style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.onSurface),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TagColorSwatch(colorHex: selected.colorHex),
            const SizedBox(width: 8),
            // `Flexible`, not a bare `Text` (task 11.205's own regression,
            // caught by `position_screen_space_budget_test.dart`): the swatch
            // added ~22 pixels this row could not give up anywhere else, and
            // that was enough to strip it at xxLarge. Ellipsis rather than
            // clip, matching every other narrow control on this screen
            // (task 11.147) — a shortened label has to say it was shortened.
            Flexible(
              child: Text(
                '${_tagPickerLine(selected)}  ▾',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTag(BuildContext context) async {
    final result = await showModalBottomSheet<Tag>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        var current = selected;
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                WheelPicker<Tag>(
                  items: tags,
                  selected: current,
                  labelBuilder: _tagPickerLine,
                  leadingBuilder: (t) => TagColorSwatch(colorHex: t.colorHex),
                  onChanged: (t) => setSheetState(() => current = t),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(current),
                  child: const Text('Select'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (result != null) onChanged(result);
  }
}

/// One bearing ray projected to geographic endpoints for the live map, plus
/// whether it's currently included in the solve. Both endpoints are real
/// lat/lon so the ray can be drawn as a `Polyline` and hit-tested against taps
/// in screen space (via the live [MapCamera]).
class _MapRay {
  const _MapRay({
    required this.observationId,
    required this.userId,
    required this.origin,
    required this.end,
    required this.included,
    required this.bearingDeg,
    required this.halfWidthDeg,
    required this.lengthM,
  });
  final String observationId;

  /// Who recorded this bearing — a teammate's ray is otherwise visually
  /// identical to the user's own (task 11.5).
  final String userId;
  final ll.LatLng origin;
  final ll.LatLng end;
  final bool included;

  /// True-north bearing and its ± uncertainty (°), plus the ray length, so the
  /// translucent uncertainty wedge can be drawn from the measurement point.
  final double bearingDeg;
  final double halfWidthDeg;
  final double lengthM;
}

/// How the bearing selector list (and the map rays drawn from it) are
/// ordered for the user to scan — purely a display concern, never fed to the
/// solver. Distance means distance from the user's current GPS position,
/// same definition as task 11.4's Log screen; with no fix it must present as
/// unavailable rather than silently reordering by something else.
enum _BearingSort { time, member, distance }

class _EstimationContent extends ConsumerStatefulWidget {
  const _EstimationContent({
    super.key,
    required this.project,
    required this.tag,
    required this.excludedIds,
    required this.onToggleExcluded,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.saving,
    required this.onSave,
    required this.panelFraction,
    required this.onPanelFractionChanged,
    required this.panelCollapsed,
    required this.onPanelCollapsedChanged,
  });

  final Project project;
  final Tag tag;
  final Set<String> excludedIds;
  final ValueChanged<String> onToggleExcluded;
  final VoidCallback onSelectAll;
  final ValueChanged<List<String>> onDeselectAll;
  final bool saving;
  final void Function(GeographicLocalizationResult result, List<String> includedIds) onSave;

  /// Null until the first layout has computed a default from real height.
  final double? panelFraction;
  final ValueChanged<double> onPanelFractionChanged;

  /// Whether the panel is closed down to its grab handle (task 11.204). See
  /// `_PositionEstimationBodyState._panelCollapsed` for why it is held above
  /// this widget and why re-opening restores [panelFraction] rather than a
  /// default.
  final bool panelCollapsed;
  final ValueChanged<bool> onPanelCollapsedChanged;

  @override
  ConsumerState<_EstimationContent> createState() => _EstimationContentState();
}

class _EstimationContentState extends ConsumerState<_EstimationContent> {
  final MapController _mapController = MapController();

  // ---- Space budget (see this file's header comment) --------------------
  //
  // The panel's fixed furniture: the header row that carries the drag
  // handle, the estimate readout, the cautions button and the past-estimates
  // button; the controls row; the save button with its padding; and the rule
  // the panel is drawn against the map with. They are declared here as
  // numbers rather than left implicit in the widget tree because the split is
  // computed *from* them — the panel asks for "chrome plus N whole bearing
  // rows" rather than being handed a fraction and letting the list keep
  // whatever survives.
  //
  // `position_screen_space_budget_test.dart` renders the panel and fails if
  // the real chrome no longer sums to 151.5 at the default text size. That is
  // the check that catches the next permanent row somebody adds.
  static const _headerRowHeight = 46.0;
  static const _controlsRowHeight = 40.0;

  /// The header row at a given system text size: its 6pt gap and 4pt drag
  /// pill, plus a content band that grows with the text in it. Exactly
  /// [_headerRowHeight] at scale 1.0.
  static double _headerRowHeightFor(TextScaler scaler) =>
      (_headerRowHeight - 36) + math.max(36.0, scaler.scale(36));

  /// The controls row at a given system text size. Exactly
  /// [_controlsRowHeight] at scale 1.0.
  ///
  /// **This row is why the whole panel got converted rather than just the
  /// save row 11.138 named.** Held at 40 logical pixels it did not stripe at
  /// any text size — it quietly cut the bottom off the sort button's label
  /// and off "All" and "None", which is the failure nobody reports because
  /// nobody can see it.
  static double _controlsRowHeightFor(TextScaler scaler) =>
      math.max(_controlsRowHeight, scaler.scale(_controlsRowHeight));

  /// The save row at the default text size. Not used directly any more —
  /// [_saveRowHeightFor] is, and returns exactly this at scale 1.0 — but it
  /// is the base that function scales, and the number the space budget is
  /// written in.
  static const _saveRowHeightAtDefaultTextSize = 64.0;

  /// The sentence a viewer is shown in the save row instead of a working
  /// button. Named because two places need it: the row that renders it, and
  /// the measurement that reserves room for it.
  static const _viewerCannotSaveReason =
      'Viewers cannot save a position estimate — ask an owner to change '
      'your role.';

  /// The extra height the save row takes when it must also say **why** saving
  /// is unavailable (task 11.138) — **measured against the phone's actual
  /// text size, not a constant (task 11.139).**
  ///
  /// It is reserved rather than left to overflow because the save row is a
  /// fixed-height box: a sentence added inside one without growing the box is
  /// not a reason nobody can read, it is a yellow-and-black overflow stripe.
  ///
  /// **It used to be the constant 52.0**, measured once at the default system
  /// text size — and that is the defect task 11.139 was raised on. A sentence
  /// that wraps does not grow smoothly with the text size; it gains a whole
  /// line at a width nobody can predict. Measured on this ladder, a viewer's
  /// panel **striped at xLarge — one notch above the default**, the first
  /// stop on the iOS text-size slider, and went on striping at every size
  /// above it. Nothing predicted from 52 would have got that right, so
  /// nothing predicts: [DisabledReasonNote.heightFor] lays the real sentence
  /// out in the real width at the real scale and answers.
  ///
  /// **Who pays.** Only a viewer, and a viewer is exactly the person for whom
  /// this panel is nothing but the bearings list, since they cannot write to
  /// it. Everybody who can save sees the panel task 11.109 left them, to the
  /// pixel — [_saveRowHeightFor] returns exactly 64 at text scale 1.0.
  ///
  /// [reason] is whichever sentence the row will actually show — a viewer's,
  /// or the snapshot refusal (task 11.237), which is longer and wraps sooner.
  /// Measuring the viewer sentence for a snapshot's row would be task 11.139's
  /// defect back again with a different constant.
  double _saveReasonHeightFor(
    BuildContext context,
    double panelWidth, {
    required String reason,
  }) =>
      DisabledReasonNote.heightFor(
        context,
        reason: reason,
        // The save row's own 20/20 horizontal padding, which the sentence
        // does not get to use.
        maxWidth: math.max(0, panelWidth - 40),
      );

  /// The save row at a given system text size: the button, whose own height
  /// follows its label, plus the row's 4/12 padding.
  ///
  /// Returns exactly [_saveRowHeightAtDefaultTextSize] at scale 1.0, so every
  /// number the space budget was written against is unchanged for a phone at
  /// the default text size.
  static double _saveRowHeightFor(TextScaler scaler) =>
      _saveRowHeightAtDefaultTextSize - 48 + math.max(48.0, scaler.scale(48));

  /// The hairline drawn between map and panel. It is 1.5 logical pixels and
  /// it is in this sum because leaving a real cost out is how a budget
  /// quietly stops being the truth.
  static const _panelTopBorder = 1.5;

  /// **The panel closed** (task 11.204): the hairline and a grab-handle strip,
  /// and nothing else. Michael, 2026-09-09: *"the non-map part of the screen
  /// should be minimizable if the drag is pulled all the way down… there
  /// should still be the little grey bar that allows the user to pull it back
  /// up."*
  ///
  /// The strip is a **touch target**, not a pill. The pill inside it is 4
  /// logical pixels tall; 48 is the smallest thing this project asks a gloved
  /// hand to hit, and it scales with the system text size for the same reason
  /// every other row on this screen does — a person who has turned the text up
  /// has usually turned it up because hitting things is harder, not easier.
  static double _collapsedPanelHeightFor(TextScaler scaler) =>
      _panelTopBorder + math.max(48.0, scaler.scale(48.0));

  /// The panel's furniture at the **default** system text size is
  /// `_headerRowHeight + _controlsRowHeight + _saveRowHeight +
  /// _panelTopBorder` = **151.5**, and that is the number
  /// `position_screen_space_budget_test.dart` asserts the real chrome
  /// against.
  ///
  /// It is deliberately not a constant here any more. Task 11.139 made the
  /// split compute its chrome from [_saveRowHeightFor] and
  /// [_saveReasonHeightFor] **at the phone's actual text size**, because a
  /// panel sized by a number measured once at 1.0 is a panel that stripes on
  /// somebody else's phone. A constant sitting beside those functions would
  /// be a second answer to the same question.


  /// A two-line dense bearing row's height. Only ever used to *ask* for
  /// space; nothing is forced to this height, so a row that comes out taller
  /// (large text scale, a wrapped observer name) still lays out correctly —
  /// it just means fewer whole rows fit, which is what the budget test
  /// measures rather than assumes.
  static const _bearingRowHeight = 64.0;

  /// **The default split asks for every bearing there is**, and lets the
  /// ceiling below decide how many actually fit.
  ///
  /// It used to ask for at most four, and on a tablet that was wrong (task
  /// 11.139). `/w-11` photographed this screen on a 13-inch iPad showing
  /// **four bearing rows out of five, with "N=5" and "5 of 5 selected"
  /// printed directly above the list** — the screen contradicting itself in
  /// a single glance, in the ordinary case rather than a stress fixture, and
  /// **666 logical pixels of map sitting unused below it.** The panel asked
  /// for four rows because a constant said four, and nothing in the
  /// calculation ever wanted more.
  ///
  /// **Nothing about a 6.1-inch phone moved**, and that is measured rather
  /// than hoped: on a phone the ceiling — 60% of the surface, or whatever is
  /// left once the map has its floor — binds long before four rows do, so
  /// the four never decided anything there. It only ever decided anything on
  /// the screen where it was wrong.

  /// The upper drag limit: past this there is not enough map left to pick a
  /// ray out of a bundle of them.
  ///
  /// The *lower* limit is not a fraction and not a constant either: it is
  /// **this panel's furniture at this phone's text size, plus one whole
  /// bearing row at that size**, computed in `build` and passed to
  /// [_clampPanelHeight].
  ///
  /// Deliberately a pixel floor rather than a fraction. A fraction that looks
  /// generous on paper — a quarter of the screen — is 156 logical pixels on a
  /// 6.1-inch phone, which is less than this panel's furniture alone: the
  /// drag would have been able to reproduce, by hand, the exact state task
  /// 11.109 exists to remove. **The subject cannot be dragged away.**
  /// A viewer's floor is taller by the height of the sentence saying why
  /// saving is unavailable (task 11.138), measured at the phone's own text
  /// size by [_saveReasonHeightFor] (task 11.139).
  static const _maxPanelFraction = 0.85;

  /// The default split must not eat the map: past this the map stops being
  /// somewhere you can pick a ray out of a bundle of them.
  static const _maxDefaultPanelFraction = 0.60;

  /// **What this screen does when the body cannot hold the map's floor at
  /// all** — decided by task 11.149, and stated because until then it was a
  /// fallback nobody had picked.
  ///
  /// [_defaultPanelFraction] normally hands the panel whichever binds first:
  /// 60% of the body, or everything the map does not need. Above a certain
  /// text size there is no third option, because the body is smaller than
  /// [_minMapHeightFor] on its own. At that point both halves are below their
  /// floors and something has to be chosen.
  ///
  /// **The panel is chosen, and it is the same 60% the ordinary ceiling
  /// uses.** The reasoning, rather than the number:
  ///
  /// - The panel holds **the terminal action of the screen** (SAVE POSITION),
  ///   the cautions, and the bearing list — all of which still *work* at a
  ///   smaller size. They get harder to read; they do not stop functioning.
  /// - A map below its clear-band floor is **not a map anybody can read a
  ///   crossing in**. Giving the map more of a body too small for its floor
  ///   buys a bigger unreadable map.
  /// - It is not given *nothing*, though, and that is deliberate: the map is
  ///   the only place the geometry appears at all, and 40% of the body is
  ///   still an orientation strip — you can see that there are rays and
  ///   roughly where they run, which is more than a person gets from a list
  ///   of bearings.
  ///
  /// **Task 11.206: the numbers this paragraph used to carry — a 457-pixel
  /// map wanted against a 423-pixel body at AX3, 545 against 345 at AX5, and
  /// what a person saw at AX3/AX4/AX5 as a result — were measured with both
  /// shell banners live**, a configuration task 11.189 removed. **They are
  /// not re-measured here, because there is nothing to measure them
  /// against**: task 11.206 re-ran `position_screen_space_budget_test.dart`
  /// on the current shell and confirmed what task 11.205 had already found —
  /// the map reaches its full 545-pixel floor at every stop on the ladder,
  /// through AX5 (`mapFloorHoldsThrough`, 53/17), so the body this paragraph
  /// describes as too small for the map never occurs on the measured phone
  /// geometry today. The reasoning above stands regardless of whether the
  /// condition is currently reachable; the numbers that described a specific
  /// instance of it do not.
  ///
  /// **Task 11.205 found this fallback no longer engages anywhere on the
  /// measured ladder, and did so without touching this split.**
  /// `_TagSelectorBar`'s label was a bare `Text` with no `maxLines` or
  /// `overflow`, so at these text scales it wrapped to several lines and its
  /// `BoxConstraints(minHeight: 52)` let the bar grow to fit them — eating
  /// directly into the body left for map and panel, silently, at exactly the
  /// sizes this fallback exists for. Constraining that label to one line
  /// (`Flexible` + ellipsis — needed anyway, once it carried a colour swatch
  /// too) recovered the space: at AX5 the body is now 615.5 logical pixels
  /// against the map's 545-pixel floor, where it used to be 491. **The map
  /// holds its floor through the whole ladder now** — see
  /// `mapFloorHoldsThrough` in the test file. This code path is unreached at
  /// the measured phone size and kept rather than deleted, because the app
  /// shell and this screen's own furniture can still grow past it — a wider
  /// tag name, a longer observer list — and the day one does, this is where
  /// it lands.
  static const _panelFractionWhenNothingFits = _maxDefaultPanelFraction;

  // ---- The map's own floor (task 11.110) ----------------------------------
  //
  // The symmetric half of [_minPanelHeight]. A fraction is not enough here
  // for the same reason it was not enough there: the map's furniture is a
  // fixed number of pixels, so on a shorter surface a fraction leaves the
  // *subject* — the part of the map with nothing drawn over it — smaller and
  // smaller, and there is no bearing count or map extent at which that
  // becomes visible. **What used to make the surface shorter was the app
  // shell's two conditional banners**, which cost every screen about 109
  // logical pixels between them at the default text size and far more at the
  // accessibility sizes, and were invisible to any test that pumped a screen
  // bare. Task 11.149 bounded them to a quarter of the shell; **task 11.189
  // removed them**, so the shell now hands the whole body to whichever tab is
  // showing and this screen's own budget is the only one in play.

  /// The single control row along the top (basemap toggle, legend, and the
  /// north arrow when the map is rotated), plus its inset.
  static const _mapControlRowHeight = 8.0 + 48.0;

  /// The inset the bottom-left readout column sits in, on all three sides.
  /// The horizontal half is what decides where the credit wraps, so it is one
  /// constant used by both the reservation and the `Positioned` below.
  static const _mapReadoutInset = 12.0;

  /// The bottom-left column: the scale bar and coordinate readout sharing one
  /// line, the map-source credit under it, and the inset.
  ///
  /// **This used to be the constant 94, and task 11.148 is why it is not.**
  /// 94 was measured once at the default system text size, and the column is
  /// text — a scale-bar label, a coordinate readout, and an attribution
  /// credit that wraps to as many lines as the licence needs. Turn the phone's
  /// text up one notch and the column grew while the reservation did not: the
  /// clear band fell to 93 logical pixels at xLarge against a floor of 96, and
  /// to 62 at xxxLarge, with the map's own height never moving.
  ///
  /// **`94 * textScaler` would not have fixed it.** Task 11.147 measured the
  /// column growing a whole line at a time, at a width nothing predicts, so a
  /// multiplier under-reserves at some sizes and over-reserves at others. A
  /// multiplier is still a prediction. [MapBottomReadoutColumn.heightFor] lays
  /// the real strings out at the real width and reports what it gets.
  static double _mapReadoutColumnHeightFor(
    BuildContext context, {
    required double width,
    required Position? gps,
    required TileSource source,
    required CoordinateFormat format,
    required double latitude,
    required double zoom,
  }) =>
      _mapReadoutInset +
      MapBottomReadoutColumn.heightFor(
        context,
        maxWidth: math.max(0, width - 2 * _mapReadoutInset),
        latitude: latitude,
        zoom: zoom,
        gps: gps,
        format: format,
        source: source,
      );

  /// The band of map with nothing over it. A ray crossing is what somebody is
  /// looking for and two rays arrive from different directions, so anything
  /// under about three marker heights cannot show a crossing *and* enough of
  /// its neighbourhood to see it is a crossing.
  static const _mapClearBandFloor = 96.0;

  /// The map's floor at this phone's text size. At the default it measures
  /// **241** — five pixels under the 246 the old constant asked for, because
  /// that constant over-reserved for the readout column — and it grows with
  /// the column, reaching 329 at AX1. Above AX1 the surface is smaller than
  /// this number and no split can satisfy it; see rule 1 of the MAP SPACE
  /// BUDGET.
  double _minMapHeightFor(
    BuildContext context, {
    required double width,
    required Position? gps,
    required TileSource source,
    required CoordinateFormat format,
    required double latitude,
    required double zoom,
  }) =>
      _mapControlRowHeight +
      _mapReadoutColumnHeightFor(
        context,
        width: width,
        gps: gps,
        source: source,
        format: format,
        latitude: latitude,
        zoom: zoom,
      ) +
      _mapClearBandFloor;

  /// The fraction of [availableHeight] the panel takes when the user has not
  /// dragged it: enough for the chrome plus one row per bearing, never more
  /// than [_maxDefaultPanelFraction] and never less than a two-row panel.
  double _defaultPanelFraction(
    double availableHeight,
    int bearingCount, {
    required double chrome,
    required double rowHeight,
    required double minMapHeight,
  }) {
    if (availableHeight <= 0) return _panelFractionWhenNothingFits;
    final rows = math.max(bearingCount, 1);
    final wanted = chrome + rows * rowHeight;
    // Two rows is the default's own floor, even for a single bearing: a list
    // showing exactly one row does not read as a list.
    final floor = (chrome + 2 * rowHeight) / availableHeight;
    // Whichever binds first: 60% of the surface, or whatever is left after
    // the map has its floor. On a full-height screen the fraction binds; once
    // the shell puts a banner up, this does — and the panel gives back a row
    // rather than the map giving back all of its clear band.
    //
    // **And when neither can be satisfied**, [_panelFractionWhenNothingFits]
    // — a stated decision about what this screen gives up when the body is
    // smaller than the map's floor on its own, with what a person sees at
    // each size it applies to. It was the bare `_maxDefaultPanelFraction`
    // until task 11.149, which is the same number reached by nobody choosing
    // it.
    final mapBound = availableHeight > minMapHeight
        ? (availableHeight - minMapHeight) / availableHeight
        : _panelFractionWhenNothingFits;
    final ceiling = math.min(_maxDefaultPanelFraction, mapBound);
    return (wanted / availableHeight).clamp(math.min(floor, ceiling), ceiling);
  }

  /// The panel's height for a given split fraction, held between "furniture
  /// plus one whole row" and [_maxPanelFraction] — the same clamp for the
  /// computed default and for the user's drag, so neither can produce a state
  /// the other could not.
  ///
  /// **Task 11.147 — where the panel's own floor stops.** That minimum used
  /// to be unconditional, and above the ordinary text-size slider it is the
  /// line that took the map apart: at AX3 the panel's furniture plus one
  /// scaled bearing row is about 470 logical pixels on a 6.1-inch phone, so
  /// the panel claimed all of that and left the map with less than a third of
  /// the band it needs to show a ray crossing — and then striped anyway,
  /// because 470 was more than the surface had left to give.
  ///
  /// So the floor now yields to the map's, and only there: the panel is never
  /// pushed past `minMapHeight` from the bottom of the surface. Below it the
  /// panel scrolls as one ([_ObservationSheet.scrollAsOne]) rather than being
  /// clamped and bursting. **A person scrolls to a bearing instead of not
  /// having it, and the map keeps the band the estimate is judged in.**
  ///
  /// The *upper* limit is untouched, so a user who drags the panel up may
  /// still cover the map: that is their explicit choice, made a gesture at a
  /// time, and the rule this file states is about the default.
  double _clampPanelHeight(
    double wanted,
    double availableHeight, {
    required double chrome,
    required double rowHeight,
    required double minMapHeight,
  }) =>
      wanted.clamp(
        _minPanelHeight(availableHeight,
            chrome: chrome, rowHeight: rowHeight, minMapHeight: minMapHeight),
        availableHeight * _maxPanelFraction,
      );

  /// The open panel's floor — furniture plus one whole bearing row, yielding
  /// to the map's floor and to [_maxPanelFraction] where those bind first.
  ///
  /// **Named rather than inlined into [_clampPanelHeight] because the drag has
  /// to know it too** (task 11.204): the snap point between "open at its
  /// smallest" and "closed" is halfway between this and
  /// [_collapsedPanelHeightFor], and a second copy of this arithmetic is how
  /// the drag and the layout would come to disagree about where the panel's
  /// floor is.
  double _minPanelHeight(
    double availableHeight, {
    required double chrome,
    required double rowHeight,
    required double minMapHeight,
  }) {
    final maxPanel = availableHeight * _maxPanelFraction;
    final mapFloorBound = math.max(0.0, availableHeight - minMapHeight);
    return math.min(math.min(chrome + rowHeight, mapFloorBound), maxPanel);
  }

  /// The height the drag is working from, in logical pixels, while a drag is in
  /// progress — **unclamped, and that is the point.**
  ///
  /// The layout's own height cannot carry a drag past the panel's floor:
  /// [_clampPanelHeight] returns the floor, the next delta is applied to the
  /// floor again, and pulling further down accumulates nothing. So a person
  /// pulling the panel *all the way* down was, before task 11.204, pulling
  /// against a number that had already stopped moving. This is the raw one.
  double? _dragRawPanelHeight;

  /// The split the panel had when the current drag started.
  ///
  /// **A drag that ends closed must leave the remembered height alone**, and
  /// it cannot simply not write one on the way down: a close is reached by
  /// dragging *through* every height between here and the floor, and each of
  /// those is a legitimate resize until the finger keeps going. So the fraction
  /// is written continuously, and restored from this the moment the panel
  /// snaps shut — "the height it had before" means before the gesture, not
  /// wherever the finger happened to pass.
  double? _dragStartFraction;

  // Camera mirror for scale bar / north arrow (flutter_map doesn't expose the
  // live camera as a listenable — same pattern as the Main Map).
  double _cameraRotation = 0;
  double _cameraZoom = 14;
  // Display-only mirror for the scale bar and lat/lon readout, replaced by
  // `onMapReady` on the first frame. Task 11.103: the initialiser was
  // `LatLng(0, 0)`, so for one frame the readout claimed a place in the Gulf
  // of Guinea. This map's camera comes from a fit over the bearings, which
  // are always supplied — but the seed value should still not be a location.
  ll.LatLng _cameraCenter = MapCameraTarget.worldViewCenter;

  bool _showLegend = false;
  // Task 11.203: the map-type selector moved behind a corner button, and the
  // two panels this row can open (layers, legend) share a "one at a time"
  // rule — opening one closes the other, since they anchor at the same
  // corner and both stacking open would collide on a short screen.
  bool _showLayers = false;

  // Display-only ordering for the bearing selector / map rays — never fed
  // into the solve, so it cannot change `result` for a given included set
  // (task 11.5's hard requirement).
  _BearingSort _sort = _BearingSort.time;

  // Applied once per tag (this widget is re-created via ValueKey(tag.tagId)
  // whenever the selected tag changes, so this naturally resets): defaults
  // the selection to bearings within 50km AND within
  // kTriangulationDefaultWindow of the most recent bearing for this tag
  // (task 11.268, item 7 — the distance filter alone was the whole default
  // until then), excluding everything outside either bound, without
  // stomping manual checkbox toggles made after the default is applied.
  bool _appliedDefaultFilter = false;

  /// Observation ids more than [_defaultRangeMeters] from, or more than
  /// [kTriangulationDefaultWindow] older than, the most recent bearing for
  /// this tag (by timestampUtc). Empty when there's nothing to exclude (0 or
  /// 1 observations total).
  static const _defaultRangeMeters = 50000.0;

  List<String> _defaultExclusions(List<Observation> observations) {
    if (observations.length <= 1) return [];
    final mostRecent =
        observations.reduce((a, b) => a.timestampUtc.isAfter(b.timestampUtc) ? a : b);
    final origin = GeoPoint(mostRecent.latitude, mostRecent.longitude);
    final cutoff = mostRecent.timestampUtc.subtract(kTriangulationDefaultWindow);
    return [
      for (final o in observations)
        if (distanceAndBearing(origin, GeoPoint(o.latitude, o.longitude)).distanceMeters >
                _defaultRangeMeters ||
            o.timestampUtc.isBefore(cutoff))
          o.observationId,
    ];
  }

  /// Orders a *copy* of [canonical] for display. Never mutates the input, so
  /// the caller's canonical (solver-feeding) list is untouched regardless of
  /// what the user has picked here.
  List<Observation> _sortForDisplay(
    List<Observation> canonical,
    _BearingSort sort,
    Map<String, User> observers,
    double? Function(Observation) distanceMeters,
  ) {
    final list = [...canonical];
    switch (sort) {
      case _BearingSort.time:
        list.sort((a, b) => b.timestampUtc.compareTo(a.timestampUtc));
      case _BearingSort.member:
        list.sort((a, b) => observerName(a.userId, observers)
            .compareTo(observerName(b.userId, observers)));
      case _BearingSort.distance:
        list.sort((a, b) {
          final da = distanceMeters(a);
          final db = distanceMeters(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return da.compareTo(db);
        });
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final obsAsync =
        ref.watch(_directionalObservationsProvider((widget.project.projectId, widget.tag.tagId)));
    final tileCategoryAsync = ref.watch(selectedTileCategoryProvider);
    final tileSourceAsync = ref.watch(selectedTileSourceProvider);
    final gps = ref.watch(gpsPositionProvider).value;
    // Task 11.14: the same role gradient every other write control asks —
    // saving an estimate is contributor-level like recording an observation,
    // not author-restricted like editing one. Defaults to permitted while
    // unresolved, matching `_TagRow.mayEdit`'s own momentary assumption.
    //
    // The standing rather than the bare bool since task 11.237, because the
    // sentence in the save row depends on *why*: a viewer's, or a snapshot's.
    // "Permitted while unresolved" is spelled as the unknown standing, which
    // is what `?? true` always meant here.
    final standing =
        ref.watch(myProjectStandingProvider(widget.project.projectId)).value ??
        ProjectStanding.unknown;
    final mayWrite = standing.mayWriteProjectData;
    final cannotSaveReason =
        standing.writeRefusal(asViewer: _viewerCannotSaveReason) ??
        _viewerCannotSaveReason;

    return obsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => LoadFailure('the bearings for this tag', error: e),
      data: (loaded) {
        final observers = loaded.observers;
        if (loaded.observations.isEmpty) {
          return const Center(child: Text('No directional observations for this tag yet.'));
        }

        // Newest first — this is the canonical order everything the solver
        // touches is built from (`included`, `geoObs`, `result`). It must
        // never depend on `_sort`: that is display-only, further down.
        final observations = [...loaded.observations]
          ..sort((a, b) => b.timestampUtc.compareTo(a.timestampUtc));

        if (!_appliedDefaultFilter) {
          _appliedDefaultFilter = true;
          final toExclude = _defaultExclusions(observations);
          if (toExclude.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) widget.onDeselectAll(toExclude);
            });
          }
        }

        final included =
            observations.where((o) => !widget.excludedIds.contains(o.observationId)).toList();
        final geoObs = [
          for (final o in included)
            GeographicObservation(
              latitude: o.latitude,
              longitude: o.longitude,
              trueNorthBearingDeg: o.trueNorthBearing!,
              id: o.observationId,
              positionAccuracyM: o.positionAccuracyM,
            ),
        ];
        final result = LenthGeographic.solve(geoObs);

        final estimate = result.hasEstimate
            ? ll.LatLng(result.latitude!, result.longitude!)
            : null;

        double? distanceMeters(Observation o) => gps == null
            ? null
            : distanceAndBearing(
                GeoPoint(gps.latitude, gps.longitude),
                GeoPoint(o.latitude, o.longitude),
              ).distanceMeters;

        // Distance sort must never silently reorder by something else when
        // there's no GPS fix (task 11.4's rule, carried over here) — fall
        // back to the clearly-labelled time order instead.
        final distanceAvailable = gps != null;
        final usingDistanceFallback = _sort == _BearingSort.distance && !distanceAvailable;
        final displaySort = usingDistanceFallback ? _BearingSort.time : _sort;
        final displayObservations =
            _sortForDisplay(observations, displaySort, observers, distanceMeters);

        // Draw each ray long enough to reach past the estimate (or a sane
        // default when there's no fix yet), projected from its own observer.
        // Uses the display order only — which ray is drawn first never
        // changes which observations feed the solve above.
        final rays = <_MapRay>[
          for (final o in displayObservations)
            () {
              final observer = GeoPoint(o.latitude, o.longitude);
              double lengthM = 500;
              if (estimate != null) {
                final d = distanceAndBearing(
                  observer,
                  GeoPoint(estimate.latitude, estimate.longitude),
                ).distanceMeters;
                lengthM = math.max(300, d * 1.3);
              }
              final dest = destinationPoint(observer, o.trueNorthBearing!, lengthM);
              return _MapRay(
                observationId: o.observationId,
                userId: o.userId,
                origin: ll.LatLng(o.latitude, o.longitude),
                end: ll.LatLng(dest.latitude, dest.longitude),
                included: !widget.excludedIds.contains(o.observationId),
                bearingDeg: o.trueNorthBearing!,
                halfWidthDeg: (o.bearingUncertainty ?? 12.0).clamp(0.0, 90.0),
                lengthM: lengthM,
              );
            }(),
        ];

        final ellipsePolygon = (estimate != null &&
                result.ellipseSemiMajorMeters != null &&
                result.ellipseSemiMinorMeters != null)
            ? _ellipsePoints(
                center: estimate,
                semiMajorM: result.ellipseSemiMajorMeters!,
                semiMinorM: result.ellipseSemiMinorMeters!,
                rotationCompassDeg: result.ellipseRotationDegrees ?? 0,
              )
            : null;

        final timestamps = included.map((o) => o.timestampUtc).toList()..sort();
        final spanMinutes = timestamps.isEmpty
            ? 0
            : timestamps.last.difference(timestamps.first).inMinutes;

        // Task 11.205: the same animal is orange on the Main Map and blue
        // here without this — every ray, marker and ellipse on this screen
        // used a fixed theme colour instead of the tag's own.
        final tagColor = tagColorFromHex(widget.tag.colorHex);
        final tileSource = tileSourceAsync.value ?? TileSources.openStreetMap;

        // The map/panel split. Explicit heights from one `LayoutBuilder`
        // rather than a pair of `Expanded` flex factors: the flex version
        // (6:5, unchanged since this screen was first built) could not be
        // told that the panel needed more room, so every widget added to the
        // panel came directly out of the bearings list. See this file's
        // header comment.
        return LayoutBuilder(
          builder: (context, constraints) {
            final available = constraints.maxHeight;

            // **The panel's furniture at this phone's text size (task
            // 11.139).** Every one of these was a constant measured once at
            // the default size, and the split was computed from the
            // constants — so when somebody turned their text up, the rows
            // grew and the box they were in did not. At scale 1.0 each of
            // these returns exactly the number it replaced, so nothing about
            // the default phone has moved.
            final scaler = MediaQuery.textScalerOf(context);
            final saveRowHeight = _saveRowHeightFor(scaler) +
                (mayWrite
                    ? 0
                    : _saveReasonHeightFor(
                        context,
                        constraints.maxWidth,
                        reason: cannotSaveReason,
                      ));
            final headerRowHeight = _headerRowHeightFor(scaler);
            final controlsRowHeight = _controlsRowHeightFor(scaler);
            final chrome = headerRowHeight +
                controlsRowHeight +
                saveRowHeight +
                _panelTopBorder;
            // A bearing row is two lines of text, so it grows with the text
            // too. Asking for the scaled height is what keeps roughly the
            // same *number* of rows visible rather than the same number of
            // pixels; the map's own floor still binds first, so this cannot
            // eat the map.
            final rowHeight = scaler.scale(_bearingRowHeight);

            // **The map's floor at this phone's text size, not at the one it
            // was measured on** (task 11.148). The reservation for the bottom
            // readout column used to be the constant 94; the column is text,
            // so above the default text size it grew and the reservation did
            // not, and the band of map somebody reads a crossing in fell
            // below its floor at the first notch up the slider.
            final minMapHeight = _minMapHeightFor(
              context,
              width: constraints.maxWidth,
              gps: gps,
              source: tileSource,
              format: widget.project.coordinateFormat,
              latitude: _cameraCenter.latitude,
              zoom: _cameraZoom,
            );

            final fraction = widget.panelFraction ??
                _defaultPanelFraction(available, observations.length,
                    chrome: chrome,
                    rowHeight: rowHeight,
                    minMapHeight: minMapHeight);
            final openPanelHeight = _clampPanelHeight(
                available * fraction, available,
                chrome: chrome,
                rowHeight: rowHeight,
                minMapHeight: minMapHeight);
            final collapsedHeight = _collapsedPanelHeightFor(scaler);

            // **Closing is offered only where it buys map** (task 11.204).
            // Above the ordinary text-size slider the open panel is already
            // squeezed under the map's floor — at AX4 on a 6.1-inch phone it
            // is 47.5 logical pixels — while the closed strip is a scaled
            // 48-pixel touch target, so *closing* it there would take room
            // away from the map. A control whose only effect is to make the
            // subject smaller is not a control; the panel stays open and the
            // handle keeps saying it resizes.
            final canCollapse = collapsedHeight < openPanelHeight - 0.5;
            final collapsed = widget.panelCollapsed && canCollapse;
            final panelHeight = collapsed ? collapsedHeight : openPanelHeight;

            // **Where "all the way down" becomes "closed"** (task 11.204).
            // Halfway between the open panel's floor and the closed strip, so
            // neither state is reachable by accident from the other, and a
            // panel showing half a bearing row — which is neither state — is
            // not reachable at all.
            final snapAt = (collapsedHeight +
                    _minPanelHeight(available,
                        chrome: chrome,
                        rowHeight: rowHeight,
                        minMapHeight: minMapHeight)) /
                2;

            void handleResizeDragStart() {
              _dragRawPanelHeight = panelHeight;
              _dragStartFraction = fraction;
            }

            void handleResizeDrag(double dy) {
              if (available <= 0) return;
              final raw = ((_dragRawPanelHeight ?? panelHeight) - dy)
                  .clamp(0.0, available * _maxPanelFraction);
              _dragRawPanelHeight = raw;
              if (raw < snapAt && canCollapse) {
                if (!widget.panelCollapsed) {
                  final restore = _dragStartFraction;
                  if (restore != null) widget.onPanelFractionChanged(restore);
                  widget.onPanelCollapsedChanged(true);
                }
                return;
              }
              if (collapsed) {
                // **Re-opening restores the height it had, not a default.**
                // The fraction was never cleared, so this is simply the panel
                // it was; the drag then continues from there rather than from
                // wherever the finger happens to be.
                widget.onPanelCollapsedChanged(false);
                _dragRawPanelHeight = openPanelHeight;
                return;
              }
              widget.onPanelFractionChanged(
                _clampPanelHeight(raw, available,
                        chrome: chrome,
                        rowHeight: rowHeight,
                        minMapHeight: minMapHeight) /
                    available,
              );
            }
            return Column(
          children: [
            Expanded(
              child: Stack(
                key: const ValueKey('position-map'),
                children: [
                  DesktopTrackpadZoom(
                    mapController: _mapController,
                    child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCameraFit: CameraFit.bounds(
                        bounds: _boundsFor(rays, estimate, ellipsePolygon),
                        padding: const EdgeInsets.all(48),
                        maxZoom: 16,
                      ),
                      minZoom: 2,
                      cameraConstraint: const CameraConstraint.containLatitude(
                        85.05112878,
                        -85.05112878,
                      ),
                      onTap: (_, point) => _onMapTap(rays, point),
                      // Match the Main Map's gesture tuning so a slight twist
                      // while panning/pinching doesn't spin the map.
                      interactionOptions: InteractionOptions(
                        flags: mapInteractionFlags(),
                        enableMultiFingerGestureRace: true,
                        rotationThreshold: 30.0,
                        pinchZoomThreshold: 0.5,
                        pinchMoveThreshold: 40.0,
                      ),
                      onMapReady: () => setState(() {
                        _cameraCenter = _mapController.camera.center;
                        _cameraZoom = _mapController.camera.zoom;
                        _cameraRotation = _mapController.camera.rotation;
                      }),
                      onMapEvent: (event) => setState(() {
                        _cameraRotation = event.camera.rotation;
                        _cameraCenter = event.camera.center;
                        _cameraZoom = event.camera.zoom;
                      }),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: tileSource.urlTemplate,
                        subdomains: tileSource.subdomains,
                        maxZoom: tileSource.maxZoom.toDouble(),
                        tileProvider: CachedTileProvider(source: tileSource),
                      ),
                      // Task 11.185 verdict: this screen does NOT have the
                      // Main Map's collision. There, a selected estimate's
                      // wedges are *darkened* to 0.35 fill / 0.45 border —
                      // above the ellipse's own 0.18 fill — so the wedges
                      // bury it. Here, wedges never exceed 0.14 fill / 0.3
                      // border (included) or 0.05/0.12 (excluded), well
                      // under the ellipse's 0.18 fill and especially its 0.7
                      // border, so the ellipse boundary stays the most
                      // visible thing on screen. No highlighting step here
                      // raises a wedge's alpha above the ellipse's the way
                      // the map's selection highlight does. Nothing changed.
                      if (ellipsePolygon != null)
                        PolygonLayer(
                          polygons: [
                            Polygon(
                              points: ellipsePolygon,
                              color: tagColor.withValues(alpha: 0.18),
                              borderColor: tagColor.withValues(alpha: 0.7),
                              borderStrokeWidth: 1.5,
                            ),
                          ],
                        ),
                      // Translucent uncertainty wedges (±bearing uncertainty)
                      // fanning from each measurement point, under the rays.
                      PolygonLayer(
                        polygons: [
                          for (final r in rays)
                            Polygon(
                              points: [
                                for (final p in bearingWedgePoints(
                                  origin: GeoPoint(
                                    r.origin.latitude,
                                    r.origin.longitude,
                                  ),
                                  bearingDeg: r.bearingDeg,
                                  halfWidthDeg: r.halfWidthDeg,
                                  rangeMeters: r.lengthM,
                                ))
                                  ll.LatLng(p.latitude, p.longitude),
                              ],
                              color: tagColor.withValues(
                                alpha: r.included ? 0.14 : 0.05,
                              ),
                              borderColor: tagColor.withValues(
                                alpha: r.included ? 0.3 : 0.12,
                              ),
                              borderStrokeWidth: 0.5,
                            ),
                        ],
                      ),
                      // Excluded rays first (underneath), translucent, so the
                      // user still sees them and can tap to re-include.
                      PolylineLayer(
                        polylines: [
                          for (final r in rays.where((r) => !r.included))
                            Polyline(
                              points: [r.origin, r.end],
                              color: tagColor.withValues(alpha: 0.28),
                              strokeWidth: 2,
                            ),
                          for (final r in rays.where((r) => r.included))
                            Polyline(
                              points: [r.origin, r.end],
                              color: tagColor,
                              strokeWidth: 3,
                            ),
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          for (final r in rays)
                            // Task 11.94/11.101 exemption: `tooltip:` carries
                            // the full name, but the marker already renders
                            // the observer's initials as visible text — the
                            // tooltip is not this marker's only label.
                            Marker(
                              point: r.origin,
                              // **Sized from the text it holds** (task
                              // 11.204). Held at a flat 22 it clipped the
                              // initials from xxxLarge up — 22 of 38 pixels
                              // shown at AX1, with nothing to say so, which
                              // is the silent-clip class the text-scale probe
                              // exists to catch. **Found by the closed-panel
                              // measurement**: with the panel open at its
                              // default split the map is small enough that
                              // these markers never came out clipped, so no
                              // ladder in this suite had ever seen it.
                              //
                              // Growing it costs the map picture, not the
                              // clear band — a marker is drawn *inside* the
                              // map, not over it — and it is the same
                              // decision every row on this screen already
                              // makes. **Nobody has looked at one of these on
                              // a device at an accessibility text size.**
                              width: observerMarkerSize(context),
                              height: observerMarkerSize(context),
                              child: Tooltip(
                                message: observerName(r.userId, observers),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: r.included
                                        ? tagColor
                                        : tagColor.withValues(alpha: 0.28),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white, width: 1.5),
                                  ),
                                  // Initials, not colour, are what tells two
                                  // observers' rays apart (the project's
                                  // standing rule against colour-only cues —
                                  // colour here only ever encodes
                                  // included/excluded).
                                  child: Center(
                                    child: Text(
                                      observerInitials(r.userId, observers),
                                      style: const TextStyle(
                                        fontSize: 8,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (estimate != null)
                            Marker(
                              point: estimate,
                              width: 18,
                              height: 18,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: tagColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                          if (gps != null)
                            Marker(
                              point: ll.LatLng(gps.latitude, gps.longitude),
                              width: 18,
                              height: 18,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    ),
                  ),
                  // **A corner cluster, not a band** (task 11.203). The
                  // basemap toggle used to run the full width of the top
                  // strip, which is what made that strip a band at all — MAP
                  // SPACE BUDGET rule 4 is "corners before edges, edges
                  // before bands," and a 48px square costs the clear band
                  // nothing that a full-width control could not avoid. The
                  // north arrow (still a condition, not a fixture — it only
                  // appears when the map is rotated) keeps the opposite
                  // corner so the two clusters can never collide.
                  // Task 11.205: joins the north arrow's corner (rule 4 —
                  // "corners before edges") rather than taking an anchor of
                  // its own. This screen was the only live map in the app
                  // saying nothing when the tile service stops answering,
                  // and the reason was a measurement, not an oversight: the
                  // clear band used to be 96 against a floor of 96, with
                  // nothing spare. Task 11.204's clear-band rewrite found the
                  // band was actually 161.8 — the old arithmetic had been
                  // charging for pixels this corner never covered — so the
                  // band now fits.
                  Positioned(
                    key: const ValueKey('position-map-top-band'),
                    top: 8,
                    left: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TilesNotLoadingBand(
                          bannerKey: ValueKey('position-tiles-not-loading'),
                          padding: EdgeInsets.only(bottom: 8),
                        ),
                        if (_cameraRotation.abs() > 0.5)
                          MapNorthArrow(
                            rotationDeg: _cameraRotation,
                            onTap: () => _mapController.rotate(0),
                          ),
                      ],
                    ),
                  ),
                  // **The layers and legend squares, stacked** (task 11.203):
                  // layers above legend, as asked. Whichever panel is open
                  // is this column's own third child, so its position is
                  // derived from the buttons above it rather than a `top:`/
                  // `bottom:` constant that drifts the next time a button is
                  // added — this screen has been bitten by exactly that.
                  // Only one of the two panels is ever in the tree.
                  Positioned(
                    key: const ValueKey('position-map-corner-buttons'),
                    top: 8,
                    right: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        MapLayersButton(
                          active: _showLayers,
                          onPressed: () => setState(() {
                            _showLayers = !_showLayers;
                            if (_showLayers) _showLegend = false;
                          }),
                        ),
                        const SizedBox(height: 8),
                        MapLegendButton(
                          active: _showLegend,
                          onPressed: () => setState(() {
                            _showLegend = !_showLegend;
                            if (_showLegend) _showLayers = false;
                          }),
                        ),
                        if (_showLayers) ...[
                          const SizedBox(height: 8),
                          tileCategoryAsync.when(
                            // **The shared control, straight on the map**
                            // (task 11.319 item 5) — the one the Map tab and
                            // *Take on map* use, with no card behind it: its
                            // labels are white over their own dark outline,
                            // so a near-white card would put white on white.
                            // The bound is task 11.274's and is kept:
                            // `SegmentedToggle`'s `Row` has flex children and
                            // needs a bounded width from whatever places it.
                            // The Main Map gets one from a `ConstrainedBox
                            // (maxWidth: 340)` in its full-width top band;
                            // this corner column (`Positioned(top:, right:)`,
                            // task 11.203) has no width constraint of its own
                            // at all, so without the same bound the toggle
                            // threw out of `performLayout` with `size:
                            // MISSING` the moment the panel opened. The fix
                            // is the caller, not `SegmentedToggle`.
                            data: (category) => ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 340),
                              child: MapTypeToggle(
                                category: category,
                                onChanged: (c) => ref
                                    .read(selectedTileCategoryProvider.notifier)
                                    .set(c),
                              ),
                            ),
                            loading: () => const SizedBox.shrink(),
                            error: (_, _) => const SizedBox.shrink(),
                          ),
                        ] else if (_showLegend) ...[
                          const SizedBox(height: 8),
                          MapLegendCard(
                            rows: [
                              (tagColor, 'Included bearing'),
                              (tagColor.withValues(alpha: 0.3), 'Excluded bearing'),
                              (tagColor, 'Estimated position'),
                            ],
                            footnote: 'Tap a ray on the map to include or '
                                'exclude that bearing.',
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Task 11.95: one bottom-left column — hint, scale bar,
                  // lat/lon readout, map-source credit — rather than three
                  // separately positioned pieces stacked by `bottom:`
                  // constants. The credit wraps to as many lines as it needs
                  // (flutter_map's own attribution widget clipped it on every
                  // phone), and everything above it moves up by however many
                  // lines that turns out to be, by construction.
                  Positioned(
                    key: const ValueKey('position-map-bottom-band'),
                    left: _mapReadoutInset,
                    // Full width: this is what decides where the credit
                    // wraps, so the readout column doesn't need to guess a
                    // right inset — and it is the same width
                    // [_mapReadoutColumnHeightFor] measures the column at.
                    right: _mapReadoutInset,
                    bottom: _mapReadoutInset,
                    // The "tap a ray to include/exclude" hint used to sit in
                    // this column, as a permanent band. It is onboarding copy
                    // — read once, then paid for forever — so task 11.110
                    // moved it into the legend card, behind the legend
                    // button. See this file's MAP SPACE BUDGET.
                    //
                    // Task 11.148 moved the column itself into
                    // [MapBottomReadoutColumn], so that the height this
                    // screen reserves for it and the widget that fills the
                    // reservation are one piece of code.
                    child: MapBottomReadoutColumn(
                      latitude: _cameraCenter.latitude,
                      zoom: _cameraZoom,
                      gps: gps,
                      format: widget.project.coordinateFormat,
                      source: tileSource,
                      onShowAttributionDetails: () =>
                          showMapAttributionSheet(context, tileSource),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: panelHeight,
              child: collapsed
                  ? _CollapsedPanelHandle(
                      cautions: _ObservationSheet.warningMessagesFor(
                        result,
                        spanMinutes,
                        kTriangulationDefaultWindow.inMinutes,
                      ),
                      onExpand: () => widget.onPanelCollapsedChanged(false),
                      onResizeDragStart: handleResizeDragStart,
                      onResizeDrag: handleResizeDrag,
                      onResizeDragEnd: () => _dragRawPanelHeight = null,
                    )
                  : _ObservationSheet(
                headerRowHeight: headerRowHeight,
                controlsRowHeight: controlsRowHeight,
                saveRowHeight: saveRowHeight,
                // **Task 11.147.** The panel scrolls as one exactly when it
                // has less room than its own furniture plus a bearing row —
                // which, now that [_clampPanelHeight] holds the map's floor,
                // is what happens above the ordinary text-size slider. At
                // every size below that this is false and the panel is the
                // one task 11.109 built, to the pixel.
                scrollAsOne: panelHeight < chrome + rowHeight - 0.5,
                cannotSaveReason: cannotSaveReason,
                onResizeDragStart: handleResizeDragStart,
                onResizeDrag: handleResizeDrag,
                onResizeDragEnd: () => _dragRawPanelHeight = null,
                observations: displayObservations,
                observers: observers,
                sort: _sort,
                distanceAvailable: distanceAvailable,
                usingDistanceFallback: usingDistanceFallback,
                onSortChanged: (s) => setState(() => _sort = s),
                excludedIds: widget.excludedIds,
                onToggleExcluded: widget.onToggleExcluded,
                onSelectAll: widget.onSelectAll,
                onDeselectAll: () =>
                    widget.onDeselectAll(observations.map((o) => o.observationId).toList()),
                result: result,
                spanMinutes: spanMinutes,
                windowMinutes: kTriangulationDefaultWindow.inMinutes,
                saving: widget.saving,
                mayWrite: mayWrite,
                onSave: () => widget.onSave(
                  result,
                  included.map((o) => o.observationId).toList(),
                ),
                onViewPastEstimates: () =>
                    _showPastEstimatesSheet(context, widget.project.projectId, widget.tag),
              ),
            ),
          ],
            );
          },
        );
      },
    );
  }

  void _onMapTap(List<_MapRay> rays, ll.LatLng point) {
    final hit = _hitTestRay(rays, point);
    if (hit != null) widget.onToggleExcluded(hit);
  }

  /// Nearest ray to a tapped point, in screen pixels via the live camera, or
  /// null if nothing is within [thresholdPx].
  String? _hitTestRay(List<_MapRay> rays, ll.LatLng tapLatLng, {double thresholdPx = 24}) {
    final camera = _mapController.camera;
    final tap = camera.latLngToScreenOffset(tapLatLng);
    String? best;
    var bestDist = thresholdPx;
    for (final r in rays) {
      final a = camera.latLngToScreenOffset(r.origin);
      final b = camera.latLngToScreenOffset(r.end);
      final d = _distanceToSegment(tap, a, b);
      if (d < bestDist) {
        bestDist = d;
        best = r.observationId;
      }
    }
    return best;
  }

  static double _distanceToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
    if (lenSq == 0) return (p - a).distance;
    var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
    t = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  /// LatLng bounds enclosing every ray endpoint, the estimate, and the error
  /// ellipse, so the initial camera frames the whole geometry.
  LatLngBounds _boundsFor(
    List<_MapRay> rays,
    ll.LatLng? estimate,
    List<ll.LatLng>? ellipse,
  ) {
    final points = <ll.LatLng>[
      for (final r in rays) ...[r.origin, r.end],
      ?estimate,
      ...?ellipse,
    ];
    return LatLngBounds.fromPoints(points);
  }

  /// Uncertainty-ellipse boundary as lat/lon points (shared math with the Main
  /// Map, see [ellipsePolygonPoints]).
  List<ll.LatLng> _ellipsePoints({
    required ll.LatLng center,
    required double semiMajorM,
    required double semiMinorM,
    required double rotationCompassDeg,
  }) {
    return [
      for (final p in ellipsePolygonPoints(
        center: GeoPoint(center.latitude, center.longitude),
        semiMajorMeters: semiMajorM,
        semiMinorMeters: semiMinorM,
        rotationCompassDeg: rotationCompassDeg,
      ))
        ll.LatLng(p.latitude, p.longitude),
    ];
  }

  /// Browse + delete past saved estimates for the current tag (design doc's
  /// Interaction Patterns Summary: "Destructive actions... require confirm +
  /// undo"). This screen otherwise only ever computes/saves a *new* estimate
  /// from the currently-selected observations — there's no other place a
  /// saved [EstimatedPosition] is browsable except as an unlabeled marker on
  /// Main Map, so past-estimate management lives here, one level below the
  /// tag selector that already scopes everything else on this screen.
  Future<void> _showPastEstimatesSheet(BuildContext context, String projectId, Tag tag) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final estimatesAsync = ref.watch(_pastEstimatesProvider((projectId, tag.tagId)));
          // Task 11.14: deleting an estimate is the same contributor-level
          // rung as saving one — not author-restricted (`EstimatedPositionRepository`
          // uses `MutationRule.anyUser`), so this is the coarser `mayWrite`
          // gate rather than `authorEditVerdict`.
          final standing =
              ref.watch(myProjectStandingProvider(projectId)).value ??
              ProjectStanding.unknown;
          final mayWrite = standing.mayWriteProjectData;
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    'Past estimates · ${tag.tagName}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
                Expanded(
                  child: estimatesAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) =>
                        LoadFailure('the saved estimates for this tag', error: e),
                    data: (estimates) => estimates.isEmpty
                        ? const Center(child: Text('No saved estimates for this tag yet.'))
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: estimates.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, i) {
                              final e = estimates[i].estimate;
                              final resolution = estimates[i].resolution;
                              return ListTile(
                                dense: true,
                                title: Text(e.timestampLocal.toString().substring(0, 16)),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${e.hasEllipse ? 'ellipse ${e.semiMajorAxis!.round()}×${e.semiMinorAxis!.round()}m' : 'no ellipse'} · '
                                      '${resolution.label('observations')}',
                                    ),
                                    // Task 11.336: by the stored list's
                                    // length, not the resolvable count — see
                                    // `FewBearingsCaution`.
                                    if (FewBearingsCaution.applies(
                                      bearings: resolution.totalCount,
                                      hasEllipse: e.hasEllipse,
                                    ))
                                      const Text(FewBearingsCaution.text),
                                  ],
                                ),
                                // Task 11.94/11.101: the refusal used to live
                                // only in this button's `tooltip:`, which a
                                // touchscreen never shows. It stays tappable
                                // and explains itself instead.
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: 'Delete',
                                  onPressed: () => mayWrite
                                      ? _deleteEstimate(context, ref, projectId, tag, e)
                                      : _explainCannotDeleteEstimate(context, standing),
                                ),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _explainCannotDeleteEstimate(
    BuildContext context,
    ProjectStanding standing,
  ) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            standing.isSnapshot
                ? 'You are not on this project'
                : 'Only an owner or contributor can delete this',
          ),
          content: Text(
            standing.writeRefusal(
                  asViewer:
                      'Viewers cannot delete a position estimate — ask an '
                      'owner to change your role.',
                ) ??
                // Unreachable — this dialog is only opened when the write is
                // refused — but a fallback that asserts no cause is the honest
                // one for a branch the code does not expect.
                'This estimate cannot be deleted on this device right now.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );

  Future<void> _deleteEstimate(
    BuildContext context,
    WidgetRef ref,
    String projectId,
    Tag tag,
    EstimatedPosition estimate,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this estimate?'),
        content: const Text('You can undo this from the confirmation that follows.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    // Guard every subsequent `ref`/`context` use: the dialog await can span
    // an arbitrarily long real-world gap (backgrounding the app, dismissing
    // the sheet, navigating away), and `ref` throws — not a silent no-op —
    // if the underlying element has been unmounted by the time it resolves.
    if (confirmed != true || !context.mounted) return;

    final user = await ref.read(currentUserProvider.future);
    if (!context.mounted) return;
    final deviceId = await ref.read(deviceIdProvider.future);
    if (!context.mounted) return;
    final repo = await ref.read(estimatedPositionRepositoryProvider.future);
    if (!context.mounted) return;
    final deleted = await runGuardedWrite(
      context,
      write: () => repo.softDelete(estimate,
          actor: MutationActor.user(user.userId), deviceId: deviceId),
      refused: 'Only a project owner can delete this estimate; it is still '
          'here.',
      failed: 'Could not delete this estimate; it is still in the list. Try '
          'again, and report it if this keeps happening.',
    );
    if (!deleted || !context.mounted) return;
    ref.invalidate(_pastEstimatesProvider((projectId, tag.tagId)));
    ref.read(recordingsRevisionProvider.notifier).bump();

    // Clear any still-showing snackbar first — otherwise deleting a second
    // estimate shortly after the first queues its undo bar behind the first
    // instead of replacing it.
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Estimate deleted'),
        duration: const Duration(seconds: 6),
        // Task 11.42: an action makes this default to `persist: true`
        // (Material 3), which leaves `duration` dead — see
        // `projects_screen.dart`'s delete-project undo bar for the finding.
        persist: false,
        action: SnackBarAction(
          label: 'UNDO',
          onPressed: () async {
            if (!context.mounted) return;
            final restored = await runGuardedWrite(
              context,
              write: () => repo.restore(estimate,
                  actor: MutationActor.user(user.userId), deviceId: deviceId),
              refused: 'You may no longer change this estimate, so it could '
                  'not be brought back. Ask a project owner.',
              failed: 'Could not bring this estimate back; it is still '
                  'deleted. Try again, and report it if this keeps happening.',
            );
            if (!restored || !context.mounted) return;
            ref.invalidate(_pastEstimatesProvider((projectId, tag.tagId)));
            ref.read(recordingsRevisionProvider.notifier).bump();
          },
        ),
      ),
    );
  }
}

/// **Task 11.7: the one place that decides what the solver counts.**
///
/// Superseded and excluded observations are removed here, before anything
/// downstream sees them, so the bearing list, the map rays and the solve all
/// agree — and so a corrected bearing and the bearing it corrects can never be
/// counted as two independent lines of evidence. The Lenth estimator's
/// confidence ellipse tightens with the number of bearings it is given, so
/// double-counting would report a position that is both wrong and more precise
/// than the data supports. See [AnalysisEligibility] for the rule and
/// `test/data/analysis/analysis_eligibility_test.dart` for the proof that it
/// moves the estimate.
///
/// ## Why the observers come back from this same provider (task 11.144)
///
/// [observers] is every person who contributed one of these bearings.
/// Teammates' bearings are included in the solve by default (Phase 6 replica
/// import), so without their names a teammate's ray is visually
/// indistinguishable from the user's own — task 11.5's whole reason for
/// existing: an unattributable ray is a data-quality hazard, not a cosmetic
/// gap.
///
/// **It used to be a second provider that watched this one, and that pairing
/// is what made every completed sync round trip a framework assertion.** A
/// sync round announces its arrival, which marks this provider stale. On the
/// next frame the screen's `build` calls `ref.watch` on it, and Riverpod
/// recomputes it *there*, inside the build — which is fine on its own. What
/// was not fine is what the recomputation then did: it notified the observers
/// provider, which watched this one, so that provider invalidated itself and
/// asked the surrounding `ProviderScope` to schedule a refresh. That ask is a
/// `setState` on a widget above the one being built, and a debug build stops
/// on it with *"setState() or markNeedsBuild() called during build"*. Release
/// builds do not check the rule, so a phone showed nothing at all — but a
/// widget writing above itself mid-build is a real ordering fault, and it was
/// reached from **any** tab, because `StatefulShellRoute.indexedStack` keeps
/// every visited branch mounted.
///
/// **The remedy is to have nothing downstream to notify.** One provider
/// answering both halves of one question cannot cascade into a second one, and
/// it also loads the users in the same round trip the bearings arrive on, so
/// the list no longer shows raw user ids for a frame while their names catch
/// up. `position_estimation_no_write_during_build_test.dart` is the guard.
final _directionalObservationsProvider = FutureProvider.family<
    ({List<Observation> observations, Map<String, User> observers}),
    (String, String)>((ref, key) async {
  // Refresh whenever anything anywhere adds/edits/deletes a recording — so a
  // bearing saved from the Record screen shows up here live, without leaving
  // and re-entering Position Estimation (same fix as historyDataProvider in
  // log_screen.dart and _mapDataProvider in map_screen.dart).
  ref.watch(recordingsRevisionProvider);
  final (projectId, tagId) = key;
  final repo = await ref.watch(observationRepositoryProvider.future);
  final markRepo = await ref.watch(observationExclusionRepositoryProvider.future);
  final userRepo = await ref.watch(userRepositoryProvider.future);
  final all = await repo.findByProjectAndTag(projectId, tagId);
  final marks = await markRepo.activeByObservation(projectId);
  final observations = AnalysisEligibility.eligible(
    all
        .where((o) =>
            o.observationType == ObservationType.directional && o.trueNorthBearing != null)
        .toList(),
    marks,
  );
  final observers = <String, User>{};
  for (final id in observations.map((o) => o.userId).toSet()) {
    final user = await userRepo.findById(id, includeDeleted: true);
    if (user != null) observers[id] = user;
  }
  return (observations: observations, observers: observers);
});

/// Two-letter fallback so a marker/badge is never blank while a user record
/// is still loading or (for an orphaned replica) missing entirely.
String observerInitials(String userId, Map<String, User> users) {
  final u = users[userId];
  if (u == null) {
    return userId.isEmpty ? '?' : userId.substring(0, 1).toUpperCase();
  }
  final first = u.firstName.isNotEmpty ? u.firstName[0] : '';
  final last = u.lastName.isNotEmpty ? u.lastName[0] : '';
  final initials = '$first$last'.toUpperCase();
  return initials.isEmpty ? '?' : initials;
}

String observerName(String userId, Map<String, User> users) {
  final u = users[userId];
  return u == null ? userId : '${u.firstName} ${u.lastName}';
}

/// First initial and surname — the row form (task 11.152). Shortens what is
/// *rendered*; the stored observation, and anything that exports, syncs or
/// is read in R, still carries the full name via [observerName].
///
/// **Collision is accepted, not resolved.** Two observers can share an
/// initial and a surname and this returns the same string for both — the
/// same tradeoff the initials badge ([observerInitials]) already makes one
/// step further, since it drops the surname entirely. A row's [Tooltip]
/// carries the full name for the case this collapses.
/// **Whether two observers in [observations] would share one badge.**
///
/// Task 11.274: Michael's short name is dropped from the bearing row's
/// visible line whenever the badge already says enough — but
/// [observerInitials] is two letters, and two field techs can share both
/// (a "J.D." pair, say). This checks the set that can actually collide on
/// one screen — the observers who appear in *this* bearing list, not the
/// whole project's membership, which could share initials harmlessly
/// without ever landing on the same row together.
bool _observerInitialsCollide(List<Observation> observations, Map<String, User> observers) {
  final seen = <String>{};
  for (final userId in observations.map((o) => o.userId).toSet()) {
    if (!seen.add(observerInitials(userId, observers))) return true;
  }
  return false;
}

String observerShortName(String userId, Map<String, User> users) {
  final u = users[userId];
  if (u == null) return userId;
  final first = u.firstName.isNotEmpty ? '${u.firstName[0]}. ' : '';
  return '$first${u.lastName}'.trim().isEmpty ? observerName(userId, users) : '$first${u.lastName}';
}

/// A past estimate together with which of its `observation_ids_used`
/// resolve to a bearing this device actually holds — task 11.259. A
/// season-clone carries the list across on purpose (see
/// `_createEstimatedPositions`'s doc comment in `lib/data/db/schema.dart`),
/// so an id here can name a bearing that stayed in last season's project.
typedef _PastEstimate = ({
  EstimatedPosition estimate,
  EstimateBearingResolution resolution,
});

final _pastEstimatesProvider =
    FutureProvider.family<List<_PastEstimate>, (String, String)>((ref, key) async {
  // See _directionalObservationsProvider above for why this watch is needed.
  ref.watch(recordingsRevisionProvider);
  final (projectId, tagId) = key;
  final repo = await ref.watch(estimatedPositionRepositoryProvider.future);
  final obsRepo = await ref.watch(observationRepositoryProvider.future);
  final all = await repo.findByProject(projectId);
  final forTag = all.where((e) => e.tagId == tagId).toList()
    ..sort((a, b) => b.timestampUtc.compareTo(a.timestampUtc));
  // Every bearing this device holds for this tag, resolvable or not, eligible
  // or excluded — resolution asks only "does this id name a bearing that is
  // here", not whether that bearing currently feeds an analysis.
  final localIds = {
    for (final o in await obsRepo.findByProjectAndTag(projectId, tagId))
      o.observationId,
  };
  return [
    for (final e in forTag)
      (
        estimate: e,
        resolution: EstimateBearingResolution.of(e.observationIdsUsed, localIds),
      ),
  ];
});

/// The observer marker's diameter at this phone's text size.
///
/// 22 logical pixels at the default, and it grows with the initials inside it
/// (task 11.204): the marker is a circle holding two letters, and a circle
/// that does not grow with its letters clips them silently.
double observerMarkerSize(BuildContext context) =>
    math.max(22.0, MediaQuery.textScalerOf(context).scale(22.0));

/// Small circular badge showing an observer's initials — the non-colour cue
/// that tells one observer's bearing rows apart from another's in the list,
/// matching the map markers drawn by [_MapRay].
///
/// ## Why the dimmed initials are full-strength (task 11.201)
///
/// The excluded badge used to draw `onSurfaceVariant` initials on an
/// `outlineVariant` circle. Neither token was passed to the app's
/// [ColorScheme], both fell back to `onSurface`, and the initials were
/// **invisible** — 1.00:1, in the one state where somebody is asking *whose
/// bearing did I take out*. Task 11.200 defined `onSurfaceVariant` and got
/// 3.26:1 light / 2.46:1 dark, which is visible and still under any floor.
///
/// Two levers reach a floor from there, and only one of them keeps a badge.
/// Holding the muted initials and lightening the circle until the pair clears
/// 4.5:1 needs a fill of about `#EBEBE8` in light, which is 1.06:1 against
/// the card — a *circle nobody can see*, trading an invisible label for an
/// invisible shape. So the fill became a mid neutral and the initials became
/// full-strength [ColorScheme.onSurface]: **7.12:1 light, 7.93:1 dark**,
/// clearing WCAG 2.1 AAA for normal text, which is the case 9px bold text
/// falls in (WCAG "large" starts at 14pt bold).
///
/// **Excluded is still unmistakable, and not from this badge alone.** The
/// circle gives up the brand green — which is the dimming `CLAUDE.md` asks an
/// excluded row to keep — and the row around it carries an unticked checkbox
/// and a muted title. Full-strength initials on a grey chip never read as the
/// included state, because the included state is white on green.
class ObserverBadge extends StatelessWidget {
  const ObserverBadge({super.key, required this.initials, required this.dimmed});
  final String initials;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 12,
      backgroundColor: dimmed ? scheme.outlineVariant : scheme.primary,
      child: Text(
        initials,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          color: dimmed ? scheme.onSurface : scheme.onPrimary,
        ),
      ),
    );
  }
}

/// The bearing sort, as one button that opens a menu.
///
/// Was three permanently-visible `ChoiceChip`s in a row of their own until
/// task 11.109. Sort *is* an input you act on while choosing bearings, so by
/// rule 2 it keeps permanent space — but a whole row for a control that is
/// touched a few times a session, on a screen where the subject had no room
/// left, is not the shape that space should take. It shares the controls row
/// instead.
///
/// The rule from tasks 11.4 and 11.5 is unchanged and is what the menu form
/// has to keep carrying: **distance sort must present as unavailable with a
/// visible reason when there is no GPS fix, never stay selectable and quietly
/// order by something else.** So the reason is written into the menu entry
/// itself — not a tooltip (task 11.101) — and the button always shows the
/// order the list is actually in.
class _SortMenuButton extends StatelessWidget {
  const _SortMenuButton({
    required this.sort,
    required this.distanceAvailable,
    required this.onChanged,
  });

  final _BearingSort sort;
  final bool distanceAvailable;
  final ValueChanged<_BearingSort> onChanged;

  static const _options = [
    (_BearingSort.time, 'Time', Icons.schedule),
    (_BearingSort.member, 'Member', Icons.person_outline),
    (_BearingSort.distance, 'Distance', Icons.social_distance),
  ];

  static String labelFor(_BearingSort sort) =>
      _options.firstWhere((o) => o.$1 == sort).$2;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The button names the order the list is *actually* in. With no fix,
    // `sort` may still be `distance` while the caller is displaying time
    // order; showing "Distance" there would be the exact lie 11.4 forbade.
    final effective =
        (sort == _BearingSort.distance && !distanceAvailable) ? _BearingSort.time : sort;
    return PopupMenuButton<_BearingSort>(
      tooltip: 'Sort bearings',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final (value, label, icon) in _options)
          PopupMenuItem<_BearingSort>(
            value: value,
            enabled: value != _BearingSort.distance || distanceAvailable,
            child: Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value == _BearingSort.distance && !distanceAvailable
                        // The reason is in the row, visible without hovering
                        // or long-pressing anything.
                        ? '$label — no GPS fix'
                        : label,
                  ),
                ),
                if (value == effective) const Icon(Icons.check, size: 18),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sort, size: 16, color: scheme.primary),
            const SizedBox(width: 4),
            // Task 11.147: `Flexible`, because this button is now a child of
            // a `Wrap` and a `Wrap` cannot break *inside* a child. "Distance"
            // at the top of the accessibility ladder is wider than the panel,
            // so without this the one control that could not wrap would be
            // the one that overflowed. Ellipsis rather than clip: a
            // shortened word has to say it was shortened.
            Flexible(
              child: Text(
                labelFor(effective),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _ObservationSheet extends StatelessWidget {
  const _ObservationSheet({
    required this.headerRowHeight,
    required this.controlsRowHeight,
    required this.saveRowHeight,
    required this.scrollAsOne,
    required this.cannotSaveReason,
    required this.onResizeDragStart,
    required this.onResizeDrag,
    required this.onResizeDragEnd,
    required this.observations,
    required this.observers,
    required this.sort,
    required this.distanceAvailable,
    required this.usingDistanceFallback,
    required this.onSortChanged,
    required this.excludedIds,
    required this.onToggleExcluded,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.result,
    required this.spanMinutes,
    required this.windowMinutes,
    required this.saving,
    required this.mayWrite,
    required this.onSave,
    required this.onViewPastEstimates,
  });

  /// The panel's fixed furniture, sized by the caller so that the caller can
  /// compute the split *from* it rather than after it. Changing these here
  /// without changing them there is exactly the drift the space-budget test
  /// exists to catch.
  final double headerRowHeight;
  final double controlsRowHeight;
  final double saveRowHeight;

  /// **Whether the whole panel scrolls as one piece (task 11.147).**
  ///
  /// False — the ordinary case, and every text size on the ordinary slider —
  /// gives the panel task 11.109 built: fixed furniture top and bottom, and
  /// the bearings list scrolling in the middle, so the sort, the count and
  /// SAVE POSITION are always on screen.
  ///
  /// True when the panel has less height than its furniture plus one bearing
  /// row, which above the accessibility text sizes it does. Then the header,
  /// the controls, every bearing and the save row become one scrolling
  /// column. **The furniture stops being pinned, and that is the price
  /// Michael's decision paid**: what it buys is that nothing is clamped, so
  /// nothing bursts and no bearing is unreachable.
  final bool scrollAsOne;

  /// The sentence shown instead of a working save button. Passed in rather
  /// than written here because the caller has to measure it to reserve
  /// [saveRowHeight] for it (task 11.139) — two copies of a sentence is how
  /// one of them gets edited.
  /// The sentence shown instead of a working SAVE — a viewer's, or the
  /// snapshot refusal (task 11.237). Only read while [mayWrite] is false.
  final String cannotSaveReason;

  /// Vertical drag on the header row, in logical pixels (positive = down).
  ///
  /// [onResizeDragStart] and [onResizeDragEnd] bracket it so the caller can
  /// carry an unclamped height across the gesture — without that a drag cannot
  /// push the panel past its own floor, and "all the way down" is unreachable
  /// (task 11.204).
  final VoidCallback onResizeDragStart;
  final ValueChanged<double> onResizeDrag;
  final VoidCallback onResizeDragEnd;

  /// Ordered by the caller per [sort] — display only, never the set fed to
  /// the solver.
  final List<Observation> observations;
  final Map<String, User> observers;
  final _BearingSort sort;
  final bool distanceAvailable;
  final bool usingDistanceFallback;
  final ValueChanged<_BearingSort> onSortChanged;
  final Set<String> excludedIds;
  final ValueChanged<String> onToggleExcluded;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;
  final GeographicLocalizationResult result;
  final int spanMinutes;
  final int windowMinutes;
  final bool saving;

  /// Task 11.14: whether the role gradient permits saving an estimate in this
  /// project at all — a viewer walks away with the raw `UnauthorizedMutation`
  /// throw otherwise, the same class of gap 11.12 fixed for recording an
  /// observation.
  final bool mayWrite;
  final VoidCallback onSave;
  final VoidCallback onViewPastEstimates;

  @override
  Widget build(BuildContext context) {
    final n = observations.where((o) => !excludedIds.contains(o.observationId)).length;
    final total = observations.length;
    final cautions = warningMessagesFor(result, spanMinutes, windowMinutes);
    // Task 11.274, Michael: "you don't need the user name as well (initial
    // and last name), right? That will save a bit of room on each line" —
    // the badge already carries it. Computed once per build, over every
    // observer who actually appears in this list (not the whole project),
    // because that's the only set two rows next to each other can collide
    // within.
    final observerInitialsCollide = _observerInitialsCollide(observations, observers);

    final column = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        // `min` when the panel scrolls: the column is then laid out at its
        // natural height inside an unbounded viewport, and it is the viewport
        // that is the panel's height.
        mainAxisSize: scrollAsOne ? MainAxisSize.min : MainAxisSize.max,
        children: [
          _PanelHeaderRow(
            height: headerRowHeight,
            onResizeDragStart: onResizeDragStart,
            onResizeDrag: onResizeDrag,
            onResizeDragEnd: onResizeDragEnd,
            cautions: cautions,
            onViewPastEstimates: onViewPastEstimates,
          ),
          _PanelControlsRow(
            height: controlsRowHeight,
            selectedCount: n,
            total: total,
            sort: sort,
            distanceAvailable: distanceAvailable,
            onSortChanged: onSortChanged,
            onSelectAll: onSelectAll,
            onDeselectAll: onDeselectAll,
          ),
          // A condition, so it takes space only while it holds (rule 3):
          // the user picked distance sort and then lost the fix, and the
          // list must never quietly claim to be in an order it is not
          // (tasks 11.4/11.5).
          if (usingDistanceFallback)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
              child: Text(
                'No GPS fix — distance unavailable, showing time order instead.',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          // Scrolling in the middle of a fixed frame, or one row of a column
          // that scrolls as a whole — see [scrollAsOne]. `Expanded` is what
          // makes it the former, and it is exactly what cannot be used in the
          // latter: a flex child has no natural height to give a viewport.
          _flexOrShrinkWrap(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shrinkWrap: scrollAsOne,
              // One scroll gesture, not two nested ones. When the panel
              // scrolls as a whole, this list is not a scroller at all.
              physics: scrollAsOne ? const NeverScrollableScrollPhysics() : null,
              itemCount: observations.length,
              itemBuilder: (context, index) {
                final o = observations[index];
                final excluded = excludedIds.contains(o.observationId);
                final colors = Theme.of(context).extension<TriTrackColors>()!;
                return CheckboxListTile(
                  // Keyed so the space-budget test can ask for a *named* row
                  // — specifically the last one, which is the row a clamped
                  // panel loses first and the one task 11.147's reachability
                  // check is about.
                  key: ValueKey('bearing-row-${o.observationId}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: !excluded,
                  onChanged: (_) => onToggleExcluded(o.observationId),
                  secondary: ObserverBadge(
                    initials: observerInitials(o.userId, observers),
                    dimmed: excluded,
                  ),
                  title: Tooltip(
                    // Task 11.94/11.101 exemption, as for the map marker
                    // above: the tooltip is the full-name disambiguator, not
                    // the row's only label — the badge (and, when initials
                    // collide, the short name printed here too) already
                    // carry it visibly.
                    message: observerName(o.userId, observers),
                    child: Semantics(
                      // Task 11.274: the visible line drops the observer's
                      // name when nothing else on screen collides with it —
                      // Michael's "you don't need the user name as well"
                      // — but a screen reader still needs to be told whose
                      // bearing this is, so the full sentence is said either
                      // way and only the *painted* text shortens.
                      label: '${observerName(o.userId, observers)}, '
                          '${o.timestampLocal.month}/${o.timestampLocal.day} '
                          '${o.timestampLocal.hour.toString().padLeft(2, '0')}:'
                          '${o.timestampLocal.minute.toString().padLeft(2, '0')}',
                      child: ExcludeSemantics(
                        child: Text(
                          [
                            // Kept only when two observers on this list
                            // would otherwise share the same badge — see
                            // [_observerInitialsCollide].
                            if (observerInitialsCollide) observerShortName(o.userId, observers),
                            '${o.timestampLocal.month}/${o.timestampLocal.day} '
                                '${o.timestampLocal.hour.toString().padLeft(2, '0')}:'
                                '${o.timestampLocal.minute.toString().padLeft(2, '0')}',
                          ].join(' — '),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: excluded ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // **The row a person actually decides on** (Michael,
                  // 2026-09-07). It used to print `bearingQuality.db` and
                  // `signalStrength.db` — the raw database tokens, in one flat
                  // grey — so a bounced bearing read `suspected_bounce` on the
                  // one screen where somebody is choosing what to count, while
                  // the Record screen had been showing `Bounce?` in red all
                  // along. The words and the three colours now come from
                  // `observation_quality_display.dart`, which both screens
                  // read.
                  //
                  // **The colour never carries the meaning on its own** — the
                  // word is always there beside it. A coloured dot alone was
                  // the alternative and it was rejected: there is no legend on
                  // this panel to teach one, and green-and-red is the pair that
                  // collapses for a red-green colour vision deficiency.
                  //
                  // **An excluded row keeps its dimming and loses its colour**,
                  // deliberately. Being out of the estimate is the louder fact
                  // about that row, and a green *✓ Good* glowing inside a
                  // greyed-out line says the opposite of what the row means.
                  subtitle: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: '${o.trueNorthBearing?.round()}°'
                            '±${o.bearingUncertainty?.round()}° · '
                            '${signalStrengthLabel(o.signalStrength)} · ',
                      ),
                      if (o.bearingQuality case final quality?)
                        TextSpan(
                          text: bearingQualityLabel(quality),
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: excluded
                                ? null
                                : bearingQualityColor(quality, colors),
                          ),
                        )
                      else
                        // A bearing recorded before this field existed, or an
                        // omnidirectional detection, which is never asked. Not
                        // coloured, because there is no answer to colour.
                        const TextSpan(text: '—'),
                      // **Task 11.193's flag, on the screen where it is
                      // useful.** Michael's point, 2026-09-07: bearing quality
                      // is shown here because here is where you would care
                      // about excluding a bearing — and the same is true of a
                      // signal that sounded like a failing collar.
                      //
                      // **It still excludes nothing.** The row stays ticked and
                      // the bearing stays in the estimate; this only stops the
                      // fact being invisible until somebody exports a CSV.
                      // Withdrawing a bearing remains a deliberate act with a
                      // name on it (task 11.7).
                      if (o.signalIrregular ?? false)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 13,
                              color: excluded
                                  ? Theme.of(context).colorScheme.onSurfaceVariant
                                  : colors.bounceRed,
                              // Task 11.194: Michael's word, read from
                              // `observation_quality_display.dart` so this
                              // cannot drift from the Record chip.
                              semanticLabel: irregularSignalLabel,
                            ),
                          ),
                        ),
                    ]),
                    style: TextStyle(
                      fontSize: 11,
                      color: excluded ? Theme.of(context).colorScheme.onSurfaceVariant : null,
                    ),
                  ),
                );
              },
            ),
          ),
          // No `SafeArea` here on purpose. Task 11.63's rule is that the app
          // shell owns the device insets and each tab screen stops reserving
          // them separately; the shell's `NavigationBar` already sits below
          // this. Keeping one here would make the row's height depend on the
          // device rather than on [saveRowHeight], and the whole point of the
          // space budget is that the panel's furniture is a knowable number.
          // **A minimum, not a fixed height (task 11.139).** The caller
          // reserves [saveRowHeight] out of the panel, measured against this
          // phone's own text size; this box takes exactly that much at every
          // size it was measured at, and grows rather than stripes if the
          // measurement is ever a pixel short. A fixed box has only one way
          // to be wrong and it is the yellow-and-black one.
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: saveRowHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              // Task 11.138: the reason was in a `Tooltip` on the button and
              // a touchscreen never opens one, so a viewer saw SAVE POSITION
              // greyed out with nothing to read.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!mayWrite)
                    DisabledReasonNote(reason: cannotSaveReason),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: !result.hasEstimate || saving || !mayWrite ? null : onSave,
                      child: const Text('SAVE POSITION',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

    return Container(
      // Keyed so `position_screen_space_budget_test.dart` can measure the
      // panel and the list it contains, and so hold the furniture to the
      // height the split calculation assumes.
      key: const ValueKey('bearings-panel'),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outline, width: 1.5)),
      ),
      child: scrollAsOne
          ? SingleChildScrollView(
              key: const ValueKey('bearings-panel-scroll'),
              child: column,
            )
          : column,
    );
  }

  /// [Expanded] in the fixed-frame panel; the child unchanged in the
  /// scroll-as-one panel, where there is no bounded height to expand into.
  Widget _flexOrShrinkWrap({required Widget child}) =>
      scrollAsOne ? child : Expanded(child: child);

  /// The cautions for a given solve. **`static`, and called by name from the
  /// collapsed panel** (task 11.204): a caution must not vanish because the
  /// panel it usually lives in has been closed, and two copies of this list is
  /// how one of them would come to disagree with the other.
  static List<String> warningMessagesFor(
    GeographicLocalizationResult result,
    int spanMinutes,
    int windowMinutes,
  ) {
    final messages = <String>[];
    if (spanMinutes > windowMinutes) {
      messages.add('Time span ${spanMinutes}min > ${windowMinutes}min window — animal may have moved');
    }
    if (result.warnings.contains(GeometryWarning.nearParallel)) {
      messages.add('Bearings near-parallel — try a different angle');
    }
    if (result.warnings.contains(GeometryWarning.highGdop)) {
      messages.add('Poor geometry — try a different observer position');
    }
    if (result.warnings.contains(GeometryWarning.coincidentObservers)) {
      messages.add('All observers are nearly at the same point — no triangulation information');
    }
    if (result.warnings.contains(GeometryWarning.largePositionUncertainty)) {
      messages.add('Some observations have low-accuracy GPS fixes — reported error may understate true error');
    }
    // **Why there is no ellipse** (task 11.323). Two bearings always cross
    // exactly, so there is no spread left to measure; more than two can
    // still disagree too much, or sit too badly, for one.
    if (result.hasEstimateWithoutEllipse) {
      messages.add(
        result.observationCount == 2
            ? "No ellipse — two bearings can't measure their own spread. "
                  'Add a third.'
            : "No ellipse — these bearings can't measure their own spread.",
      );
    }
    // **Few bearings** (task 11.336): the ellipse is drawn and labeled 95%,
    // and with this few bearings it usually contains the animal less often
    // than that. Says nothing about geometry, so "Poor geometry" is untouched.
    if (FewBearingsCaution.applies(
      bearings: result.observationCount,
      hasEllipse: result.ellipseSemiMajorMeters != null,
    )) {
      messages.add(FewBearingsCaution.text);
    }
    if (result.warnings.contains(GeometryWarning.didNotConverge)) {
      messages.add('Solver did not fully converge — treat this estimate as provisional');
    }
    if (result.status == LocalizationStatus.singleBearing) {
      messages.add('Only one bearing selected — showing the ray only, no estimate');
    }
    if (result.status == LocalizationStatus.refused) {
      messages.add('Geometry too degenerate to estimate — adjust which observations are included');
    }
    return messages;
  }
}

/// The panel's one header row: grab handle, estimate readout, cautions
/// button, past estimates.
///
/// Four things share one row on purpose. Each of them was a candidate for a
/// band of its own, and the sum of those bands is what left task 11.109 with
/// no visible bearing row. The readout and the cautions are *output* — rule
/// 2 in this file's header gives output one compact line, not a panel.
class _PanelHeaderRow extends StatelessWidget {
  const _PanelHeaderRow({
    required this.height,
    required this.onResizeDragStart,
    required this.onResizeDrag,
    required this.onResizeDragEnd,
    required this.cautions,
    required this.onViewPastEstimates,
  });

  /// The 6pt gap above the drag pill plus the 4pt pill itself — everything
  /// in this row that is not the content band.
  static const _headerRowFurniture = 10.0;

  final double height;
  final VoidCallback onResizeDragStart;
  final ValueChanged<double> onResizeDrag;
  final VoidCallback onResizeDragEnd;
  final List<String> cautions;
  final VoidCallback onViewPastEstimates;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    return Semantics(
      label: 'Resize the bearings list',
      child: GestureDetector(
        key: const ValueKey('position-panel-resize'),
        // Opaque so the whole row is the grab target, not just the 4-pixel
        // pill: this is the gesture Michael reached for on hardware and the
        // one this screen had never actually had.
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => onResizeDragStart(),
        onVerticalDragUpdate: (details) => onResizeDrag(details.delta.dy),
        onVerticalDragEnd: (_) => onResizeDragEnd(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          // `min`, and the content row is not `Expanded`, because the box
          // above is now a *minimum* rather than a fixed height (task
          // 11.139): a flex child cannot expand into an unbounded height, and
          // the row has to be free to grow past 46 when the text does.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // The content band, sized from [height] rather than flexed
              // into it: a flex child cannot expand into the unbounded
              // height a minimum-height box hands down. At the default text
              // size this is 36 logical pixels — exactly what the `Expanded`
              // it replaced resolved to — and it grows with [height] as the
              // text does (task 11.139).
              SizedBox(
                height: height - _headerRowFurniture,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
                  child: Row(
                    children: [
                      // Task 11.147: `Flexible`, so the row can narrow it.
                      // Held at its intrinsic width it was the only child of
                      // this row that could not give — a fixed-width sibling
                      // and the history button (also fixed) left it nowhere
                      // to shrink — so from AX4 the row overflowed to the
                      // right by 39 pixels and painted the stripe. It keeps
                      // its word wherever there is room for it and loses the
                      // tail of it, visibly, where there is not.
                      if (cautions.isNotEmpty) ...[
                        Flexible(
                          child: _CautionsButton(
                            cautions: cautions,
                            color: colors.fairAmber,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      // Task 11.205: the `N=`/ellipse/span summary that used
                      // to fill this space is gone — duplicated, jargon, and
                      // only interesting when a caution has already said so
                      // in words. Nothing replaces it; the spacer just pushes
                      // the history button to the row's own edge.
                      const Spacer(),
                      // Task 11.94/11.101 exemption: labelled only by
                      // `tooltip:`. Left as-is: non-destructive (opens a
                      // read-only sheet), reversible, and the save row it
                      // sits in is already at 11.109/11.133's measured space
                      // budget — a text label does not fit without pushing
                      // something else off. If this proves undiscoverable in
                      // practice, that budget is the thing to revisit.
                      IconButton(
                        icon: const Icon(Icons.history, size: 20),
                        tooltip: 'Past estimates for this tag',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                        padding: EdgeInsets.zero,
                        onPressed: onViewPastEstimates,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// **The panel closed** (task 11.204): the hairline, a grey pull-bar, and a
/// caution glyph when there is a caution. Nothing else.
///
/// Michael asked for the panel to be minimizable by dragging it all the way
/// down, with "the little grey bar" left to pull it back up. Three things here
/// were not asked for and are not optional:
///
/// * **The bar is a button as well as a drag target, and its label changes.**
///   *"Resize the bearings list"* is what the open panel's handle says, and it
///   is false when the list is not there. **A panel that can only be re-opened
///   by a drag gesture cannot be re-opened by anybody using a screen reader** —
///   the screen would simply have lost its bearings list for them, with no
///   control to say otherwise.
/// * **A caution does not disappear with the rest of the panel.** *"Geometry
///   too degenerate to estimate"* silently vanishing while somebody carries on
///   tapping rays is the whole reason: the panel is closed precisely when
///   somebody is working on the map, which is when the geometry is changing.
///   The glyph opens the same sheet the open panel's cautions button does
///   ([_CautionsButton.show]).
/// * **The glyph carries a word in its label, not only a colour.** Amber alone
///   says nothing to roughly one man in twelve, and there is no legend on this
///   strip to teach one. It is a warning triangle — a shape — and its tooltip
///   and semantics label say how many cautions there are.
class _CollapsedPanelHandle extends StatelessWidget {
  const _CollapsedPanelHandle({
    required this.cautions,
    required this.onExpand,
    required this.onResizeDragStart,
    required this.onResizeDrag,
    required this.onResizeDragEnd,
  });

  final List<String> cautions;
  final VoidCallback onExpand;
  final VoidCallback onResizeDragStart;
  final ValueChanged<double> onResizeDrag;
  final VoidCallback onResizeDragEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.extension<TriTrackColors>()!;
    final cautionLabel =
        cautions.length == 1 ? '1 caution' : '${cautions.length} cautions';
    return Container(
      // The same key the open panel carries, so the space-budget test measures
      // "the panel" in both states rather than losing sight of it in one.
      key: const ValueKey('bearings-panel'),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outline, width: 1.5),
        ),
      ),
      child: GestureDetector(
        key: const ValueKey('position-panel-resize'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => onResizeDragStart(),
        onVerticalDragUpdate: (details) => onResizeDrag(details.delta.dy),
        onVerticalDragEnd: (_) => onResizeDragEnd(),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                button: true,
                label: 'Show the bearings list',
                child: InkWell(
                  key: const ValueKey('position-panel-expand'),
                  onTap: onExpand,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (cautions.isNotEmpty)
              IconButton(
                key: const ValueKey('position-panel-collapsed-cautions'),
                icon: Icon(Icons.warning_amber_rounded,
                    color: colors.fairAmber, size: 22),
                tooltip: cautionLabel,
                onPressed: () =>
                    _CautionsButton.show(context, cautions, colors.fairAmber),
              ),
          ],
        ),
      ),
    );
  }
}

/// Geometry/time cautions as a labelled button that opens a sheet.
///
/// Before task 11.109 these were an amber banner between the summary line and
/// the bearings list. Task 11.5 had already collapsed them once, from a stack
/// of full-height cards to a single expandable line, for exactly this reason
/// — and a single line above the list was still enough, with everything else
/// on the screen, to leave the list with less height than one row. **A
/// condition may not occupy a band of its own** (rule 3): it lives in a row
/// that exists anyway, and its detail lives in a sheet.
///
/// Deliberately carries a word, not just a glyph and a count: task 11.101's
/// rule is that a control whose meaning is only in its tooltip is not a
/// control a person in the field can use.
class _CautionsButton extends StatelessWidget {
  const _CautionsButton({required this.cautions, required this.color});

  final List<String> cautions;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final label = cautions.length == 1 ? '1 caution' : '${cautions.length} cautions';
    return InkWell(
      onTap: () => show(context, cautions, color),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        // A minimum, so the word inside it is not cut in half at a large
        // system text size (task 11.139).
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        // Task 11.147: `ellipsis`, not the default `clip`. This label was the
        // one thing in the header row that could not narrow, so it pushed the
        // row 39 pixels off the right-hand edge at AX4; it is `Flexible` in
        // that row now, which means it can be given less width than the word
        // needs. Clipped, it would lose letters with nothing to say so —
        // the silent failure the text-scale probe exists to catch. **The
        // glyph and the count are the front of the string on purpose**: they
        // are what survives the ellipsis, and they are the part somebody
        // acts on.
        child: Text(
          '⚠ $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
  }

  /// **`static`, so the collapsed panel opens the same sheet rather than its
  /// own** (task 11.204). A second sheet that drifted from this one would be
  /// worse than no sheet at all: it would look like the cautions, and be a
  /// different set of them.
  static Future<void> show(
    BuildContext context,
    List<String> cautions,
    Color color,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                cautions.length == 1 ? 'Caution' : 'Cautions',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const SizedBox(height: 4),
              const Text(
                'These describe the geometry and timing of the bearings you have '
                'selected. They do not stop you saving the estimate.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (final m in cautions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(m, style: const TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The panel's one controls row: how many bearings are selected, the sort,
/// and select-all/none. These are inputs you act on while choosing bearings,
/// so by rule 2 they earn their permanent line — one line, shared.
///
/// **One line while one line is enough, and more when it is not (task
/// 11.147).** Task 11.139 measured this row across the iOS text-size ladder
/// and found it overflowing to the right **by 36 to 137 logical pixels from
/// AX3 upward**: the count could ellipsize and the `Spacer` could vanish, but
/// the sort menu and the two buttons are text at their intrinsic width and
/// nothing could make them narrower.
///
/// The three controls are now a [Wrap], bounded to the row's own width, so
/// they break onto a second run instead of off the edge. Two consequences
/// worth stating rather than discovering:
///
/// * **At the default text size nothing moves.** The three fit one run, the
///   `Wrap` reports exactly their combined width, and the count takes the
///   rest — which is why the panel's furniture still sums to 151.5 and the
///   space budget above is untouched.
/// * **At the top of the ladder the count is what gives way**, ellipsized to
///   almost nothing so the controls keep their words. That is the right way
///   round: the count is a readout and the controls are what somebody is
///   reaching for. It ellipsizes rather than clipping, so it says that it
///   has been shortened.
///   **Task 11.205 removed the header row's separate `N=` summary above it**
///   — duplicated, in jargon, in a smaller font — so this is now the only
///   place on the panel showing the selected count.
class _PanelControlsRow extends StatelessWidget {
  const _PanelControlsRow({
    required this.height,
    required this.selectedCount,
    required this.total,
    required this.sort,
    required this.distanceAvailable,
    required this.onSortChanged,
    required this.onSelectAll,
    required this.onDeselectAll,
  });

  final double height;
  final int selectedCount;
  final int total;
  final _BearingSort sort;
  final bool distanceAvailable;
  final ValueChanged<_BearingSort> onSortChanged;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
        // The width is needed as a *number* here, and there is no other way
        // to get it: a non-flex child of a `Row` is laid out with unbounded
        // width, so a `Wrap` placed there would never wrap.
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              // Flexible, so a large text scale ellipsizes the count rather
              // than pushing the two buttons off the right-hand edge.
              Flexible(
                child: Text(
                  '$selectedCount of $total selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              // Bounded to the whole row's width rather than to what is left
              // after the count, so the three controls take a second run only
              // when they genuinely do not fit the panel — not merely when
              // the count is long.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _SortMenuButton(
                      sort: sort,
                      distanceAvailable: distanceAvailable,
                      onChanged: onSortChanged,
                    ),
                    TextButton(
                      onPressed: selectedCount == total ? null : onSelectAll,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('All', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: selectedCount == 0 ? null : onDeselectAll,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('None', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
