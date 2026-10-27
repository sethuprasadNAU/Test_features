import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/active_selection_provider.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/errors/failure_message.dart';
import '../../../core/providers/database_provider.dart';
import '../../../core/theme/design_tokens.dart';
import '../../../core/text/role_labels.dart';
import '../../../data/csv/actual_tag_location_csv.dart';
import '../../../data/csv/csv_export_archive.dart';
import '../../../data/csv/non_detection_csv.dart';
import '../../../data/csv/observation_csv.dart';
import '../../../data/csv/position_estimate_csv.dart';
import '../../../data/csv/deployment_csv.dart';
import '../../../data/csv/schema_table_csv.dart';
import '../../../data/models/project.dart';
import '../../../data/models/tag.dart';
import '../../../data/models/user.dart';
import '../../../data/repositories/repository_providers.dart';
import '../../../data/repositories/project_standing.dart';
import '../../../data/sync/backup_archive.dart';
import '../../../data/sync/consent_summary.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/sync/merge_report.dart';
import '../../../data/sync/project_exporter.dart';
import '../../../data/sync/project_merger.dart';
import '../../../widgets/load_failure.dart';

/// Data Export / Backup (design doc §11): export the full project as a
/// shareable `.zip` archive, export a filterable observation CSV, and import
/// a backup with defined merge behavior — warning on schema/version
/// differences and corrupt archives without ever touching the existing
/// project on failure (see [BackupArchive.decode] / [ProjectMerger]).
class DataExportScreen extends ConsumerWidget {
  const DataExportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectAsync = ref.watch(currentProjectProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Data Export / Backup')),
      body: projectAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => LoadFailure('this project', error: e),
        data: (project) => _Body(project: project),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.project});
  final Project? project;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  String? _csvTagId;
  DateTimeRange? _csvDateRange;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return ListView(
      padding: const EdgeInsets.all(DesignTokens.spacingScreenHorizontal),
      children: [
        const _SectionLabel('PROJECT BACKUP'),
        const SizedBox(height: 8),
        const Text(
          'A full project backup (.zip, ~100–250KB) can be shared via WhatsApp, '
          'email, or cloud storage and restored on any device.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: project == null || _busy ? null : () => _exportBackup(context, project),
          child: const Text('Export project backup (.zip)'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy ? null : () => _importBackup(context),
          child: const Text('Import backup'),
        ),
        // The security model's original verdict on this path deferred it as
        // "a deliberate whole-project act on a file the user chose" — three
        // lines above the copy that tells the user to send these files over
        // WhatsApp. Choosing a file says where the bytes came from, not who
        // wrote them, and the person who most plausibly hands you an edited
        // one is a colleague who legitimately has your project's backup. The
        // enforcement is in ProjectMerger; this is the part the user needs
        // said out loud, on the button that reaches it.
        const SizedBox(height: 4),
        const Text(
          'A backup can add to and correct this project. If it would replace '
          'anything, you see exactly what first.',
          style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
        ),
        const SizedBox(height: 24),
        const _SectionLabel('CSV EXPORT'),
        const SizedBox(height: 8),
        if (project == null)
          const Text('Set up a project first.')
        else ...[
          _CsvFilterRow(
            projectId: project.projectId,
            tagId: _csvTagId,
            dateRange: _csvDateRange,
            onTagChanged: (id) => setState(() => _csvTagId = id),
            onDateRangeChanged: (range) => setState(() => _csvDateRange = range),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => _exportCsv(context, project),
            child: const Text('Export CSV'),
          ),
        ],
      ],
    );
  }

  Future<void> _exportBackup(BuildContext context, Project project) async {
    setState(() => _busy = true);
    try {
      final db = await ref.read(appDatabaseProvider.future);
      final backup = await ProjectExporter.collect(db.raw, project.projectId, now: DateTime.now());
      final bytes = BackupArchive.encode(backup);
      final dateStamp = DateTime.now().toIso8601String().substring(0, 10);
      final safeName = project.projectName.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
      final path = await FilePicker.saveFile(
        fileName: '${safeName}_backup_$dateStamp.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      if (context.mounted && path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Backup saved (${(bytes.length / 1024).toStringAsFixed(0)} KB)')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(describeFailure(
            e,
            fallback:
                'Could not finish saving the backup; the project is '
                'unchanged. Delete any half-written .zip left where you saved '
                'it. Try again — in this device\'s own storage, not a memory '
                'card or cloud folder, if it keeps failing.',
          )),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importBackup(BuildContext context) async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    final path = result?.files.single.path;
    if (path == null) return;

    setState(() => _busy = true);
    ProjectBackup backup;
    try {
      final bytes = await File(path).readAsBytes();
      backup = BackupArchive.decode(Uint8List.fromList(bytes));
    } on BackupFormatException catch (e) {
      if (context.mounted) await _showError(context, 'Invalid backup', e.message);
      setState(() => _busy = false);
      return;
    } catch (e) {
      if (context.mounted) {
        await _showError(
          context,
          'Could not read backup',
          describeFailure(
            e,
            fallback:
                'That file could not be read, so nothing was imported. Check '
                'it is the .zip the app saved, not unzipped or renamed, then '
                'try again.',
          ),
        );
      }
      setState(() => _busy = false);
      return;
    }

    if (!context.mounted) {
      setState(() => _busy = false);
      return;
    }

    final strategy = await _pickMergeStrategy(context, backup);
    if (strategy == null) {
      setState(() => _busy = false);
      return;
    }

    try {
      final db = await ref.read(appDatabaseProvider.future);
      final importingUser = await ref.read(currentUserProvider.future);
      final merger = ProjectMerger(db.raw);

      // §4.19 rule 4, two-phase. The first call is allowed to write only if it
      // destroys nothing; anything else comes back as a plan with the
      // field-by-field list and an untouched database. The user sees exactly
      // what would be destroyed before it is, which is the whole of the
      // guarantee an unauthenticated archive can offer.
      var report = await merger.merge(
        backup,
        strategy: strategy,
        importingUserId: importingUser.userId,
      );
      // §4.19 clause 6 (task 11.20). Reported before the merge report, and as
      // an error rather than a result, because nothing happened and nothing
      // *will* happen — unlike the consent gate below, re-running with consent
      // changes nothing. Naming the rung the user actually holds rather than
      // assuming `viewer` is the same courtesy the share screen pays, and for
      // the same reason: "you may not do this" without saying why is a bug
      // report waiting to be filed.
      if (report.outcome == MergeOutcome.refusedNotPermitted) {
        if (context.mounted) {
          await _showError(
            context,
            'You cannot restore into this project',
            'This backup is for "${backup.manifest.projectName}", and your '
            'role there is '
            // Written label, not the stored column value (task 11.99) — see
            // `lib/core/text/role_labels.dart`.
            '${report.receiverRole?.inSentence ?? 'not one that can make changes'} — '
            'you can read that project but not change it, so nothing was '
            'imported.\n\nIf that is wrong, ask an owner to make you a '
            'contributor, then try again.',
          );
        }
        return;
      }
      if (report.outcome == MergeOutcome.needsConfirmation) {
        if (!context.mounted) return;
        final accepted = await _confirmDestructiveChanges(context, report);
        if (accepted != true) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Import canceled — nothing was changed.'),
            ));
          }
          return;
        }
        report = await merger.merge(
          backup,
          strategy: strategy,
          importingUserId: importingUser.userId,
          confirmChanges: true,
        );
      }
      if (context.mounted) {
        await _showMergeReport(context, backup, report);
      }
      ref.invalidate(currentProjectProvider);
      // A restore writes a whole project's observations that no screen asked
      // for; the merger that writes them announces it. See `DataArrival`
      // (task 11.45).
    } on BackupFormatException catch (e) {
      // Task 11.239: the merger refuses a file that says one collar is two
      // tag records in its own project (see `forkedTagArchiveRefusal`). It
      // throws before any row is written, so the generic fallback below —
      // which honestly allows that some records may already have landed —
      // would be less true than the sentence the merger authored.
      if (context.mounted) {
        await _showError(context, 'Invalid backup', e.message);
      }
    } on SchemaTooNewException catch (e) {
      if (context.mounted) {
        await _showError(
          context,
          'Backup too new',
          // A written sentence rather than the exception's own `toString()`,
          // which opens with the class name. The two version numbers are the
          // only facts on it worth a person's time, and only because they
          // make it obvious which device is behind.
          'This backup was made by a newer version of TriTrack (data format '
          '${e.backupVersion}; this app reads up to ${e.appVersion}), so '
          'nothing was imported. Update TriTrack, then import it again.',
        );
      }
    } catch (e) {
      if (context.mounted) {
        await _showError(
          context,
          'Import failed',
          describeFailure(
            e,
            fallback:
                // **Deliberately not "nothing was changed".** Each call to
                // the merger is one transaction, but §4.19's consent rule
                // makes this a *two*-phase import: the first call is allowed
                // to write whatever destroys nothing, and only the destructive
                // remainder waits for the dialog. So a failure in the second
                // phase leaves the first phase's additions committed, and
                // promising an untouched project would be copy describing a
                // mechanism this code does not have — the defect task 11.54
                // exists to catch.
                'The import stopped partway, so some records may already '
                'have been added (none half-written). Importing the same file '
                'again is safe — it skips what already arrived. If it keeps '
                'stopping, the backup may be damaged: try an earlier one, and '
                'report this.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<MergeStrategy?> _pickMergeStrategy(BuildContext context, ProjectBackup backup) async {
    final m = backup.manifest;
    return showDialog<MergeStrategy>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import backup'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Project: ${m.projectName}'),
            Text('Created: ${m.createdAtUtc.toLocal().toString().substring(0, 16)}'),
            Text('Schema version: ${m.schemaVersion}'),
            Text('Rows: ${m.totalRows}'),
            const SizedBox(height: 12),
            const Text('How should conflicts with existing data be resolved?'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.of(context).pop(MergeStrategy.lastWriteWins),
            child: const Text('Merge (last-write-wins)'),
          ),
          // Kept, and the gate's fact (a) is why it is not the fix: the full
          // K-1 damage profile lands under `lastWriteWins` on the strength of
          // an unbounded `revision` alone, so removing this button would have
          // changed nothing at all. What makes it safe is the same thing that
          // makes the default safe — the clock bound, the authorship rules and
          // the consent gate, all of which this strategy also passes through.
          FilledButton(
            onPressed: () => Navigator.of(context).pop(MergeStrategy.preferIncoming),
            child: const Text('Overwrite with backup'),
          ),
        ],
      ),
    );
  }

  /// §4.19 rule 4's dialog: what this file would destroy, before it destroys
  /// any of it — summarised per table by [ConsentSummary] (task 10.87), which
  /// is where the reasoning about size and about finding L-5 lives.
  ///
  /// Deliberately not a bare count. Finding K-1's reproduction was reported as
  /// *"Inserted: 1, Updated: 3"* — a summary that was accurate and told the
  /// user nothing about an observation moved to (0,0). The per-table lines say
  /// which kind of record, how many, which columns, and how many are removed
  /// outright; what they no longer do is list a thousand of them.
  Future<bool?> _confirmDestructiveChanges(BuildContext context, MergeReport report) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('This backup would replace data you already have'),
        content: ConsentSummaryContent(report: report),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep my data'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace it'),
          ),
        ],
      ),
    );
  }

  /// "a", "a and b", "a, b and c" — the export receipt names every file it
  /// wrote, so a person who expected a truth-point file and does not see it
  /// mentioned knows there were none rather than assuming it failed.
  /// "1 truth point" / "2 truth points". Task 11.100: the receipt's plural
  /// was unconditional, so every single-record export contradicted its own
  /// count. All three nouns here take a plain "s".
  static String _countLabel(int count, String singular) =>
      '$count ${count == 1 ? singular : '${singular}s'}';

  static String _joinWithAnd(List<String> parts) => switch (parts.length) {
    0 => 'nothing',
    1 => parts.first,
    _ => '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}',
  };

  Future<void> _showMergeReport(BuildContext context, ProjectBackup backup, MergeReport report) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import complete'),
        content: ImportReportContent(report: report),
        actions: [
          if (ref.read(activeProjectIdProvider).value != backup.manifest.projectId)
            TextButton(
              onPressed: () async {
                await ref.read(activeProjectIdProvider.notifier).set(backup.manifest.projectId);
                ref.invalidate(currentProjectProvider);
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Switch to this project'),
            ),
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _showError(BuildContext context, String title, String message) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }


  Future<void> _exportCsv(BuildContext context, Project project) async {
    setState(() => _busy = true);
    try {
      final obsRepo = await ref.read(observationRepositoryProvider.future);
      final tagRepo = await ref.read(tagRepositoryProvider.future);
      final userRepo = await ref.read(userRepositoryProvider.future);

      var observations = await obsRepo.findByProject(project.projectId);
      if (_csvTagId != null) {
        observations = observations.where((o) => o.tagId == _csvTagId).toList();
      }
      if (_csvDateRange != null) {
        final range = _csvDateRange!;
        observations = observations.where((o) {
          final day = DateTime(o.timestampLocal.year, o.timestampLocal.month, o.timestampLocal.day);
          return !day.isBefore(range.start) && !day.isAfter(range.end);
        }).toList();
      }

      final userIds = observations.map((o) => o.userId).toSet();
      // **One read of the project's tags, indexed by id** — task 11.219. A
      // tag belongs to this project now, so the three loops that used to
      // look each referenced id up one at a time (bearings, non-detections,
      // truth points) all read from this. Deleted ones included: a removed
      // tag still names the collar an earlier bearing was taken against.
      final tagsById = {
        for (final tag in await tagRepo.findByProject(
          project.projectId,
          includeDeleted: true,
        ))
          tag.tagId: tag,
      };
      final usersById = <String, User>{};
      for (final id in userIds) {
        final u = await userRepo.findById(id, includeDeleted: true);
        if (u != null) usersById[id] = u;
      }

      // Task 11.32: the tag values each bearing was actually recorded against,
      // so a spreadsheet made today and one made after a rename agree about
      // the same row.
      final tagVersionRepo = await ref.read(
        tagVersionRepositoryProvider.future,
      );
      final recordedStates = await tagVersionRepo.recordedStatesFor(
        observations,
        tagsById: tagsById,
      );

      final csvText = ObservationCsv.export(
        observations,
        tagsById: tagsById,
        usersById: usersById,
        recordedStates: recordedStates,
      );
      final dateStamp = DateTime.now().toIso8601String().substring(0, 10);
      // Task 11.241: **one file, one save dialog.** Until this the export
      // opened a save dialog per CSV — three, then five once task 11.240
      // added the collars and the animals — and a person exporting weekly
      // answered "where?" five times for one export. The files are collected
      // here and written as one `.zip` at the end; nothing about any file's
      // columns changed.
      final files = <String, String>{'observations.csv': csvText};

      final ndRepo = await ref.read(nonDetectionRepositoryProvider.future);
      var nonDetections = await ndRepo.findByProject(project.projectId);
      if (_csvTagId != null) {
        nonDetections =
            nonDetections.where((n) => n.tagIdsListenedFor.contains(_csvTagId)).toList();
      }
      if (_csvDateRange != null) {
        final range = _csvDateRange!;
        nonDetections = nonDetections.where((n) {
          final day = DateTime(n.timestampLocal.year, n.timestampLocal.month, n.timestampLocal.day);
          return !day.isBefore(range.start) && !day.isAfter(range.end);
        }).toList();
      }
      if (nonDetections.isNotEmpty) {
        final ndUserIds = nonDetections.map((n) => n.userId).toSet();
        for (final id in ndUserIds.difference(usersById.keys.toSet())) {
          final u = await userRepo.findById(id, includeDeleted: true);
          if (u != null) usersById[id] = u;
        }

        final ndCsvText = NonDetectionCsv.export(
          nonDetections,
          tagsById: tagsById,
          usersById: usersById,
        );
        files['non_detections.csv'] = ndCsvText;
      }

      // Task 11.92: the truth points — where somebody physically found the
      // animal or the collar. Their own file, not extra rows in
      // `observations.csv`: they are the yardstick the estimates are measured
      // against, and one table holding both invites scoring a bearing against
      // itself. Before this they could leave the device only inside a full
      // backup.
      final truthRepo = await ref.read(actualTagLocationRepositoryProvider.future);
      var truthPoints = await truthRepo.findByProject(project.projectId);
      if (_csvTagId != null) {
        truthPoints = truthPoints.where((t) => t.tagId == _csvTagId).toList();
      }
      if (_csvDateRange != null) {
        final range = _csvDateRange!;
        truthPoints = truthPoints.where((t) {
          final day = DateTime(t.timestampLocal.year, t.timestampLocal.month, t.timestampLocal.day);
          return !day.isBefore(range.start) && !day.isAfter(range.end);
        }).toList();
      }
      if (truthPoints.isNotEmpty) {
        // Task 11.32's rule, applied to a truth point: what the collar was
        // called when somebody stood in front of it, alongside what it is
        // called today. A rename must not silently rewrite last month's export.
        final truthRecordedStates = await tagVersionRepo.recordedStatesForRows(
          [
            for (final t in truthPoints)
              (rowId: t.locationId, tagId: t.tagId, tagVersionId: t.tagVersionId),
          ],
          tagsById: tagsById,
        );
        // Task 11.93: the finders, so the export names a person rather than a
        // uuid. Resolved on top of the observers already loaded above — a
        // truth point can name somebody who took no bearing in this project.
        for (final id in truthPoints
            .map((t) => t.userId)
            .whereType<String>()
            .toSet()
            .difference(usersById.keys.toSet())) {
          final u = await userRepo.findById(id, includeDeleted: true);
          if (u != null) usersById[id] = u;
        }
        final truthCsvText = ActualTagLocationCsv.export(
          truthPoints,
          usersById: usersById,
          tagsById: tagsById,
          recordedStates: truthRecordedStates,
        );
        files['truth_points.csv'] = truthCsvText;
      }

      // Task 11.240: the collars and the animals wearing them, as two lookup
      // tables the files above join to. Columns derived from the schema —
      // see `SchemaTableCsv` for why, and for what `lineage_id` is for. The
      // tag filter narrows both: the one collar, and the animal it names.
      // Removed collars are included, as `tagsById` includes them, because a
      // bearing taken against one still names it.
      final individualRepo = await ref.read(individualRepositoryProvider.future);
      final deploymentRepo = await ref.read(
        deploymentRepositoryProvider.future,
      );
      var exportedTags = tagsById.values.toList();
      var individuals = await individualRepo.findByProject(
        project.projectId,
        includeDeleted: true,
      );
      // **The dated links, exported as a table of their own** (task 11.243).
      // Without them the tag and animal files are two lists with nothing
      // joining them, and the join is the thing an analysis needs: it is what
      // says which animal a bearing was about.
      var deployments = await deploymentRepo.findByProject(
        project.projectId,
        includeDeleted: true,
      );
      // Before the tag filter narrows them: an estimate names its animal by
      // every deployment and every animal, as the Log does.
      final allDeployments = deployments;
      final individualsById = {for (final i in individuals) i.individualId: i};
      if (_csvTagId != null) {
        exportedTags = exportedTags.where((t) => t.tagId == _csvTagId).toList();
        deployments = deployments
            .where((d) => d.tagId == _csvTagId)
            .toList();
        // Every animal that has *ever* worn the collar, not only the one
        // wearing it now — the same reason the Log and Map filters read all
        // the deployments.
        final worn = deployments.map((d) => d.individualId).toSet();
        individuals = individuals
            .where((i) => worn.contains(i.individualId))
            .toList();
      }
      files['tags.csv'] = SchemaTableCsv.export(
        Tables.tags,
        [for (final t in exportedTags) t.toColumns()],
        omit: SchemaTableCsv.retiredTagColumns,
      );
      files['individuals.csv'] = SchemaTableCsv.export(
        Tables.individuals,
        [for (final i in individuals) i.toColumns()],
      );
      files['deployments.csv'] = deploymentsCsv(deployments);

      // Task 11.323: the saved position estimates, one row each. Until this
      // they left the device only inside a full backup. Filtered like the
      // truth points; the bearings each one names are looked up across the
      // whole project, because an estimate's bearings can fall outside a
      // date filter that its own day is inside.
      final estimateRepo = await ref.read(
        estimatedPositionRepositoryProvider.future,
      );
      var estimates = await estimateRepo.findByProject(project.projectId);
      if (_csvTagId != null) {
        estimates = estimates.where((e) => e.tagId == _csvTagId).toList();
      }
      if (_csvDateRange != null) {
        final range = _csvDateRange!;
        estimates = estimates.where((e) {
          final day = DateTime(e.timestampLocal.year, e.timestampLocal.month, e.timestampLocal.day);
          return !day.isBefore(range.start) && !day.isAfter(range.end);
        }).toList();
      }
      if (estimates.isNotEmpty) {
        for (final id in estimates
            .map((e) => e.sync.lastModifiedBy)
            .whereType<String>()
            .toSet()
            .difference(usersById.keys.toSet())) {
          final u = await userRepo.findById(id, includeDeleted: true);
          if (u != null) usersById[id] = u;
        }
        files['position_estimates.csv'] = PositionEstimateCsv.export(
          estimates,
          tagsById: tagsById,
          usersById: usersById,
          individualsById: individualsById,
          deployments: allDeployments,
          observationsById: {
            for (final o in await obsRepo.findByProject(project.projectId))
              o.observationId: o,
          },
        );
      }

      final safeName = project.projectName.replaceAll(
        RegExp(r'[^A-Za-z0-9_-]+'),
        '_',
      );
      final path = await FilePicker.saveFile(
        fileName: '${safeName}_csv_$dateStamp.zip',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: CsvExportArchive.encode(files),
      );

      if (context.mounted && path != null) {
        // Task 11.100: the plural was unconditional on all three, so a
        // one-record export read "1 truth points". A receipt is the only
        // confirmation the person gets that the file holds what they think
        // it does, so it has to agree with its own numbers.
        final parts = <String>[
          _countLabel(observations.length, 'observation'),
          if (nonDetections.isNotEmpty)
            _countLabel(nonDetections.length, 'non-detection'),
          if (truthPoints.isNotEmpty)
            _countLabel(truthPoints.length, 'truth point'),
          if (estimates.isNotEmpty)
            _countLabel(estimates.length, 'position estimate'),
          _countLabel(exportedTags.length, 'tag'),
          _countLabel(individuals.length, 'animal'),
        ];
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported ${_joinWithAnd(parts)}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(describeFailure(
            e,
            fallback:
                'Could not finish the CSV export; your records are '
                'unchanged. Any file left where you saved it may be missing '
                'rows, so do not use it. Try again, with a narrower date range '
                'if it keeps failing.',
          )),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// The body of the "Import complete" receipt.
///
/// A widget rather than a private builder so the property finding **L-2**
/// turned on can be tested without a file picker: the counts *and* the name of
/// every record the import did not apply.
///
/// §14.3's transcript is what a count alone reads like. The screen rendered
/// `Refused …: 1` and never rendered `report.issues`, so an irreplaceable field
/// record dropped from a disaster recovery got a number and no name — and a
/// number of that shape reads like a formatting complaint about a file that
/// was well-formed throughout. Task 10.28's rule is that a refused row must not
/// vanish quietly; **a count the user cannot trace back to a record is quiet.**
/// The body of §4.19 rule 4's consent dialog — task 10.87's per-table shape.
///
/// Public so a test can pump it at 1,000 rows and count what a person is
/// actually asked to read. See [ConsentSummary] for why a line per table and
/// not a line per change.
///
/// **Two framings, decided by which of task 11.237's cases the import is.**
/// When the project is already on this device, this is an ordinary merge and
/// the lines are about its records. When it is *not* — [ImportCase.adopt] or
/// [ImportCase.snapshot] — none of the project's own records exist here to be
/// overwritten, and the gate can only have fired for the two tables the
/// schema keeps global, `Users` and `User_Emails`: a file that renames a
/// person this device already knows. **Measured, not assumed** (task 10.87
/// watched an adopt import reach `needsConfirmation` on `Users.last_name`),
/// which is why the not-here case still has a dialog rather than none.
class ConsentSummaryContent extends StatelessWidget {
  const ConsentSummaryContent({super.key, required this.report});

  final MergeReport report;

  static String _plural(int n, String one, String many) =>
      '$n ${n == 1 ? one : many}';

  @override
  Widget build(BuildContext context) {
    final destructive = report.destructiveChanges;
    final tables = ConsentSummary.of(destructive);
    final records = tables.fold(0, (a, t) => a + t.records);
    final removed = tables.fold(0, (a, t) => a + t.removed);
    final projectHere = switch (report.importCase) {
      ImportCase.adopt || ImportCase.snapshot => false,
      ImportCase.merge || ImportCase.mergeIntoSnapshot || null => true,
    };

    final headline = projectHere
        ? '${_plural(destructive.length, 'value', 'values')} in '
            '${_plural(records, 'record', 'records')} this device already '
            'holds would be replaced or removed. Nothing has been changed yet.'
        : 'This project is not on this device yet, so none of its records '
            'can be overwritten. But the file would change '
            '${_plural(destructive.length, 'detail', 'details')} this device '
            'already holds about ${_plural(records, 'person', 'people')} — '
            'their name or email address. Nothing has been changed yet.';

    return SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            removed > 0
                ? '${_plural(removed, 'record', 'records')} would be removed '
                    'from every screen. Your previous versions are kept under '
                    'Sync Status → Overwritten edits.'
                : 'Your previous versions are kept under Sync Status → '
                    'Overwritten edits.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          // One line per table and never more — see ConsentSummary.tableOrder.
          // A Column rather than a ListView because the length is bounded by
          // the schema, not the file, and the whole of it must be on screen.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final t in tables)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${t.label} · '
                            '${_plural(t.records, 'record', 'records')}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${_plural(t.values, 'value', 'values')} replaced'
                            '${t.removed > 0 ? ' · ${_plural(t.removed, 'record', 'records')} removed' : ''}',
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            t.columns
                                .map((c) => c.replaceAll('_', ' '))
                                .join(', '),
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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
}

class ImportReportContent extends StatelessWidget {
  const ImportReportContent({super.key, required this.report});

  final MergeReport report;

  /// How many refusals are listed by name before the rest are summarised. The
  /// cap is stated rather than silently truncating, for the same reason the
  /// consent dialog's is.
  static const int shownIssues = 20;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      'Inserted: ${report.totalInserted}',
      'Updated: ${report.totalUpdated}',
      'Unchanged (local was newer): ${report.totalSkipped}',
      if (report.destructiveChanges.isNotEmpty)
        'Values replaced, as you confirmed: ${report.destructiveChanges.length}',
      if (report.totalInvalid > 0) 'Rejected (invalid): ${report.totalInvalid}',
      // Never folded into "invalid". A refused row is a row the file was not
      // allowed to send — an out-of-range merge clock, or a row addressed at a
      // different project — and task 10.28's rule is that it must not vanish
      // quietly into a number that reads like a formatting complaint.
      if (report.totalRefused > 0)
        'Refused (out of range or another project): ${report.totalRefused}',
      if (report.usersDeduped > 0)
        'Users matched to local accounts: ${report.usersDeduped}',
      if (report.rowsReattributed > 0)
        'Records re-attributed to a local account by that match: '
            '${report.rowsReattributed}',
      if (report.usersMatchedViaPriorEmail > 0)
        'Matched via a previous email address: '
            '${report.usersMatchedViaPriorEmail}',
      // Task 11.239. A collar this project already held under another id:
      // the file's records for it now sit under this device's tag rather than
      // beside it, and that is a rewrite a person should be able to see.
      if (report.tagsMatchedByLineage > 0)
        'Tags matched to a tag this project already had: '
            '${report.tagsMatchedByLineage}',
      if (report.migratedSchema)
        'Migrated from schema v${report.schemaMigratedFrom} to '
            'v${report.currentSchemaVersion}',
    ];
    final issues = report.issues;

    // Task 11.237: an import by somebody who is not on the project is a
    // read-only snapshot, and the dialog says so once here — and the projects
    // list says so every day after, which is the copy that matters.
    final snapshot = report.importCase?.isSnapshot ?? false;

    return SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (snapshot) ...[
            const Text(
              snapshotProjectDescription,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(notAMemberWriteRefusal),
            const SizedBox(height: 12),
          ],
          for (final l in lines) Text(l),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Records this import did not apply:',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final issue in issues.take(shownIssues))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${issue.table} · ${issue.primaryKeyValue}\n'
                        '${issue.field}: ${issue.message}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (issues.length > shownIssues)
                    Text(
                      '…and ${issues.length - shownIssues} more not listed '
                      'here.',
                      style: const TextStyle(
                          fontSize: 12, fontStyle: FontStyle.italic),
                    ),
                ],
              ),
            ),
          ],
        ],
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

class _CsvFilterRow extends ConsumerWidget {
  const _CsvFilterRow({
    required this.projectId,
    required this.tagId,
    required this.dateRange,
    required this.onTagChanged,
    required this.onDateRangeChanged,
  });

  final String projectId;
  final String? tagId;
  final DateTimeRange? dateRange;
  final ValueChanged<String?> onTagChanged;
  final ValueChanged<DateTimeRange?> onDateRangeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(projectActiveTagsProvider(projectId));
    final tags = tagsAsync.value ?? const <Tag>[];
    final selectedTag = tags.where((t) => t.tagId == tagId).firstOrNull;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ActionChip(
          avatar: const Icon(Icons.podcasts, size: 16),
          label: Text(selectedTag == null ? 'Tag: All' : 'Tag: ${selectedTag.tagName}'),
          onPressed: () async {
            final selected = await showDialog<String?>(
              context: context,
              builder: (context) => SimpleDialog(
                title: const Text('Filter by tag'),
                children: [
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('All tags'),
                  ),
                  for (final tag in tags)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(tag.tagId),
                      child: Text('${tag.frequencyMhz.toStringAsFixed(3)} MHz · ${tag.tagName}'),
                    ),
                ],
              ),
            );
            onTagChanged(selected);
          },
        ),
        ActionChip(
          avatar: const Icon(Icons.date_range, size: 16),
          label: Text(dateRange == null
              ? 'Date: All'
              : 'Date: ${dateRange!.start.month}/${dateRange!.start.day}–'
                  '${dateRange!.end.month}/${dateRange!.end.day}'),
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(now.year - 10),
              lastDate: DateTime(now.year + 1),
              initialDateRange: dateRange,
            );
            if (picked != null) onDateRangeChanged(picked);
          },
        ),
        if (tagId != null || dateRange != null)
          ActionChip(
            avatar: const Icon(Icons.clear, size: 16),
            label: const Text('Clear'),
            onPressed: () {
              onTagChanged(null);
              onDateRangeChanged(null);
            },
          ),
      ],
    );
  }
}
