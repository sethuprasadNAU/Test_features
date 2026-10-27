import 'package:flutter/material.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../core/text/tag_status_labels.dart';
import '../data/models/individual.dart';
import 'tag_form.dart' show ColorSwatchGrid;

/// **The animal's own fields — name, status, sex, species, notes, colour —
/// and the one definition of them** (task 11.244).
///
/// Extracted from the animal dialog Project Setup used to open when the
/// Animals screen arrived, because that screen shows the same fields **plus
/// the animal's collars** and a second copy of six form controls is the
/// hand-maintained duplicate this project keeps finding. **Task 11.245
/// removed that dialog** — the Animals screen (`animal_detail_screen.dart`)
/// is the only door to an animal's fields now — so this is the one
/// definition with one caller, kept as its own widget because the caller
/// still needs it standing beside the collar list rather than folded in.
///
/// **It reports the whole edited row on every keystroke** rather than
/// handing back six values, so a container only has to know *"the animal as
/// it now stands"* — which is what both of them save.
///
/// [readOnly] is a viewer's view: every field shown, nothing editable. A
/// refusal must not be the end of the road (Michael, 2026-09-06), and an
/// animal's status, sex and notes are exactly what a viewer most wants to
/// read.
class IndividualFields extends StatefulWidget {
  const IndividualFields({
    super.key,
    required this.individual,
    required this.onChanged,
    this.readOnly = false,
  });

  final Individual individual;

  /// Called with the animal as edited, on every change. Never called with a
  /// row whose name is blank *silently* — the name may be blank, and the
  /// container is expected to refuse to save it, which is what both do.
  final ValueChanged<Individual> onChanged;
  final bool readOnly;

  @override
  State<IndividualFields> createState() => IndividualFieldsState();
}

class IndividualFieldsState extends State<IndividualFields> {
  late final _name = TextEditingController(text: widget.individual.name);
  late final _species =
      TextEditingController(text: widget.individual.species ?? '');
  late final _notes = TextEditingController(text: widget.individual.notes ?? '');
  late IndividualStatus _status = widget.individual.status;
  late IndividualSex? _sex = widget.individual.sex;

  @override
  void dispose() {
    _name.dispose();
    _species.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// The animal as the form now stands.
  ///
  /// **Colour is not one of these fields** (task 11.248) — it lives in
  /// [AnimalColorSection] now, which the caller places below the tag list.
  /// `widget.individual.colorHex` is left untouched here, so a caller that
  /// passes the animal *as currently edited* — colour included — threads a
  /// colour change through every later keystroke without this widget having
  /// to know about it.
  Individual get edited => widget.individual.copyWith(
        name: _name.text.trim(),
        status: _status,
        sex: _sex,
        species: _species.text.trim().isEmpty ? null : _species.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );

  void _report() => widget.onChanged(edited);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('individual_name'),
          readOnly: widget.readOnly,
          controller: _name,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (_) => setState(_report),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<IndividualStatus>(
          key: const ValueKey('individual_status'),
          initialValue: _status,
          decoration: const InputDecoration(labelText: 'Status'),
          items: [
            for (final s in IndividualStatus.values)
              DropdownMenuItem(value: s, child: Text(individualStatusLabel(s))),
          ],
          onChanged: widget.readOnly
              ? null
              : (s) => setState(() {
                    _status = s ?? _status;
                    _report();
                  }),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<IndividualSex?>(
          key: const ValueKey('individual_sex'),
          initialValue: _sex,
          decoration: const InputDecoration(labelText: 'Sex'),
          items: [
            for (final s in <IndividualSex?>[null, ...IndividualSex.values])
              DropdownMenuItem(value: s, child: Text(individualSexLabel(s))),
          ],
          onChanged: widget.readOnly
              ? null
              : (s) => setState(() {
                    _sex = s;
                    _report();
                  }),
        ),
        const SizedBox(height: 8),
        TextField(
          readOnly: widget.readOnly,
          controller: _species,
          decoration: const InputDecoration(labelText: 'Species (optional)'),
          onChanged: (_) => _report(),
        ),
        const SizedBox(height: 8),
        TextField(
          readOnly: widget.readOnly,
          controller: _notes,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
          minLines: 1,
          maxLines: 3,
          onChanged: (_) => _report(),
        ),
      ],
    );
  }
}

/// **The animal's colour, on its own** — task 11.248 moved it below the tag
/// list, because Michael's fields are edited far more often than the colour
/// is: *"colour is less likely to be edited."*
///
/// Kept a separate widget rather than folded back into [IndividualFields] so
/// the caller can place it wherever the layout wants it, and so a colour
/// change and a text-field change go through the same [onSelect] /
/// [onChanged] shape without either widget needing to know about the other's
/// state.
class AnimalColorSection extends StatelessWidget {
  const AnimalColorSection({
    super.key,
    required this.colorHex,
    required this.onSelect,
    this.readOnly = false,
  });

  final String colorHex;
  final ValueChanged<String> onSelect;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Color', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        // The consequence, before the swatches rather than after the map
        // redraws: this is the colour of every tag the animal has ever been
        // heard on, not of one tag.
        Text(
          'Every tag this animal has worn shows this color.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        if (!readOnly) ColorSwatchGrid(selected: colorHex, onSelect: onSelect),
      ],
    );
  }
}

/// The sentence a person reads before a merge happens — what moves, what
/// stays, and the one thing that cannot be undone. Shared by the dialog that
/// asks and by the test that holds the wording.
String mergeConfirmationText({
  required String absorbName,
  required String keepName,
  required int collarsMoving,
}) {
  final tags = collarsMoving == 1 ? '1 tag' : '$collarsMoving tags';
  return '$absorbName\'s $tags will now belong to $keepName. No bearing, '
      'no-signal entry, estimate or truth point moves.\n\n'
      '$absorbName\'s own record — name, color, status, species, sex and '
      'notes — is deleted, and that cannot be undone. Note down anything you '
      'need first.';
}
