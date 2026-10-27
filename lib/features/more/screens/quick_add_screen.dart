import 'dart:io';

import 'package:clock/clock.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/failure_message.dart';
import '../../../core/format/pulse_rate_format.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/providers/device_id_provider.dart';
import '../../../core/providers/project_time_zone_provider.dart';
import '../../../core/providers/pulse_rate_unit_provider.dart';
import '../../../core/providers/tag_view_refresh.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/individual.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/tag_library_entry.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../data/repositories/individual_repository.dart';
import '../../../data/repositories/mutation_authorization.dart';
import '../../../data/repositories/quick_add.dart';
import '../../../data/repositories/tag_library_repository.dart';
import '../../../data/repositories/tag_repository.dart';
import '../../../widgets/info_button.dart';
import '../../../widgets/went_on_date_card.dart';

/// **Quick add: many animals and their tags at once** — task 11.321, item 3,
/// reached from More → Animals.
///
/// Michael, 2026-09-30: twenty animals took sixty screens. "Same for all" sits
/// at the top — **the date the tags went on first, prefilled with today and
/// hard to miss**, because every bearing's animal is worked out from it —
/// then a table of names and frequencies, typed, pasted or read from a CSV.
/// Review shows what will happen before anything is written, and Save writes
/// every row or none ([QuickAddCommit]).
///
/// Who may use it: whoever may add an animal and link a tag today — a
/// contributor or owner (PERMISSIONS_MATRIX §4.7, IN1, DP1, T2). The Animals
/// screen gates the way in; the write refuses a viewer anyway.
class QuickAddScreen extends ConsumerStatefulWidget {
  const QuickAddScreen({super.key, required this.projectId});

  final String projectId;

  @override
  ConsumerState<QuickAddScreen> createState() => _QuickAddScreenState();
}

/// One row's fields while the screen is open.
class _RowFields {
  _RowFields(this.id, [QuickAddRow row = const QuickAddRow()])
    : name = TextEditingController(text: row.name),
      frequency = TextEditingController(text: row.frequency),
      species = TextEditingController(text: row.species ?? ''),
      tagName = TextEditingController(text: row.tagName ?? ''),
      pulseRateBpm = row.pulseRateBpm,
      expanded = (row.species ?? '').isNotEmpty || (row.tagName ?? '').isNotEmpty;

  final int id;
  final TextEditingController name;
  final TextEditingController frequency;
  final TextEditingController species;
  final TextEditingController tagName;

  /// From a paste or CSV only; there is no field for it on screen.
  final double? pulseRateBpm;
  bool expanded;

  QuickAddRow get row => QuickAddRow(
    name: name.text,
    frequency: frequency.text,
    species: species.text.trim().isEmpty ? null : species.text,
    tagName: tagName.text.trim().isEmpty ? null : tagName.text,
    pulseRateBpm: pulseRateBpm,
  );

  void dispose() {
    name.dispose();
    frequency.dispose();
    species.dispose();
    tagName.dispose();
  }
}

class _QuickAddScreenState extends ConsumerState<QuickAddScreen> {
  /// The day the person picked, as a calendar date, or null for today in
  /// the project's zone (task 11.331) — kept as a date rather than an
  /// instant because the zone is known only once the project is read.
  DateTime? _pickedDay;

  /// The project's zone; read in [build].
  String? _zone;

  /// The start of the chosen day in the project's zone — what is stored.
  DateTime get _date =>
      fieldDayStart(_pickedDay ?? fieldCalendarDate(clock.now(), _zone), _zone);
  final _species = TextEditingController();
  late final PulseRateUnit _unit = ref.read(pulseRateUnitProvider);
  late final _normal = TextEditingController(
    text: formatPulseRateValue(60, _unit),
  );
  late final _mortality = TextEditingController(
    text: formatPulseRateValue(120, _unit),
  );
  var _nextId = 0;
  late final List<_RowFields> _rows = [_RowFields(_nextId++)];
  bool _busy = false;

