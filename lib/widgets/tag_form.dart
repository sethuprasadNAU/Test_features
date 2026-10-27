/// **The tag form and the tag row, shared by the two screens that show a
/// transmitter** — task 11.219.
///
/// Copy-on-add gave the app two places a collar's details live: this device's
/// personal library, on the Tag Library screen, and a project's own copy, on
/// `More → Tags` (moved off Project Setup by task 11.245). **The form is the
/// same in both** — frequency, name, pulse modes, dates, status, notes,
/// colour — and it is a large piece of UI whose geometry has been measured
/// several times (tasks 11.126, 11.187, 11.191).
///
/// They lived in `tag_database_screen.dart` while there was only one screen
/// that used them. A second copy for the project's own tags would have been
/// the hand-maintained-list defect in its most expensive form: two
/// renderings of one form, drifting apart, each with its own overflow
/// history.
///
/// What differs between the two callers is supplied as parameters and
/// nothing else: whether the form is read-only, whether it offers to put a
/// copy into a project, and how many projects already hold one.
/// A small grey icon standing in for a tag's status when it is not `active`.
///
/// **Michael, 2026-09-06, choosing between three offered treatments:** "keep
/// it on one line and use either a little icon or color state of the text
/// (grey etc.) to indicate non standard states", then picking the variant
/// that tells the three non-active states apart rather than only saying
/// "something is off here". So the row does both: the line goes grey *and*
/// the icon says which state.
///
/// **The colour is deliberately not doing any of the work.** All three icons
/// are drawn in the same colour, so the state is carried by the shape;
/// colour alone is the one channel that fails in bright sun and for a
/// colour-blind reader, and this app is used outdoors.
///
/// **Task 11.198: that colour was `outline`, and it was never readable.**
/// Neither this badge nor the padlock beside it (nor the row's own grey-out
/// of the tag name) appears in a published screenshot — the seeded harness
/// has no badged tag and always photographs an owner — so nobody had looked.
/// Measured against the `Scaffold`'s own background — this list has no card
/// under it — `outline` is 1.12:1 in light mode and 1.28:1 in dark, both far
/// under WCAG's 3:1 floor for icons; the same shape task 11.197 found for the
/// record screen's checkbox label, which is what it was copied from. Now
/// `onSurfaceVariant`. **Task 11.200 changed what that means and the numbers
/// with it:** the token was undefined when 11.198 measured it and resolved to
/// `onSurface`, giving the 14.98:1 / 16.44:1 recorded here. It is now the
/// palette's muted grey and measures **4.60:1 light, 6.69:1 dark** against
/// this list's background — still well clear of the 3:1 icon floor, and now
/// actually reading as secondary.
///
/// **Task 11.138's rule applies and is answered, not ignored: an icon is not
/// a label.** The word is on the Tag details page one tap away, which every
/// reader can now open — including a viewer, who previously got a refusal
/// instead (see [_showEditDialog]). `semanticLabel` carries the word for a
/// screen reader, which is the only reader that cannot make that tap.
///
/// **Task 11.199: the word comes from [tagStatusLabel], not from here.** This
/// `switch` used to carry its own lower-cased copy of three of the four status
/// words — the only mapping of that vocabulary in the app, sitting inside one
/// widget, while three other places printed the raw stored token. The icon is
/// this function's to choose; the word is not.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/format/pulse_rate_format.dart';
import '../core/providers/pulse_rate_unit_provider.dart';
import '../core/text/tag_status_labels.dart';
import '../core/theme/design_tokens.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../data/models/project.dart';
import '../data/models/pulse_mode.dart';
import '../data/models/tag.dart';
import '../data/models/tag_draft.dart';
import '../data/models/tag_fields.dart';
import '../core/providers/tag_sort_provider.dart';
import 'info_button.dart';
import 'tag_color_swatch.dart';
import 'tag_view_only_banner.dart';
import 'wheel_picker.dart';

({IconData icon, String label})? tagStatusBadge(TagStatus status) => switch (status) {
      TagStatus.active => null,
      TagStatus.recovered =>
        (icon: Icons.check_circle_outline, label: tagStatusLabel(status)),
      TagStatus.lost => (icon: Icons.help_outline, label: tagStatusLabel(status)),
      TagStatus.malfunction =>
        (icon: Icons.warning_amber_rounded, label: tagStatusLabel(status)),
    };
class TagListRow extends ConsumerWidget {
  const TagListRow({
    super.key,
    required this.tag,
    required this.sortOrder,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.leading,
    this.subtitle,
    this.removed = false,
    this.action,
  });
  /// Any tag-shaped row — a library entry here, a project's own tag on
  /// Project Setup. See `TagFields` for why one widget rather than two.
  final TagFields tag;

  /// **The order the list is in, because the row leads with whichever field
  /// the person is scanning by** (Michael, 2026-09-06). A column of numbers
  /// is scannable when the numbers are all in the same place and the eye
  /// only has to move down; sorting by name and still printing the frequency
  /// first means every value the sort put in order is the second thing on
  /// its line, behind a name of unpredictable width.
  final TagSortOrder sortOrder;

  final VoidCallback onTap;

  /// **Task 11.288.** Starts multi-select — the row itself carries no other
  /// affordance for it, so this is the only way in. Null on a caller (Project
  /// Setup's own tags) that has no selection to start.
  final VoidCallback? onLongPress;

  /// **Task 11.288.** Whether the library screen is currently mid-selection.
  /// While true, [onTap] toggles this row's selection instead of opening the
  /// tag form — the caller decides that, this widget only draws the checkbox
  /// leading [selected] asks for.
  final bool selectionMode;

  /// **Task 11.288.** Whether this row is one of the selected ones. Ignored
  /// unless [selectionMode] is true.
  final bool selected;

