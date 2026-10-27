import 'package:csv/csv.dart';
import 'package:sqflite/sqflite.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../db/data_arrival.dart';
import '../models/deployment.dart';
import '../models/individual.dart';
import '../models/sync_meta.dart';
import '../models/tag.dart';
import '../models/tag_library_entry.dart';
import '../tags/library_groups.dart';
import 'deployment_repository.dart';
import 'individual_repository.dart';
import 'tag_repository.dart';

/// **Many animals and their collars at once** — task 11.321, item 3.
///
/// Michael, 2026-09-30, preparing for deployment: putting a collar on an
/// animal took three screens, and twenty animals took sixty. Crews usually
/// have the list already, so this takes a table — typed, pasted from a
/// spreadsheet, or read from a CSV — and writes every animal, its tag and the
/// link between them **together, or not at all.**
///
/// Three pieces, so each can be tested without a screen:
///
/// - [QuickAddPaste] reads pasted or CSV text into [QuickAddRow]s.
/// - [QuickAddPlanner] decides, for every row, which tag it will use and
///   whether anything is wrong — **and writes nothing.** The preview the
///   person confirms is this.
/// - [QuickAddCommit] writes exactly that preview in one transaction.
///
/// ## Which tag a frequency means
///
/// Frequencies are compared to the kilohertz (three decimals, as every tag
/// list shows them). A frequency that matches **one** tag on this project
/// reuses it; one that matches **one** Tag Library tag the project does not
/// hold copies it in (the same copy More → Tags makes); one that matches
/// nothing creates a new tag. **A frequency that matches more than one is
/// asked about, never guessed** (Michael's rule) — the person picks one, or a
/// new tag.
///
/// **A new tag whose Tag ID this project already has stops and asks** (task
/// 11.339, Michael, 2026-10-08: *stop and ask*). Task 11.324 first made such a
/// row use the existing tag by default; in a pasted table a coincidental Tag
/// ID with a correct new frequency then attached the animal to the wrong
/// collar unless somebody read the line. Now the row waits, like a frequency
/// matching two tags: *Use the existing tag* or *Create anyway*
/// ([QuickAddRowPlan.sameTagId]). A row whose Tag ID **and** frequency both
/// match is not asked about: its frequency already finds that tag.
class QuickAddRow {
  const QuickAddRow({
    this.name = '',
    this.frequency = '',
    this.species,
    this.tagName,
    this.pulseRateBpm,
  });

  /// The animal's name.
  final String name;

  /// The frequency as typed, in MHz. Parsed by the planner, so a typo is a
  /// problem on its row rather than a row that silently vanished.
  final String frequency;

  /// Overrides "Same for all" for this row when set.
  final String? species;

  /// The new tag's ID. Defaults to the frequency when blank.
  final String? tagName;

  /// The new tag's Normal rate, in beats per minute (a CSV's `pulse_rate`
  /// column, the unit the tag CSV import already reads). Overrides "Same for
  /// all" for this row.
  final double? pulseRateBpm;

  bool get isBlank =>
      name.trim().isEmpty &&
      frequency.trim().isEmpty &&
      (species ?? '').trim().isEmpty &&
      (tagName ?? '').trim().isEmpty &&
      pulseRateBpm == null;

  QuickAddRow copyWith({
    String? name,
    String? frequency,
    String? species,
    String? tagName,
  }) => QuickAddRow(
    name: name ?? this.name,
    frequency: frequency ?? this.frequency,
    species: species ?? this.species,
    tagName: tagName ?? this.tagName,
    pulseRateBpm: pulseRateBpm,
  );
}

/// "Same for all": what every row gets unless it says otherwise.
class QuickAddDefaults {
  const QuickAddDefaults({
    required this.attachedDate,
    this.species,
    this.normalRateBpm = 60,
    this.mortalityRateBpm = 120,
    this.timeZone,
  });

  /// **The day the tags went on.** Every bearing's animal is worked out from
  /// it, which is why the screen prefills today and puts it first. A bare
  /// day, as `deploymentDateFor` makes one — the same value a single link
  /// writes when it is not a swap.
  final DateTime attachedDate;
  final String? species;

  /// The project's zone, which [attachedDate] is a day in and every row
  /// written stores (task 11.331).
  final String? timeZone;

  /// For new tags only: a tag reused or copied keeps its own rates.
  final double normalRateBpm;
  final double mortalityRateBpm;
}

/// Where a row's tag comes from.
enum QuickAddSource { projectTag, library, newTag }

