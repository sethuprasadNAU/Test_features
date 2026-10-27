import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../compass/bearing_capture.dart';
import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../routing/tab_visibility.dart';
import '../../../core/errors/failure_message.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../core/providers/compass_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/time/project_time_zone.dart';
import '../../../core/providers/deployments_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/format/observation_quality_display.dart';
import '../../../core/format/pulse_rate_format.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/pulse_rate_unit_provider.dart';
import '../../../core/providers/recordings_revision_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/actual_tag_location.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/individual.dart';
import '../../../data/models/non_detection.dart';
import '../../../data/models/observation.dart';
import '../../../data/models/project.dart';
import '../../../data/models/pulse_mode.dart';
import '../../../data/models/sync_meta.dart';
import '../../../data/models/tag.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/individual_repository.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/tag_repository.dart';
import '../../../localization/declination/declination_override_provider.dart';
import '../../../localization/declination/wmm_provider.dart';
import '../../../widgets/budgeted_column.dart';
import '../../../widgets/disabled_reason.dart';
import '../../../widgets/load_failure.dart';
import '../../../widgets/raw_hold_gesture.dart';
import '../../../widgets/segmented_toggle.dart';
import '../../../widgets/tag_color_swatch.dart';
import '../../../widgets/wheel_picker.dart';
import '../providers/observation_form_provider.dart';
import '../providers/receiver_altitude_provider.dart';
import '../widgets/bearing_entry_sheet.dart';
import '../widgets/receiver_altitude_sheet.dart';
import '../../../widgets/near_duplicate_tag_dialog.dart';

/// Sentinel tag id marking the "Add new tag" entry appended to the end of
/// the tag wheel. Never persisted — constructed fresh below with dummy
/// field values just to satisfy [Tag]'s required fields.
const _addNewTagSentinelId = '__add_new_tag__';

/// **A collar's line on the wheel and on the no-signal checklist: the
/// frequency and the animal's name, nothing else** — task 11.249.
///
/// Michael, 2026-09-14, on his phone after the first version: *"The tag ID
/// isn't needed on that scroll wheel. Just the animal name and tag
/// frequency."* And the order follows the sort: **by frequency the line
/// leads with the frequency, by animal it leads with the name**, so whatever
/// the wheel is ordered by is what a person's eye lands on first.
///
/// Every collar this screen offers has a deployment (that is the rule this
/// task added), so it has an animal to name; the collar's own ID is the
/// fallback for the one case the model allows and the wheel should never
/// meet — a collar whose animal row is missing on this device.
///
/// The pulse rate rode on this line from task 11.187 until 2026-09-14 and the
/// tag ID until later the same day. The rate is on the tag's details in the
/// Tag Database and under the MODE wheel further down this form; the ID is
/// what the Tag Database is for. Removing the rate is what pays for the sort
/// switch beside the wheel — measured in `record_screen_space_budget_test.dart`.
String _tagLine(Tag t, TagWheelSort sort) {
  final frequency = '${t.frequencyMhz.toStringAsFixed(3)} MHz';
  final animal = t.individualName ?? t.tagName;
  return switch (sort) {
    TagWheelSort.frequency => '$frequency · $animal',
    TagWheelSort.animal => '$animal · $frequency',
  };
}

/// The wheel in the order the switch says (task 11.249).
///
/// By frequency is the order `projectActiveTagsProvider` already returns and
/// the order the wheel has always had. By animal is the name the collar's
/// line shows — the animal of its latest deployment — falling back to the
/// collar's own ID for a collar whose animal row is missing, with frequency
/// breaking ties so two collars on one animal (the handover day) sit
/// together in a stable order.
List<Tag> _sortedForWheel(List<Tag> tags, TagWheelSort sort) {
  if (sort == TagWheelSort.frequency) return tags;
  String key(Tag t) => (t.individualName ?? t.tagName).toLowerCase();
  return [...tags]..sort((a, b) {
      final byName = key(a).compareTo(key(b));
      return byName != 0 ? byName : a.frequencyMhz.compareTo(b.frequencyMhz);
    });
}

final _addNewTagSentinel = Tag(
  tagId: _addNewTagSentinelId,
  // A sentinel is never stored and never synced, so its scope and lineage
  // are the same placeholder its id already is. It exists only so the wheel
  // can carry an "add a tag" entry in a list of tags.
  projectId: _addNewTagSentinelId,
  lineageId: _addNewTagSentinelId,
  frequencyMhz: 0,
  tagName: '',
  status: TagStatus.active,
  colorHex: TagColorPalette.colors.first,
  sync: SyncMeta.initial(now: DateTime.fromMillisecondsSinceEpoch(0)),
);

/// **The glyph each record type is shown as** — task 11.197, Michael's own
/// mapping, and it covers all five of [RecordType].
///
/// *"The record type selector looks crowded with text all the way up to the
/// vertical separator lines."* So the four types a person is not currently
/// recording are drawn as icons and the one they are keeps its word; see
/// [SegmentedToggle.iconFor] for why the selected one is not also wordless.
///
/// **`RecordType.label` is not touched.** Those words live in
/// `package:tritrack_sync`, which the server depends on, and they are the
/// wire's vocabulary as well as this screen's. Icons belong to the screen and
/// stay here.
///
/// **The one place this departs from Michael's list, said plainly so he can
/// overrule it.** For *No Signal* he offered *"an X or a `?`"*, and this is
/// the `?`. An X in a row of five controls is the universal *dismiss / clear
/// this* glyph, and on the one control in the app that decides what kind of
/// row gets written, a segment that reads as a cancel button is a worse
/// mistake than a segment that reads as a question. A `?` is also what a
/// no-signal record means: the person listened on those frequencies and
/// learned nothing. It is the bare glyph, not the circled `help_outline`,
/// which would read as *explain this screen to me*.
IconData _recordTypeIcon(RecordType type) => switch (type) {
  // A compass — a bearing is taken by pointing.
  RecordType.directional => Icons.explore_outlined,
  // A signal wedge, the wifi arc Michael named: something heard from an
  // unknown direction.
  RecordType.omnidirectional => Icons.wifi_tethering,
  // A note page.
  RecordType.note => Icons.description_outlined,
  // Listened, heard nothing — see the note above about the X.
  RecordType.noSignal => Icons.question_mark,
  // The animal itself, which is what a truth point is a position for.
  RecordType.groundTruth => Icons.pets,
};

/// The share of the screen's body the pinned action bar may take (rule 3
/// of this file's SPACE BUDGET, made enforceable by task 11.165).
///
/// **Half is a decision, not a measurement.** It was chosen so that it
/// binds nowhere today — with both shell banners live on a 6.1-inch phone
/// the bar wants 86 logical pixels of a 570-pixel body at the default text
/// size and 222 of 533 at AX5, its worst stop, which is 42% — so **nothing
/// a person sees moves.** And the worst case it does allow, a form and a
/// pinned bar sharing the body equally, is still a form somebody can scroll
/// and a button they can press. The bound is a *fraction* rather than a
/// pixel count for the reason task 11.149 gave for the app shell's own,
/// since deleted: a pixel count is a prediction about one device at one
/// text size, and this project keeps finding constants that were correct on
/// exactly one of each.
///
/// **What it refuses.** A second line added to this bar — the thing rule 3
/// exists to stop, and the thing task 11.164 had to undo by hand — is paid
/// for by the bar rather than by the form's viewport. If even the button
/// does not fit inside the share, the button still wins and
/// `record_screen_space_budget_test.dart` says so.
///
/// **Since 2026-09-07 the bar has nothing but the button in it**, so there
/// is nothing for a new line to be paid *out of* — it would be the first
/// thing to stand down itself. That is the mechanism armed rather than
/// spent; see the `BudgetedColumn` call below.
const double kRecordPinnedBarShare = 0.5;

/// The tag wheel's height — three rows of [WheelPicker]'s 34-pixel extent
/// and a little of the next, which is what it has shown since task 11.197
/// and what `record_screen_space_budget_test.dart` asserts it still shows.
const double kTagWheelHeight = 106;

/// **The sort switch beside the wheel, and what it costs the wheel** — task
/// 11.249.
///
/// Two icon buttons stacked to the wheel's height, in a column
/// [kTagWheelSortWidth] wide with [kTagWheelSortGap] between it and the
/// wheel: **46 logical pixels off the wheel's width, exact**, because a
/// margin is a margin in any font. What paid for them is the pulse rate
/// leaving the collar's line — *"· 40 bpm"* at the centred row's 18-pixel
/// weight-800 measures **76–78 pixels in Roboto** (2026-09-14, from the SDK's
/// own font files: 352.9 → 277.0 for a long line as a bare `TextPainter`,
/// 363.4 → 285.3 as the wheel actually draws it), so the centred line has
/// **about 30 more pixels for the name** than it had, on a 6.1-inch phone:
/// its label box went from 330 to 284 logical pixels while the text it holds
/// lost 76–78. The realistic line — a collar named after its frequency, an
/// animal named after it, *"150.523 MHz · Marie"* (measured with the older
/// *"150.523 MHz · 150.523 (Marie)"*, which is longer) — needs at most 257
/// and fits. **So the switch did not move; the room was there.** The
/// space-budget test measures the exact half of this (the widths) and prints
/// the font-dependent half rather than asserting it, for the reason task
/// 11.133 gave.
///
/// 40 wide rather than the 48-pixel default because two defaults do not fit
/// in 106 side by side with any gap; Material still pads each button's hit
/// area to 48 tall, and two of those are 96, which fit. Rule 4 of the SPACE
/// BUDGET (44-point targets) is met vertically by that padding and
/// horizontally by the column's full width being the hit area.
const double kTagWheelSortWidth = 40;
const double kTagWheelSortGap = 6;

