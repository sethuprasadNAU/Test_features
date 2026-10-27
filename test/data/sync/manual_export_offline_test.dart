import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// Task 10.19's acceptance criterion: "a manual export that always works,
/// even with sync broken and no cloud folder linked."
///
/// `DataExportScreen._exportBackup`/`_importBackup` call exactly the three
/// functions this test drives — `ProjectExporter.collect`, `BackupArchive.
/// encode`/`decode`, `ProjectMerger.merge` — and none of them read
/// `serverConfigProvider`, `CloudBackupSettings`, or any network/platform
/// channel. This proves that by never configuring either: no server URL is
/// set anywhere in this test, no `CloudFolderChannel` is touched, and the
/// round trip still completes and lands the data correctly on a second,
/// completely independent database.
void main() {
  test('collect → encode → decode → merge succeeds with no server '
      'configured and no cloud folder linked', () async {
    final source = await AppDatabase.openInMemory();
    addTearDown(source.close);

    await source.raw.insert(
      Tables.users,
      sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
    );
    await source.raw.insert(
      Tables.projects,
      sampleProject(id: 'proj-1', ownerUserId: 'user-1').toColumns(),
    );

    final backup = await ProjectExporter.collect(
      source.raw,
      'proj-1',
      now: DateTime.utc(2026, 8, 6),
    );
    final bytes = BackupArchive.encode(backup);
    expect(bytes, isNotEmpty);

    // A fresh, unrelated database — standing in for the device this file
    // gets handed to, which never talked to any server either.
    final destination = await AppDatabase.openInMemory();
    addTearDown(destination.close);

    final decoded = BackupArchive.decode(bytes);
    final report = await ProjectMerger(destination.raw).merge(decoded);

    expect(report.issues, isEmpty);
    final projectRows = await destination.raw.query(Tables.projects);
    expect(projectRows.single['project_id'], 'proj-1');
    final userRows = await destination.raw.query(Tables.users);
    expect(userRows.single['email'], 'sam@example.com');
  });
}