/// One tag a frequency could mean, offered when it means more than one.
class QuickAddCandidate {
  const QuickAddCandidate.project(Tag this.projectTag) : libraryEntry = null;
  const QuickAddCandidate.library(TagLibraryEntry this.libraryEntry)
    : projectTag = null;
  const QuickAddCandidate.newTag() : projectTag = null, libraryEntry = null;

  final Tag? projectTag;
  final TagLibraryEntry? libraryEntry;

  /// What [QuickAddPlanner.plan]'s `choices` holds for this candidate.
  String get key => projectTag != null
      ? 'project:${projectTag!.tagId}'
      : libraryEntry != null
      ? 'library:${libraryEntry!.tagId}'
      : 'new';
}

/// What will happen to one row — or why it cannot.
class QuickAddRowPlan {
  const QuickAddRowPlan({
    required this.number,
    required this.row,
    this.frequencyMhz,
    this.source,
    this.projectTag,
    this.libraryEntry,
    this.candidates = const [],
    this.problem,
    this.sameTagId = false,
  });

  /// The row's number in the table, from 1, counting blank rows too, so it
  /// matches what the person sees.
  final int number;
  final QuickAddRow row;
  final double? frequencyMhz;
  final QuickAddSource? source;
  final Tag? projectTag;
  final TagLibraryEntry? libraryEntry;

  /// Set when the frequency matched more than one tag and nobody has picked
  /// yet. Includes a new tag as the last choice.
  final List<QuickAddCandidate> candidates;

  /// Why the deployment rules or the table refuse this row. One sentence.
  final String? problem;

  /// The row would have made a new tag, but its Tag ID is already on this
  /// project (task 11.324). Set whichever way it was decided, so the review
  /// can say why; [candidates] then holds that tag and a new one. Until the
  /// person chooses, the row [needsChoice] and [projectTag] is the tag with
  /// that ID, so the review can name its frequency (task 11.339).
  final bool sameTagId;

  bool get needsChoice => problem == null && source == null;
}

/// The whole table, decided — what the preview shows and the save writes.
class QuickAddPreview {
  const QuickAddPreview(this.rows);

  final List<QuickAddRowPlan> rows;

  int get animals => rows.length;
  int _count(QuickAddSource s) =>
      rows.where((r) => r.problem == null && r.source == s).length;
  int get newTags => _count(QuickAddSource.newTag);
  int get fromLibrary => _count(QuickAddSource.library);
  int get onProject => _count(QuickAddSource.projectTag);
  int get problems => rows.where((r) => r.problem != null).length;
  int get unchosen => rows.where((r) => r.needsChoice).length;

  /// Nothing is saved while any row has a problem or an open question —
  /// all rows together, or none.
  bool get canSave => rows.isNotEmpty && problems == 0 && unchosen == 0;

  /// *"20 animals, 14 new tags, 6 from your library, 1 problem."*
  String get summary {
    String n(int count, String one, String many) =>
        '$count ${count == 1 ? one : many}';
    return [
      n(animals, 'animal', 'animals'),
      if (newTags > 0) n(newTags, 'new tag', 'new tags'),
      if (fromLibrary > 0) '$fromLibrary from your library',
      if (onProject > 0) '$onProject already on this project',
      if (unchosen > 0) n(unchosen, 'tag to choose', 'tags to choose'),
      if (problems > 0) n(problems, 'problem', 'problems'),
    ].join(', ');
  }
}

/// Decides every row, writing nothing.
abstract final class QuickAddPlanner {
  /// Frequencies are matched to the kilohertz.
  static int _khz(double mhz) => (mhz * 1000).round();