  /// Drawn at the start of the row when not selecting — the Tag Library's
  /// drag handle (task 11.321). The selection checkbox takes its place while
  /// selecting.
  final Widget? leading;

  /// **More → Tags only** (task 11.321: Michael asked that a project's tag
  /// list look like the Tag Library). What that list knows and the library
  /// does not — who is wearing the tag, that it was removed from the
  /// project, its status in words — goes on a second line under the same
  /// 18-point line. Null, the library's case, keeps the row one line.
  final String? subtitle;

  /// A tag removed from its project: the line is struck through and muted.
  final bool removed;

  /// A button in place of the chevron — More → Tags's remove / *Add back*.
  final Widget? action;

  /// **The whole row is one line, and it is one line structurally rather than
  /// by hope** (Michael, 2026-09-06: "keep it on one line ... My concern with
  /// forcing it all to one line and increasing the font size is that it won't
  /// all fit on a single line and then wrap").
  ///
  /// That concern is correct and nothing here is left to fit by luck: the line
  /// is capped at `maxLines: 1` and ellipsises, so **the row's height cannot
  /// depend on how long anybody's tag names are**, at any font size or text
  /// scale. The failure mode is `Kestrel Nest Sit…`, never a second line.
  ///
  /// **The part that gives way is the part that is second**, which is the same
  /// rule as [sortOrder] and falls out of it for free: the field the list is
  /// sorted by leads, so the field somebody is scanning a column of is the one
  /// that survives, and the other is what the ellipsis eats.
  ///
  /// **A first attempt split this into a [Row] so that only the name could
  /// ever be cut** — keeping the frequency whole under either sort. It
  /// overflowed by 13 pixels at a 2.0 text scale on a 6.1-inch phone, because
  /// a non-flexible child cannot shrink and a frequency at double text size is
  /// wider than the space a row has: it turned "the line might wrap", which is
  /// ugly, into "the line overflows", which is a yellow-and-black stripe. A
  /// single [Text] cannot do that. **The lesson is the project's own** (tasks
  /// 11.149, 11.162, 11.166): a budget must be able to *refuse*, and a layout
  /// where one child is forbidden to shrink has no way to say no.
  static const _rowFontSize = 18.0;