  @override
  void dispose() {
    _species.dispose();
    _normal.dispose();
    _mortality.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  bool get _isToday =>
      _date.isAtSameMomentAs(deploymentDateFor(clock.now(), _zone));

  Future<void> _pickDate() async {
    final today = fieldCalendarDate(clock.now(), _zone);
    final picked = await showDatePicker(
      context: context,
      initialDate: fieldCalendarDate(_date, _zone),
      firstDate: DateTime(2000),
      lastDate: today,
      helpText: 'When did the tags go on?',
    );
    if (picked == null || !mounted) return;
    setState(() => _pickedDay = DateTime(picked.year, picked.month, picked.day));
  }

  void _addRows(List<QuickAddRow> rows) {
    setState(() {
      // Fill the blank rows at the end first, so a paste into a fresh
      // screen does not leave an empty first row above it.
      while (_rows.isNotEmpty && _rows.last.row.isBlank) {
        _rows.removeLast().dispose();
      }
      for (final row in rows) {
        _rows.add(_RowFields(_nextId++, row));
      }
      if (_rows.isEmpty) _rows.add(_RowFields(_nextId++));
    });
  }

  void _say(String message) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final rows = QuickAddPaste.parse(data?.text ?? '');
    if (rows.isEmpty) {
      _say('Nothing to paste. Copy the rows from a spreadsheet first.');
      return;
    }
    _addRows(rows);
    _say(rows.length == 1 ? 'Added 1 row.' : 'Added ${rows.length} rows.');
  }