  static QuickAddPreview plan({
    required List<QuickAddRow> rows,
    required QuickAddDefaults defaults,
    required String projectId,
    required List<Tag> projectTags,
    required List<TagLibraryEntry> library,
    required List<Individual> animals,
    required List<Deployment> deployments,
    Map<int, String> choices = const {},
  }) {
    final fromLibrary = libraryEntriesNotOnProject(library, projectTags);
    final existingNames = {
      for (final a in animals) a.name.trim().toLowerCase(): a.name,
    };
    final animalNames = {for (final a in animals) a.individualId: a.name};
    final namesSeen = <String, int>{};
    final khzSeen = <int, int>{};
    final plans = <QuickAddRowPlan>[];

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final number = i + 1;
      if (row.isBlank) continue;
      QuickAddRowPlan refuse(
        String problem, {
        double? mhz,
        List<QuickAddCandidate> candidates = const [],
      }) => QuickAddRowPlan(
        number: number,
        row: row,
        frequencyMhz: mhz,
        problem: problem,
        candidates: candidates,
        sameTagId: candidates.isNotEmpty,
      );

      final name = row.name.trim();
      if (name.isEmpty) {
        plans.add(refuse('Needs a name.'));
        continue;
      }
      final mhz = double.tryParse(row.frequency.trim());
      if (mhz == null) {
        plans.add(refuse('Frequency is not a number.'));
        continue;
      }
      final key = name.toLowerCase();
      if (existingNames.containsKey(key)) {
        plans.add(refuse('Already an animal on this project.', mhz: mhz));
        continue;
      }
      final sameName = namesSeen[key];
      if (sameName != null) {
        plans.add(refuse('Same name as row $sameName.', mhz: mhz));
        continue;
      }
      namesSeen[key] = number;
      final sameKhz = khzSeen[_khz(mhz)];
      if (sameKhz != null) {
        plans.add(refuse('Same frequency as row $sameKhz.', mhz: mhz));
        continue;
      }
      khzSeen[_khz(mhz)] = number;

      final candidates = [
        for (final t in projectTags)
          if (_khz(t.frequencyMhz) == _khz(mhz)) QuickAddCandidate.project(t),
        for (final e in fromLibrary)
          if (_khz(e.frequencyMhz) == _khz(mhz)) QuickAddCandidate.library(e),
      ];
      // Task 11.324: the Tag ID a new tag here would get, already on this
      // project. Asked only when the frequency alone would make a new tag.
      final newId = _tagIdOf(row, mhz);
      final sameIdTag = candidates.isNotEmpty
          ? null
          : projectTags
                .where((t) => t.tagName.trim().toLowerCase() == newId)
                .firstOrNull;
      final sameIdChoices = sameIdTag == null
          ? const <QuickAddCandidate>[]
          : [
              QuickAddCandidate.project(sameIdTag),
              const QuickAddCandidate.newTag(),
            ];
      final QuickAddCandidate picked;
      final chosen = choices[number];
      if (chosen != null) {
        picked = [
          ...candidates,
          ...sameIdChoices,
          const QuickAddCandidate.newTag(),
        ].firstWhere(
          (c) => c.key == chosen,
          orElse: () => const QuickAddCandidate.newTag(),
        );
      } else if (sameIdTag != null) {
        // **Stop and ask** (task 11.339, Michael, 2026-10-08). The Tag ID
        // matches a tag on this project and the frequency does not, so one
        // of the two is wrong and only the person knows which.
        plans.add(
          QuickAddRowPlan(
            number: number,
            row: row,
            frequencyMhz: mhz,
            projectTag: sameIdTag,
            candidates: sameIdChoices,
            sameTagId: true,
          ),
        );
        continue;
      } else if (candidates.length > 1) {
        // **Never guessed** — Michael's rule.
        plans.add(
          QuickAddRowPlan(
            number: number,
            row: row,
            frequencyMhz: mhz,
            candidates: [...candidates, const QuickAddCandidate.newTag()],
          ),
        );
        continue;
      } else {
        picked = candidates.isEmpty
            ? const QuickAddCandidate.newTag()
            : candidates.single;
      }

      final projectTag = picked.projectTag;
      if (projectTag != null) {
        // The deployment rules, asked the way `DeploymentRepository.link`
        // asks them: a new animal cannot clash, so only the tag can.
        final conflict = DeploymentInterlock.conflictFor(
          _candidate(projectId, projectTag.tagId, number, defaults).interval,
          deployments.map((d) => d.interval),
        );
        if (conflict != null) {
          final who = animalNames[conflict.other.individualId];
          plans.add(
            refuse(
              who == null
                  ? 'This tag is on another animal on that date.'
                  : 'This tag is on $who on that date.',
              mhz: mhz,
              candidates: sameIdChoices,
            ),
          );
          continue;
        }
        plans.add(
          QuickAddRowPlan(
            number: number,
            row: row,
            frequencyMhz: mhz,
            source: QuickAddSource.projectTag,
            projectTag: projectTag,
            candidates: sameIdChoices,
            sameTagId: sameIdTag != null,
          ),
        );
        continue;
      }
      final entry = picked.libraryEntry;
      if (entry != null) {
        plans.add(
          QuickAddRowPlan(
            number: number,
            row: row,
            frequencyMhz: mhz,
            source: QuickAddSource.library,
            libraryEntry: entry,
          ),
        );
        continue;
      }
      // A new tag is held to the same bounds every other tag is.
      final issues = RowValidator.validate(
        Tables.tags,
        newTagFor(
          row,
          mhz,
          defaults,
          projectId: projectId,
          tagId: 'preview',
          sync: SyncMeta.initial(now: DateTime.now()),
        ).toColumns(),
      );
      if (issues.isNotEmpty) {
        plans.add(
          refuse(
            _sentence(issues.first.message),
            mhz: mhz,
            candidates: sameIdChoices,
          ),
        );
        continue;
      }
      plans.add(
        QuickAddRowPlan(
          number: number,
          row: row,
          frequencyMhz: mhz,
          source: QuickAddSource.newTag,
          candidates: sameIdChoices,
          sameTagId: sameIdTag != null,
        ),
      );
    }
    return QuickAddPreview(plans);
  }

  static String _sentence(String message) {
    final s = message.trim();
    if (s.isEmpty) return 'This row cannot be saved.';
    final first = s[0].toUpperCase() + s.substring(1);
    return first.endsWith('.') ? first : '$first.';
  }

  static Deployment _candidate(
    String projectId,
    String tagId,
    int number,
    QuickAddDefaults defaults,
  ) => Deployment(
    deploymentId: 'quick-add-$number',
    projectId: projectId,
    tagId: tagId,
    individualId: 'quick-add-$number',
    attachedDate: defaults.attachedDate,
    sync: SyncMeta.initial(now: DateTime.now()),
    timeZone: defaults.timeZone,
  );

  /// The Tag ID [newTagFor] would give this row, trimmed and lower-cased for
  /// comparing with the project's tags.
  static String _tagIdOf(QuickAddRow row, double mhz) {
    final named = (row.tagName ?? '').trim();
    return (named.isEmpty ? mhz.toStringAsFixed(3) : named).toLowerCase();
  }

  /// The tag a row creates when its frequency matches nothing: Normal and
  /// Mortality modes at "Same for all"'s rates (the row's own Normal rate
  /// wins), and an ID that is the frequency unless the row names one.
  static Tag newTagFor(
    QuickAddRow row,
    double mhz,
    QuickAddDefaults defaults, {
    required String projectId,
    required String tagId,
    required SyncMeta sync,
  }) {
    final named = (row.tagName ?? '').trim();
    return Tag(
      tagId: tagId,
      projectId: projectId,
      // Created here, not copied: its own id is its lineage, as on the
      // Record screen's quick-add.
      lineageId: tagId,
      frequencyMhz: mhz,
      tagName: named.isEmpty ? mhz.toStringAsFixed(3) : named,
      status: TagStatus.active,
      colorHex: TagColorPalette.noIndividual,
      pulseMode1Name: defaultPulseModeNames[0],
      pulseRate: row.pulseRateBpm ?? defaults.normalRateBpm,
      pulseMode2Name: defaultPulseModeNames[1],
      pulseMode2RateBpm: defaults.mortalityRateBpm,
      sync: sync,
    );
  }
}

