import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/csv/csv_export_archive.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/data_export_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.323 item 3 — the CSV export carries the saved position
/// estimates.** Until this they left the device only inside a full backup.
///
/// Driven through the real *Export CSV* button, with the platform's file
/// picker replaced by one that keeps the bytes it was handed, so what is
/// checked is the archive a person would actually save — not a function the
/// screen might stop calling.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('the CSV export has a position_estimates.csv, one row per saved '
      'estimate, with no ellipse written as none', (tester) async {
    final picker = _KeepingFilePicker();
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);

    final user = sampleUser();
    final project = sampleProject(ownerUserId: user.userId);
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => user),
        currentProjectProvider.overrideWith((ref) async => project),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, user.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(userId: user.userId, role: ProjectRole.owner)
            .toColumns(),
      );
      await db.insert(Tables.tags, sampleTag().toColumns());
      await db.insert(Tables.individuals, sampleIndividual().toColumns());
      await db.insert(Tables.deployments, sampleDeployment().toColumns());
      for (final (id, lon, bearing) in const [
        ('obs-1', -111.70, 45.0),
        ('obs-2', -111.50, 315.0),
        // Not quite through the crossing, so there is spread to measure.
        ('obs-3', -111.60, 5.0),
      ]) {
        await db.insert(
          Tables.observations,
          sampleObservation(
            id: id,
            sessionId: null,
            tagVersionId: null,
            latitude: 35.10,
            longitude: lon,
          ).copyWith(trueNorthBearing: bearing).toColumns(),
        );
      }
      // One estimate with an ellipse, from three bearings …
      await db.insert(
        Tables.estimatedPositions,
        sampleEstimatedPosition(id: 'est-ellipse').toColumns(),
      );
      // … and one with none, from two.
      await db.insert(
        Tables.estimatedPositions,
        sampleEstimatedPosition(id: 'est-none')
            .copyWith(
              semiMajorAxis: null,
              semiMinorAxis: null,
              rotationAngle: null,
              observationIdsUsed: const ['obs-1', 'obs-2'],
            )
            .toColumns(),
      );
      await container.read(activeProjectIdProvider.notifier).set(
        project.projectId,
      );
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const DataExportScreen(),
      tabIndex: 4,
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Export CSV'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Export CSV'));
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (picker.saved == null) {
        if (DateTime.now().isAfter(deadline)) fail('nothing was saved');
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });

    final files = CsvExportArchive.decode(picker.saved!);
    expect(files.keys, contains('position_estimates.csv'));

    final lines = files['position_estimates.csv']!
        .trim()
        .split(RegExp(r'\r?\n'));
    final header = lines.first.split(',');
    Map<String, String> row(String id) {
      final cells = lines.firstWhere((l) => l.startsWith('$id,')).split(',');
      return {for (var i = 0; i < header.length; i++) header[i]: cells[i]};
    }

    expect(lines, hasLength(3), reason: 'a header and one row per estimate');

    final withEllipse = row('est-ellipse');
    expect(withEllipse['ellipse_semi_major_m'], '120.0');
    expect(withEllipse['ellipse_semi_minor_m'], '60.0');
    expect(withEllipse['ellipse_orientation_deg'], '42.0');
    expect(withEllipse['ellipse_confidence'], '0.95');
    expect(withEllipse['bearing_count'], '3');
    expect(withEllipse['bearing_ids'], 'obs-1;obs-2;obs-3');
    expect(withEllipse['bearings_on_device'], '3');
    expect(withEllipse['animal'], 'Marie');
    expect(withEllipse['saved_by'], '${user.firstName} ${user.lastName}');
    expect(withEllipse['kappa_recomputed'], isNotEmpty);

    final none = row('est-none');
    for (final column in const [
      'ellipse_semi_major_m',
      'ellipse_semi_minor_m',
      'ellipse_orientation_deg',
      'ellipse_confidence',
    ]) {
      expect(none[column], isEmpty, reason: '$column for no ellipse');
    }
    expect(none['bearing_count'], '2');
    expect(
      none['kappa_recomputed'],
      isEmpty,
      reason: 'two bearings cannot measure their spread, so κ is not a number',
    );
    expect(none['cautions_recomputed'], contains('near_singular'));
  });
}

/// The platform file picker, replaced by one that keeps the bytes of the one
/// file it is asked to save and reports a path, as a person choosing a place
/// would.
class _KeepingFilePicker extends FilePickerPlatform {
  Uint8List? saved;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    required String fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    required Uint8List bytes,
    Function(FilePickerStatus)? onFileLoading,
    bool lockParentWindow = false,
  }) async {
    saved = bytes;
    return '/tmp/$fileName';
  }
}
