import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

void main() {
  late AppDatabase database;
  late Database db;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
  });
  tearDown(() async => database.close());

  Future<void> seed(String table, Map<String, Object?> columns) =>
      db.insert(table, columns);

  Future<Map<String, Object?>?> fetch(String table, String pkCol, String id) async {
    final rows = await db.query(table, where: '$pkCol = ?', whereArgs: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  // A minimal valid project graph in a backup: one user + one project.
  Map<String, List<Map<String, Object?>>> baseGraph() => {
        Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns()],
      };

  group('insert into an empty database', () {
    test('a whole export round-trips through archive into a fresh DB', () async {
      // Build a project in DB #1, export+encode, decode+merge into DB #2.
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());
      await seed(Tables.tags, sampleTag(id: 'tag-1', projectId: 'project-1').toColumns());
      await seed(Tables.observations,
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1').toColumns());

      final backup = await ProjectExporter.collect(db, 'project-1', now: DateTime.utc(2026, 7, 17));
      final bytes = BackupArchive.encode(backup);

      final other = await AppDatabase.openInMemory();
      addTearDown(other.close);
      final report = await ProjectMerger(other.raw).merge(BackupArchive.decode(bytes));

      expect(report.totalInserted, greaterThanOrEqualTo(4)); // user, project, tag, projecttag, obs
      expect(report.totalUpdated, 0);
      expect(report.totalInvalid, 0);
      final obs = await other.raw.query(Tables.observations);
      expect(obs.single['observation_id'], 'obs-1');
      final proj = await other.raw.query(Tables.projects);
      expect(proj.single['project_name'], 'Mesa Coyotes');
    });
  });

  group('last-write-wins on conflict', () {
    test('incoming with a higher revision overwrites the local row', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects,
          sampleProject(id: 'project-1', ownerUserId: 'user-1').copyWith(projectName: 'Old Name').toColumns());

      final incoming = sampleProject(id: 'project-1', ownerUserId: 'user-1').copyWith(
        projectName: 'New Name',
        sync: sampleSync().copyWith(revision: 5, updatedAt: DateTime.utc(2026, 7, 18)),
      );
      // `confirmChanges: true` because renaming the project replaces a value
      // this device already holds, and §4.19 rule 4 now holds that at the door
      // (task 10.73). The gate itself is covered in
      // `backup_restore_overwrite_test.dart`; this test is about which row wins
      // once consent exists.
      final report = await ProjectMerger(db).merge(
        makeBackup({
          Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
          Tables.projects: [incoming.toColumns()],
        }),
        confirmChanges: true,
      );

      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['project_name'], 'New Name');
      expect(report.statsFor(Tables.projects).updated, 1);
    });

    test('incoming with a lower revision is skipped (local wins)', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects,
          sampleProject(id: 'project-1', ownerUserId: 'user-1')
              .copyWith(projectName: 'Local Winner', sync: sampleSync().copyWith(revision: 9))
              .toColumns());

      final incoming = sampleProject(id: 'project-1', ownerUserId: 'user-1')
          .copyWith(projectName: 'Stale', sync: sampleSync().copyWith(revision: 2));
      final report = await ProjectMerger(db).merge(makeBackup({
        Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
        Tables.projects: [incoming.toColumns()],
      }));

      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['project_name'], 'Local Winner');
      expect(report.statsFor(Tables.projects).skipped, 1);
    });
  });

  group('tombstones never resurrect and never wrongly bury', () {
    test('a stale incoming tombstone does not delete a newer local live row', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());
      await seed(Tables.tags, sampleTag(id: 'tag-1').toColumns());
      await seed(Tables.observations,
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1')
              .copyWith(sync: sampleSync().copyWith(revision: 5))
              .toColumns());

      final staleDelete = sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1')
          .copyWith(sync: sampleSync().copyWith(revision: 3, deletedAt: DateTime.utc(2026, 7, 10)));
      await ProjectMerger(db).merge(makeBackup({
        ...baseGraph(),
        Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
        Tables.observations: [staleDelete.toColumns()],
      }));

      expect((await fetch(Tables.observations, 'observation_id', 'obs-1'))!['deleted_at'], isNull);
    });

    test('a newer incoming tombstone deletes the local live row', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());
      await seed(Tables.tags, sampleTag(id: 'tag-1').toColumns());
      await seed(Tables.observations,
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1')
              .copyWith(sync: sampleSync().copyWith(revision: 1))
              .toColumns());

      final newerDelete = sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1')
          .copyWith(sync: sampleSync().copyWith(revision: 4, deletedAt: DateTime.utc(2026, 7, 20)));
      // Consent, because a tombstone landing on a live row is destructive —
      // see [UntrustedImportRules.isDestructiveChange], which is the one place
      // that says so and the reason `was == null` does not read as "nothing
      // was there".
      await ProjectMerger(db).merge(
        makeBackup({
          ...baseGraph(),
          Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
          Tables.observations: [newerDelete.toColumns()],
        }),
        confirmChanges: true,
      );

      expect((await fetch(Tables.observations, 'observation_id', 'obs-1'))!['deleted_at'], isNotNull);
    });
  });

  group('cross-device user dedup by normalized email', () {
    test('incoming user is merged onto the local user and every FK is rewritten',
        () async {
      // Local device already knows this person as user-LOCAL.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'ranger@x.com').toColumns());

      // Incoming backup calls the same person user-REMOTE (different device id)
      // and every row references user-REMOTE.
      final incomingUser = sampleUser(id: 'user-REMOTE', email: 'Ranger@X.com'); // different case
      final backup = makeBackup({
        Tables.users: [incomingUser.toColumns()],
        Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
        Tables.observations: [
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-REMOTE', tagId: 'tag-1').toColumns(),
        ],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 1);
      // No duplicate user was created.
      expect((await db.query(Tables.users)).length, 1);
      expect(await fetch(Tables.users, 'user_id', 'user-REMOTE'), isNull);
      // FKs now point at the local id.
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-LOCAL');
      expect((await fetch(Tables.observations, 'observation_id', 'obs-1'))!['user_id'], 'user-LOCAL');
    });

    test('a genuinely new user (unseen email) is inserted with its own id', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      final backup = makeBackup({
        Tables.users: [
          sampleUser(id: 'user-1', email: 'a@x.com').toColumns(),
          sampleUser(id: 'user-2', email: 'b@x.com').toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns()],
      });
      final report = await ProjectMerger(db).merge(backup);
      expect(report.usersDeduped, 0);
      expect(await fetch(Tables.users, 'user_id', 'user-2'), isNotNull);
    });

    test(
      'a non-string user_id in the archive is refused, not a crash that '
      'kills the whole merge (task 10.78, finding K-11b)',
      () async {
        // `_buildUserRemap` reads `backup`'s rows directly, before
        // `RowValidator` runs in `_plan` — an unauthenticated archive with a
        // malformed identity column used to throw an uncaught `TypeError`
        // right there, so this one bad row took every other row in the
        // backup down with it. The fix skips the row for remap purposes
        // only; `RowValidator` still gets to rule on it.
        await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
        final malformedUser = {
          ...sampleUser(id: 'user-2', email: 'b@x.com').toColumns(),
          'user_id': 42, // not a String
        };
        final backup = makeBackup({
          Tables.users: [malformedUser],
          Tables.projects: [
            sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns(),
          ],
        });

        final report = await ProjectMerger(db).merge(backup);

        // No crash, and the malformed row is refused rather than admitted —
        // RowValidator's own type check on the primary key catches it, same
        // as any other write path would.
        expect(report.totalInvalid, greaterThanOrEqualTo(1));
        expect((await db.query(Tables.users)).length, 1);
        // The one genuinely well-formed row in the same backup is unaffected.
        expect(await fetch(Tables.projects, 'project_id', 'project-1'), isNotNull);
      },
    );
  });

  group('prior-email fallback matching (Phase 7)', () {
    test('two devices whose users share a current email dedupe as before (no regression)',
        () async {
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'ranger@x.com').toColumns());
      final report = await ProjectMerger(db).merge(makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'ranger@x.com').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      }));

      expect(report.usersDeduped, 1);
      expect(report.usersMatchedViaPriorEmail, 0);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-LOCAL');
    });

    test('incoming current email matches a local prior email and dedupes, reported distinctly',
        () async {
      // Local device (macOS) never changed its email.
      await seed(Tables.users, sampleUser(id: 'user-MAC', email: 'old@x.com').toColumns());

      // Incoming device (iPhone) changed its email; its own backup carries
      // the prior address it recorded when it did.
      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-IPHONE', email: 'new@x.com').toColumns()],
        Tables.userEmails: [
          sampleUserEmail(id: 'ue-1', userId: 'user-IPHONE', email: 'old@x.com').toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-IPHONE').toColumns()],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 1);
      expect(report.usersMatchedViaPriorEmail, 1);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-MAC');
    });

    test(
        "local device's own prior email matches an incoming user's current email and dedupes",
        () async {
      // Local device changed its email; its own User_Emails row records the
      // old one.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'new@x.com').toColumns());
      await seed(
          Tables.userEmails, sampleUserEmail(id: 'ue-1', userId: 'user-LOCAL', email: 'old@x.com').toColumns());

      // Incoming device never updated and still has the old address as its
      // *current* email.
      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'old@x.com').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 1);
      expect(report.usersMatchedViaPriorEmail, 1);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-LOCAL');
    });

    test('a current-email match is never overridden by a competing prior-email match',
        () async {
      // Two distinct local users. user-CURRENT shares the incoming user's
      // CURRENT email (must win); user-OTHER's prior email happens to match
      // the incoming user's own prior email history too — a decoy that must
      // be ignored once tier 1 already resolved the match.
      await seed(Tables.users, sampleUser(id: 'user-CURRENT', email: 'shared@x.com').toColumns());
      await seed(Tables.users, sampleUser(id: 'user-OTHER', email: 'other@x.com').toColumns());
      await seed(Tables.userEmails,
          sampleUserEmail(id: 'ue-other', userId: 'user-OTHER', email: 'decoy@x.com').toColumns());

      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'shared@x.com').toColumns()],
        Tables.userEmails: [
          sampleUserEmail(id: 'ue-remote', userId: 'user-REMOTE', email: 'decoy@x.com').toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 1);
      expect(report.usersMatchedViaPriorEmail, 0, reason: 'tier 1 must win outright, no fallback used');
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-CURRENT');
    });

    test('a prior-to-prior-only overlap does not merge', () async {
      // Local user recorded "shared@x.com" as a PRIOR email.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'new-local@x.com').toColumns());
      await seed(Tables.userEmails,
          sampleUserEmail(id: 'ue-local', userId: 'user-LOCAL', email: 'shared@x.com').toColumns());

      // Incoming user's CURRENT email is different, and "shared@x.com" only
      // appears as one of ITS prior emails too — prior-to-prior, never a
      // qualifying tier.
      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'new-remote@x.com').toColumns()],
        Tables.userEmails: [
          sampleUserEmail(id: 'ue-remote', userId: 'user-REMOTE', email: 'shared@x.com').toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 0);
      expect(report.usersMatchedViaPriorEmail, 0);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-REMOTE');
      expect(await fetch(Tables.users, 'user_id', 'user-REMOTE'), isNotNull);
    });

    test('an address recorded as a prior email by two distinct local users is ambiguous and does not auto-merge',
        () async {
      // A reassigned shared address: two different local users each once
      // used "lab@x.com".
      await seed(Tables.users, sampleUser(id: 'user-STUDENT-1', email: 'student1@x.com').toColumns());
      await seed(Tables.users, sampleUser(id: 'user-STUDENT-2', email: 'student2@x.com').toColumns());
      await seed(Tables.userEmails,
          sampleUserEmail(id: 'ue-1', userId: 'user-STUDENT-1', email: 'lab@x.com').toColumns());
      await seed(Tables.userEmails,
          sampleUserEmail(id: 'ue-2', userId: 'user-STUDENT-2', email: 'lab@x.com').toColumns());

      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'lab@x.com').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      });

      final report = await ProjectMerger(db).merge(backup);

      expect(report.usersDeduped, 0);
      expect(await fetch(Tables.users, 'user_id', 'user-REMOTE'), isNotNull,
          reason: 'ambiguous prior email must not silently merge into either student');
    });

    // **This test used to assert the opposite** — that prior addresses
    // round-trip through export/import — and task 11.30 reversed it
    // deliberately. Prior addresses are personal data no screen in this app
    // has ever displayed, and an archive is a file people email to each other.
    // The two tests below pin both halves of that decision: what stopped
    // travelling, and what still works without it.
    test('prior addresses do not travel in an archive', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'new@x.com').toColumns());
      await seed(
          Tables.userEmails, sampleUserEmail(id: 'ue-1', userId: 'user-1', email: 'old@x.com').toColumns());
      await seed(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());

      final backup = await ProjectExporter.collect(db, 'project-1', now: DateTime.utc(2026, 7, 31));
      final bytes = BackupArchive.encode(backup);

      final other = await AppDatabase.openInMemory();
      addTearDown(other.close);
      await ProjectMerger(other.raw).merge(BackupArchive.decode(bytes));

      expect(await other.raw.query(Tables.userEmails), isEmpty);
      // The *current* address is a different matter and is supposed to travel:
      // the app displays it, and the merge anchors identity on it.
      final users = await other.raw.query(Tables.users);
      expect(users.single['email'], 'new@x.com');
    });

    test('a receiving device still dedupes using its own address history',
        () async {
      // **The cost of the narrowing, bounded by a test.** The merge has three
      // tiers of identity matching. Only the tier that reads the *sender's*
      // history is lost; this one reads the *receiver's*, which never left any
      // device, so it is unaffected. In practice: if this device already knows
      // that Sam once used old@x.com, an archive naming Sam by that address
      // still lands on the local Sam rather than creating a second one.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'new@x.com').toColumns());
      await seed(
          Tables.userEmails,
          sampleUserEmail(id: 'ue-local', userId: 'user-LOCAL', email: 'old@x.com').toColumns());

      final incoming = makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'old@x.com').toColumns()],
        Tables.projects: [
          sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns(),
        ],
      });

      await ProjectMerger(db).merge(incoming);

      final users = await db.query(Tables.users);
      expect(users.map((r) => r['user_id']), ['user-LOCAL'],
          reason: 'The incoming user should have deduped onto the local one, '
              'not created a second record for the same person.');
      final projects = await db.query(Tables.projects);
      expect(projects.single['owner_user_id'], 'user-LOCAL');
    });
  });

  // Task 10.55 / Gate C finding I-4. The server now refuses a `Users.email`
  // it has not authenticated — and the question the finding actually asked was
  // whether the *client* should still treat a matching address as proof of
  // identity once it does. It should not, on the sync path: see [IdentityTrust].
  group('identity trust (task 10.55)', () {
    test('a server-delivered page never remaps a user id by email', () async {
      // The forgery, as it would arrive after a pull: an attacker's own user
      // row carrying this device's owner's address, with every row on the page
      // attributed to the attacker's id. Under the file-import rule this
      // dedupes onto user-LOCAL and the observation becomes theirs.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'ranger@x.com').toColumns());
      final page = makeBackup({
        Tables.users: [sampleUser(id: 'user-ATTACKER', email: 'ranger@x.com').toColumns()],
        Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-ATTACKER').toColumns()],
        Tables.observations: [
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-ATTACKER', tagId: 'tag-1').toColumns(),
        ],
      });

      final report = await ProjectMerger(db)
          .merge(page, origin: MergeOrigin.authenticatedServer);

      expect(report.usersDeduped, 0);
      // The ids arrive as the server assigned them, untouched.
      expect((await fetch(Tables.observations, 'observation_id', 'obs-1'))!['user_id'], 'user-ATTACKER');
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-ATTACKER');
      expect(await fetch(Tables.users, 'user_id', 'user-LOCAL'), isNotNull);
    });

    test('nor by a prior address, which is the same remap one tier down', () async {
      // Tier 2b: the incoming user's *claimed* prior address matching a local
      // user's current one. Same rewrite, same harm, and equally unverifiable.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'ranger@x.com').toColumns());
      final page = makeBackup({
        Tables.users: [sampleUser(id: 'user-ATTACKER', email: 'someone@else.com').toColumns()],
        Tables.userEmails: [
          sampleUserEmail(id: 'ue-1', userId: 'user-ATTACKER', email: 'ranger@x.com').toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-ATTACKER').toColumns()],
      });

      final report = await ProjectMerger(db)
          .merge(page, origin: MergeOrigin.authenticatedServer);

      expect(report.usersDeduped, 0);
      expect(report.usersMatchedViaPriorEmail, 0);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-ATTACKER');
    });

    test('a backup file still dedupes — the rule is right for that source', () async {
      // The control, and the reason this is a parameter rather than a deletion.
      // Nobody assigned a file's ids; email is the only anchor it has.
      await seed(Tables.users, sampleUser(id: 'user-LOCAL', email: 'ranger@x.com').toColumns());
      final report = await ProjectMerger(db).merge(makeBackup({
        Tables.users: [sampleUser(id: 'user-REMOTE', email: 'ranger@x.com').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-REMOTE').toColumns()],
      }));

      expect(report.usersDeduped, 1);
      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['owner_user_id'], 'user-LOCAL');
    });
  });

  group('overwrite strategy', () {
    test('preferIncoming wins even when the local row is newer', () async {
      await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await seed(Tables.projects,
          sampleProject(id: 'project-1', ownerUserId: 'user-1')
              .copyWith(projectName: 'Local Newer', sync: sampleSync().copyWith(revision: 99))
              .toColumns());

      final incoming = sampleProject(id: 'project-1', ownerUserId: 'user-1')
          .copyWith(projectName: 'Forced', sync: sampleSync().copyWith(revision: 1));
      await ProjectMerger(db).merge(
        makeBackup({
          Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
          Tables.projects: [incoming.toColumns()],
        }),
        strategy: MergeStrategy.preferIncoming,
        confirmChanges: true,
      );

      expect((await fetch(Tables.projects, 'project_id', 'project-1'))!['project_name'], 'Forced');
    });
  });

  group('validation', () {
    test('an invalid row is rejected and reported, not inserted', () async {
      final badObs = sampleObservation(sessionId: null, id: 'bad', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1')
          .toColumns()
        ..['true_north_bearing'] = 999.0;
      final report = await ProjectMerger(db).merge(makeBackup({
        Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
        Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns()],
        Tables.observations: [badObs],
      }));

      expect(report.totalInvalid, 1);
      expect(report.issues.single.field, 'true_north_bearing');
      expect(await fetch(Tables.observations, 'observation_id', 'bad'), isNull);
    });
  });

  group('transactional safety', () {
    test('a dangling foreign key rolls back the entire merge', () async {
      // Observation references a user that is neither in the backup nor local.
      final backup = makeBackup({
        Tables.users: [sampleUser(id: 'user-1', email: 'a@x.com').toColumns()],
        Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns()],
        Tables.observations: [
          sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'ghost', tagId: 'tag-1').toColumns(),
        ],
      });

      // L-13 / task 10.95: `throwsA(anything)` guards K-1's own merge path —
      // it would pass identically on an unrelated bug (a typo, a missing
      // import, a wrong table name) as it does on the dangling foreign key
      // this test exists to prove rolls back. Assert the actual mechanism:
      // sqlite's own FOREIGN KEY enforcement refusing the insert.
      await expectLater(
        ProjectMerger(db).merge(backup),
        throwsA(isA<DatabaseException>().having(
          (e) => e.toString(),
          'message',
          contains('FOREIGN KEY constraint failed'),
        )),
      );

      // Nothing partially committed — the project the merge started inserting
      // must be gone.
      expect(await fetch(Tables.projects, 'project_id', 'project-1'), isNull);
      expect(await db.query(Tables.users), isEmpty);
    });
  });
}