/// Writes a [QuickAddPreview], all of it or none of it.
abstract final class QuickAddCommit {
  static const _uuid = Uuid();

  /// One transaction for every row: the animal, its tag (reused, copied in,
  /// or created) and the link. **Any refusal rolls back every row** — a
  /// viewer's, the deployment rules' (a sync can change things between the
  /// preview and the save), or the database's. Returns how many animals were
  /// added. Throws, having written nothing, if [preview] cannot be saved.
  static Future<int> commit(
    Database db,
    QuickAddPreview preview, {
    required String projectId,
    required QuickAddDefaults defaults,
    required String modifiedBy,
    String? deviceId,
    DateTime? now,
  }) async {
    if (!preview.canSave) {
      throw StateError('a quick add with problems or open choices was saved');
    }
    final at = now ?? DateTime.now();
    final sync = SyncMeta.initial(
      now: at,
      modifiedBy: modifiedBy,
      originDeviceId: deviceId,
    );
    await db.transaction((txn) async {
      final individuals = IndividualRepository(txn);
      final tags = TagRepository(txn);
      final deployments = DeploymentRepository(txn);
      for (final plan in preview.rows) {
        final row = plan.row;
        final individualId = _uuid.v4();
        final species = (row.species ?? '').trim().isNotEmpty
            ? row.species!.trim()
            : (defaults.species ?? '').trim().isEmpty
            ? null
            : defaults.species!.trim();
        await individuals.insert(
          Individual(
            individualId: individualId,
            projectId: projectId,
            name: row.name.trim(),
            // Read inside the transaction, so each row continues the
            // round-robin from the one before it.
            colorHex: await individuals.nextColorHex(projectId: projectId),
            // `unknown`, as everywhere an animal is created: nothing has been
            // observed about it yet (design §5).
            status: IndividualStatus.unknown,
            species: species,
            lineageId: individualId,
            sync: sync,
          ),
        );
        final String tagId;
        switch (plan.source!) {
          case QuickAddSource.projectTag:
            tagId = plan.projectTag!.tagId;
          case QuickAddSource.library:
            tagId = (await tags.copyFromLibrary(
              plan.libraryEntry!,
              projectId: projectId,
              modifiedBy: modifiedBy,
              deviceId: deviceId,
              now: at,
            )).tagId;
          case QuickAddSource.newTag:
            tagId = _uuid.v4();
            final tag = QuickAddPlanner.newTagFor(
              row,
              plan.frequencyMhz!,
              defaults,
              projectId: projectId,
              tagId: tagId,
              sync: sync,
            );
            // Written as `insert(tag)` on purpose: the guard that lists
            // every place a tag is created matches this shape.
            await tags.insert(tag);
        }
        await deployments.link(
          Deployment(
            deploymentId: _uuid.v4(),
            projectId: projectId,
            tagId: tagId,
            individualId: individualId,
            attachedDate: defaults.attachedDate,
            sync: sync,
            timeZone: defaults.timeZone,
          ),
        );
      }
    });
    // One announcement for the batch (task 11.45's reason).
    DataArrival.announce();
    return preview.rows.length;
  }
}