  Future<void> _importCsv() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'txt'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final String text;
    try {
      text = await File(path).readAsString();
    } catch (e) {
      if (mounted) {
        _say(describeFailure(e, fallback: 'Could not read that file.'));
      }
      return;
    }
    if (!mounted) return;
    final rows = QuickAddPaste.parse(text);
    if (rows.isEmpty) {
      _say('No rows found in that file.');
      return;
    }
    _addRows(rows);
    _say(rows.length == 1 ? 'Added 1 row.' : 'Added ${rows.length} rows.');
  }

  Future<void> _review() async {
    final normal = pulseRateToBpm(double.tryParse(_normal.text.trim()), _unit);
    final mortality = pulseRateToBpm(
      double.tryParse(_mortality.text.trim()),
      _unit,
    );
    if (normal == null || mortality == null) {
      _say('Pulse rates must be numbers.');
      return;
    }
    final rows = [for (final r in _rows) r.row];
    if (rows.every((r) => r.isBlank)) {
      _say('Add at least one animal.');
      return;
    }
    // The zone is normally read by now; if not, wait for it rather than
    // store a day with none (task 11.331).
    _zone ??= await ref.read(projectTimeZoneProvider(widget.projectId).future);
    if (!mounted) return;
    final defaults = QuickAddDefaults(
      attachedDate: _date,
      timeZone: _zone,
      species: _species.text.trim().isEmpty ? null : _species.text.trim(),
      normalRateBpm: normal,
      mortalityRateBpm: mortality,
    );
    setState(() => _busy = true);
    final _QuickAddInputs inputs;
    try {
      final database = await ref.read(appDatabaseProvider.future);
      final db = database.raw;
      inputs = _QuickAddInputs(
        projectTags: await TagRepository(db).findByProject(widget.projectId),
        library: await TagLibraryRepository(db).findAll(),
        animals: await IndividualRepository(
          db,
        ).findByProject(widget.projectId),
        deployments: await DeploymentRepository(
          db,
        ).findByProject(widget.projectId),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        _say(describeFailure(e, fallback: 'Could not check the rows.'));
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    QuickAddPreview planWith(Map<int, String> choices) => QuickAddPlanner.plan(
      rows: rows,
      defaults: defaults,
      projectId: widget.projectId,
      projectTags: inputs.projectTags,
      library: inputs.library,
      animals: inputs.animals,
      deployments: inputs.deployments,
      choices: choices,
    );
    // A paste's "Added N rows." would otherwise float over Review's Save.
    ScaffoldMessenger.of(context).clearSnackBars();
    final added = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (context) => QuickAddPreviewScreen(
          plan: planWith,
          save: (preview) => _save(preview, defaults),
        ),
      ),
    );
    if (added == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(added == 1 ? 'Added 1 animal.' : 'Added $added animals.'),
      ),
    );
  }

  /// Returns null on success, or the sentence to show.
  Future<String?> _save(QuickAddPreview preview, QuickAddDefaults defaults) async {
    try {
      final user = await ref.read(currentUserProvider.future);
      final deviceId = await ref.read(deviceIdProvider.future);
      final database = await ref.read(appDatabaseProvider.future);
      await QuickAddCommit.commit(
        database.raw,
        preview,
        projectId: widget.projectId,
        defaults: defaults,
        modifiedBy: user.userId,
        deviceId: deviceId,
      );
    } on OverlappingDeployment catch (e) {
      return 'Nothing was saved. ${e.message} Go back and review again.';
    } on UnauthorizedMutation catch (e) {
      return 'Nothing was saved. ${e.refusalSentence(
        asViewer: 'Viewers cannot add animals — ask an owner to change your role.',
      )}';
    } catch (e) {
      return describeFailure(
        e,
        fallback: 'Nothing was saved. Try again, and report it if this keeps '
            'happening.',
      );
    }
    refreshTagViews(ref, projectId: widget.projectId);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Task 11.331: "today" and the stored day are the project's zone's. Until
    // it is read (a moment), this phone's zone stands in — the same day for
    // any crew working where they are.
    _zone = ref.watch(projectTimeZoneProvider(widget.projectId)).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quick add'),
        actions: [
          IconButton(
            key: const ValueKey('quick_add_paste'),
            tooltip: 'Paste rows',
            icon: const Icon(Icons.content_paste),
            onPressed: _paste,
          ),
          IconButton(
            key: const ValueKey('quick_add_import_csv'),
            tooltip: 'Import CSV',
            icon: const Icon(Icons.upload_file),
            onPressed: _importCsv,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text('Same for all', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          WentOnDateCard(
            key: const ValueKey('quick_add_date'),
            label: 'Tags went on',
            date: _date,
            timeZone: _zone,
            isToday: _isToday,
            onChange: _pickDate,
            textKey: const ValueKey('quick_add_date_text'),
            buttonKey: const ValueKey('quick_add_change_date'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('quick_add_species'),
            controller: _species,
            decoration: const InputDecoration(labelText: 'Species (optional)'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('quick_add_normal_rate'),
                  controller: _normal,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Normal (${_unit.suffix})',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: const ValueKey('quick_add_mortality_rate'),
                  controller: _mortality,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Mortality (${_unit.suffix})',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Pulse rates apply to new tags only.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text('Animals', style: theme.textTheme.titleMedium),
              ),
              const InfoButton(
                title: 'How tags are matched',
                detailKey: ValueKey('quick_add_matching_detail'),
                detail:
                    'Each frequency is matched to a tag on this project '
                    'first, then to your Tag Library, which is copied in. '
                    'Anything else becomes a new tag, named by its '
                    'frequency.\n\n'
                    'If a frequency matches more than one tag, you choose '
                    'which in the review.\n\n'
                    'Paste rows copied from a spreadsheet, or import a CSV: '
                    'name and frequency, and optionally species and tag.',
              ),
            ],
          ),
          for (var i = 0; i < _rows.length; i++)
            KeyedSubtree(
              key: ValueKey('quick_add_row_${_rows[i].id}'),
              child: _RowEditor(
                index: i,
                fields: _rows[i],
                onToggle: () =>
                    setState(() => _rows[i].expanded = !_rows[i].expanded),
                onRemove: _rows.length == 1
                    ? null
                    : () => setState(() => _rows.removeAt(i).dispose()),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('quick_add_add_row'),
              icon: const Icon(Icons.add),
              label: const Text('Add row'),
              onPressed: () => setState(() => _rows.add(_RowFields(_nextId++))),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('quick_add_review'),
            onPressed: _busy ? null : _review,
            child: const Text('Review'),
          ),
        ],
      ),
    );
  }
}