  /// The row's whole line: the sorted field, then the other one.
  String get _line {
    final frequency = '${tag.frequencyMhz.toStringAsFixed(3)} MHz';
    return switch (sortOrder) {
      TagSortOrder.frequency => '$frequency · ${tag.tagName}',
      TagSortOrder.name => '${tag.tagName} · $frequency',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **The padlock is gone and that is the model, not a regression** (task
    // 11.219). It previewed "you may read this but not change it", which was
    // true while every tag was global and belonged to somebody's project.
    // This row shows the device's own tag *library* now: those entries are
    // in no project, so no role governs them and nothing can refuse an edit.
    //
    // **Where the read-only case went**, because it did not disappear: a
    // *project's* copy of a tag is still owner-only to change, it is edited
    // on Project Setup, and that screen says so once under the section
    // rather than once per row — task 11.138's rule, and
    // `tagsSectionDisabledReason` is where the sentence lives.
    final scheme = Theme.of(context).colorScheme;
    final badge = tagStatusBadge(tag.status);

    // **Everything the second line used to carry now lives on Tag details**
    // (Michael, 2026-09-06: "The special notes (ie view only) should move to
    // the tag details page. This will allow all the info on the tag database
    // table be on one line (frequency name) which will allow the font size to
    // be increased a bit for readability"). The pulse rate, the status word
    // and the "view only" words were the three things on it; all three are on
    // that page, and the two that are worth finding while *scanning* — a
    // non-active status, and not being allowed to edit — are still on the row
    // as icons, which cost height nothing.
    // **Task 11.198: `outline` measured unreadable, the same finding task
    // 11.197 made for the record screen's checkbox label.** This list sits
    // directly on the `Scaffold`'s background, no card under it: `outline`
    // (`#E2E2DF` light, `#2A2A2A` dark) measures 1.12:1 against it in light
    // mode and 1.28:1 in dark, both far under WCAG's 3:1 floor for text and
    // icons. `onSurfaceVariant` is what 11.197 switched to for the same
    // reason. **Task 11.200 closed the gap this comment used to describe:**
    // the token was never set in this app's `ColorScheme`, so it resolved to
    // `onSurface` (14.98:1 light, 16.44:1 dark) and every "muted" label in the
    // app — including the checkbox Michael asked to be "light grey by
    // default" — rendered as full body text. The token is now the palette's
    // `secondaryText` grey and this row measures **4.60:1 light, 6.69:1
    // dark**: secondary to the tag name beside it, and comfortably readable.
    final style = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontSize: _rowFontSize,
          color: badge == null && !removed ? null : scheme.onSurfaceVariant,
          decoration: removed ? TextDecoration.lineThrough : null,
        );

    // **The colour swatch is gone from this row** (task 11.244). This list is
    // the device's tag **library**, and a library entry's colour is read by
    // nothing: it was the seed for the animal a copy-into-a-project used to
    // create (task 11.241), and task 11.243 stopped creating that animal —
    // a collar is equipment now and invents no bird. Task 11.244's linking
    // flow attaches a collar to an animal that already exists and already has
    // a colour, so the seed has nowhere left to land.
    //
    // **A swatch showing a colour nothing uses is worse than no swatch**: it
    // is a promise about the map that the map does not keep. Colour is still
    // edited on a *project's* tag, where it writes through to the animal —
    // see `TagRepository.update`.
    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selectionMode && selected,
      // **Task 11.288.** Only drawn while [selectionMode] is true, so a
      // single-entry swipe delete costs the row nothing the rest of the
      // time — the same "a budget must be able to refuse" rule this row's
      // own history (tasks 11.149, 11.162, 11.166) already applies to width.
      leading: selectionMode
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : leading,
      // `label:` as well as the text, so a screen reader is read the *whole*
      // line even when the display has ellipsised it — which is more than a
      // sighted reader gets.
      title: Semantics(
        label: _line,
        child: Text(
          _line,
          style: style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // **No subtitle on the library.** A `ListTile` with a title and no
      // subtitle is a one-line tile, which is the whole point of the change —
      // the row's height stops depending on what is true about the tag. More
      // → Tags passes one; see [subtitle].
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badge != null)
            Icon(
              badge.icon,
              size: 20,
              color: scheme.onSurfaceVariant,
              semanticLabel: badge.label,
            ),
          // **Task 11.138: a padlock is not a label**, and the words it stood
          // in for used to be on the subtitle this change removed. They moved
          // to where the tap goes rather than disappearing: the Tag details
          // page now opens for a viewer too and leads with "Only an owner can
          // change this tag", naming the tag and saying what changing it
          // would do to the observations already recorded against it. That is
          // reached by the tap somebody actually makes — the same answer this
          // screen's create FAB and CSV import already give (11.94/11.101) —
          // rather than by a tooltip a touchscreen never opens.
          // **Task 11.288.** The chevron promises "tapping opens something" —
          // true the rest of the time, false the moment a tap toggles a
          // checkbox instead.
          if (action != null)
            action!
          else if (!selectionMode)
            const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// What the form produced, plus which project (if any) to put a **copy**
/// into — only meaningful when creating; editing an existing row never
/// touches any project.
class TagEditResult {
  const TagEditResult(this.draft, this.projectId);

  /// The edited values with no identity attached — see [TagDraft] for why the
  /// form does not build a row itself.
  final TagDraft draft;
  final String? projectId;
}

class TagEditDialog extends ConsumerStatefulWidget {
  const TagEditDialog({
    super.key,
    this.existing,
    this.readOnly = false,
    this.projects = const [],
    this.initialProjectId,
    required this.initialColorHex,
    this.projectCopyCount = 0,
    this.showColor = true,
    this.offerProject = true,
  });

  /// The row being edited, or null when creating. **Any tag shape** — a
  /// library entry from this screen, a project's own tag from Project Setup
  /// — because the form is the same either way; see `TagFields` and
  /// [TagDraft].
  final TagFields? existing;

  /// How many of this device's projects hold a copy of this collar (§2.5).
  ///
  /// **A count, never the projects' names.** A device can legitimately hold
  /// a project the person is only a viewer on, and naming it would tell them
  /// it exists — the disclosure cancelled task 11.29 left a standing rule
  /// against. Zero renders nothing.
  final int projectCopyCount;

  /// **Read-only Tag details, for somebody who may not change this tag.**
  ///
  /// Before 2026-09-06 a viewer's tap on a locked row opened a refusal and
  /// stopped, so **the one person who most needed to read a tag was the only
  /// one who could not** — pulse rate, pattern, notes, colour and date put on
  /// were all unreachable to them. That was invisible because the refusal was
  /// correct: it explained itself, it was actionable, and it was covered by a
  /// test. Nothing was wrong with the message; what was wrong was that it was
  /// the *end* of the road.
  ///
  /// It was found while moving the row's "view only" words onto this page at
  /// Michael's request — the destination turned out to be unreachable by the
  /// audience the words were written for. Michael chose to open it up
  /// (2026-09-06).
  ///
  /// The refusal itself is not deleted: it is the banner at the top of this
  /// page, with the same wording and the same `tag_edit_not_permitted` key it
  /// had as a dialog, so the `on UnauthorizedMutation` handler still ends in
  /// a sentence a person reads.
  final bool readOnly;

  /// Every project on the device, offered as the "link to project" choice
  /// when creating a new tag. Empty (and unused) when editing.
  final List<Project> projects;
  final String? initialProjectId;

  /// The color to preselect: the tag's current color when editing, or the
  /// next auto-assigned palette color (from [TagRepository.nextColorHex])
  /// when creating.
  final String initialColorHex;

  /// **Whether this form edits a colour at all** — task 11.244.
  ///
  /// True for a *project's* tag, where the colour is the animal's and editing
  /// it recolours every collar that animal has worn (`TagRepository.update`
  /// writes it through). **False for a tag-library entry**, whose colour is
  /// read by nothing since task 11.243 stopped a copy-into-a-project
  /// inventing an animal to seed.
  ///
  /// The value is still carried — [initialColorHex] comes back out in the
  /// draft — so the column keeps whatever it had rather than being nulled by
  /// a form that no longer asks about it.
  final bool showColor;

  /// **Whether a new tag's form asks which project to add it to** — task
  /// 11.321. False from an animal's *New tag…*, where the project is the
  /// animal's and asking would offer a choice that is not one.
  final bool offerProject;

  @override
  ConsumerState<TagEditDialog> createState() => TagEditDialogState();
}

/// One row of the pulse-mode editor while the dialog is open.
///
/// **[rateBpm] is the value and the controller is only a view of it.** The
/// person may flip the unit while this dialog is open, and re-rendering the
/// field from beats per minute is what stops 90 bpm becoming 89.55 on a
/// round trip through "0.67 s" that nobody typed. A rate only changes when
/// somebody edits the field.
class _PulseModeDraft {
  _PulseModeDraft({required this.slot, required String name, this.rateBpm})
      : nameController = TextEditingController(text: name);

  final int slot;
  final TextEditingController nameController;
  double? rateBpm;

  /// Rebuilt rather than kept, so the text always reflects [rateBpm] in the
  /// unit currently chosen.
  final TextEditingController rateController = TextEditingController();

  void dispose() {
    nameController.dispose();
    rateController.dispose();
  }
}

class TagEditDialogState extends ConsumerState<TagEditDialog> {
  late final _freqController =
      TextEditingController(text: widget.existing?.frequencyMhz.toString() ?? '');
  /// The tag's modes while the dialog is open, in slot order.
  ///
  /// **A new tag starts with Michael's two defaults** (2026-09-07: *"'Normal'
  /// at 1 pulse per second and Mortality at 2 pulses per second"*, i.e. 60 and
  /// 120 bpm). An existing tag starts with whatever it has, which after schema
  /// v12's migration is Normal — carrying the `pulse_rate` it already had — and
  /// Mortality with no rate, because the old schema had nowhere to record one
  /// and inventing 120 for a collar somebody deployed would be a measurement
  /// nobody took.
  late final List<_PulseModeDraft> _modes = widget.existing == null
      ? [
          for (var i = 0; i < defaultPulseModeNames.length; i++)
            _PulseModeDraft(
              slot: i + 1,
              name: defaultPulseModeNames[i],
              rateBpm: defaultPulseModeRatesBpm[i],
            ),
        ]
      : [
          for (final mode in widget.existing!.pulseModes)
            _PulseModeDraft(
              slot: mode.slot,
              name: mode.name,
              rateBpm: mode.rateBpm,
            ),
        ];

  /// The unit the rate fields were last rendered in, so a flip of the
  /// preference re-renders them rather than reinterpreting the digits already
  /// on screen as the new unit.
  PulseRateUnit? _renderedRateUnit;

  late final _nameController = TextEditingController(text: widget.existing?.tagName ?? '');
  late final _notesController = TextEditingController(text: widget.existing?.notes ?? '');
  late TagStatus _status = widget.existing?.status ?? TagStatus.active;
  late String? _projectId = widget.initialProjectId;

  /// The currently selected palette swatch. Meaningless while [_customHexController]
  /// holds non-empty text — the custom field takes priority when populated.
  late String _selectedSwatch = TagColorPalette.colors.contains(widget.initialColorHex)
      ? widget.initialColorHex
      : TagColorPalette.defaultColor;
  late final _customHexController = TextEditingController(
    text: TagColorPalette.colors.contains(widget.initialColorHex) ? '' : widget.initialColorHex,
  );
  late bool _advancedExpanded = !TagColorPalette.colors.contains(widget.initialColorHex);
  String? _customHexError;

  /// The color that will actually be saved: the custom hex if one is entered
  /// and valid, otherwise the selected swatch.
  String get _effectiveColorHex {
    final custom = _customHexController.text.trim();
    return (custom.isNotEmpty && TagColorPalette.isValidHex(custom)) ? custom : _selectedSwatch;
  }

  void _selectSwatch(String hex) {
    setState(() {
      _selectedSwatch = hex;
      _customHexController.clear();
      _customHexError = null;
    });
  }

  void _onCustomHexChanged(String value) {
    setState(() {
      final v = value.trim();
      _customHexError = (v.isEmpty || TagColorPalette.isValidHex(v))
          ? null
          : 'Enter a hex color like #RRGGBB';
    });
  }

  @override
  void dispose() {
    _freqController.dispose();
    for (final mode in _modes) {
      mode.dispose();
    }
    _nameController.dispose();
    _notesController.dispose();
    _customHexController.dispose();
    super.dispose();
  }

  /// Rewrites every rate field from its stored beats-per-minute value when the
  /// display unit has changed since the last build.
  ///
  /// **This runs in `build` and writes to controllers, which is normally the
  /// wrong shape** — it is safe here because it changes nothing unless
  /// [_renderedRateUnit] disagrees with the preference, so it cannot loop, and
  /// because the alternative (a listener) would have to reach the same
  /// controllers from outside the frame that knows the unit.
  void _renderRateFields(PulseRateUnit unit) {
    if (_renderedRateUnit == unit) return;
    _renderedRateUnit = unit;
    for (final mode in _modes) {
      mode.rateController.text = mode.rateBpm == null
          ? ''
          : formatPulseRateValue(mode.rateBpm, unit);
    }
  }

  /// **The tag's pulse modes — task 11.187.**
  ///
  /// One to three named modes, each with an optional rate. Slot 1 has no
  /// remove button: Michael's rule is *"up to three modes but not fewer than
  /// 1"*, and a control that is not offered is a rule that cannot be broken by
  /// pressing it.
  ///
  /// **Every field is inside an `Expanded`,** which is what task 11.126 found
  /// this dialog needed: it had only ever been rendered on an 800-pixel test
  /// surface and overflowed by 139 logical pixels at real phone width, because
  /// a non-flexible child cannot give way. Two fields on one row is the widest
  /// thing added here, and both of them can shrink.
  ///
  /// **The header is a `Wrap`, not a `Row` — task 11.232.** It was a `Row` of
  /// `Expanded(title)` beside the unit toggle, and **a `Row` hands a
  /// non-flexible child no width bound at all** — so a control that knows how
  /// to fit itself to a bound is never told there is one, and the only child
  /// that can give way is the flexible title. Measured in the phone's font on
  /// a 6.1-inch phone: *"Pulse modes"* was given 116 logical pixels at
  /// xxxLarge, 43 at AX4 and **19.7 at AX5** — a column of single letters
  /// beside a control that still read fine. In the test font, which is about
  /// 1.6× wider, the same row went on past the title to a striped overflow
  /// from xxxLarge up (3.4 px) to AX5 (255 px). Same mechanism, two faces.
  ///
  /// A `Wrap` gives every child the run's width as its bound. Two things
  /// follow. The toggle drops to its own line instead of taking the title's
  /// width — on a phone that is enough at every size iOS offers, since the
  /// toggle measures 277 px at AX5 against a 297 px row. And where even a
  /// whole line is too narrow (the test font from AX1 up), the bound reaches
  /// the `SegmentedButton`, which caps each segment at half the width it is
  /// given and wraps the label inside it — taller, never striped. **Nothing
  /// changes where the toggle already fits**, which on a phone is everywhere.
  ///
  /// Not a `FittedBox`, which was tried first: `AlertDialog` measures its
  /// content with `IntrinsicWidth`, and Material's `_RenderSegmentedButton`
  /// reads its own `constraints` inside `computeDryLayout`, which throws
  /// *"does not have any constraints before it has been laid out"* on the
  /// dry pass a `FittedBox` needs. A control that cannot be dry-laid-out
  /// cannot sit under anything that asks its size before laying it out.
  Widget _pulseModesSection(PulseRateUnit unit) {
    final theme = Theme.of(context);
    final freeSlot = nextFreePulseModeSlot([for (final m in _modes) m.slot]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          children: [
            Text('Pulse modes', style: theme.textTheme.titleMedium),
            // The unit control lives here because this is where rates are
            // typed. It is a **device preference**, not part of the tag, so
            // changing it here changes every screen and survives a restart —
            // and it writes nothing to the tag being edited.
            PulseRateUnitToggle(
              unit: unit,
              onChanged: (next) =>
                  ref.read(pulseRateUnitSettingProvider.notifier).set(next),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final mode in _modes) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: ValueKey('pulse_mode_name_${mode.slot}'),
                    readOnly: widget.readOnly,
                    controller: mode.nameController,
                    decoration: InputDecoration(
                      labelText: 'Mode ${mode.slot} name',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: ValueKey('pulse_mode_rate_${mode.slot}'),
                    readOnly: widget.readOnly,
                    controller: mode.rateController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: unit.suffix,
                      isDense: true,
                    ),
                    onChanged: (text) => mode.rateBpm = pulseRateToBpm(
                      double.tryParse(text.trim()),
                      unit,
                    ),
                  ),
                ),
                // Slot 1 keeps its space so the three rows line up, and shows
                // nothing to press.
                SizedBox(
                  width: 40,
                  child: widget.readOnly || mode.slot == 1
                      ? null
                      : IconButton(
                          key: ValueKey('pulse_mode_remove_${mode.slot}'),
                          icon: const Icon(Icons.remove_circle_outline),
                          tooltip: 'Remove this mode',
                          onPressed: () => setState(() {
                            mode.dispose();
                            _modes.remove(mode);
                          }),
                        ),
                ),
              ],
            ),
          ),
        ],
        if (!widget.readOnly && freeSlot != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('pulse_mode_add'),
              icon: const Icon(Icons.add),
              label: const Text('Add mode'),
              onPressed: () => setState(() {
                final draft = _PulseModeDraft(slot: freeSlot, name: '');
                _modes
                  ..add(draft)
                  ..sort((a, b) => a.slot.compareTo(b.slot));
              }),
            ),
          ),
        Text(
          'Rates are stored in beats per minute whatever this shows.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// **Which way the copy went, in one line, with the long form behind an
  /// information icon** — §2.5 of `TAG_COPY_ON_ADD_DESIGN.md`, and Michael's
  /// standing simplicity instruction of 2026-09-07 for the shape.
  ///
  /// Two directions, and the one that will actually confuse people is
  /// **editing the library and expecting the project to follow**. So the
  /// line appears on a library entry that any project holds a copy of, and
  /// on a project's tag that was copied in.
  ///
  /// **A count, never the projects' names.** A device can legitimately hold
  /// a project the person is only a viewer on, and *"will not reach Kruger
  /// 2027"* would tell them that project exists — the disclosure cancelled
  /// task 11.29 left a standing rule against. "Two of your projects" tells
  /// them what they need in order not to lose an edit, and nothing else.
  ///
  /// Nothing here relies on a colour or a bare glyph: the sentence is the
  /// answer. Getting this wrong writes the wrong data, which is the
  /// exception the simplicity instruction itself names.
  ///
  /// ## Which rows reach which branch (task 11.234)
  ///
  /// `copiedAt` is read off [Tag] only — a [TagLibraryEntry] always presents
  /// as `null` here, since a library entry is never itself copied.
  ///
  /// - **`(copiedAt: non-null, _)`** — a project's tag that has a record of
  ///   being copied in. Shows "Copied in on …" regardless of [copies]; this
  ///   is the branch that swallowed the bug, because it is checked first and
  ///   a copied-in tag's own count was never wrong in a way anybody could
  ///   see through it.
  /// - **`(copiedAt: null, copies > 0)`** — reached by a library entry any
  ///   project holds a copy of ([TagLibraryRepository.libraryCopyCount], no
  ///   self-match possible), *or* by a project's tag that was never copied
  ///   in but whose collar some *other* project also holds
  ///   ([TagLibraryRepository.otherProjectCopyCount], this project's own row
  ///   excluded). This was the branch task 11.234 fixed: before the fix, a
  ///   project's own tag always matched itself, so `copies` was never zero
  ///   here for that caller.
  /// - **`(copiedAt: null, copies == 0)`** — a project's own tag, never
  ///   copied elsewhere and copied from nowhere. No line at all.
  List<Widget> _copyProvenance() {
    final existing = widget.existing;
    if (existing == null) return const [];
    final copiedAt = existing is Tag ? existing.copiedAt : null;
    final copies = widget.projectCopyCount;
    final (String short, String long)? line = switch ((copiedAt, copies)) {
      (final DateTime at, _) => (
        'Copied in on ${_dayOf(at)}',
        'This project has its own copy of this tag, made on '
            '${_dayOf(at)}. Changes here reach only this project — not your '
            'tag library or any other project.',
      ),
      (null, > 0) => (
        // **Task 11.250: the visible line states the consequence, not the
        // fact.** "One of your projects uses this collar" was true and it
        // was a check that fails correctly into a place with no reader — the
        // sentence that would have stopped a typo-fix from being lost sat
        // behind the information icon, where a person correcting a typo has
        // no reason to tap it. A count, never a project's name (§2.5).
        copies == 1
            ? "Changes here won't reach the 1 project using this tag"
            : "Changes here won't reach the $copies projects using this "
                'tag',
        'Each project that uses this tag has its own copy, so changes here '
            'will not reach ${copies == 1 ? 'that project' : 'those projects'}. '
            'Change it on the project, or use "Apply to your projects" after '
            'saving.',
      ),
      _ => null,
    };
    if (line == null) return const [];
    final scheme = Theme.of(context).colorScheme;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              line.$1,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          InfoButton(
            key: const ValueKey('tag_copy_provenance_info'),
            detailKey: const ValueKey('tag_copy_provenance_detail'),
            title: 'Each project has its own copy',
            tooltip: 'What a copy means',
            detail: line.$2.replaceAll('**', ''),
          ),
        ],
      ),
    ];
  }

  static String _dayOf(DateTime at) {
    final local = at.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final unit = ref.watch(pulseRateUnitProvider);
    _renderRateFields(unit);
    return AlertDialog(
      // **"Tag details", not "Edit tag"** (Michael, 2026-09-06). The chevron
      // on a list row promises somewhere to read the rest of a tag, and this
      // form already *is* that: every field the row dropped is here,
      // including the date put on. Renaming it is the whole of the change —
      // a separate read-only page would be a second rendering of the same
      // fields to keep true, for a form the person can already just read.
      title: Text(widget.existing == null ? 'Add tag' : 'Tag details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.readOnly) ...[
              TagViewOnlyBanner(tag: widget.existing!),
              const SizedBox(height: 12),
            ],
            ..._copyProvenance(),
            // **Task 11.229: the name leads.** Michael opens this dialog to
            // see which tag it is, and until now that was the fourth field,
            // behind frequency and the whole pulse-mode editor. On *Add tag*
            // this field is deliberately still empty first — a new tag has no
            // ID yet to lead with, and `_submit` already refuses to save one
            // blank, so nothing is lost by asking for it before frequency
            // instead of after.
            //
            // **"Tag ID", not "Tag / animal name" (task 11.245).** The column
            // is still `tag_name` (design §3) — renaming it would be wire
            // churn with no behavioural gain — but Michael: *"so that there
            // isn't any confusion that a tag identifier and an animal name
            // are different."* See `Tag.tagName`'s doc comment for the same
            // note where the column is declared.
            TextField(
              readOnly: widget.readOnly,
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Tag ID'),
            ),
            const SizedBox(height: 12),
            TextField(
              readOnly: widget.readOnly,
              controller: _freqController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Frequency (MHz)'),
            ),
            const SizedBox(height: 12),
            _pulseModesSection(unit),
            // **"Pulse pattern" left this form at task 11.268** (item 6).
            // Michael: *"Do tags need 'pulse patterns'? We don't use that
            // anywhere?"* — a free-text field no screen displayed and
            // nothing filtered or computed with. The column stays, still
            // versioned, and this form now always writes it null; see the
            // `pulse_pattern` entry in `tag_column_kinds.dart` for why it
            // keeps `TagColumnKind.measurementContext` rather than moving to
            // `TagColumnKind.retired` the way `Tags.color_hex` did.
            const SizedBox(height: 12),
            Text('Status', style: Theme.of(context).textTheme.titleMedium),
            // Read-only: a wheel that scrolls but discards the choice would
            // be a control that lies about what it does, so the value is
            // printed instead of offered.
            if (widget.readOnly)
              Text(tagStatusLabel(_status))
            else
              WheelPicker<TagStatus>(
                items: TagStatus.values,
                selected: _status,
                height: 84,
                labelBuilder: tagStatusLabel,
                onChanged: (s) => setState(() => _status = s),
              ),
            // **"Date put on" left this form at schema v17** (task 11.243).
            // It described a deployment, and this form describes a piece of
            // equipment; when the collar went on an animal is a
            // `Deployments` row, recorded where the animal is chosen.
            //
            // Task 11.126's overflow measurement was about that row and went
            // with it: the dialog was found over by 139 logical pixels at
            // 6.1-inch phone width, the date being the part that gave way.
            // The row is gone rather than fixed, so **this dialog is one
            // measured row shorter than 11.126 left it** and the number is
            // not transferable to whatever replaces it.
            const SizedBox(height: 8),
            TextField(
              readOnly: widget.readOnly,
              controller: _notesController,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
              minLines: 1,
              maxLines: 3,
            ),
            // **Only where a colour means something** — task 11.244. On a
            // project's tag this edits the *animal's* colour and every collar
            // she has worn redraws; on a tag-library entry it edits a value
            // nothing reads. See [TagEditDialog.showColor].
            if (widget.showColor) ...[
              const SizedBox(height: 12),
              Text('Color', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (widget.readOnly)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TagColorSwatch(colorHex: widget.existing!.colorHex),
                )
              else
                ColorSwatchGrid(
                  selected: _customHexController.text.trim().isEmpty ? _selectedSwatch : null,
                  onSelect: _selectSwatch,
                ),
              const SizedBox(height: 8),
              if (!widget.readOnly)
                _AdvancedColorSection(
                  expanded: _advancedExpanded,
                  onToggle: () => setState(() => _advancedExpanded = !_advancedExpanded),
                  controller: _customHexController,
                  error: _customHexError,
                  onChanged: _onCustomHexChanged,
                ),
            ],
            if (widget.existing == null && widget.offerProject) ...[
              const SizedBox(height: 12),
              Text('Also add to project', style: Theme.of(context).textTheme.titleMedium),
              DropdownButtonFormField<String?>(
                // Task 11.126: measured overflowing by 5.3 logical pixels at
                // phone width. A project name is arbitrary length, so the
                // menu has to be told it may use the width it is given
                // rather than the width its longest entry wants.
                isExpanded: true,
                // **Task 11.232: not dense, so the selected label may wrap.**
                // `DropdownButtonFormField` defaults `isDense: true`, and a
                // dense `DropdownButton` boxes its selected item at exactly
                // one line of the text style — `max(scaled line height, icon
                // size, 24)` — at every text scale. Its own comment says
                // "don't make it smaller than the text that it contains",
                // which holds for a label on one line and fails the moment
                // the label wraps: the second line is cut off with no
                // ellipsis and no stripe. Measured in the phone's font on a
                // 6.1-inch phone against the label text at the time
                // ("None (unlinked)"): fits until AX2 and is half-shown from
                // AX3 (2.35×) up; a project name goes the same way from AX4.
                // **Task 11.234 renamed that label to "Don't add to a
                // project" — longer, so those exact breakpoints are stale
                // and unverified; the mechanism (non-dense, wraps whole)
                // does not depend on the wording and still applies.**
                // Non-dense, the box is as tall as what it holds — 48 px
                // minimum, the ordinary Material dropdown — and a wrapped
                // label shows whole. Measured cost: this field is 64 px
                // tall at the default size where it was 48, in a dialog
                // that scrolls anyway.
                isDense: false,
                initialValue: widget.projects.any((p) => p.projectId == _projectId) ? _projectId : null,
                items: [
                  const DropdownMenuItem(value: null, child: Text("Don't add to a project")),
                  for (final p in widget.projects)
                    DropdownMenuItem(value: p.projectId, child: Text(p.projectName)),
                ],
                onChanged: (v) => setState(() => _projectId = v),
              ),
            ],
          ],
        ),
      ),
      actions: widget.readOnly
          ? [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ]
          : [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(onPressed: _submit, child: const Text('Save')),
            ],
    );
  }

  void _submit() {
    final freq = double.tryParse(_freqController.text.trim());
    final name = _nameController.text.trim();
    if (freq == null || name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Frequency and name are required.')),
      );
      return;
    }
    final customHex = _customHexController.text.trim();
    if (customHex.isNotEmpty && !TagColorPalette.isValidHex(customHex)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Custom color must be a hex value like #RRGGBB.')),
      );
      return;
    }
    // **Task 11.187.** A mode with a blank name is not a mode — that is how a
    // slot is switched off — so a blank row is dropped rather than saved as an
    // unnamed one. Slot 1 is the exception the whole design turns on: if
    // somebody empties it, it falls back to the default name rather than
    // leaving the tag with no modes, which `buildPulseModes` would do on read
    // anyway. Writing the default here means the *stored* row says it too,
    // instead of relying on every future reader to apply the same fallback.
    final named = {
      for (final mode in _modes)
        if (mode.nameController.text.trim().isNotEmpty ||
            mode.slot == 1)
          mode.slot: (
            mode.nameController.text.trim().isEmpty
                ? defaultPulseModeNames[0]
                : mode.nameController.text.trim(),
            mode.rateBpm,
          ),
    };
    // A rate with no mode is never read (see `buildPulseModes`), but storing
    // one would leave the columns disagreeing about a slot that is off, so a
    // removed mode takes its rate with it.
    final draft = TagDraft(
      frequencyMhz: freq,
      pulseRate: named[1]?.$2,
      pulseMode1Name: named[1]?.$1 ?? defaultPulseModeNames[0],
      pulseMode2Name: named[2]?.$1,
      pulseMode2RateBpm: named[2]?.$2,
      pulseMode3Name: named[3]?.$1,
      pulseMode3RateBpm: named[3]?.$2,
      // **Off the form — task 11.268.** Carried forward from the existing
      // row rather than written null on every save: `pulsePattern` is
      // `TagColumnKind.measurementContext`, so nulling it unconditionally
      // here would manufacture a "was X, becomes null" change on *every*
      // edit of a tag that already had a value — including a pure colour
      // change, which must ask nothing (`_TagEditIntentDialogState`'s own
      // rule, `editing a project tag asks about earlier records
      // recolouring asks nothing at all`). A brand-new tag has nothing to
      // carry forward, so this is null there, which is what "off the form"
      // should mean for it. See the comment above `_pulseModesSection` in
      // `build`.
      pulsePattern: widget.existing?.pulsePattern,
      tagName: name,
      status: _status,
      notes: _notesController.text.trim().isEmpty
          ? null
          : _notesController.text.trim(),
      colorHex: _effectiveColorHex,
    );
    Navigator.of(context).pop(TagEditResult(draft, _projectId));
  }
}