/// Reads rows pasted from a spreadsheet, or a CSV file.
///
/// Tabs (what a spreadsheet puts on the clipboard) or commas. A first line
/// naming its columns is read as a header — `name`, `frequency`, and
/// optionally `species`, `tag` and `pulse_rate`, in any order and common
/// spellings. Without one, the first two columns are the name and the
/// frequency, whichever way round they are.
abstract final class QuickAddPaste {
  static const _aliases = <String, List<String>>{
    'name': ['name', 'animal', 'animal_name', 'individual', 'animal_id'],
    'frequency': ['frequency', 'freq', 'frequency_mhz', 'freq_mhz', 'mhz'],
    'species': ['species'],
    'tag': ['tag', 'tag_name', 'tag_id', 'tagname', 'collar', 'collar_id'],
    'pulse_rate': ['pulse_rate', 'ppm', 'bpm', 'pulse_rate_bpm', 'rate'],
  };

  static String _normalize(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  static List<QuickAddRow> parse(String text) {
    var body = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (body.isNotEmpty && body.codeUnitAt(0) == 0xFEFF) {
      body = body.substring(1);
    }
    final lines = body.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return const [];
    final delimiter = lines.any((l) => l.contains('\t')) ? '\t' : ',';
    final table = Csv(
      fieldDelimiter: delimiter,
      autoDetect: false,
    ).decode(lines.join('\n'));
    if (table.isEmpty) return const [];

    String cell(List<dynamic> r, int? i) =>
        i == null || i >= r.length ? '' : '${r[i]}'.trim();

    final header = [for (final c in table.first) _normalize('$c')];
    int? column(String field) {
      for (var i = 0; i < header.length; i++) {
        if (_aliases[field]!.contains(header[i])) return i;
      }
      return null;
    }

    final nameAt = column('name');
    final freqAt = column('frequency');
    if (nameAt != null || freqAt != null) {
      final speciesAt = column('species');
      final tagAt = column('tag');
      final rateAt = column('pulse_rate');
      return [
        for (final r in table.skip(1))
          QuickAddRow(
            name: cell(r, nameAt),
            frequency: cell(r, freqAt),
            species: _orNull(cell(r, speciesAt)),
            tagName: _orNull(cell(r, tagAt)),
            pulseRateBpm: double.tryParse(cell(r, rateAt)),
          ),
      ];
    }
    return [
      for (final r in table)
        if (double.tryParse(cell(r, 0)) != null &&
            double.tryParse(cell(r, 1)) == null)
          QuickAddRow(name: cell(r, 1), frequency: cell(r, 0))
        else
          QuickAddRow(name: cell(r, 0), frequency: cell(r, 1)),
    ];
  }

  static String? _orNull(String s) => s.isEmpty ? null : s;
}
