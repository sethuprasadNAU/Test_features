import 'package:flutter/material.dart';

import 'package:tritrack_sync/tritrack_sync.dart';

import '../core/format/pulse_rate_format.dart';
import '../data/models/pulse_mode.dart';
import '../data/models/tag_fields.dart';
import '../data/repositories/tag_version_repository.dart';

/// Asks whether a tag edit is a **correction** or a **change** — task 11.32.
///
/// ## Why the app has to ask
///
/// Editing a frequency because the transmitter drifted and editing it because
/// it was typed in wrong are the same keystrokes with opposite correct answers
/// for every bearing already recorded. Nothing in the edit distinguishes them,
/// so the only place the answer exists is the person doing it.
///
/// ## Why there is no default
///
/// Drift and typo are both common, so either default is silently wrong a good
/// share of the time — and silence is precisely the harm this task exists to
/// end. Neither option is preselected, the affirmative button stays disabled
/// until one is chosen, and dismissing the dialog abandons the edit rather than
/// picking a side.
///
/// ## Why it reads like the supersede dialog
///
/// It is deliberately the same question in the same shape as the
/// supersede-versus-overwrite decision already taken for observations: *is the
/// old record still true of the moment it describes?* Somebody who has met one
/// should recognise the other.
///
/// Shown **only when a versioned field actually moved** — the caller checks
/// `TagRepository.versionedFieldsChanged` first. A recolour, a status change or
/// an edited note must ask nothing at all; keeping the common case frictionless
/// is part of the requirement.
///
/// **Task 11.250: [before] and [after] are [TagFields], not `Tag`.** The
/// library push asks this question once for every project a collar is
/// copied into, and the only thing this dialog reads off either argument is
/// what a library entry can supply just as well — frequency, name, pulse
/// modes, pulse pattern. Widening the type means the library's own edit can
/// be shown here directly, rather than needing a stand-in project row.
///
/// Returns null if the person dismissed it without choosing.
Future<TagEditIntent?> askTagEditIntent(
  BuildContext context, {
  required TagFields before,
  required TagFields after,
  required PulseRateUnit unit,
}) => showDialog<TagEditIntent>(
  context: context,
  builder: (context) =>
      _TagEditIntentDialog(before: before, after: after, unit: unit),
);

class _TagEditIntentDialog extends StatefulWidget {
  const _TagEditIntentDialog({
    required this.before,
    required this.after,
    required this.unit,
  });

  final TagFields before;
  final TagFields after;

  /// How to print a pulse rate — the device preference, passed in.
  final PulseRateUnit unit;

  @override
  State<_TagEditIntentDialog> createState() => _TagEditIntentDialogState();
}

class _TagEditIntentDialogState extends State<_TagEditIntentDialog> {
  /// No initial value, on purpose — see the class doc.
  TagEditIntent? _intent;

  /// The versioned fields that actually moved, as `label: was → becomes`.
  ///
  /// Showing the diff rather than just naming the fields is what makes the
  /// question answerable: "148.520 → 148.535" is recognisably a drift, and
  /// "F12 → F21" is recognisably a typo, and the person can see which they are
  /// looking at without remembering what they typed.
  List<(String, String, String)> get _changes => [
    if (widget.before.frequencyMhz != widget.after.frequencyMhz)
      (
        'Frequency',
        '${widget.before.frequencyMhz} MHz',
        '${widget.after.frequencyMhz} MHz',
      ),
    if (widget.before.tagName != widget.after.tagName)
      ('Name', widget.before.tagName, widget.after.tagName),
    // **Task 11.187: one row per pulse mode that moved**, rather than a row
    // for `pulseRate` alone. A mode is a name and a rate together, and a
    // person deciding "was this wrong, or has it changed?" needs to see the
    // pair — "Mortality 120 bpm → Mortality 90 bpm" is recognisably a
    // re-measurement, and "Mortality 120 bpm → — " is recognisably a mode
    // switched off, which are opposite answers.
    //
    // Slot 1's rate is `pulseRate`, so this row replaces the old "Pulse rate"
    // one rather than sitting beside it; `pulse_modes.dart` says why that
    // column keeps its name.
    ..._modeChanges,
    if (widget.before.pulsePattern != widget.after.pulsePattern)
      (
        'Pulse pattern',
        _orDash(widget.before.pulsePattern),
        _orDash(widget.after.pulsePattern),
      ),
  ];

  static String _orDash(String? value) =>
      value == null || value.isEmpty ? '—' : value;

  /// One `was → becomes` row per slot whose name or rate moved.
  ///
  /// **Keyed by slot, not by position in the list**, because the slot is what
  /// an observation stored: switching mode 2 off and mode 3 on is two changes,
  /// not one mode moving down the screen, and the records already taken can
  /// tell the difference even if the screen could not.
  ///
  /// Rates are shown in the unit the person chose — the dialog is handed it
  /// rather than reading a provider, so this widget stays a plain
  /// [StatefulWidget] and the caller stays the one place that knows the
  /// preference.
  List<(String, String, String)> get _modeChanges {
    final before = widget.before.pulseModes;
    final after = widget.after.pulseModes;
    return [
      for (var slot = 1; slot <= maxPulseModes; slot++)
        if (_describeMode(pulseModeAt(before, slot)) !=
            _describeMode(pulseModeAt(after, slot)))
          (
            'Pulse mode $slot',
            _describeMode(pulseModeAt(before, slot)),
            _describeMode(pulseModeAt(after, slot)),
          ),
    ];
  }

  /// A mode as one readable phrase, or an em dash when the slot is off.
  String _describeMode(PulseMode? mode) {
    if (mode == null) return '—';
    final rate = formatPulseRate(mode.rateBpm, widget.unit);
    return rate == null ? mode.name : '${mode.name}  $rate';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('tag_edit_intent_dialog'),
      title: const Text('Was this wrong, or has it changed?'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Records already taken against this tag remember what it read '
                'at the time. What happens to them depends on why you are '
                'editing it.',
              ),
              const SizedBox(height: 12),
              for (final (label, was, becomes) in _changes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '$label:  $was  →  $becomes',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              for (final option in TagEditIntent.values)
                RadioListTile<TagEditIntent>(
                  key: ValueKey('tag_edit_intent_${option.name}'),
                  value: option,
                  // ignore: deprecated_member_use
                  groupValue: _intent,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _intent = v),
                  contentPadding: EdgeInsets.zero,
                  title: Text(option.prompt),
                  subtitle: Text(option.consequence),
                  isThreeLine: true,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('tag_edit_intent_save'),
          // Disabled until a choice is made. This is the "no default" rule as
          // a widget: there is nothing to press until the question is answered.
          onPressed: _intent == null
              ? null
              : () => Navigator.of(context).pop(_intent),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