/// # SPACE BUDGET — read this before adding a field or a band
///
/// **This screen answers "what is furniture?" differently from the two map
/// screens, because it scrolls.** Nothing here can be pushed off the screen;
/// it can only be pushed *below the fold*, and a field app's fold is a real
/// cost — a bearing is taken with one hand, often in gloves, sometimes while
/// the animal is still audible. A control the person has to go looking for is
/// a control they will use late or not at all.
///
/// So the subject is not "the form". **The subject is whichever one control
/// this record type is actually gated on**, and the budget asserts that it is
/// fully visible with no scrolling, on a 6.1-inch phone, inside the real app
/// shell:
///
/// | record type | the control this screen exists to reach |
/// | ----------- | --------------------------------------- |
/// | directional | the bearing capture block (POINT / RANGE) |
/// | no signal   | the frequency checklist                   |
/// | truth point | the PRECISION field                       |
///
/// **And, since task 11.197, one line that is not any record type's gate:
/// everything above the position row is reachable without scrolling.** That
/// is the record type, the tag, the bearing block, the three wheels and the
/// irregular-signal checkbox — every answer somebody gives on every
/// directional record.
///
/// **What is allowed below the fold, by name: the position row (the
/// coordinate and `Preview/Set`), the notes box, and ADVANCED.** Naming them
/// is the point. A floor that does not say what is outside it is a floor
/// nobody can add to deliberately, and this screen has now been squeezed by
/// four tasks in a row each buying pixels for the next one to spend.
///
/// **This replaces a floor that was withdrawn by the person it was for.**
/// Tasks 11.193 and 11.195 were both written to hold `Preview / set position
/// on map` above the fold — 11.193 bought 138 logical pixels for it and
/// 11.195 another 157, by folding the record type and the tag behind a
/// header card. Michael tested that on his phone and rejected it (*"the two
/// things that are most likely to be changed for each record — is an extra
/// click away in order to better expose options that are far less likely to
/// be used"*), and then withdrew the requirement itself: **"I'm okay with
/// notes and preview/set position on map being below the fold."** The
/// measurement was real and it was being spent from the wrong pocket. The
/// header card is reverted; the floor is not deleted, it is restated.
///
/// **The subject and the surface are separate claims** (task 11.126). This
/// one is asserted on a **6.9-inch** phone as well as the 6.1-inch one,
/// because that is the geometry the harness photographs and therefore the
/// geometry a reader of the guide sees. A larger screen is not automatically
/// the safe case — it is 104 logical pixels taller and it is where task
/// 11.193's defect was.
///
/// `test/features/observations/record_screen_space_budget_test.dart` measures
/// it. The rules:
///
/// 1. **Above the subject is the scarce resource.** Anything added *above*
///    the subject in the column spends the budget; anything added below is
///    nearly free. When you add a section, add it below unless it is an
///    input the person needs *before* the one they came for.
/// 2. **A condition occupies space only while it holds — and the conditions
///    here are the usual variable.** The viewer lock banner, the "no compass
///    on this device" line, and the app shell's two banners (~76 logical
///    pixels between them) are each invisible in the calm state and each
///    push the subject down. **Measure with them live.** Task 11.109's whole
///    finding was that a conditional band appearing, not a list growing, was
///    what broke a screen.
/// 3. **The pinned action bar is the floor, not a place to expand.** Save is
///    always reachable because it never scrolls; that is exactly why a new
///    permanent line down there costs every record type at once. **It is one
///    button and nothing else, and it stays that.** It carried a "Draft
///    autosaves" note until 2026-09-07, when Michael had it removed —
///    *"users will figure this out as they use the app"* — which gave the
///    form back 21 logical pixels at the default text size.
///    **Enforced since task 11.165, having been a comment before it.** This
///    rule used to be a sentence with nothing able to refuse a line added to
///    the bar: the bar is a non-flex child of a `Column`, a `Column` hands
///    such a child unbounded height, and the scrolling form got whatever was
///    left — which reached **zero** at AX4 before task 11.149 fixed the
///    shell, with the bar alone taller than the whole body. The bar is now
///    laid out inside [kRecordPinnedBarShare] of the body, the Save button is
///    served from that budget first and never sheds. **So a line added here
///    is paid for inside the bar rather than by the form** — and with the
///    note gone there is nothing else in there, so the new line is what
///    stands down. `record_screen_space_budget_test.dart` measures the bar
///    at every text size.
/// 4. **Do not buy space by shrinking type or touch targets.** Field app,
///    gloves: 11pt text and 44pt targets are the floor. Collapsing a section
///    (as ADVANCED already does) is the sanctioned way to spend less.
///
/// ---
///
/// Observation Logging: the highest-frequency screen in the app, so every
/// categorical field is a haptic scroll wheel (never a dropdown) and the
/// whole form fits one scrollable column ending in a sticky Save button.
/// See [[tritrack-compass]] for the bearing-capture logic this reuses.
class ObservationLoggingScreen extends ConsumerWidget {
  const ObservationLoggingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return Scaffold(
      body: SafeArea(
        child: projectAsync.when(
          data: (project) => project == null
              ? const _NoProjectEmptyState()
              : _ObservationForm(project: project),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 40),
            const SizedBox(height: 12),
            Text('No active project', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            const Text(
              'Set up a project (name + extent) before logging observations.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.push('/more/project-setup'),
              child: const Text('Set up project'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObservationForm extends ConsumerStatefulWidget {
  const _ObservationForm({required this.project});

  final Project project;

  @override
  ConsumerState<_ObservationForm> createState() => _ObservationFormState();
}

class _ObservationFormState extends ConsumerState<_ObservationForm>
    with WidgetsBindingObserver {
  final _notesController = TextEditingController();

  /// Where the notes box is, so the form can be scrolled until it is on
  /// screen (see [_scrollNotesIntoView]).
  final _notesKey = GlobalKey();

  /// **The notes box is one line until somebody taps it** (Michael,
  /// 2026-09-07). A note is written on maybe one record in ten, and until it
  /// is being written it was three lines of empty box sitting between the
  /// position row and ADVANCED. Focused, it opens to
  /// [_focusedNotesLines]; unfocused, it closes again **without losing what
  /// was typed** — the text lives in the controller and in the autosaved
  /// draft, and only the number of lines drawn changes.
  ///
  /// This node is also what dismisses the keyboard. On iOS and Android
  /// Flutter's default `onTapOutside` deliberately does *nothing*, so a
  /// keyboard raised by this field stays up over the rest of the form until
  /// something explicitly asks it to go; the field passes
  /// `onTapOutside: (_) => _notesFocus.unfocus()` to say so.
  final _notesFocus = FocusNode();

  /// The gap left between the bottom of the opened notes box and the bottom
  /// of the form, so it does not sit flush against the pinned SAVE bar.
  static const _notesRevealGap = 8.0;

  /// How tall the box opens to. Four lines of the field's own text plus its
  /// border is about 100 logical pixels at the default text size, which is
  /// enough to see a sentence and its continuation without taking so much of
  /// the form that ADVANCED leaves the screen behind it.
  static const _focusedNotesLines = 4;

  /// The same thing on a **Note**, where the box is not a trailing field but
  /// the record itself — so it is worth more of the screen.
  ///
  /// **Why the Note needs a line count at all, when its box already fills the
  /// space.** `Expanded` fills *what is left*, and when the keyboard comes up
  /// there is very little left: measured, a Note's box shrank to a single
  /// line as the keyboard rose, because the column it lives in is sized to
  /// the viewport and the viewport is what the keyboard takes. Michael, on
  /// seeing it: *"the opening of the keyboard simply reduces the size of the
  /// large notes block... in all cases it should move up the other items
  /// above it."*
  ///
  /// **So while it is being written the box stops filling and starts
  /// demanding.** At [_focusedNoteLines] it is taller than what the keyboard
  /// leaves, which makes the column taller than its viewport, which makes the
  /// form scroll — and [_scrollNotesIntoView] then takes the record type and
  /// the tag off the top instead of taking lines off the box. `maxLines` stays
  /// null, so it goes on growing past this as somebody writes.
  static const _focusedNoteLines = 8;

  bool _advancedExpanded = false;
  bool _saving = false;
  String? _notesSyncedFor;

  @override
  void initState() {
    super.initState();
    // Only the line count depends on focus, so this rebuilds the form and
    // nothing else. It fires on both edges — opening on a tap and closing
    // when focus goes anywhere else, including to another field.
    _notesFocus.addListener(_onNotesFocusChanged);
    // **The keyboard's arrival is the second half of the problem below.**
    // It does not come with the tap; the inset lands some frames later, and
    // it takes the bottom of the form with it.
    WidgetsBinding.instance.addObserver(this);
  }

  void _onNotesFocusChanged() {
    if (!mounted) return;
    setState(() {});
    if (_notesFocus.hasFocus) _scrollNotesIntoView();
  }

  /// **Called again whenever the keyboard changes size.**
  ///
  /// The metrics change arrives one or more frames after the tap that raised
  /// the keyboard, and it shortens the form's viewport by the height of the
  /// keyboard. Scrolling once, on the tap, would put the box where the
  /// keyboard was about to be.
  @override
  void didChangeMetrics() {
    if (_notesFocus.hasFocus) _scrollNotesIntoView();
  }

  /// **Scroll the form until the whole notes box is above the pinned SAVE bar
  /// and above the keyboard.**
  ///
  /// Michael, 2026-09-07, on the first version of this: *"the expansion of
  /// the notes pushed below the save button rather than moving the stuff
  /// above the notes block up."* He is describing what a `ListView` does on
  /// its own — a child that grows grows **downward**, into whatever is below
  /// it, and on this screen that is the fold, then the pinned bar, then the
  /// keyboard. **Nothing scrolls unless something asks it to**, and Flutter's
  /// own scroll-on-focus does not cover this: `EditableText` asks for the
  /// *caret* to be shown, the caret is on the first line, so that request is
  /// already satisfied while the other three lines are underneath.
  ///
  /// ## Why this measures rather than calling `Scrollable.ensureVisible`
  ///
  /// That was the first implementation and it **under-scrolled by exactly the
  /// amount the box was overflowing** — measured with a simulated keyboard:
  /// the offset moved 128 → 310 where 350 was needed, leaving the last 40
  /// pixels of the box under the bar. `getOffsetToReveal` works from the
  /// viewport's own idea of where its children are, and a `SliverList`
  /// estimates the extent of children it has not laid out; the estimate is
  /// still settling on the frame after a child changes height and the
  /// keyboard changes the viewport.
  ///
  /// **What is on the screen is not an estimate.** This asks the two render
  /// boxes where they actually are, scrolls by the difference, and is
  /// therefore correct on the first try whatever the sliver believes. It also
  /// does nothing at all when the box already fits, which is the common case
  /// on a tall screen.
  ///
  /// ## Why it jumps rather than animates
  ///
  /// The first version animated each correction over 180 ms and Michael's
  /// verdict was *"it expands a little bit and then expands out in jittery
  /// steps rather than one continuous expansion."* **The keyboard is what
  /// makes that unavoidable:** it rises over a couple of hundred milliseconds
  /// and reports its new height on **every frame** of that rise, so every
  /// frame started a fresh 180 ms animation that interrupted the one before
  /// it. Animations that keep interrupting each other are exactly what
  /// stepping looks like.
  ///
  /// **A jump per frame is the continuous one.** The form then tracks the
  /// keyboard frame by frame as it comes up — the smooth motion the eye sees
  /// is the keyboard's own, and the content simply stays put relative to it.
  /// Nothing here animates, so nothing here can fight anything else.
  void _scrollNotesIntoView({int attemptsLeft = 4}) {
    // One frame's delay, because the four-line box does not exist until the
    // `setState` above has been laid out — measuring the one-line box would
    // scroll by the wrong amount.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _notesKey.currentContext;
      // Focus can be gone again by the time this runs, and a record type with
      // no notes field in the tree has nothing to reveal.
      if (!mounted || !_notesFocus.hasFocus || context == null) return;
      final position = Scrollable.maybeOf(context)?.position;
      final scrollContext = Scrollable.maybeOf(context)?.context;
      final box = context.findRenderObject();
      final viewport = scrollContext?.findRenderObject();
      if (position == null ||
          box is! RenderBox ||
          viewport is! RenderBox ||
          !box.hasSize ||
          !viewport.hasSize) {
        return;
      }
      final boxBottom = box.localToGlobal(Offset.zero).dy + box.size.height;
      final viewportBottom =
          viewport.localToGlobal(Offset.zero).dy + viewport.size.height;
      // A little air, so the box does not sit flush against the SAVE bar.
      final overflow = boxBottom - viewportBottom + _notesRevealGap;
      if (overflow <= 0) return;
      // **Not if the person has taken hold of the form themselves** — a
      // reveal that fights a drag is worse than no reveal at all.
      if (position.userScrollDirection != ScrollDirection.idle) return;
      position.jumpTo(
        (position.pixels + overflow).clamp(0.0, position.maxScrollExtent),
      );
      // **And then look again on the next frame, a bounded number of times.**
      // One pass is not enough: the keyboard's inset reaches the two
      // `Scaffold`s above this form over more than one frame, so a
      // measurement taken on the frame the metrics changed can be reading a
      // layout that is about to move underneath it — measured, the first
      // pass landed 48 pixels short. Each pass measures afresh from what is
      // drawn, so this converges rather than accumulates, and it stops the
      // moment the box fits. **Bounded**, because a loop that runs until a
      // condition holds is a loop that spins forever the day it cannot.
      if (attemptsLeft > 1) {
        _scrollNotesIntoView(attemptsLeft: attemptsLeft - 1);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notesFocus.removeListener(_onNotesFocusChanged);
    _notesFocus.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draftAsync = ref.watch(observationFormProvider);
    final tagsAsync = ref.watch(projectActiveTagsProvider(widget.project.projectId));
    // Task 11.249: the dated links, because which collars are *offered* is
    // a question about today and not about the tag list. Same refresh list
    // as the tags (`refreshTagViews`), so a link written on the Animals
    // screen or arriving by sync reaches this wheel without a restart.
    final deploymentsAsync = ref.watch(
      projectDeploymentsProvider(widget.project.projectId),
    );
    // Task 11.12: a viewer walking this form to Save and hitting a raw
    // `UnauthorizedMutation` is the failure this task exists to fix — resolved
    // before rendering the form for the same reason `isProjectOwnerProvider`
    // is on the settings screen: showing Save enabled and then disabling it
    // would be a worse lie than a moment's spinner.
    //
    // The standing rather than the bare bool since task 11.237: the sentence
    // under a refused Save depends on *why* — a viewer's, or a snapshot's.
    final standingAsync = ref.watch(myProjectStandingProvider(widget.project.projectId));

    return draftAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) =>
          LoadFailure('the observation you were part way through', error: e),
      data: (draft) {
        // Populate the notes controller from the persisted draft once (on
        // first load, and again after a save resets it) without clobbering
        // in-progress typing on every rebuild.
        if (_notesSyncedFor == null) {
          _notesController.text = draft.notes;
        }
        _notesSyncedFor = widget.project.projectId;

        return tagsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => LoadFailure('the tag list', error: e),
          data: (allTags) => deploymentsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                LoadFailure('which tags are on an animal', error: e),
            data: (deployments) => standingAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => LoadFailure(
                'what you are allowed to do in this project',
                error: e,
              ),
              data: (standing) {
                // **Only collars on an animal right now** (task 11.249,
                // narrowed from the day to the moment by task 11.260). The
                // rule and its boundaries are on `tagIdsAudibleOn`.
                final now = DateTime.now();
                final audible = tagIdsAudibleOn(deployments, now);
                final tags = [
                  for (final t in allTags)
                    if (audible.contains(t.tagId)) t,
                ];
                if (tags.isEmpty) {
                  return _NoTagsEmptyState(
                    project: widget.project,
                    standing: standing,
                    // Two different situations with the same empty wheel,
                    // and the sentence has to say which: no equipment at
                    // all, or equipment that is not on anything today.
                    projectHasTags: allTags.isNotEmpty,
                  );
                }
                // **Two collars audible for one animal at once gets no
                // prompt.** Tasks 11.260 and 11.262 put a line above the
                // wheel here offering to set a removal time; task 11.263
                // deleted it, because the interlock no longer lets this app
                // write the pair it explained (design §6a), and a control
                // that fires only on legacy rows is machinery serving
                // nothing. Such a pair, if one exists, is simply two rows on
                // the wheel — and *contested* on the Map and the Log.
                final lastTagId = ref.watch(lastObservationTagIdProvider).value;
                final sort = ref.watch(tagWheelSortSettingProvider).value ??
                    TagWheelSort.frequency;
                return _buildForm(
                  context,
                  draft,
                  _sortedForWheel(tags, sort),
                  lastTagId,
                  standing,
                  sort,
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildForm(
    BuildContext context,
    ObservationDraftState draft,
    List<Tag> tags,
    String? lastTagId,
    ProjectStanding standing,
    TagWheelSort sort,
  ) {
    final mayWrite = standing.mayWriteProjectData;
    final writeRefusal = standing.writeRefusal(
      asViewer:
          'Viewers cannot record observations — ask an owner to change your '
          'role.',
    );
    final notifier = ref.read(observationFormProvider.notifier);
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    // Default to the last-selected tag (persisted across records/restarts, so
    // a field user tracking one individual repeatedly doesn't have to re-pick
    // it every time); fall back to the old middle-of-list behavior if there's
    // no persisted tag or it's not in this project.
    final persistedTag = lastTagId == null
        ? null
        : tags.where((t) => t.tagId == lastTagId).firstOrNull;
    final selectedTag = tags.firstWhere(
      (t) => t.tagId == draft.tagId,
      orElse: () => persistedTag ?? tags[(tags.length / 2).floor()],
    );
    // Only the tag-scoped types force-default a tag; Note can be tagless
    // (general geotagged note) and No Signal manages its own multi-select.
    // A ground-truth point is always about one collar, so it forces a tag the
    // same way the two radio types do.
    final tagRequired = draft.recordType == RecordType.directional ||
        draft.recordType == RecordType.omnidirectional ||
        draft.recordType == RecordType.groundTruth;
    // Also re-point the draft when `draft.tagId` is non-null but no longer
    // among this project's active tags (e.g. the tag went inactive/was
    // deleted after it was selected) — not just when it's null — so the
    // persisted draft stays in sync with the tag actually shown as selected.
    final tagIdStale = draft.tagId != null && !tags.any((t) => t.tagId == draft.tagId);
    if (tagRequired && (draft.tagId == null || tagIdStale)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifier.setTag(selectedTag.tagId);
      });
    }
    // The same repair for the no-signal checklist (task 11.249). The draft
    // persists across days; a collar ticked on Tuesday and taken off that
    // evening is not on Wednesday's checklist, but its id was still in the
    // draft — so the count read one more than anybody could see and Save
    // would have written a no-signal record naming a collar nobody was
    // listening for. Pruned here, once, so the draft, the checklist and the
    // record written from it are the same list.
    final offeredIds = {for (final t in tags) t.tagId};
    if (draft.noSignalTagIds.any((id) => !offeredIds.contains(id))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          notifier.setNoSignalTags([
            for (final id in draft.noSignalTagIds)
              if (offeredIds.contains(id)) id,
          ]);
        }
      });
    }

    final recordType = draft.recordType;
    final isNoSignal = recordType == RecordType.noSignal;
    final isDirectional = recordType == RecordType.directional;
    final isNote = recordType == RecordType.note;
    final isGroundTruth = recordType == RecordType.groundTruth;
    final showRadioFields = isDirectional || recordType == RecordType.omnidirectional;

    // **Task 11.187: the tag's own pulse modes, read live.**
    //
    // `selectedTag` comes from `projectActiveTagsProvider`, which every tag
    // write already invalidates through `refreshTagViews` /
    // `refreshTagViewsEverywhere` (tasks 11.151, 11.153). So renaming a mode
    // in the Tag Database — or a teammate's rename arriving on a sync pull —
    // rebuilds this screen and this wheel, with no restart, because the wheel
    // is built from the tag row rather than from a constant. Michael asked for
    // exactly that on 2026-09-07; `record_screen_pulse_modes_test.dart` is
    // what holds it.
    final pulseModes = selectedTag.pulseModes;
    // **The draft's slot is resolved against the tag actually selected**, and
    // never written back from here. Spinning the tag wheel onto a collar with
    // one mode must not silently leave a bearing pointing at a mode that
    // collar does not have; offering its first mode is the honest answer, and
    // the save path stores whatever this resolves to.
    final selectedPulseSlot =
        pulseModeAt(pulseModes, draft.pulseMode)?.slot ?? pulseModes.first.slot;
    final pulseRateUnit = ref.watch(pulseRateUnitProvider);
    // **Task 11.67: the receiver's height above ground, as it stands now.**
    // Resolved at read (the four-hour rule is applied inside the provider),
    // so a screen rebuilt after a fuel stop shows the notice rather than the
    // value. Zero for everybody on foot, and then it costs this form nothing.
    final altitude = ref.watch(receiverAltitudeProvider);

    final canSave = mayWrite &&
        !_saving &&
        switch (recordType) {
          RecordType.directional => draft.hasBearing,
          RecordType.noSignal => draft.noSignalTagIds.isNotEmpty,
          // Task 11.33: `uncertainty_radius` is what every accuracy statistic
          // divides by, so a truth point with no precision claim is not a
          // record that can be saved and quietly fixed later.
          RecordType.groundTruth =>
            (draft.truthPrecisionM ?? 0) > 0,
          _ => true,
        };

    // **The pinned bar is bounded here, because a `Column` cannot bound it**
    // (task 11.165). Rule 3 above says the bar is a floor and not a place to
    // expand — and until this `LayoutBuilder` existed, that rule was a
    // sentence in a comment with nothing able to refuse a line added to it.
    // A `Column` hands a non-flex child unbounded height, so the bar took
    // whatever it wanted and the scrolling form got the remainder: measured
    // on a 6.1-inch phone with both shell banners live, the bar was 86
    // logical pixels of a 570-pixel body at the default text size and **222
    // of 533 at AX5**, and before task 11.149 fixed the shell it reached 222
    // against a body of 56, which left the form a viewport of zero.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
      children: [
        Expanded(
          child: _FormBody(
            // **A Note's box grows into whatever is left; every other record
            // type's form is a plain scrolling list** (task 11.197). See
            // [_FormBody] for what the difference costs and why it is not the
            // default.
            fillLastChild: isNote,
            children: [
              // Task 11.164 — moved back here from the pinned bar. Task
              // 11.110 put it there to spare the form's scarce headroom, but
              // a pinned bar is not a place to grow: it is the one strip on
              // this screen that costs every record type at once (rule 3
              // above), and this message has no button in it — a viewer has
              // nothing to press, only something to read. At AX5 the
              // sentence alone was taller than the shell's guaranteed body
              // (task 11.149), which the pinned bar cannot do anything about
              // because it never scrolls. Read, not pressed, so it scrolls.
              // **This sentence was white on white until task 11.201.**
              // `onErrorContainer` was never passed to the app's
              // `ColorScheme`, so Flutter's getter handed back `onError` —
              // which this theme sets to white in *both* modes — and the one
              // line telling a viewer why they cannot record rendered white
              // on a light form. It is a defined dark red now: 10.02:1 on the
              // card and 8.62:1 on the app background.
              //
              // It is an "on-container" colour drawn with no container behind
              // it, which is deliberate and worth stating so it is not read
              // as the defect above coming back. Rule 3 on this screen says
              // the form's headroom is scarce; a tinted box around a sentence
              // a viewer can only read would be furniture bought for nothing.
              if (writeRefusal != null) ...[
                Row(
                  children: [
                    Icon(Icons.lock_outline,
                        size: 16,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        writeRefusal,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              // **Task 11.67 — the one line a ground user never sees.**
              // While the four-hour window has cleared an altitude and
              // nobody has been told, one line sits above everything else on
              // this form. **Zero pixels on foot** (rule 2 of the SPACE
              // BUDGET: a condition occupies space only while it holds),
              // which is what keeps Michael's 30 August constraint — aerial
              // tracking must not complicate the ground case — true to the
              // pixel. The value *in force* is not shown here: the *At
              // altitude* checkbox below carries the number (Michael,
              // 2026-09-12).
              if (altitude.noticeOwed) ...[
                _AltitudeClearedLine(altitude: altitude),
                const SizedBox(height: 10),
              ],
              // **No "RECORD TYPE" heading** (task 11.197). Michael's
              // standing rule, now in `CLAUDE.md`: simplicity over verbosity
              // where a person can still find the option. A five-way toggle
              // at the top of a form headed *Record type* was announcing
              // what it obviously is. **The word survives where it is not
              // obvious** — [_recordTypeIcon]'s segments each carry their
              // own name as a `Semantics` label, and a screen reader is told
              // the same five things it always was.
              SegmentedToggle<RecordType>(
                key: const ValueKey('record-type-toggle'),
                options: [
                  for (final t in RecordType.values) (t, t.label),
                ],
                iconFor: _recordTypeIcon,
                selected: recordType,
                onChanged: notifier.setRecordType,
              ),
              const SizedBox(height: 14),
              if (isNoSignal) ...[
                _SectionLabel('TAGS NOT HEARD (${draft.noSignalTagIds.length})'),
                const SizedBox(height: 2),
                Text(
                  'Select every frequency you scanned and heard nothing on.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                Row(
                  children: [
                    TextButton(
                      onPressed: draft.noSignalTagIds.length == tags.length
                          ? null
                          : () => notifier.setNoSignalTags([for (final t in tags) t.tagId]),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: const Text('Select all', style: TextStyle(fontSize: 12.5)),
                    ),
                    TextButton(
                      onPressed: draft.noSignalTagIds.isEmpty
                          ? null
                          : () => notifier.setNoSignalTags(const []),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: const Text('Deselect all', style: TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
                for (final t in tags)
                  CheckboxListTile(
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    value: draft.noSignalTagIds.contains(t.tagId),
                    onChanged: (_) => notifier.toggleNoSignalTag(t.tagId),
                    secondary: TagColorSwatch(colorHex: t.colorHex),
                    title: Text(
                      _tagLine(t, sort),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ] else ...[
                // **No "TAG" heading** (task 11.197). A wheel of
                // "150.900 MHz · 46 bpm · Sage" is not something a person
                // needs told is a tag. The word is kept for a screen reader,
                // which cannot see the frequencies.
                // A Note can be a general geotagged note with no tag.
                if (isNote)
                  Row(
                    children: [
                      Checkbox(
                        value: draft.tagId == null,
                        onChanged: (v) {
                          if (v ?? false) {
                            notifier.clearTag();
                          } else {
                            notifier.setTag(selectedTag.tagId);
                          }
                        },
                      ),
                      const Expanded(child: Text('General note (no tag)')),
                    ],
                  ),
                if (!(isNote && draft.tagId == null))
                  Row(
                    // The switch declares the wheel's height itself
                    // (`kTagWheelHeight`), at Michael's request, so the two
                    // read as one control: the list and the order it is in.
                    // Not `stretch`: this row is a child of the scrolling
                    // form, whose height is unbounded.
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Expanded(
                  child: Semantics(
                    container: true,
                    label: 'Tag',
                    child: WheelPicker<Tag>(
                    items: [...tags, _addNewTagSentinel],
                    selected: selectedTag,
                    height: kTagWheelHeight,
                    // Michael, 2026-09-07: the centred tag is the line
                    // somebody reads to check they are about to record
                    // against the right collar, and 16 was small for it.
                    // See [WheelPicker.selectedFontSize] for why this wheel
                    // and not the three beside it.
                    selectedFontSize: 18,
                    // Task 11.241: the receiver is tuned to a frequency, so
                    // the wheel still picks a *collar*. The animal's name is
                    // appended only when it differs from the collar's —
                    // every collar named after its animal, which is all of
                    // them until somebody merges or renames, reads exactly
                    // as it did before. Measured in
                    // `record_screen_space_budget_test.dart`: the fold does
                    // not move either way.
                    labelBuilder: (t) => t.tagId == _addNewTagSentinelId
                        ? '＋  Add new tag'
                        : _tagLine(t, sort),
                    leadingBuilder: (t) => t.tagId == _addNewTagSentinelId
                        ? null
                        : TagColorSwatch(colorHex: t.colorHex),
                    onChanged: (t) {
                      // Ignore the sentinel while it's merely scrolling past
                      // the center — only a settled release (onSettled below)
                      // should trigger the add-tag dialog.
                      if (t.tagId == _addNewTagSentinelId) return;
                      notifier.setTag(t.tagId);
                      ref.read(lastObservationTagIdProvider.notifier).set(t.tagId);
                    },
                    onSettled: (t) async {
                      if (t.tagId != _addNewTagSentinelId) {
                        // A normal tag settled — make sure it's selected.
                        // Harmless no-op if it already is (also covers the
                        // programmatic re-sync jump this wheel does after a
                        // draft/tag change elsewhere, since `selected` is
                        // always a real tag).
                        notifier.setTag(t.tagId);
                        ref.read(lastObservationTagIdProvider.notifier).set(t.tagId);
                        return;
                      }
                      final previousTagId = selectedTag.tagId;
                      final newTag = await quickAddTagDialog(context, ref, widget.project);
                      if (newTag != null) {
                        notifier.setTag(newTag.tagId);
                        ref.read(lastObservationTagIdProvider.notifier).set(newTag.tagId);
                      } else {
                        // Cancelled — revert off the sentinel back to
                        // whatever was selected before the wheel settled here.
                        notifier.setTag(previousTagId);
                      }
                    },
                  ),
                  ),
                  ),
                  const SizedBox(width: kTagWheelSortGap),
                  _TagWheelSortSwitch(
                    sort: sort,
                    onChanged: (s) =>
                        ref.read(tagWheelSortSettingProvider.notifier).set(s),
                  ),
                    ],
                  ),
              ],
              if (isGroundTruth) ...[
                const SizedBox(height: 14),
                _GroundTruthBlock(draft: draft),
              ],
              if (isDirectional) ...[
                const SizedBox(height: 14),
                // **No "BEARING" heading** (task 11.197). The block below it
                // shows a live compass reading in degrees over a POINT /
                // RANGE pair; nothing else on this screen could be mistaken
                // for it. The word stays for a screen reader.
                Semantics(
                  container: true,
                  label: 'Bearing',
                  child: _BearingCaptureBlock(
                    key: const ValueKey('record-bearing-capture'),
                    draft: draft,
                  ),
                ),
              ],
              if (showRadioFields) ...[
                const SizedBox(height: 14),
                _RollerRow(
                  isDirectional: isDirectional,
                  bearingQuality: draft.bearingQuality,
                  onBearingQualityChanged: notifier.setBearingQuality,
                  pulseModes: pulseModes,
                  selectedPulseSlot: selectedPulseSlot,
                  onPulseModeChanged: notifier.setPulseMode,
                  pulseRateUnit: pulseRateUnit,
                  signalStrength: draft.signalStrength,
                  onSignalStrengthChanged: notifier.setSignalStrength,
                  signalIrregular: draft.signalIrregular,
                  onSignalIrregularChanged: notifier.setSignalIrregular,
                  altitude: altitude,
                  onOpenAltitude: () => _openAltitudeSheet(draft),
                  colors: colors,
                ),
              ] else ...[
                // **Task 11.67 — the record types with no signal line.** A
                // no-signal sweep, a note and a truth point have no mode line
                // for the *At altitude* box to share, so it takes a
                // left-justified row of its own where the wheels would be
                // (Michael, 2026-09-12) — above the position line, not on it.
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _AtAltitudeToggle(
                    altitude: altitude,
                    onTap: () => _openAltitudeSheet(draft),
                  ),
                ),
              ],
              // **The position block comes before the two trailing fields
              // (task 11.193).** It ends in `Preview/Set`, a control somebody
              // uses while standing in the place the record is about — it
              // opens the map to correct a GPS fix that multipath has thrown
              // off. Notes and ADVANCED are fields filled in afterwards, and
              // neither is what anybody opened this screen for. Rule 1 says
              // the space above a control is the scarce resource, and those
              // two were spending **138 logical pixels** of it at the default
              // text size.
              //
              // **The order stands; the reason it was chosen does not any
              // more.** 11.193 moved them to keep this button above the fold,
              // and task 11.197 recorded Michael withdrawing that
              // requirement. It is kept because the order is still right —
              // the thing you press outdoors comes before the thing you type
              // afterwards — which is a better reason than the one it was
              // built on.
              const SizedBox(height: 14),
              _PositionRow(draft: draft),
              const SizedBox(height: 14),
              // **On a Note, this box is the record** (task 11.197), so it
              // takes whatever height is left above SAVE NOTE instead of
              // three lines and a scrollbar. Michael asked for exactly that.
              // On every other record type the notes are an afterthought
              // field and stay the three-line box they were.
              //
              // The `Expanded` is what does it, and it only works because
              // the Note form below is laid out inside a bounded column
              // rather than a `ListView` — see [_formBody].
              // **A Note being written is not a Note at rest.** At rest the
              // box fills whatever the screen has left, because on this
              // record type the box *is* the record and an empty screen
              // under a three-line box is the wrong shape. Being written, it
              // stops filling and asks for [_focusedNoteLines] instead — see
              // that constant for why, and [_scrollNotesIntoView] for what
              // then moves out of its way.
              if (isNote && _notesFocus.hasFocus)
                KeyedSubtree(
                  key: _notesKey,
                  child: TextField(
                    key: const ValueKey('record-notes-field'),
                    controller: _notesController,
                    focusNode: _notesFocus,
                    minLines: _focusedNoteLines,
                    maxLines: null,
                    decoration: const InputDecoration(
                      hintText: 'Note',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    onTapOutside: (_) => _notesFocus.unfocus(),
                    onChanged: notifier.setNotes,
                  ),
                )
              else if (isNote)
                Expanded(
                  child: KeyedSubtree(
                    key: _notesKey,
                    child: TextField(
                    key: const ValueKey('record-notes-field'),
                    controller: _notesController,
                    focusNode: _notesFocus,
                    expands: true,
                    maxLines: null,
                    minLines: null,
                    textAlignVertical: TextAlignVertical.top,
                    decoration: const InputDecoration(
                      hintText: 'Note',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(),
                    ),
                    // The keyboard still has to go away when somebody taps a
                    // control behind it — Flutter's own default for this
                    // callback does nothing on a phone.
                    onTapOutside: (_) => _notesFocus.unfocus(),
                    onChanged: notifier.setNotes,
                    ),
                  ),
                )
              else
                KeyedSubtree(
                  key: _notesKey,
                  child: TextField(
                  key: const ValueKey('record-notes-field'),
                  controller: _notesController,
                  focusNode: _notesFocus,
                  // **One line at rest, four while it is being written**
                  // (Michael, 2026-09-07). `minLines` and `maxLines` are the
                  // same number on purpose: the box is a fixed size in each
                  // state rather than one that grows a line at a time as
                  // somebody types, which would move everything under it
                  // while they were mid-sentence.
                  minLines: _notesFocus.hasFocus ? _focusedNotesLines : 1,
                  maxLines: _notesFocus.hasFocus ? _focusedNotesLines : 1,
                  decoration: InputDecoration(
                    hintText: isGroundTruth
                        ? 'Notes (optional) — e.g. found in burrow'
                        : 'Notes (optional)',
                    border: const OutlineInputBorder(),
                  ),
                  // **What closes it, and what puts the keyboard away.**
                  // Flutter's default handler for this callback does nothing
                  // at all on iOS and Android — it only unfocuses on
                  // desktop — so without this line the box stays open and
                  // the keyboard stays up over the wheels somebody has just
                  // gone back to.
                  onTapOutside: (_) => _notesFocus.unfocus(),
                  onChanged: notifier.setNotes,
                  ),
                ),
              if (showRadioFields) ...[
                const SizedBox(height: 14),
                _AdvancedSection(
                  expanded: _advancedExpanded,
                  onToggle: () => setState(() => _advancedExpanded = !_advancedExpanded),
                  showBearingMethod: isDirectional,
                  bearingMethod: draft.bearingMethod,
                  onBearingMethodChanged: notifier.setBearingMethod,
                  antennaType: draft.antennaType,
                  receiverGain: draft.receiverGain,
                  onAntennaTypeChanged: notifier.setAntennaType,
                  onReceiverGainChanged: notifier.setReceiverGain,
                ),
              ],
            ],
          ),
        ),
        ConstrainedBox(
          // Rule 3, as something that can say no. The bar may take at most
          // [kRecordPinnedBarShare] of the screen's body; the form keeps the
          // rest.
          constraints: BoxConstraints(
            maxHeight: constraints.maxHeight.isFinite
                ? constraints.maxHeight * kRecordPinnedBarShare
                // No surface — a widget test pumping this screen bare — so
                // there is no bound rather than a NaN one, and the bar
                // renders in full. Same failing-open rule `BudgetedColumn`
                // states: the bound exists to protect the form, and off a
                // surface there is no form to protect.
                : double.infinity,
          ),
          child: SafeArea(
          key: const ValueKey('record-action-bar'),
          minimum: const EdgeInsets.fromLTRB(
              DesignTokens.spacingScreenHorizontal, 0, DesignTokens.spacingScreenHorizontal, 12),
          child: BudgetedColumn(
            // **The button is served from the budget first and never sheds**
            // — it is the control the whole screen is for, and a Save button
            // with its label cut off is task 11.139's silent failure.
            //
            // **There is nothing else in this bar to shed any more, and that
            // is deliberate rather than an oversight.** Until 2026-09-07 the
            // line above the button read *"Draft autosaves"*; Michael had it
            // removed — *"users will figure this out as they use the app"* —
            // which is his simplicity-over-verbosity rule applied to a
            // sentence that explained a behaviour nobody has to act on. It
            // was worth 21 logical pixels of the form's headroom at the
            // default text size.
            //
            // **`BudgetedColumn` stays, with one child that never sheds.**
            // It is what makes rule 3 above something that can refuse rather
            // than a comment: the day somebody adds a second line here, it
            // is that line which stands down, not the form which loses its
            // viewport. Keeping it armed costs nothing; taking it out would
            // mean the next addition to this bar is paid for by the screen.
            layoutOrder: const [0],
            children: [
              // A **minimum** height, not a fixed one (task 11.139). Held at
              // exactly 52 this box cut the bottom off its own label as soon
              // as the system text size went up — at the largest accessibility
              // size less than half of "SAVE OBSERVATION" was drawn — with no
              // overflow stripe and no ellipsis to say so. It is the primary
              // control on the screen, and a silent cut is the failure nobody
              // reports because nobody can see it.
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: 52,
                  minWidth: double.infinity,
                ),
                child: FilledButton(
                  onPressed: canSave ? () => _save(context, draft, selectedTag) : null,
                  child: _saving
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(
                          switch (recordType) {
                            RecordType.noSignal => 'SAVE NO-SIGNAL',
                            RecordType.note => 'SAVE NOTE',
                            RecordType.groundTruth => 'SAVE TRUTH POINT',
                            _ => 'SAVE OBSERVATION',
                          },
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                ),
              ),
            ],
          ),
          ),
        ),
      ],
      ),
    );
  }

  /// Opens the altitude sheet over the position the next record will be
  /// placed at — the draft's pin if there is one, else the GPS fix, else
  /// nothing (which leaves AGL entry working and MSL refused, in the sheet).
  Future<void> _openAltitudeSheet(ObservationDraftState draft) {
    double? lat;
    double? lon;
    if (draft.useManualPosition &&
        draft.manualLat != null &&
        draft.manualLon != null) {
      lat = draft.manualLat;
      lon = draft.manualLon;
    } else {
      final gps = ref.read(gpsPositionProvider).value;
      lat = gps?.latitude;
      lon = gps?.longitude;
    }
    return showReceiverAltitudeSheet(context, latitude: lat, longitude: lon);
  }

  Future<void> _save(BuildContext context, ObservationDraftState draft, Tag tag) async {
    setState(() => _saving = true);
    try {
      final user = await ref.read(currentUserProvider.future);
      final deviceId = await ref.read(deviceIdProvider.future);
      final gps = ref.read(gpsPositionProvider).value;

      double latitude;
      double longitude;
      double? accuracy;
      PositionSource source;
      if (draft.useManualPosition && draft.manualLat != null && draft.manualLon != null) {
        latitude = draft.manualLat!;
        longitude = draft.manualLon!;
        accuracy = null;
        source = PositionSource.manualPin;
      } else if (gps != null) {
        latitude = gps.latitude;
        longitude = gps.longitude;
        accuracy = gps.accuracy;
        source = PositionSource.gpsFix;
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No GPS fix yet — use manual pin instead.')),
          );
        }
        setState(() => _saving = false);
        return;
      }

      // **Task 11.67: the receiver's height above ground.** Read through the
      // notifier so the four-hour rule is applied at the moment of saving,
      // not at the moment this screen was last built — a screen left open
      // across the window still writes the truth. Zero on foot.
      final altitudeNotifier =
          ref.read(receiverAltitudeSettingProvider.notifier);
      final altitudeAgl = altitudeNotifier.resolveNow().aglMetres;

      // Prefer the DEM (surveyed ground elevation) when the tile covering this
      // point has been downloaded; GPS altitude is noisy and only a fallback.
      //
      // **What the fallback stores when the receiver is in the air.** With
      // no tile, `elevation` used to be the phone's own GPS altitude — on
      // foot that is the ground plus a couple of metres and a fair stand-in;
      // in an aircraft it is the aircraft's altitude, written into a column
      // named *ground elevation*. Now that the height above ground is known,
      // the ground is the receiver's altitude minus that height: the same
      // reasoning the ground case has always used, with the term that was
      // zero filled in. Both inputs are real — one measured by the phone, one
      // typed by the person — so this is a derivation, not a guess about a
      // missing quantity (the MSL entry refuses in the case where one *is*
      // missing; see `receiver_altitude_sheet.dart`).
      final demElevation = await DemTileStore().elevationAt(latitude, longitude);
      final elevation =
          demElevation ?? (gps == null ? 0.0 : gps.altitude - altitudeAgl);

      final now = DateTime.now();

      // "No Signal" is negative evidence for a set of tags — a NonDetection,
      // not a single-tag Observation (design ask #13).
      if (draft.recordType == RecordType.noSignal) {
        final nonDetection = NonDetection(
          nonDetectionId: const Uuid().v4(),
          projectId: widget.project.projectId,
          userId: user.userId,
          timestampLocal: now,
          timestampUtc: now.toUtc(),
          timezoneOffset: DbCodec.encodeOffset(now.timeZoneOffset),
          latitude: latitude,
          longitude: longitude,
          positionAccuracyM: accuracy,
          positionSource: source,
          elevation: elevation,
          // The same value a bearing gets, or a flight's no-signal records
          // would claim ground level while its detections do not.
          altitudeAgl: altitudeAgl,
          tagIdsListenedFor: draft.noSignalTagIds,
          notes: draft.notes.isEmpty ? null : draft.notes,
          sync: SyncMeta.initial(now: now, modifiedBy: user.userId, originDeviceId: deviceId),
        );
        final repo = await ref.read(nonDetectionRepositoryProvider.future);
        await repo.insert(nonDetection);
        await altitudeNotifier.recordSaved();
        ref.read(recordingsRevisionProvider.notifier).bump();
        await ref.read(observationFormProvider.notifier).reset();
        _notesController.clear();
        _notesSyncedFor = null;
        if (context.mounted) {
          HapticFeedback.mediumImpact();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No-signal record saved')),
          );
        }
        return;
      }

      // **Task 11.33 — where the animal or the collar actually was.**
      //
      // Written to `Actual_Tag_Locations`, not to `Observations`. That is the
      // safety property, not a filing decision: a truth point is the yardstick
      // the position estimates are measured against, and living in its own
      // table means no solver query has to remember to exclude it. See
      // `test/data/analysis/ground_truth_not_in_solver_test.dart`.
      if (draft.recordType == RecordType.groundTruth) {
        final precision = draft.truthPrecisionM;
        if (precision == null || precision <= 0) {
          // Unreachable while Save is gated on the same condition; kept so a
          // future caller cannot write a truth point with no precision claim.
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Enter how precisely this position is known.'),
              ),
            );
          }
          setState(() => _saving = false);
          return;
        }

        // The same call a bearing makes (task 11.32): what the tag read at the
        // moment somebody stood in front of this collar. Null is an ordinary
        // answer — a tag with no version history yet — and is stored as null
        // rather than as today's reading.
        final tagVersionRepo = await ref.read(tagVersionRepositoryProvider.future);
        final truthTagVersionId =
            await tagVersionRepo.currentVersionIdFor(tag.tagId);

        final truthPoint = ActualTagLocation(
          locationId: const Uuid().v4(),
          projectId: widget.project.projectId,
          tagId: tag.tagId,
          timestampLocal: now,
          timestampUtc: now.toUtc(),
          timezoneOffset: DbCodec.encodeOffset(now.timeZoneOffset),
          latitude: latitude,
          longitude: longitude,
          uncertaintyRadius: precision,
          notes: draft.notes.isEmpty ? null : draft.notes,
          foundKind: draft.truthKind,
          tagVersionId: truthTagVersionId,
          // **Task 11.93: who walked in and found it, and how the coordinate
          // was got.** `user_id` is the person saving the record, not
          // `sync.lastModifiedBy` — a colleague who later corrects the
          // precision figure has not become the finder. `position_source` is
          // the same `source` the bearing path above computes, from the same
          // two branches, so a pin here and a pin there mean the same thing.
          userId: user.userId,
          positionSource: source,
          sync: SyncMeta.initial(
            now: now,
            modifiedBy: user.userId,
            originDeviceId: deviceId,
          ),
        );
        final repo = await ref.read(actualTagLocationRepositoryProvider.future);
        await repo.insert(truthPoint);
        // A truth point carries no altitude column, but it is a record saved:
        // it moves the four-hour clock and retires the lapse notice like any
        // other, so a walk-in at a fuel stop is not silently different.
        await altitudeNotifier.recordSaved();
        ref.read(recordingsRevisionProvider.notifier).bump();
        await ref.read(observationFormProvider.notifier).reset();
        _notesController.clear();
        _notesSyncedFor = null;
        if (context.mounted) {
          HapticFeedback.mediumImpact();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Truth point saved')),
          );
        }
        return;
      }

      final observationType = draft.recordType.observationType ?? ObservationType.omnidirectional;
      final isDirectional = observationType == ObservationType.directional;
      // Note can be tagless; the tag-scoped types always resolve to a real tag.
      // `tag` (the screen's already-validated `selectedTag`) is used rather than
      // `draft.tagId` directly — `draft.tagId` can point at a tag that's since
      // gone inactive/deleted (see `_buildForm`'s `selectedTag` fallback), and
      // saving that stale id trips the Observations.tag_id foreign key.
      final observationTagId = draft.recordType == RecordType.note ? draft.tagId : tag.tagId;
      // Resolved against the tag being saved, exactly as the wheel resolves it
      // for display: a draft slot the collar does not have becomes that
      // collar's first mode rather than a number pointing at nothing. A record
      // with no radio fields (`note`) and one with no tag both record no mode.
      final pulseModeForRecord = observationType == ObservationType.note ||
              observationTagId == null
          ? null
          : (pulseModeAt(tag.pulseModes, draft.pulseMode) ??
                  tag.pulseModes.first)
              .slot;
      double? magneticBearing;
      double? trueNorthBearing;
      double? declination;
      String? wmmVersion;
      if (isDirectional && draft.bearingDeg != null) {
        magneticBearing = draft.bearingDeg;
        // A manual declination override (set on the compass/bearing tool) wins
        // over the computed WMM value for the stored true-north bearing, and is
        // recorded as such so the provenance is clear in exports.
        final manualDeclination = ref.read(declinationOverrideProvider).value;
        if (manualDeclination != null) {
          declination = manualDeclination;
          final t = (magneticBearing! + manualDeclination) % 360.0;
          trueNorthBearing = t < 0 ? t + 360.0 : t;
          wmmVersion = 'manual';
        } else {
          final wmm = await ref.read(wmmServiceProvider.future);
          declination = wmm.declinationDegrees(latitude: latitude, longitude: longitude, date: now);
          trueNorthBearing = wmm.magneticToTrueNorth(
            magneticBearingDeg: magneticBearing!,
            latitude: latitude,
            longitude: longitude,
            date: now,
          );
          wmmVersion = wmm.model.modelName;
        }
      }

      // **Nothing on this screen starts a triangulation session any more**
      // (task 11.197). Michael: *"I don't think this is needed since we would
      // select bearings from the list in the position menu."* He is right,
      // and it was checkable before it was removed:
      // `ObservationRepository.findBySession` had **no callers anywhere in
      // the repository** — position estimation groups bearings by tag and
      // time, never by session — so a person who ticked the box got a row
      // written into `Triangulation_Sessions` and an id stamped onto their
      // observation, and nothing in the app ever read either one back.
      //
      // **The column stays.** `Observations.session_id` still exists, still
      // syncs, and still holds whatever any device has already written to
      // it; `Triangulation_Sessions` keeps every row it has. What has gone
      // is the only thing that created new ones, so that table is now
      // **write-nothing**: it is read by the sync engine and by nothing
      // else, and it will not grow again unless somebody builds a feature
      // that means it. A column holding real data is not dropped to tidy a
      // screen.
      //
      // **Task 11.32.** The `Tag_Versions` row the tag reads *right now* — what
      // the receiver was tuned to and what the tag was called at the moment
      // this bearing was taken. Editing the tag afterwards cannot change it.
      //
      // Null is an ordinary answer and is written as null: a tag created
      // before schema v9 has no version, and inventing one now would be a
      // claim about a past nobody observed.
      final tagVersionRepo = await ref.read(tagVersionRepositoryProvider.future);
      final tagVersionId = await tagVersionRepo.currentVersionIdFor(
        observationTagId,
      );

      final observation = Observation(
        observationId: const Uuid().v4(),
        projectId: widget.project.projectId,
        userId: user.userId,
        tagId: observationTagId,
        // Always null now — see the note above. The parameter is kept rather
        // than dropped from the call so that the column's continued
        // existence is visible at the one place a row is written.
        sessionId: null,
        timestampLocal: now,
        timestampUtc: now.toUtc(),
        timezoneOffset: DbCodec.encodeOffset(now.timeZoneOffset),
        latitude: latitude,
        longitude: longitude,
        positionAccuracyM: accuracy,
        positionSource: source,
        elevation: elevation,
        altitudeAgl: altitudeAgl,
        observationType: observationType,
        magneticBearing: magneticBearing,
        trueNorthBearing: trueNorthBearing,
        bearingUncertainty: isDirectional ? draft.bearingUncertaintyDeg : null,
        bearingCaptureMethod: draft.bearingCaptureMethodDb == null || !isDirectional
            ? null
            : BearingCaptureMethod.fromDb(draft.bearingCaptureMethodDb!),
        bearingMethod: isDirectional ? draft.bearingMethod : null,
        magneticBearingStart: isDirectional ? draft.bearingStartDeg : null,
        magneticBearingEnd: isDirectional ? draft.bearingEndDeg : null,
        magneticDeclination: declination,
        wmmModelVersion: wmmVersion,
        antennaType: draft.antennaType,
        receiverGain: draft.receiverGain,
        // **Task 11.187: the mode's identity, and the legacy projection of
        // it.** `pulse_mode` is the slot; `signal_type` is what a build that
        // predates schema v12 sees, derived here so the two can never
        // disagree (`Observation`'s own assert refuses it if they do).
        //
        // **Null slot when the record has no tag**, which is the `note` case:
        // a mode is a fact about a collar, so a bearing with no collar has no
        // mode to number, and `signal_type` keeps the `regular_pulse` it has
        // defaulted to since v1.
        pulseMode: pulseModeForRecord,
        signalType: SignalType.forPulseModeSlot(pulseModeForRecord),
        signalStrength: draft.signalStrength,
        // **Task 11.193: the answer only exists where the question was
        // asked.** A note carries no signal and shows no such control, so it
        // records NULL — nobody was asked — rather than `false`, which would
        // say somebody listened and heard nothing wrong. The two radio types
        // store whatever the control says, including `false`, which is a real
        // answer and the common one.
        signalIrregular: observationType == ObservationType.note
            ? null
            : draft.signalIrregular,
        bearingQuality: isDirectional ? draft.bearingQuality : null,
        notes: draft.notes.isEmpty ? null : draft.notes,
        tagVersionId: tagVersionId,
        sync: SyncMeta.initial(now: now, modifiedBy: user.userId, originDeviceId: deviceId),
      );

      final repo = await ref.read(observationRepositoryProvider.future);
      await repo.insert(observation);
      await altitudeNotifier.recordSaved();
      ref.read(recordingsRevisionProvider.notifier).bump();

      await ref.read(observationFormProvider.notifier).reset();
      _notesController.clear();
      _notesSyncedFor = null;
      if (context.mounted) {
        HapticFeedback.mediumImpact();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Observation saved')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        // The form is only cleared after `repo.insert` returns, so whatever
        // was typed is still on screen either way. What cannot be promised is
        // that nothing reached the database: a session row may have been
        // written just above, and a throw from the draft reset below would
        // land here with the observation already saved. Hence "in case a copy
        // did get through" rather than a flat "nothing was saved".
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeFailure(
                e,
                fallback:
                    'Could not save this observation. What you entered is '
                    'still on the form. Try Save again, then check the Log in '
                    'case a copy got through.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// The form's scrolling body — a plain `ListView` for every record type
/// except Note, and for a Note a column that hands the last child whatever
/// height is left over.
///
/// **Why a Note is different** (task 11.197). Michael: *"on the Note record
/// type, the notes box fills the vertical space above Save note."* On a Note
/// the box **is** the record — everything above it is one toggle, a tag and a
/// coordinate — so a three-line box with a scrollbar in the middle of an
/// otherwise empty screen is the wrong shape. On the other four types the
/// notes are an afterthought and there is a bearing block above them
/// competing for the same pixels.
///
/// **It still scrolls when it has to, which is the half that is easy to get
/// wrong.** `Expanded` needs a bounded height, and a `ListView`'s children
/// never have one; the obvious fix — swap the list for a `Column` — gives an
/// overflow stripe the moment the system text size grows past the surface.
/// What is used instead is the ordinary Flutter arrangement for *fill the
/// viewport, but grow past it if the content needs to*: a scroll view whose
/// child is at least a viewport tall ([ConstrainedBox]) and no taller than
/// its own content wants to be ([IntrinsicHeight]). Under a short surface or
/// a large text size the column exceeds the viewport and the whole thing
/// scrolls, exactly as the `ListView` does; the notes box then keeps its
/// natural single line rather than shrinking to nothing.
///
/// **The cost, stated because `IntrinsicHeight` is not free.** It lays its
/// child out twice. It is used on one record type whose column is five
/// widgets, three of which (the toggle and any wheels) declare a fixed height
/// and answer an intrinsic query without measuring anything. It is not used
/// on the record types whose forms are long.
class _FormBody extends StatelessWidget {
  const _FormBody({required this.fillLastChild, required this.children});

  final bool fillLastChild;
  final List<Widget> children;

  static const _padding = EdgeInsets.symmetric(
    horizontal: DesignTokens.spacingScreenHorizontal,
    vertical: 12,
  );

  @override
  Widget build(BuildContext context) {
    if (!fillLastChild) {
      return ListView(
        key: const ValueKey('record-form'),
        padding: _padding,
        children: children,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        key: const ValueKey('record-form'),
        padding: _padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.maxHeight.isFinite
                // The surface, less the padding this view has already added.
                ? (constraints.maxHeight - _padding.vertical)
                    .clamp(0.0, double.infinity)
                // No surface — a widget test pumping this screen bare. Same
                // failing-open rule as the pinned bar's bound above: with no
                // viewport there is nothing to fill, so the column takes its
                // natural height.
                : 0.0,
          ),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Faint→very strong maps to a red→green gradient (reusing the app's
/// existing bounce-red/animal-fix-green semantic colors) so weak signals
/// read as a warning color and strong ones read as a healthy/good color,
/// same visual language as the rest of the app's status colors.
Color _signalStrengthColor(SignalStrength s, TriTrackColors colors) {
  final t = SignalStrength.values.indexOf(s) / (SignalStrength.values.length - 1);
  return Color.lerp(colors.bounceRed, colors.animalFix, t)!;
}

/// Short forms so the label fits one line in the narrow roller column
/// (see [_RollerRow]) — the stored value is unaffected, this is display-only.
String _signalStrengthShortLabel(SignalStrength s) {
  switch (s) {
    case SignalStrength.faint:
      return 'Faint';
    case SignalStrength.weak:
      return 'Weak';
    case SignalStrength.medium:
      return 'Med';
    case SignalStrength.strong:
      return 'Strong';
    case SignalStrength.veryStrong:
      // Task 11.194: was 'Extreme' — a synonym for the stored value rather
      // than an abbreviation of it, so it read as a different word on a CSV
      // export than on this wheel. This is 'very strong' abbreviated the same
      // way 'medium' is shortened to 'Med' above: same word, shorter.
      return 'V. strong';
  }
}

/// Bearing Quality, Pulse Type, and Signal Strength side by side as three
/// haptic scroll wheels at the same vertical position — replaces the old
/// stacked pill-row / segmented-toggle / slider layout so all three fit on
/// screen together without scrolling (each keeps its prior semantic colors).
class _RollerRow extends StatelessWidget {
  const _RollerRow({
    required this.isDirectional,
    required this.bearingQuality,
    required this.onBearingQualityChanged,
    required this.pulseModes,
    required this.selectedPulseSlot,
    required this.onPulseModeChanged,
    required this.pulseRateUnit,
    required this.signalStrength,
    required this.onSignalStrengthChanged,
    required this.signalIrregular,
    required this.onSignalIrregularChanged,
    required this.altitude,
    required this.onOpenAltitude,
    required this.colors,
  });

  final bool isDirectional;
  final BearingQuality bearingQuality;
  final ValueChanged<BearingQuality> onBearingQualityChanged;

  /// The selected tag's modes, in slot order — never empty (see
  /// [buildPulseModes]), so the wheel always has something to offer.
  final List<PulseMode> pulseModes;
  final int selectedPulseSlot;
  final ValueChanged<int> onPulseModeChanged;
  final PulseRateUnit pulseRateUnit;
  final SignalStrength signalStrength;
  final ValueChanged<SignalStrength> onSignalStrengthChanged;

  /// Task 11.193 — whether the person is hearing the signal itself as wrong.
  final bool signalIrregular;
  final ValueChanged<bool> onSignalIrregularChanged;

  /// Task 11.67: what the *At altitude* box shows, and what it opens.
  final ReceiverAltitudeState altitude;
  final VoidCallback onOpenAltitude;
  final TriTrackColors colors;

  static const _rollerHeight = 106.0;

  // Best first (Michael, 2026-09-07): the roller shows the best answer at
  // the top and the user scrolls down for worse ones. This is a display
  // order only — `BearingQuality`'s declaration order is unchanged, and so
  // is every stored value.
  static const _bearingQualityOrder = [
    BearingQuality.good,
    BearingQuality.fair,
    BearingQuality.suspectedBounce,
  ];

  // Best first, same as bearing quality — `SignalStrength.values` is
  // declared faint-to-strong (worst-to-best) and stays that way; this list
  // only controls what the roller shows.
  static const _signalStrengthOrder = [
    SignalStrength.veryStrong,
    SignalStrength.strong,
    SignalStrength.medium,
    SignalStrength.weak,
    SignalStrength.faint,
  ];

  /// The chosen mode's rate, spelled out once under the wheels.
  ///
  /// **Always present, never a band that appears** (task 11.109's second
  /// trap): a line that shows up only when a rate happens to be recorded is a
  /// change in the screen's height that depends on the collar. It reads
  /// "rate not recorded" instead, which is also the more useful thing to see
  /// while standing in front of a receiver counting pulses.
  ///
  /// Measured cost on the Record screen: **one 16-logical-pixel line** at the
  /// default text size, inside the form's `ListView` — so it is scroll length
  /// rather than anything a fixed layout has to find room for.
  String get _selectedModeLine {
    final mode = pulseModeAt(pulseModes, selectedPulseSlot);
    if (mode == null) return unnamedPulseMode(selectedPulseSlot);
    final rate = formatPulseRate(mode.rateBpm, pulseRateUnit);
    return rate == null ? '${mode.name} · rate not recorded' : '${mode.name} · $rate';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _rollers(context),
        const SizedBox(height: 4),
        // **The flag shares the mode line rather than taking a row of its
        // own** (task 11.193). That line is one 17-pixel sentence with most of
        // a phone's width beside it doing nothing, so a chip put there costs
        // the difference between its tap target and the sentence — **31
        // logical pixels** at the default text size — instead of a whole row
        // and a gap, about 54. This screen had no row to give.
        //
        // It sits here, under the signal wheels, because this is where
        // somebody is already answering *what am I hearing*. Beside the notes
        // box it would have been free and it would have been a different
        // question in a different place.
        //
        // **A `Wrap`, not a `Row`, and that is the half that can refuse.** Turn
        // the system text up and the chip stops fitting beside the sentence: in
        // a `Row` that is an overflow stripe, measured at AX1 as 58 pixels
        // over, and a `Flexible` on the text would only shrink the half that is
        // already ellipsised while the chip went on growing. The `Wrap` moves
        // the chip to its own run instead — at AX5 the chip is 71 pixels tall
        // against a 53-pixel line and costs 75 — which on a form that scrolls
        // is length rather than anything a person cannot reach.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              key: const ValueKey('record-pulse-mode-line'),
              _selectedModeLine,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            _IrregularSignalToggle(
              value: signalIrregular,
              onChanged: onSignalIrregularChanged,
            ),
            // Task 11.67, to the right of *Malfunctioning* (Michael,
            // 2026-09-12) — which was shortened from "Irregular/
            // Malfunctioning" so the two fit on the one line. The `Wrap`
            // still refuses when they do not.
            _AtAltitudeToggle(altitude: altitude, onTap: onOpenAltitude),
          ],
        ),
      ],
    );
  }

  Widget _rollers(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isDirectional) ...[
          Expanded(
            child: _RollerColumn(
              // Task 11.197: 'BEARING QUALITY' — the column sits directly
              // under the bearing block and beside two other wheels, so the
              // qualifier was saying what the position already said. The
              // full name is what a screen reader is given.
              label: 'QUALITY',
              semanticsLabel: 'Bearing quality',
              child: WheelPicker<BearingQuality>(
                items: _bearingQualityOrder,
                selected: bearingQuality,
                height: _rollerHeight,
                // **The words and the colours are not this screen's** —
                // `observation_quality_display.dart` owns them, because the
                // Position screen shows the same three values and two copies
                // of three words is one rename away from disagreeing.
                colorBuilder: (q) => bearingQualityColor(q, colors),
                labelBuilder: bearingQualityLabel,
                onChanged: onBearingQualityChanged,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: _RollerColumn(
            // **The tag's own modes**, named by whoever entered the collar;
            // the word *Regular* has left the app (Michael, 2026-09-07).
            // Task 11.197 shortened the heading to 'MODE' — the line
            // immediately below spells the chosen mode out in full, so the
            // column heading had the word twice.
            label: 'MODE',
            semanticsLabel: 'Pulse mode',
            child: WheelPicker<int>(
              items: [for (final mode in pulseModes) mode.slot],
              selected: selectedPulseSlot,
              height: _rollerHeight,
              // **The name alone, and the rate on the line below.** A third of
              // a phone's width does not hold "Mortality · 120 bpm" at the
              // selected item's enlarged size, and a clipped rate is worse
              // than one shown once, in full, for the mode actually chosen.
              labelBuilder: (slot) =>
                  pulseModeAt(pulseModes, slot)?.name ?? unnamedPulseMode(slot),
              onChanged: onPulseModeChanged,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _RollerColumn(
            // Task 11.197: 'SIGNAL STRENGTH'. Faint … V. strong under it is
            // a strength scale and nothing else on this screen is.
            label: 'STRENGTH',
            semanticsLabel: 'Signal strength',
            child: WheelPicker<SignalStrength>(
              items: _signalStrengthOrder,
              selected: signalStrength,
              height: _rollerHeight,
              colorBuilder: (s) => _signalStrengthColor(s, colors),
              labelBuilder: _signalStrengthShortLabel,
              onChanged: onSignalStrengthChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// **"The signal itself sounded wrong"**, as one bit somebody can set with a
/// thumb (task 11.193).
///
/// Michael, 2026-09-07: *"a flag for all signal recordings — not for a weak
/// tag, but for one that seems to be malfunctioning, such as when the
/// inter-pulse duration is irregular."*
///
/// **What it is not, said in the three places it could be confused.** The
/// wheel to its left records how *strong* the signal was; the wheel beyond
/// that records how much the *bearing* is worth. This is neither: it is the
/// transmitter sounding faulty — pulses at uneven intervals, a stutter, a rate
/// that does not match the collar. And it is not the tag's `malfunction`
/// status, which is a claim about the collar today; this is a claim about one
/// listening moment, and several of them are what would later justify the
/// status. Nothing derives one from the other.
///
/// **It withdraws nothing.** Ticking it does not take the bearing out of a
/// position estimate — that is its own act, with a reason and a name on it
/// (task 11.7) — and nothing on this screen implies otherwise.
///
/// **A checkbox, not a chip — task 11.197, and the reason is a real defect.**
///
/// Michael, having used it: *"right now it looks to the user like it is on by
/// default — it isn't clear until you click on it that something happens — it
/// turns red so the user will think: is that on or off?"* He is describing a
/// control whose two states are *a chip* and *a slightly tinted chip*, on a
/// screen where the wrong reading writes the wrong data. **An unchecked
/// checkbox is unambiguous where a chip is not**: an empty box is the one
/// shape a person does not have to have seen before to read as *off*.
///
/// **Grey when off, red when checked**, and the colour is the accelerator
/// rather than the answer — the box itself already says which state it is in,
/// which is what `CLAUDE.md`'s colour rule asks for. The warning triangle
/// keeps its own colour discipline: it is grey with the label when the flag is
/// off, so nothing on a calm form is shouting.
///
/// The tap target is the whole row (`InkWell`), not the 20-pixel box, because
/// rule 4 of this file's SPACE BUDGET is 44-point targets in gloves.
class _IrregularSignalToggle extends StatelessWidget {
  const _IrregularSignalToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final scheme = Theme.of(context).colorScheme;
    // "Light grey when off, red when checked" (Michael), and the grey is the
    // theme's muted *text* colour rather than its border colour.
    //
    // **This was `scheme.outline` first and the screenshot harness settled
    // it.** `outline` is `#E2E2DF`, which is what the form's hairline borders
    // are drawn in — near-white, and nowhere near readable as words.
    // Photographed on a 6.9-inch phone in real fonts the label came out a
    // ghost: present, unreadable, and reading as *disabled* rather than as
    // *off*, which is a worse ambiguity than the one this control was
    // rebuilt to remove. `onSurfaceVariant` is the grey the pulse-mode line
    // beside it already uses, and that line is legible in the same picture.
    //
    // **Task 11.200: it was not grey when that was written.** This app's
    // `ColorScheme` never passed `onSurfaceVariant`, so it fell back to
    // `onSurface` and this label shipped as full-strength body text — the
    // pulse-mode line was the same colour, which is exactly why comparing the
    // two could not reveal it. The token is now defined (`#6B6B68` light,
    // `#9C9C98` dark) and the sentence above is true for the first time.
    //
    // `bounceRed` is the red every other *this is suspect* mark in the app
    // uses, taken from the theme rather than named here.
    final fg = value ? colors.bounceRed : scheme.onSurfaceVariant;
    return InkWell(
      key: const ValueKey('record-signal-irregular'),
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // `Checkbox` brings its own 48-pixel tap target and its own
            // padding; both are turned off here because the row above is the
            // target and the row is what has to fit beside the mode line.
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                activeColor: colors.bounceRed,
                side: BorderSide(color: scheme.outline, width: 1.5),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.warning_amber_rounded, size: 16, color: fg),
            const SizedBox(width: 4),
            // The words say what was heard, not what it means. \"Faulty tag\"
            // would be a conclusion about the collar drawn from one listen,
            // which is the distinction this whole flag exists to keep.
            //
            // Task 11.194: Michael's word, replacing "Sounded irregular" —
            // read from `observation_quality_display.dart` so this control,
            // the Position row's triangle and the paste screen's sentence
            // cannot disagree.
            // **`Flexible`, because a `Wrap` bounds its children's width.**
            // Without it this row overflowed by 25 pixels at xLarge — the
            // row is `MainAxisSize.min` but the width it is offered is the
            // form's, so a label that grows past what is left of the line
            // stripes rather than wrapping. Flexible lets the words wrap
            // onto a second line instead, which on a form that scrolls is
            // length.
            Flexible(
              child: Text(
                irregularSignalLabel,
                style: TextStyle(fontSize: 12, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RollerColumn extends StatelessWidget {
  const _RollerColumn({
    required this.label,
    required this.child,
    this.semanticsLabel,
  });
  final String label;
  final Widget child;

  /// **The unshortened name, for a screen reader** (task 11.197).
  ///
  /// Three of these headings lost a word each when Michael's
  /// simplicity-over-verbosity rule was applied to this screen. *QUALITY*
  /// and *STRENGTH* and *MODE* are unambiguous **in place**, sitting in a
  /// row under the bearing block with the wheels' own values under them —
  /// and a person listening to this form read out one control at a time has
  /// none of that context. So the ink is short and the announcement is not.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          semanticsLabel: semanticsLabel,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}

/// Live-bearing box + Point (latching) / Range (momentary) capture buttons,
/// plus the pencil button to the detailed compass/manual sheet. Simplifies
/// the common case (aim, tap Point, done) to zero extra taps while the
/// pencil sheet stays available for the full compass dial + manual entry.
class _BearingCaptureBlock extends ConsumerStatefulWidget {
  const _BearingCaptureBlock({super.key, required this.draft});
  final ObservationDraftState draft;

  @override
  ConsumerState<_BearingCaptureBlock> createState() => _BearingCaptureBlockState();
}

class _BearingCaptureBlockState extends ConsumerState<_BearingCaptureBlock> {
  static const _defaultPointUncertaintyDeg = 12.0;
  final _captureController = BearingCaptureController();

  /// The pointer holding RANGE down, or null when nobody is (task 11.317
  /// item 3 — raw pointer tracking, like *Take on map*'s hold, rather than a
  /// tap recognizer's own gesture-arena state).
  int? _rangeHoldPointer;
  bool get _rangeHolding => _rangeHoldPointer != null;

  void _onPointTap(double? liveHeadingDeg) {
    final notifier = ref.read(observationFormProvider.notifier);
    if (widget.draft.hasBearing) {
      HapticFeedback.lightImpact();
      notifier.clearBearing();
      return;
    }
    if (liveHeadingDeg == null) return;
    HapticFeedback.mediumImpact();
    final captured = _captureController.captureSinglePoint(
      liveHeadingDeg,
      uncertaintyDeg: _defaultPointUncertaintyDeg,
    );
    notifier.setBearing(
      bearingDeg: captured.magneticBearingDeg,
      uncertaintyDeg: captured.uncertaintyDeg,
      captureMethodDb: 'single_point',
    );
  }

  void _onRangeHoldStart(int pointer, double? liveHeadingDeg) {
    if (_rangeHolding || liveHeadingDeg == null) return;
    final notifier = ref.read(observationFormProvider.notifier);
    // Starting a new capture negates whatever was previously recorded,
    // whichever method produced it.
    if (widget.draft.hasBearing) notifier.clearBearing();
    HapticFeedback.mediumImpact();
    _captureController.markRangeStart(liveHeadingDeg);
    setState(() => _rangeHoldPointer = pointer);
  }

  void _onRangeHoldEnd(int pointer, double? liveHeadingDeg) {
    if (_rangeHoldPointer != pointer) return;
    setState(() => _rangeHoldPointer = null);
    if (liveHeadingDeg == null) {
      _captureController.cancelRange();
      return;
    }
    final captured = _captureController.markRangeEnd(liveHeadingDeg);
    if (captured == null) return;
    HapticFeedback.mediumImpact();
    ref.read(observationFormProvider.notifier).setBearing(
          bearingDeg: captured.magneticBearingDeg,
          uncertaintyDeg: captured.uncertaintyDeg,
          captureMethodDb: 'range_capture',
          startDeg: captured.magneticStartDeg,
          endDeg: captured.magneticEndDeg,
          ambiguousSweep: captured.ambiguousSweep,
        );
  }

  void _onRangeHoldCancel(int pointer) {
    if (_rangeHoldPointer != pointer) return;
    _captureController.cancelRange();
    setState(() => _rangeHoldPointer = null);
  }

  Future<void> _openBearingSheet(BuildContext context, {required bool initialManualTab}) async {
    final result = await showBearingEntrySheet(context, initialManualTab: initialManualTab);
    if (result == null || !mounted) return;
    ref.read(observationFormProvider.notifier).setBearing(
          bearingDeg: result.magneticBearingDeg,
          uncertaintyDeg: result.uncertaintyDeg,
          captureMethodDb: result.captureMethod == null
              ? null
              : (result.captureMethod == CaptureMode.singlePoint ? 'single_point' : 'range_capture'),
          startDeg: result.startDeg,
          endDeg: result.endDeg,
          ambiguousSweep: result.ambiguousSweep,
        );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    // Task 11.161: the Record tab is the compass's second door — both tabs
    // watch it, so both have to let go before the sensors stop. Resuming costs
    // the wait for the OS's first heading sample; the live bearing box reads
    // em-dash until it lands, exactly as on a cold start.
    final compassAvailable = ref.watchWhileTabVisible(
        context, compassAvailableProvider, whileHidden: true);
    final reading = ref.watchWhileTabVisible(context, compassControllerProvider,
        whileHidden: CompassReading.initial);
    final liveHeadingDeg = reading.magneticHeadingDeg;
    final draft = widget.draft;
    final held = draft.hasBearing;

    final String boxText;
    if (_rangeHolding) {
      boxText = liveHeadingDeg == null ? '—' : '${liveHeadingDeg.round()}°';
    } else if (held) {
      boxText = '${draft.bearingDeg!.round()}° ± ${draft.bearingUncertaintyDeg.round()}°';
    } else {
      boxText = liveHeadingDeg == null ? '—' : '${liveHeadingDeg.round()}°';
    }
    final boxColor = _rangeHolding ? colors.bearingRay.withValues(alpha: 0.85) : null;
    final boxBorderColor = _rangeHolding ? colors.bearingRay : scheme.onSurface;

    final pointLightGreen = Color.lerp(colors.animalFix, Colors.white, 0.65)!;
    final pointDarkGreen = Color.lerp(colors.animalFix, Colors.black, 0.25)!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: boxColor,
                  border: Border.all(color: boxBorderColor, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  boxText,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: _rangeHolding ? Colors.white : null,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (compassAvailable)
              SizedBox(
                height: 48,
                width: 48,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    shape: const CircleBorder(),
                    side: BorderSide(color: scheme.onSurface, width: 1.5),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => _openBearingSheet(context, initialManualTab: false),
                  // An icon that happens to be a character, inside a fixed
                  // 48pt tap target — so it does not scale with the system
                  // text size, exactly as the `Icon` next to it does not
                  // (task 11.139). Left scaling, it was cropped by the circle
                  // it sits in from AX2 upward.
                  child: const Text(
                    '✎',
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              )
            else
              SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: scheme.onSurface, width: 1.5),
                  ),
                  onPressed: () => _openBearingSheet(context, initialManualTab: true),
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Manual entry'),
                ),
              ),
          ],
        ),
        // **Task 11.138 found this already here, and that is the finding.**
        // The brief listed POINT and RANGE as bare icon buttons needing a
        // label before a reason. They have labels — POINT and RANGE — and
        // this line, six logical pixels above them, is their reason, visible,
        // on screen, since Phase 5.2. What they *also* had was a `Tooltip`
        // repeating a shorter version of it, which a touchscreen never opens.
        // The tooltip is gone; nothing was added; the screen is the same
        // height it was. Two screens tasks 11.109 and 11.133 fought for space
        // on paid nothing for this one.
        if (!compassAvailable) ...[
          const SizedBox(height: 6),
          Text(
            'No compass on this device — enter the bearing manually above.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _CaptureButton(
                label: held ? 'POINT (held)' : 'POINT',
                color: held ? pointDarkGreen : pointLightGreen,
                textColor: held ? Colors.white : pointDarkGreen,
                enabled: held || (compassAvailable && liveHeadingDeg != null),
                onTap: () => _onPointTap(liveHeadingDeg),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CaptureButton(
                key: const ValueKey('record-range-button'),
                label: _rangeHolding ? 'RANGE (recording)' : 'RANGE',
                color: _rangeHolding ? colors.bearingRay : null,
                outlineColor: colors.bearingRay,
                textColor: _rangeHolding ? Colors.white : colors.bearingRay,
                enabled: compassAvailable && (liveHeadingDeg != null || _rangeHolding),
                onHoldStart: (pointer) => _onRangeHoldStart(pointer, liveHeadingDeg),
                onHoldEnd: (pointer) => _onRangeHoldEnd(pointer, liveHeadingDeg),
                onHoldCancel: _onRangeHoldCancel,
              ),
            ),
            // **Take on map (task 11.315)** — the same range sweep, taken on
            // a map over today's other bearings on this collar, so the
            // person sees the crossing while they sweep. Beside RANGE
            // because it is a RANGE capture; a circle the size of the pencil
            // above it, so it costs this row width rather than the screen a
            // line (the SPACE BUDGET's rule 1). Only where there is a
            // compass to sweep with, like RANGE itself.
            if (compassAvailable) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 48,
                width: 48,
                child: OutlinedButton(
                  key: const ValueKey('record-take-on-map'),
                  style: OutlinedButton.styleFrom(
                    shape: const CircleBorder(),
                    side: BorderSide(color: colors.bearingRay, width: 1.5),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: () => context.push('/record-bearing-map'),
                  // The button's name for a screen reader, on the button's
                  // own node — a `Semantics` wrapped round it merged into the
                  // bearing block above instead, and made the whole block
                  // announce itself as one button.
                  child: Icon(
                    Icons.map_outlined,
                    color: colors.bearingRay,
                    semanticLabel: 'Take on map',
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Shared button chrome for Point (tap-to-latch) and Range (press-and-hold)
/// capture. Pass [onTap] for a simple tap toggle, or the `onHoldStart`/
/// `onHoldEnd`/`onHoldCancel` trio for a momentary press — [RawHoldGestureDetector],
/// the same raw-pointer hold *Take on map* uses, so a thumb sliding while
/// RANGE is held no longer loses the sweep (task 11.317 item 3).
class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    super.key,
    required this.label,
    required this.color,
    required this.textColor,
    required this.enabled,
    this.outlineColor,
    this.onTap,
    this.onHoldStart,
    this.onHoldEnd,
    this.onHoldCancel,
  });

  final String label;
  final Color? color;
  final Color textColor;
  final bool enabled;
  final Color? outlineColor;
  final VoidCallback? onTap;
  final void Function(int pointer)? onHoldStart;
  final void Function(int pointer)? onHoldEnd;
  final void Function(int pointer)? onHoldCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // **Task 11.200: 0.4 was tuned against a token that was silently
    // full-strength.** Faded body text at 0.4 rendered `#A3A3A3` (2.52:1
    // light, 3.54:1 dark); the same 0.4 on the real muted grey renders
    // `#C4C4C3` — 1.75:1, a disabled label nobody reads in sun. 0.7 holds the
    // old rendering and slightly improves on it in both modes (2.93:1 light,
    // 3.74:1 dark). Disabled controls are exempt from WCAG's contrast
    // minimum; *why can I not press this* is still a sentence somebody has to
    // read outdoors, which is the reason for the number rather than the
    // exemption.
    final disabledColor = scheme.onSurfaceVariant.withValues(alpha: 0.7);
    final chrome = Container(
      constraints: const BoxConstraints(minHeight: 48),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: enabled ? color : null,
        border: Border.all(color: enabled ? (outlineColor ?? color ?? disabledColor) : disabledColor, width: 1.5),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: enabled ? textColor : disabledColor,
        ),
      ),
    );
    if (onHoldStart != null) {
      return RawHoldGestureDetector(
        enabled: enabled,
        onStart: onHoldStart!,
        onEnd: onHoldEnd!,
        onCancel: onHoldCancel!,
        child: chrome,
      );
    }
    return GestureDetector(onTap: enabled ? onTap : null, child: chrome);
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.expanded,
    required this.onToggle,
    required this.showBearingMethod,
    required this.bearingMethod,
    required this.onBearingMethodChanged,
    required this.antennaType,
    required this.receiverGain,
    required this.onAntennaTypeChanged,
    required this.onReceiverGainChanged,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final bool showBearingMethod;
  final BearingMethod bearingMethod;
  final ValueChanged<BearingMethod> onBearingMethodChanged;
  final String? antennaType;
  final double? receiverGain;
  final ValueChanged<String?> onAntennaTypeChanged;
  final ValueChanged<double?> onReceiverGainChanged;

  static const _antennaTypes = ['yagi_3el', 'yagi_5el', 'h_adcock', 'omni', 'other'];
  static const _antennaLabels = {
    'yagi_3el': 'Yagi 3-element',
    'yagi_5el': 'Yagi 5-element',
    'h_adcock': 'H-Adcock',
    'omni': 'Omni',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outline, width: 1.5, style: BorderStyle.solid),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              // **"Advanced", and nothing else** (task 11.197). It used to
              // list its own contents — *Advanced: bearing method, antenna
              // type, receiver gain* — which is a disclosure control
              // explaining what disclosing it would show. Michael's rule:
              // simplicity over verbosity so long as a person can find the
              // option by exploring. Opening it is the exploring.
              child: Text(
                '${expanded ? '▾' : '▸'} Advanced',
                // **The list it stopped printing, kept as speech.** Michael's
                // rule licenses this because a sighted person can find out
                // what is in here by tapping it — that is one tap and a
                // glance. Expanding a section and listening to three controls
                // read out is a good deal more than that, so the cheap
                // exploration the rule relies on is not equally cheap for
                // everybody, and the words are worth more here than they were
                // on the screen.
                semanticsLabel: showBearingMethod
                    ? 'Advanced: bearing method, antenna type, receiver gain'
                    : 'Advanced: antenna type, receiver gain',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  if (showBearingMethod) ...[
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: _SectionLabel('BEARING METHOD'),
                    ),
                    const SizedBox(height: 6),
                    SegmentedToggle<BearingMethod>(
                      height: 36,
                      options: const [
                        (BearingMethod.peak, 'Peak'),
                        (BearingMethod.nullMethod, 'Null'),
                      ],
                      selected: bearingMethod,
                      onChanged: onBearingMethodChanged,
                    ),
                    const SizedBox(height: 12),
                  ],
                  WheelPicker<String>(
                    items: _antennaTypes,
                    selected: antennaType ?? _antennaTypes.first,
                    height: 90,
                    labelBuilder: (t) => _antennaLabels[t]!,
                    onChanged: onAntennaTypeChanged,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Receiver gain'),
                      Expanded(
                        child: Slider(
                          value: receiverGain ?? 0,
                          min: 0,
                          max: 100,
                          divisions: 20,
                          label: (receiverGain ?? 0).round().toString(),
                          onChanged: onReceiverGainChanged,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// **Task 11.33 — the two fields a ground-truth point adds**: what was found,
/// and how precisely the position is known.
///
/// Position itself is not here. A truth point uses the same "use current
/// location / set position on map" control every other record uses
/// ([_PositionRow] below), because the schema already has exactly two meanings
/// for a position — a GPS fix and a placed pin — and a third convention
/// invented for this one screen would be a third thing for an analysis to
/// interpret.
///
/// **The precision prefill is the part to read carefully.** For a GPS fix the
/// field starts at the horizontal accuracy the phone itself reports, and says
/// so; the user may raise or lower it freely, including below the phone's
/// figure, because somebody standing at the spot knows things the phone does
/// not. For a map pin **nothing is prefilled at all.** A pin is not
/// automatically more precise than a GPS fix — it is only as good as the
/// person's ability to identify the exact spot in the imagery, and the base
/// map's own registration is commonly off by a few metres. A confident default
/// there would quietly corrupt the accuracy statistics this whole feature
/// exists to produce, so the number is left to be entered deliberately.
class _GroundTruthBlock extends ConsumerStatefulWidget {
  const _GroundTruthBlock({required this.draft});

  final ObservationDraftState draft;

  @override
  ConsumerState<_GroundTruthBlock> createState() => _GroundTruthBlockState();
}

class _GroundTruthBlockState extends ConsumerState<_GroundTruthBlock> {
  final _precisionController = TextEditingController();

  @override
  void dispose() {
    _precisionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final notifier = ref.read(observationFormProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final gps = ref.watch(gpsPositionProvider).value;
    final usingPin =
        draft.useManualPosition && draft.manualLat != null && draft.manualLon != null;

    // Whole metres: a tenth of a metre is a precision claim nobody standing in
    // a field is making, and rounding here keeps the prefill from rewriting
    // itself on every GPS jitter.
    final deviceAccuracy = gps?.accuracy;
    final prefillTarget = deviceAccuracy?.roundToDouble();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (usingPin) {
        // The number described a GPS fix and the position is no longer one.
        // A figure the user typed is theirs and is left alone.
        if (draft.truthPrecisionIsPrefill) {
          notifier.withdrawTruthPrecisionPrefill();
        }
        return;
      }
      if (prefillTarget == null || prefillTarget <= 0) return;
      // **`truthPrecisionTouched`, not "the value is null or a prefill".** The
      // old test could not tell a field the person had just emptied from one
      // they had never typed in, so deleting the prefilled 4 to type 10 put the
      // 4 back on the next frame — the field could only be corrected by typing
      // `410` and deleting the leading digit. Found on hardware, 2026-08-31.
      if (!draft.truthPrecisionTouched && draft.truthPrecisionM != prefillTarget) {
        notifier.prefillTruthPrecision(prefillTarget);
      }
    });

    // Keep the field showing the draft's value without clobbering in-progress
    // typing: only rewrite when what is typed does not already parse to it.
    final shown = draft.truthPrecisionM;
    if (double.tryParse(_precisionController.text.trim()) != shown) {
      final text = shown == null ? '' : _trimTrailingZero(shown);
      if (_precisionController.text != text) {
        _precisionController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }

    final helper = usingPin
        ? 'Not prefilled for a map pin: a pin is only as precise as your '
              'placing of it, and imagery can be off by a few meters.'
        : (deviceAccuracy == null
              ? 'No GPS fix yet, so there is no device figure to start from.'
              : (draft.truthPrecisionIsPrefill
                    ? 'Prefilled from this device\'s reported GPS accuracy '
                          '(±${deviceAccuracy.round()} m). Raise or lower it '
                          'if you know better.'
                    : 'This device reports ±${deviceAccuracy.round()} m right '
                          'now.'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('WHAT WAS FOUND'),
        const SizedBox(height: 6),
        SegmentedToggle<GroundTruthKind>(
          options: [
            for (final k in GroundTruthKind.values) (k, k.label),
          ],
          selected: draft.truthKind,
          onChanged: notifier.setTruthKind,
        ),
        const SizedBox(height: 4),
        Text(
          'Only "animal + tag" checks a bearing estimate of a live '
          'tagged animal. A tag on its own may have been shed.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        const _SectionLabel('PRECISION'),
        const SizedBox(height: 6),
        TextField(
          controller: _precisionController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Radius in meters',
            suffixText: 'm',
            isDense: true,
          ),
          onChanged: (raw) {
            final trimmed = raw.trim();
            notifier.enterTruthPrecision(
              trimmed.isEmpty ? null : double.tryParse(trimmed),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          helper,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

String _trimTrailingZero(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

class _PositionRow extends ConsumerWidget {
  const _PositionRow({required this.draft});

  final ObservationDraftState draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(observationFormProvider.notifier);
    final gpsAsync = ref.watch(gpsPositionProvider);

    final bool hasManual =
        draft.useManualPosition && draft.manualLat != null && draft.manualLon != null;
    final String positionText = hasManual
        ? '✋ ${draft.manualLat!.toStringAsFixed(5)}, '
            '${draft.manualLon!.toStringAsFixed(5)} · manual'
        : gpsAsync.when(
            data: (p) => '📍 ${p.latitude.toStringAsFixed(3)}, '
                '${p.longitude.toStringAsFixed(3)} · ±${p.accuracy.round()}m',
            loading: () => '📍 Acquiring GPS…',
            error: (_, _) => '📍 GPS unavailable',
          );

    // **The coordinate and the button share one line, and the button is two
    // words** (task 11.197). Michael: *"being adjacent to the lat/lon implies
    // position, so just saying 'Preview/Set' is sufficient."* The sentence
    // beside it already says which position is being talked about and where
    // it came from — a GPS fix with its accuracy, or a hand-placed pin — so
    // *position on map* was the button repeating its own neighbour. That was
    // two lines and about 48 logical pixels; it is now one.
    //
    // **`Preview/Set` in both states, where the old label changed to "Adjust
    // position on map" once a pin was placed.** The pin is what the line to
    // the left is *for*: it reads `✋ 42.70081, -117.36120 · manual` the
    // moment there is one. A button that renames itself to describe a state
    // its own neighbour is showing is the verbosity this task removes.
    //
    // **A `Wrap`, not a `Row`, for the reason task 11.193 gave for the
    // pulse-mode line: it is the half that can refuse.** Turn the system
    // text size up and the button stops fitting beside the coordinate; in a
    // `Row` that is an overflow stripe, and an `Expanded` on the text would
    // ellipsise the one thing here that is data — a truncated longitude is
    // worse than a wrapped line. The `Wrap` puts the button on its own run
    // instead, which on a form that scrolls is length rather than anything a
    // person cannot reach.
    //
    // `FilledButton.tonalIcon`, not `OutlinedButton.icon`: a bare outline
    // read as a stray decorative box rather than a tappable control (task
    // 11.106). A filled tonal background reads as a button at a glance.
    return Wrap(
      key: const ValueKey('record-position-row'),
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          positionText,
          key: const ValueKey('record-position-text'),
          style: const TextStyle(fontSize: 11.5),
        ),
        if (draft.useManualPosition)
          TextButton(
            onPressed: () => notifier.setManualPosition(false),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
            child: const Text('Use GPS'),
          ),
        // Replaces typing a lat/lon by hand (design ask #16): open the map,
        // see the bearing, and tap/drag to set the position — the fix for GPS
        // multipath in canyons and dense forest.
        FilledButton.tonalIcon(
          key: const ValueKey('record-position-preview-button'),
          onPressed: () => context.push('/record-preview'),
          icon: const Icon(Icons.map_outlined, size: 18),
          // The screen reader gets the sentence the ink no longer carries.
          // "Preview/Set" beside a coordinate is unambiguous to somebody
          // looking at the line; to somebody hearing the controls read out
          // one at a time it is two verbs with no object.
          label: const Text(
            'Preview/Set',
            semanticsLabel: 'Preview or set position on map',
          ),
        ),
      ],
    );
  }
}

/// **Task 11.67 — the checkbox that says the receiver is in the air, and how
/// high.** Michael's design, 2026-09-12, replacing a gauge icon on the position
/// line that was *"too small and hard to tell what it means"*: a checkbox to
/// the right of *Malfunctioning* on a bearing record, and a left-justified row
/// of its own on the record types that have no signal line.
///
/// **The box reflects a fact; it does not toggle one.** Ticked means a
/// non-zero altitude is in force for the next record, and the label carries
/// the number — *At altitude · 300 m* — so nobody has to open anything to
/// know what is being recorded. **Every tap opens the altitude sheet**,
/// ticked or not: unticking with one tap would put the receiver on the ground
/// silently, and in an aircraft one accidental tap is not a rare event. The
/// sheet has *Back on the ground* for the deliberate version.
///
/// Same construction as [_IrregularSignalToggle] beside it — the row is the
/// tap target (44 points, rule 4), the box is 24 pixels, the label wraps
/// rather than stripes — so the two read as a pair.
class _AtAltitudeToggle extends StatelessWidget {
  const _AtAltitudeToggle({required this.altitude, required this.onTap});

  final ReceiverAltitudeState altitude;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = altitude.isAboveGround;
    final fg = on ? scheme.primary : scheme.onSurfaceVariant;
    final label = on
        ? 'At altitude · ${formatAltitude(altitude.aglMetres, altitude.unit)}'
        : 'At altitude';
    return InkWell(
      key: const ValueKey('record-at-altitude'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: on,
                // The row owns the tap; a `null` handler would draw the box
                // disabled, so it forwards to the same sheet instead.
                onChanged: (_) => onTap(),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                activeColor: scheme.primary,
                side: BorderSide(color: scheme.outline, width: 1.5),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                key: const ValueKey('record-at-altitude-label'),
                style: TextStyle(fontSize: 12, color: fg),
                semanticsLabel: on
                    ? 'At altitude, ${formatAltitude(altitude.aglMetres, altitude.unit)} '
                        'above ground. Opens the receiver altitude sheet.'
                    : 'At altitude. Opens the receiver altitude sheet.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// **Task 11.67 — the line above the fold that says an altitude was cleared.**
/// Never built on foot: the caller only makes one while a notice is owed.
///
/// The window clearing the value is the right rule (tomorrow's walk-in must
/// not be recorded at 300 m), and a timer doing it silently would be this
/// task's own defect rebuilt one level up — at four hours and a minute, a
/// fuel stop, the app would resume recording ground observations from an
/// aircraft with nothing said. So the first record screen after the window
/// lapses says *"altitude cleared — was 300 m"* until one record is saved,
/// and offers to put it back in one tap. Both directions honest, no taps in
/// the air.
class _AltitudeClearedLine extends ConsumerWidget {
  const _AltitudeClearedLine({required this.altitude});

  final ReceiverAltitudeState altitude;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final was = altitude.clearedFromMetres!;
    return Row(
      key: const ValueKey('record-altitude-cleared'),
      children: [
        Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Altitude cleared — was ${formatAltitude(was, altitude.unit)} '
            'above ground',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          key: const ValueKey('record-altitude-restore'),
          onPressed: () => ref
              .read(receiverAltitudeSettingProvider.notifier)
              .setAglMetres(was),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

/// **Frequency or animal — the wheel's order, as two icons** (task 11.249).
///
/// Michael's suggestion, and the one that fits: the Tag Database icon for
/// *by frequency* and the Animals icon for *by animal*, the same two glyphs
/// those screens wear on the More tab, rather than two words in a space that
/// has none to spare. The chosen one is drawn as a filled disc; the other as
/// a bare icon. **That is a shape difference and not only a colour** — the
/// standing rule is that colour never carries a meaning on its own here —
/// and the wheel's own order is the state anyway, visible a few pixels to
/// the left. Each button carries its meaning for a screen reader.
class _TagWheelSortSwitch extends StatelessWidget {
  const _TagWheelSortSwitch({required this.sort, required this.onChanged});

  final TagWheelSort sort;
  final ValueChanged<TagWheelSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget button(TagWheelSort value, IconData icon, String label) {
      final selected = sort == value;
      // `constraints` rather than `visualDensity`: the column is 40 wide and
      // the wheel 106 tall, and a default 48-pixel button would not fit two
      // to the column. The hit area is the whole button box.
      const box = BoxConstraints.tightFor(width: kTagWheelSortWidth, height: 40);
      // `isSelected` is what tells a screen reader which order is on —
      // `IconButton` wraps its icon in `Semantics(selected:)` from it.
      return selected
          ? IconButton.filled(
              key: ValueKey('tag-wheel-sort-${value.name}'),
              isSelected: true,
              constraints: box,
              padding: EdgeInsets.zero,
              tooltip: label,
              onPressed: () => onChanged(value),
              icon: Icon(icon, size: 20, color: scheme.onPrimary),
            )
          : IconButton(
              key: ValueKey('tag-wheel-sort-${value.name}'),
              isSelected: false,
              constraints: box,
              padding: EdgeInsets.zero,
              tooltip: label,
              onPressed: () => onChanged(value),
              icon: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
            );
    }

    return SizedBox(
      width: kTagWheelSortWidth,
      height: kTagWheelHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          button(TagWheelSort.frequency, Icons.podcasts, 'Sort by frequency'),
          button(TagWheelSort.animal, Icons.pets, 'Sort by animal'),
        ],
      ),
    );
  }
}

class _NoTagsEmptyState extends ConsumerWidget {
  const _NoTagsEmptyState({
    required this.project,
    required this.standing,
    required this.projectHasTags,
  });
  final Project project;
  final ProjectStanding standing;

  /// Whether the empty wheel is *no equipment* or *equipment on nobody*
  /// (task 11.249). The first is the state the screen has always had a
  /// sentence for; the second is new, and it is the one a person meets after
  /// entering collars in the Tag Database and before linking any on the
  /// Animals screen — the sentence has to say that, or it reads as the app
  /// having lost the tags they just typed.
  final bool projectHasTags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mayWrite = standing.mayWriteProjectData;
    final button = FilledButton(
      onPressed: mayWrite
          ? () async {
              final tag = await quickAddTagDialog(context, ref, project);
              // Nothing selected yet in this empty-state (no draft/wheel is
              // showing), but pre-seed the "last used tag" so that once the
              // provider invalidation above brings the wheel on-screen it
              // defaults straight to the tag the user just created.
              if (tag != null) {
                await ref.read(lastObservationTagIdProvider.notifier).set(tag.tagId);
              }
            }
          : null,
      child: const Text('+ Quick-add tag'),
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.podcasts, size: 40),
            const SizedBox(height: 12),
            Text(
              projectHasTags
                  ? 'No tag is on an animal today'
                  : 'No tags in this project yet',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (projectHasTags) ...[
              const SizedBox(height: 8),
              // The way in that already exists, named rather than left to be
              // found: a collar is offered here only while a deployment says
              // it is on something, and the Animals screen is where that is
              // written. Quick-add below is the field shortcut for both.
              Text(
                'Only tags on an animal are listed. Link one under More > '
                'Animals, or quick-add a tag and its animal here.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 16),
            // Task 11.12: disabled with a reason for a viewer rather than a
            // raw error once the dialog's own insert refuses it. Task 11.138:
            // that reason was in a `Tooltip`, which a touchscreen never opens,
            // so on this empty screen a viewer had a greyed button and no
            // sentence anywhere.
            button,
            DisabledReasonNote(
              reason: standing.writeRefusal(
                asViewer:
                    'Viewers cannot create tags — ask an owner to change your '
                    'role.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the quick-add-tag dialog, inserts the new [Tag] (globally and into
/// [project]'s active tag set) **together with an animal of the same name
/// and a deployment putting the collar on it from today**, refreshes every
/// view of the tag set through [refreshTagViews], and returns the created
/// tag. Returns null if the user cancels or leaves the form invalid. Shared
/// by the no-tags empty state and the tag wheel's "Add new tag" option.
///
/// ## Why it writes three rows since task 11.249, having written one since 11.243
///
/// Task 11.243 made this create a collar **on nobody** — equipment, with no
/// animal invented for it — and that was right for a tag database. Task
/// 11.249 then made the wheel offer only collars with a live deployment, so
/// a collar created on nobody would have left this dialog and **vanished
/// from the wheel it was added from.** Michael chose, 2026-09-14, between
/// that, removing quick-add from this screen, and this: the field shortcut
/// stays one dialog, and the dialog says what it makes.
///
/// **Two name fields, not one** — Michael, 2026-09-14, after using it: one
/// field labelled *"Tag / animal name"* had put the same word on the collar
/// and on the animal, and *"separate fields are needed and the tag ID field
/// needs to be the one that populates the tag database manager."* So: **Tag
/// ID** is the collar's name — the row in the Tag Database and this device's
/// library — and **Animal name** is the animal's. Both are required; an empty
/// animal name silently reusing the tag ID would rebuild the confusion he
/// saw.
///
/// **What this asserts on the person's behalf, said so it is a choice:** an
/// animal exists and is wearing this collar from today. The tech who hears an
/// unlisted collar mid-transect is making exactly that claim by recording a
/// bearing on it; the animal can be renamed, re-linked or deleted on the
/// Animals screen afterwards, and no bearing moves when it is.
///
/// **One transaction.** Half of this is worse than none: a tag with no
/// deployment is the thing the wheel now hides, and an animal with no collar
/// is a row somebody has to explain.
Future<Tag?> quickAddTagDialog(BuildContext context, WidgetRef ref, Project project) async {
  // Task 11.12: checked before the form opens rather than after it's filled
  // out — the wheel's "Add new tag" sentinel can't be greyed out the way an
  // ordinary button can (it's a scroll-wheel entry, not a disableable
  // widget), so an explanation up front is this control's version of
  // "disabled with a reason" rather than a silent no-op or a raw error at
  // Save.
  final standing = await ref.read(myProjectStandingProvider(project.projectId).future);
  if (!standing.mayWriteProjectData) {
    if (!context.mounted) return null;
    // A snapshot-holder is not a viewer, and a title saying so would be the
    // wrong-cause class; the shared refusal names what they are and the way in.
    final snapshot = standing.isSnapshot;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          snapshot ? 'You are not on this project' : 'Viewers cannot create tags',
        ),
        content: Text(
          snapshot
              ? notAMemberWriteRefusal
              : 'Ask a project owner to change your role to contributor.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
    return null;
  }
  if (!context.mounted) return null;
  final nameController = TextEditingController();
  final animalController = TextEditingController();
  final freqController = TextEditingController();
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Quick-add tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Tag ID'),
          ),
          TextField(
            controller: freqController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Frequency (MHz)'),
          ),
          TextField(
            controller: animalController,
            decoration: const InputDecoration(labelText: 'Animal name'),
          ),
          const SizedBox(height: 12),
          // Data, not decoration (the 2026-09-09 rule): somebody who did not
          // read this would be surprised to find an animal on the Animals
          // screen they never made. One line, and it names what is written.
          const Text(
            'Adds the tag to the Tag Library and the animal under Animals, '
            'wearing it from today.',
            style: TextStyle(fontSize: 12.5),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Add')),
      ],
    ),
  );
  if (result != true) return null;
  final freq = double.tryParse(freqController.text);
  final animalName = animalController.text.trim();
  if (freq == null || nameController.text.trim().isEmpty || animalName.isEmpty) {
    return null;
  }

  // **Task 11.11's warning, on the path it was written for.** This is the
  // quick-add a field tech uses mid-transect when they hear a collar that is
  // not on the list, so it is both the likeliest source of a duplicate and the
  // one place a refusal would cost a bearing. It warns; it never refuses.
  if (!context.mounted) return null;
  // **Task 11.324: a Tag ID the project already has.** *Use the existing tag*
  // is the default; then no tag is written, and the animal typed here wears
  // the existing one — what More → Animals → Quick add does with a reused
  // tag. If that tag is already on another animal today, the interlock
  // refuses the link, nothing is written, and the wheel goes to the tag.
  final Tag? reuse;
  switch (await checkNewTagAgainstExisting(
    context,
    ref,
    frequencyMhz: freq,
    tagName: nameController.text.trim(),
    projectId: project.projectId,
  )) {
    case GoBackFromNewTag():
      return null;
    case UseExistingTag(:final tag):
      reuse = tag;
    case CreateNewTag():
      reuse = null;
  }

  final now = DateTime.now();
  final deviceId = await ref.read(deviceIdProvider.future);
  final user = await ref.read(currentUserProvider.future);
  final database = await ref.read(appDatabaseProvider.future);
  // Task 11.331: the collar went on today in the field's zone, and the row
  // keeps that zone.
  final zone = await effectiveProjectTimeZone(project);
  final name = nameController.text.trim();
  final sync = SyncMeta.initial(
    now: now,
    modifiedBy: user.userId,
    originDeviceId: deviceId,
  );
  final tagId = reuse?.tagId ?? const Uuid().v4();
  final tag = reuse ?? Tag(
    tagId: tagId,
    projectId: project.projectId,
    // Created straight into the project rather than copied from the
    // library, so its own id is its lineage and `copiedAt` stays null —
    // nothing was copied. `TagRepository.insert` records the collar in this
    // device's library too, so a tag first met in the field is on the
    // person's own list afterwards.
    lineageId: tagId,
    frequencyMhz: freq,
    tagName: name,
    status: TagStatus.active,
    // Never stored — the retired `Tags.color_hex` takes null — and never
    // read back: a tag's colour comes from the animal of its current
    // deployment, which is the row written a few lines down.
    colorHex: TagColorPalette.noIndividual,
    sync: sync,
  ).withDefaultPulseModes();
  final individualId = const Uuid().v4();
  // The pre-check above already turned a viewer away before this form ever
  // opened; this catch is only the backstop for the moment between a role
  // change and a rebuild — same two-layer defense as `project_setup_screen.dart`.
  final Tag stored;
  try {
    stored = await database.raw.transaction((txn) async {
      final individuals = IndividualRepository(txn);
      await individuals.insert(
        Individual(
          individualId: individualId,
          projectId: project.projectId,
          name: animalName,
          // The same round-robin the Animals screen's "New animal" uses, so
          // an animal added here is distinguishable on the map's legend.
          colorHex: await individuals.nextColorHex(projectId: project.projectId),
          // `unknown`, as on the Animals screen: nothing has been observed
          // about this animal yet, and `unknown` is the honest default
          // (design §5).
          status: IndividualStatus.unknown,
          lineageId: individualId,
          sync: sync,
        ),
      );
      final storedTag = reuse ?? await TagRepository(txn).insert(tag);
      // A fresh collar on a fresh animal conflicts with nothing, so the
      // interlock inside `link` is a formality here — but it is the write
      // the rule lives at, and this goes through it rather than around it.
      await DeploymentRepository(txn).link(
        Deployment(
          deploymentId: const Uuid().v4(),
          projectId: project.projectId,
          tagId: tagId,
          individualId: individualId,
          attachedDate: deploymentDateFor(now, zone),
          sync: sync,
          timeZone: zone,
        ),
      );
      return storedTag;
    });
  } on OverlappingDeployment {
    // Only reachable with [reuse]: a fresh collar conflicts with nothing.
    if (reuse == null) rethrow;
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Tag ${reuse.tagName} is already on another animal today, so '
            '$animalName was not added. Recording on ${reuse.tagName}.',
          ),
        ),
      );
    }
    return reuse;
  } on UnauthorizedMutation catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.refusalSentence(
              asViewer:
                  'Viewers cannot create tags — ask a project owner to change '
                  'your role to contributor.',
            ),
          ),
        ),
      );
    }
    return null;
  }
  // Task 11.151: this tag is new to the global tag database and to the map's
  // legend as well as to this project's tag set, and naming only the last of
  // the three left the Tag Database screen and the map a restart behind.
  refreshTagViews(ref, projectId: project.projectId);
  return stored;
}