class _QuickAddInputs {
  const _QuickAddInputs({
    required this.projectTags,
    required this.library,
    required this.animals,
    required this.deployments,
  });
  final List<Tag> projectTags;
  final List<TagLibraryEntry> library;
  final List<Individual> animals;
  final List<Deployment> deployments;
}

/// One row of the table: name and frequency, and behind ⋯ the fields that
/// override "Same for all".
class _RowEditor extends StatelessWidget {
  const _RowEditor({
    required this.index,
    required this.fields,
    required this.onToggle,
    required this.onRemove,
  });

  final int index;
  final _RowFields fields;
  final VoidCallback onToggle;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: ValueKey('quick_add_name_$index'),
                  controller: fields.name,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: TextField(
                  key: ValueKey('quick_add_freq_$index'),
                  controller: fields.frequency,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'MHz'),
                ),
              ),
              IconButton(
                key: ValueKey('quick_add_more_$index'),
                tooltip: fields.expanded ? 'Fewer fields' : 'More fields',
                icon: Icon(fields.expanded ? Icons.expand_less : Icons.more_horiz),
                onPressed: onToggle,
              ),
              IconButton(
                key: ValueKey('quick_add_remove_$index'),
                tooltip: 'Remove row',
                icon: const Icon(Icons.close),
                onPressed: onRemove,
              ),
            ],
          ),
          if (fields.expanded)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('quick_add_species_$index'),
                    controller: fields.species,
                    decoration: const InputDecoration(labelText: 'Species'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('quick_add_tag_$index'),
                    controller: fields.tagName,
                    decoration: const InputDecoration(labelText: 'Tag ID'),
                  ),
                ),
                // Lines the two fields up under the ones above.
                const SizedBox(width: 96),
              ],
            ),
        ],
      ),
    );
  }
}

/// **The review: what Save will do, before anything is written.**
///
/// Public only so a test can pump it with a plan. [plan] re-decides the
/// table with the person's choices for frequencies that matched more than
/// one tag; [save] writes, returning null or the sentence to show.
class QuickAddPreviewScreen extends StatefulWidget {
  const QuickAddPreviewScreen({
    super.key,
    required this.plan,
    required this.save,
  });

  final QuickAddPreview Function(Map<int, String> choices) plan;
  final Future<String?> Function(QuickAddPreview preview) save;

  @override
  State<QuickAddPreviewScreen> createState() => _QuickAddPreviewScreenState();
}

class _QuickAddPreviewScreenState extends State<QuickAddPreviewScreen> {
  final Map<int, String> _choices = {};
  late QuickAddPreview _preview = widget.plan(_choices);
  bool _saving = false;

