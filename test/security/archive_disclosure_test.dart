import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';

/// Task 11.30: **an export must not carry personal data the app never shows.**
///
/// Exporting is not gated by role, and the security model is right that it
/// cannot be — a member who can read the data can copy it. So the question this
/// file asks is not *who* may export but *how wide* the export is, and the
/// answer has to be a property of the code rather than a sentence in a
/// document.
///
/// The known instance was `User_Emails`: every prior address every named person
/// on the project had ever used, swept into the `.zip` because it was reachable
/// from a user row. Nothing renders it. Somebody who forwarded a project file to
/// a colleague forwarded their team's old email addresses with it.
///
/// **Why the assertions read the real bytes rather than the declaration.** A
/// test that only checked `archiveDisclosure` would pass just as happily if
/// `ProjectExporter` ignored the field entirely, which is the exact defect it
/// exists to catch. So the last two tests build an archive from a database that
/// really does hold prior addresses, and search the encoded payload for them.
void main() {
  test('every synced table has decided whether it may leave the device', () {
    // The declaration is `required`, so this cannot fail by omission — it
    // fails if the set of tables and the set of decisions ever come apart,
    // and it is what makes the count below meaningful.
    expect(
      syncTables.map((t) => t.name).toSet().length,
      syncTables.length,
      reason: 'A duplicate table name would make this file measure less than '
          'it appears to.',
    );
    for (final table in syncTables) {
      expect(
        ArchiveDisclosure.values,
        contains(table.archiveDisclosure),
        reason: '${table.name} must declare whether it travels in an archive.',
      );
    }
  });

  test('User_Emails is the withheld table, and it is the only one', () {
    // Pinned deliberately. Widening the archive is a decision somebody should
    // have to make on purpose, and narrowing it further is one this test should
    // make them come back and re-read the reasoning for.
    final withheld = [
      for (final t in syncTables)
        if (t.archiveDisclosure == ArchiveDisclosure.withheld) t.name,
    ];
    expect(withheld, [Tables.userEmails]);
  });

  test('a real archive carries no prior email address', () async {
    const priorAddress = 'sam.ranger.1998@oldschool.example';

    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);

    await db.raw.insert(
      Tables.users,
      sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
    );
    // The address history the merge keeps and no screen displays.
    await db.raw.insert(
      Tables.userEmails,
      sampleUserEmail(
        id: 'user-email-1',
        userId: 'user-1',
        email: priorAddress,
      ).toColumns(),
    );
    await db.raw.insert(
      Tables.projects,
      sampleProject(id: 'proj-1', ownerUserId: 'user-1').toColumns(),
    );

    final backup = await ProjectExporter.collect(
      db.raw,
      'proj-1',
      now: DateTime.utc(2026, 8, 29),
    );

    // The exporter must not have read the table at all...
    expect(backup.rowsFor(Tables.userEmails), isEmpty);

    // ...and the bytes a person actually emails must not contain the address
    // anywhere, under any key, in any table. This is the assertion that would
    // still fail if some future path smuggled the value into another column.
    final bytes = BackupArchive.encode(backup);
    final archive = ZipDecoder().decodeBytes(bytes);
    final data = utf8.decode(archive.findFile(kDataEntry)!.content as List<int>);
    expect(data, isNot(contains(priorAddress)));
    expect(jsonDecode(data) as Map<String, Object?>,
        isNot(contains(Tables.userEmails)));

    // The current address is a different matter and is *supposed* to travel:
    // it is shown in the app, and the merge anchors identity on it.
    expect(data, contains('sam@example.com'));
  });

  test('encode refuses a withheld table even when handed one directly',
      () async {
    // `ProjectExporter` is where the decision is made; `BackupArchive.encode`
    // is the last thing that runs before bytes exist. A caller that assembles
    // a `ProjectBackup` some other way — a fixture, a future import/re-export
    // path — must not be able to widen the archive by accident.
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    await db.raw.insert(Tables.users, sampleUser(id: 'user-1').toColumns());
    await db.raw.insert(
      Tables.projects,
      sampleProject(id: 'proj-1', ownerUserId: 'user-1').toColumns(),
    );
    final backup = await ProjectExporter.collect(
      db.raw,
      'proj-1',
      now: DateTime.utc(2026, 8, 29),
    );

    backup.tables[Tables.userEmails] = [
      sampleUserEmail(email: 'smuggled@example.com').toColumns(),
    ];

    final bytes = BackupArchive.encode(backup);
    final archive = ZipDecoder().decodeBytes(bytes);
    final data = utf8.decode(archive.findFile(kDataEntry)!.content as List<int>);
    expect(data, isNot(contains('smuggled@example.com')));
  });
}