/// 12 palette swatches at [DesignTokens.minTouchTarget] (44x44 — the app's
/// minimum touch target). The selected swatch is marked with a check icon
/// and a ring — a non-color cue, since color alone can't be relied on to
/// convey selection. [selected] is null when a custom hex (entered below)
/// overrides the palette choice, in which case no swatch is shown selected.
///
/// Public since task 11.241, because the animal form (`individual_form.dart`)
/// picks a colour with the same twelve swatches — colour is the animal's, so
/// the two forms must offer the same palette or a person could pick a colour
/// in one that the other cannot show as selected.
class ColorSwatchGrid extends StatelessWidget {
  const ColorSwatchGrid({super.key, required this.selected, required this.onSelect});

  final String? selected;
  final ValueChanged<String> onSelect;

  static const _swatchSize = DesignTokens.minTouchTarget;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final hex in TagColorPalette.colors)
          _Swatch(
            key: ValueKey('tag_color_swatch_$hex'),
            hex: hex,
            isSelected: hex == selected,
            onTap: () => onSelect(hex),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({super.key, required this.hex, required this.isSelected, required this.onTap});

  final String hex;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = Color(int.parse(hex.substring(1), radix: 16) + 0xFF000000);
    // Simple relative-luminance check so the check mark stays legible against
    // both light and dark palette colors.
    final checkColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Semantics(
      button: true,
      selected: isSelected,
      label: 'Color $hex',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ColorSwatchGrid._swatchSize / 2),
        child: Container(
          width: ColorSwatchGrid._swatchSize,
          height: ColorSwatchGrid._swatchSize,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: isSelected ? Icon(Icons.check, color: checkColor) : null,
        ),
      ),
    );
  }
}