  Future<void> _choose(QuickAddRowPlan row) async {
    final options = row.candidates.isNotEmpty
        ? row.candidates
        : widget.plan({..._choices}..remove(row.number)).rows
              .firstWhere((r) => r.number == row.number)
              .candidates;
    final key = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          row.sameTagId
              ? 'Tag ID ${options.first.projectTag?.tagName} is already on '
                    'this project'
              : 'Which tag is ${row.frequencyMhz!.toStringAsFixed(3)}?',
        ),
        children: [
          for (final c in options)
            SimpleDialogOption(
              key: ValueKey('quick_add_option_${c.key}'),
              onPressed: () => Navigator.of(context).pop(c.key),
              child: Text(
                row.sameTagId ? _sameTagIdLabel(c) : _candidateLabel(c),
              ),
            ),
        ],
      ),
    );
    if (key == null || !mounted) return;
    setState(() {
      _choices[row.number] = key;
      _preview = widget.plan(_choices);
    });
  }

  /// Task 11.324's two answers, in Michael's order: the existing tag first.
  static String _sameTagIdLabel(QuickAddCandidate c) {
    final tag = c.projectTag;
    if (tag != null) {
      return 'Use the existing tag (${tag.frequencyMhz.toStringAsFixed(3)} '
          'MHz)';
    }
    return 'Create anyway: a second tag with this Tag ID';
  }

  static String _candidateLabel(QuickAddCandidate c) {
    final tag = c.projectTag;
    if (tag != null) return '${tag.tagName} · on this project';
    final entry = c.libraryEntry;
    if (entry != null) return '${entry.tagName} · from your Tag Library';
    return 'A new tag';
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final failure = await widget.save(_preview);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop(_preview.animals);
      return;
    }
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(failure)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Review')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '${preview.summary}.',
              key: const ValueKey('quick_add_summary'),
              style: theme.textTheme.titleMedium,
            ),
          ),
          if (!preview.canSave)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                preview.problems > 0
                    ? 'Go back and fix or remove the rows marked below. '
                          'Nothing is saved until every row can be.'
                    : 'Choose a tag for each row marked below.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          Expanded(
            child: ListView.separated(
              itemCount: preview.rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final row = preview.rows[i];
                final mhz = row.frequencyMhz == null
                    ? row.row.frequency
                    : '${row.frequencyMhz!.toStringAsFixed(3)} MHz';
                final problem = row.problem;
                return ListTile(
                  key: ValueKey('quick_add_preview_${row.number}'),
                  leading: Icon(
                    problem != null
                        ? Icons.error_outline
                        : row.needsChoice
                        ? Icons.help_outline
                        : Icons.check_circle_outline,
                    color: problem != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                  title: Text('${row.number}. ${row.row.name.trim()} · $mhz'),
                  subtitle: Text(
                    problem ??
                        (row.needsChoice
                            ? _choiceLine(row)
                            : _sourceLine(row)),
                    style: problem == null
                        ? null
                        : TextStyle(color: theme.colorScheme.error),
                  ),
                  trailing: row.needsChoice ||
                          row.sameTagId ||
                          _choices.containsKey(row.number)
                      ? TextButton(
                          key: ValueKey('quick_add_choose_${row.number}'),
                          onPressed: () => _choose(row),
                          child: Text(row.needsChoice ? 'Choose' : 'Change'),
                        )
                      : null,
                );
              },
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: FilledButton(
              key: const ValueKey('quick_add_save'),
              onPressed: preview.canSave && !_saving ? _save : null,
              child: Text(
                preview.animals == 1
                    ? 'Add 1 animal'
                    : 'Add ${preview.animals} animals',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What an open row is waiting for. A Tag ID already on the project, on
  /// another frequency, names both frequencies (task 11.339): one of the two
  /// is wrong, and the line has to show the person which numbers disagree.
  static String _choiceLine(QuickAddRowPlan row) {
    final tag = row.projectTag;
    if (row.sameTagId && tag != null) {
      return 'Tag ID ${tag.tagName} is already on this project at '
          '${tag.frequencyMhz.toStringAsFixed(3)} MHz; this row says '
          '${row.frequencyMhz!.toStringAsFixed(3)} MHz. Choose which.';
    }
    return 'Matches more than one tag — choose one.';
  }

  static String _sourceLine(QuickAddRowPlan row) => switch (row.source!) {
    // Task 11.324: says why a row typed on one frequency is using a tag on
    // another — the Tag ID matched, and (since task 11.339) the person chose
    // it.
    QuickAddSource.projectTag when row.sameTagId =>
      'Same Tag ID as ${row.projectTag!.tagName} on this project '
          '(${row.projectTag!.frequencyMhz.toStringAsFixed(3)} MHz), so it '
          'uses that tag',
    QuickAddSource.newTag when row.sameTagId =>
      'New tag — a second one with this Tag ID',
    QuickAddSource.projectTag => 'Tag ${row.projectTag!.tagName}, on this project',
    QuickAddSource.library =>
      'Tag ${row.libraryEntry!.tagName}, from your Tag Library',
    QuickAddSource.newTag => 'New tag',
  };
}
