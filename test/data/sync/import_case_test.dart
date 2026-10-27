import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/project_role_lookup.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

/// **Task 11.237 — an archive import is one of four cases, classified from
/// the archive's own membership rows before anything is written.**
///
/// | | The project is already on this device | It is not |
/// |---|---|---|
/// | **I am a member** | merge | adopt |
/// | **I am not** | mergeIntoSnapshot | snapshot |
///
/// The archive is the colleague's: `project-1` created by `user-colleague`,
/// whose owner row is the only membership row unless a test adds one. The
/// person importing is `user-me`. Each case is one test, and the last group
/// follows a snapshot all the way through: what the device holds afterwards is
/// read-only, offers nothing to the server, and turns live the moment a
/// membership row arrives.
void main() {
  late AppDatabase database;
  late Database db;

  const me = 'user-me';
  const colleague = 'user-colleague';
  final now = DateTime.utc(2026, 9, 13, 10);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    // The person using this device exists here, as they would after first-run
    // identity capture — so the archive's `user-me` row remaps onto them by
    // email rather than arriving as a stranger.
    await db.insert(
      Tables.users,
      sampleUser(id: me, email: 'me@example.com').toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// The colleague's archive. [meAsMember] adds an open contributor row for
  /// `user-me` — what the file carries if the colleague exported after
  /// admitting them.
  ProjectBackup archive({bool meAsMember = false}) => makeBackup({
    Tables.users: [
      sampleUser(id: colleague, email: 'colleague@example.com').toColumns(),
      sampleUser(id: me, email: 'me@example.com').toColumns(),
    ],
    Tables.projects: [
      sampleProject(id: 'project-1', ownerUserId: colleague).toColumns(),
    ],
    Tables.projectMemberships: [
      sampleMembership(id: 'm-colleague', userId: colleague).toColumns(),
      if (meAsMember)
        sampleMembership(
          id: 'm-me',
          userId: me,
          role: ProjectRole.contributor,
        ).toColumns(),
    ],
  }, schemaVersion: latestSchemaVersion);

  Future<MergeReport> import(ProjectBackup backup) =>
      ProjectMerger(db).merge(backup, importingUserId: me, now: now);

  /// The project already on this device, imported once before.
  Future<void> alreadyHere({bool meAsMember = false}) async {
    final first = await import(archive(meAsMember: meAsMember));
    expect(first.wrote, isTrue);
  }

  group('the four cases, from the archive\'s own rows', () {
    test('not here, not a member → snapshot', () async {
      final report = await import(archive());
      expect(report.importCase, ImportCase.snapshot);
      expect(report.importCase!.isSnapshot, isTrue);
      expect(report.wrote, isTrue, reason: 'allowed, not refused');
    });

    test('not here, a member → adopt', () async {
      final report = await import(archive(meAsMember: true));
      expect(report.importCase, ImportCase.adopt);
      expect(report.importCase!.isSnapshot, isFalse);
    });

    test('already here, a member → merge (task 10.87\'s case)', () async {
      await alreadyHere(meAsMember: true);
      final report = await import(archive(meAsMember: true));
      expect(report.importCase, ImportCase.merge);
    });

    test('already here as a snapshot, still not a member → mergeIntoSnapshot',
        () async {
      await alreadyHere();
      final report = await import(archive());
      expect(report.importCase, ImportCase.mergeIntoSnapshot);
      expect(report.importCase!.isSnapshot, isTrue);
    });

    test(
      'an archive older than my membership does not demote a live project — '
      'the device\'s own rows count too',
      () async {
        // Joined properly since the colleague exported: the device holds my
        // open row, the file does not.
        await alreadyHere();
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'm-me-live',
            userId: me,
            role: ProjectRole.contributor,
          ).toColumns(),
        );
        final report = await import(archive());
        expect(report.importCase, ImportCase.merge);
      },
    );

    test('a sync pull through the same merger is not classified', () async {
      final report = await ProjectMerger(db).merge(
        archive(),
        origin: MergeOrigin.authenticatedServer,
        importingUserId: me,
        now: now,
      );
      expect(report.importCase, isNull);
    });
  });

  group('what a snapshot is on the device afterwards', () {
    test('read-only: the standing says not a member, and the push offers '
        'nothing', () async {
      await import(archive());
      expect(
        await readProjectStanding(db, projectId: 'project-1', userId: me),
        ProjectStanding.notAMember,
      );
      expect(await SyncEngine.offersNothingFor(db, 'project-1', me), isTrue);
    });

    test('live the moment a membership row arrives, with no re-import',
        () async {
      await import(archive());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'm-me-approved',
          userId: me,
          role: ProjectRole.contributor,
        ).toColumns(),
      );
      expect(
        await readProjectStanding(db, projectId: 'project-1', userId: me),
        const ProjectStanding.member(ProjectRole.contributor),
      );
      expect(await SyncEngine.offersNothingFor(db, 'project-1', me), isFalse);
    });

    test('an adopted project is live from the start', () async {
      await import(archive(meAsMember: true));
      expect(
        await readProjectStanding(db, projectId: 'project-1', userId: me),
        const ProjectStanding.member(ProjectRole.contributor),
      );
    });
  });
}