/// Collapsed-by-default "advanced" custom-hex entry, matching the bordered/
/// tap-to-expand pattern already used for antenna-type/receiver-gain in
/// Observation Logging.
class _AdvancedColorSection extends StatelessWidget {
  const _AdvancedColorSection({
    required this.expanded,
    required this.onToggle,
    required this.controller,
    required this.error,
    required this.onChanged,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final TextEditingController controller;
  final String? error;
  final ValueChanged<String> onChanged;

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
            key: const ValueKey('tag_color_advanced_toggle'),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                '${expanded ? '▾' : '▸'} Advanced: custom hex color',
                // **Task 11.229.** Same fifth instance of the dialog's
                // hard-coded `fontSize: 12` found while tracing every small
                // string on it — not one of the four the task named, but the
                // same defect. The grey (`onSurfaceVariant`) is untouched;
                // only the size moves, to `titleMedium` like every other
                // section label on this dialog.
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: TextField(
                key: const ValueKey('tag_color_custom_hex_field'),
                controller: controller,
                onChanged: onChanged,
                decoration: InputDecoration(
                  labelText: 'Custom color (hex)',
                  hintText: '#RRGGBB',
                  errorText: error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// **The bpm ↔ seconds-per-pulse control — task 11.187.**
///
/// Michael, 2026-09-07: *"Keep them stored as bpm but still allow users to
/// toggle to see them in seconds-per-pulse."*
///
/// It sets a **device preference**, so every screen that prints a rate follows
/// it and it survives a restart — see `PulseRateUnitSetting`. It writes nothing
/// to any tag: no stored number ever leaves beats per minute, which is why the
/// migration for this feature had no arithmetic in it.
///
/// Both options are always visible rather than one label that toggles, because
/// a single label cannot say whether it names the current state or the action —
/// the ambiguity this project has already paid for on other controls.
class PulseRateUnitToggle extends StatelessWidget {
  const PulseRateUnitToggle({
    super.key,
    required this.unit,
    required this.onChanged,
  });

  final PulseRateUnit unit;
  final ValueChanged<PulseRateUnit> onChanged;

  @override
  Widget build(BuildContext context) {
    return _DryLayoutFromIntrinsics(
      child: SegmentedButton<PulseRateUnit>(
        key: const ValueKey('pulse_rate_unit_toggle'),
        showSelectedIcon: false,
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          // **Task 11.229.** `labelSmall` is 9.5px — the theme's smallest
          // role, and used nowhere else in the app — measured too small to
          // read. Bumped to 12px, into the 11-13px "secondary/list" band the
          // handoff's own type scale names for exactly this kind of control
          // label; the weight and color stay the role's.
          textStyle: WidgetStatePropertyAll(
            Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 12),
          ),
        ),
        segments: [
          for (final option in PulseRateUnit.values)
            ButtonSegment(
              value: option,
              label: Text(option.suffix),
              tooltip: option.label,
            ),
        ],
        selected: {unit},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// **A workaround for a Flutter defect, declared as one — task 11.232.**
///
/// Material's `SegmentedButton` cannot be dry-laid-out: its render object
/// reads its own `constraints` inside `computeDryLayout`, and before the
/// first real layout there are none, so the call throws *"A RenderObject does
/// not have any constraints before it has been laid out."* Its four intrinsic
/// methods are fine — they only ask the segments.
///
/// That matters here because `AlertDialog` measures its content with an
/// `IntrinsicWidth`, and a `Wrap` answers an intrinsic-height question by
/// dry-laying-out its children. So a `SegmentedButton` inside a `Wrap` inside
/// a dialog crashes on the first frame — which is what happened the moment
/// the pulse-modes header became a `Wrap`. (Inside a `Row` it never did:
/// `RenderFlex` answers the same question from the children's intrinsics.)
///
/// This proxy answers the dry-layout question from the child's own intrinsic
/// dimensions instead, which is the same approximation Flutter's intrinsic
/// pass already accepts. **It exists only for that defect.**
/// `tag_database_screen_test.dart` builds the unshimmed control under a
/// `Wrap` in an `IntrinsicWidth` and expects the crash; the day that test
/// goes red is the day Flutter has fixed it and this class should be deleted.
class _DryLayoutFromIntrinsics extends SingleChildRenderObjectWidget {
  const _DryLayoutFromIntrinsics({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDryLayoutFromIntrinsics();
}

class _RenderDryLayoutFromIntrinsics extends RenderProxyBox {
  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    final width =
        constraints.constrainWidth(child.getMaxIntrinsicWidth(double.infinity));
    final height = constraints.constrainHeight(child.getMaxIntrinsicHeight(width));
    return Size(width, height);
  }
}
