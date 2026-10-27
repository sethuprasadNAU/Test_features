import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';

/// **Task 11.19 — §4.19 clause 6.** `SharedObservationImporter.save` wrote an
/// `Observations` row with a direct SQL statement and asked nobody whether the
/// person at the keyboard was allowed to write in this project. Every other
/// write in the app has two layers: a screen that does not offer the control,
/// and a repository that refuses it anyway. This path had only the first, so a
/// viewer whose screen was bypassed — or whose role changed between the build
/// and the tap — reached an unguarded write, and learned about it only when the
/// server refused the row on the next sync.
///
/// The refusal is **advisory**, exactly like every other client-side permission
/// in this app (§4.21): a viewer who edits their own device's SQLite file can
/// still write the row, and the server still refuses it. What is being asserted
/// here is that the device says no *first* — the local backstop, not the
/// boundary.
///
/// ## The actor question, which is what made this an Opus task
///
/// An import has two people in it:
///
/// - the **receiver**, who is performing a write and is therefore governed by
///   the role gradient — that is clause 6 and everything this file tests;
/// - the **payload's observer**, who is not acting at all. Their name is being
///   transcribed onto a record made elsewhere, governed by §4.17's row-naming
///   invariant (clause 2), never by the gradient.
///
/// Both directions of getting that wrong are tested in the last group, because
/// each has a real cost: check the receiver too loosely and the control is the
/// courtesy it was; check the observer at all and every genuine share from a
/// colleague who is not on the project yet is refused, turning §4.17's
/// documented replication delay into local data loss.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const projectId = 'project-local';
  const projectOwner = 'user-owner';
  const alice = 'user-alice';
  const aliceEmail = 'alice@example.com';
  const receivingDevice = 'device-B';
  final now = DateTime.utc(2026, 8, 21, 12);

  late AppDatabase database;
  late Database db;
  late SharedObservationImporter importer;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    importer = SharedObservationImporter(db);
    // Users before the project: `Projects.owner_user_id` is a foreign key.
    for (final (id, email) in const [
      (projectOwner, 'owner@nau.edu'),
      ('user-viewer', 'viewer@nau.edu'),
      ('user-contributor', 'contributor@nau.edu'),
      ('user-stranger', 'stranger@nau.edu'),
    ]) {
      await db.insert(
          Tables.users, sampleUser(id: id, email: email).toColumns());
    }
    await db.insert(Tables.projects,
        sampleProject(id: projectId, ownerUserId: projectOwner).toColumns());
    await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-local', projectId: 'project-local').toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
              id: 'membership-owner',
              projectId: projectId,
              userId: projectOwner)
          .toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// Gives [userId] a membership at [role] in the project. `user-stranger`
  /// deliberately never gets one — see the `no membership row` group.
  Future<void> joinAs(String userId, ProjectRole role) => db.insert(
        Tables.projectMemberships,
        sampleMembership(
                id: 'membership-$userId',
                projectId: projectId,
                userId: userId,
                role: role)
            .toColumns(),
      );

  /// A genuine v2 share from Alice, encoded exactly as her device would.
  String alicePayload({
    String observationId = 'obs-alice',
    int revision = 3,
    String? notes = 'clear signal',
  }) =>
      ObservationShare.encode(
        sampleObservation(
          id: observationId,
          projectId: projectId,
          userId: alice,
          tagId: 'tag-local',
          sessionId: null,
        ).copyWith(
          notes: notes,
          sync: sampleSync().copyWith(
            revision: revision,
            updatedAt: DateTime.utc(2026, 8, 20, 9),
            lastModifiedBy: alice,
            originDeviceId: 'device-A',
          ),
        ),
        tag: sampleTag(id: 'tag-alice'),
        observer: sampleUser(id: alice, email: aliceEmail),
      );

  /// The same payload as an older build produced it: no identity block, so the
  /// importer takes the third write branch and mints a receiver-owned copy.
  String legacyPayload() {
    final json = jsonDecode(utf8
            .decode(base64Decode(alicePayload().substring('TT1:'.length))))
        as Map<String, Object?>
      ..['v'] = 1
      ..remove('observation_id')
      ..remove('observer_user_id')
      ..remove('observer_email')
      ..remove('position_source')
      ..remove('position_accuracy_m')
      ..remove('created_at')
      ..remove('updated_at')
      ..remove('revision')
      ..remove('last_modified_by')
      ..remove('origin_device_id');
    return 'TT1:${base64Encode(utf8.encode(jsonEncode(json)))}';
  }

  Future<SharedObservationImportResult> saveAs(
    String receivingUserId,
    String payload, {
    bool confirmChanges = false,
  }) =>
      importer.save(
        ObservationShare.decode(payload, now: now),
        projectId: projectId,
        tagId: 'tag-local',
        receivingUserId: receivingUserId,
        receivingDeviceId: receivingDevice,
        newId: () => 'minted-id',
        confirmChanges: confirmChanges,
        now: now,
      );

  /// Seeds the row a re-share would land on: Alice's observation, already held
  /// here, at an older revision so an incoming copy legitimately wins.
  Future<void> seedAlicesRowLocally({int revision = 1}) async {
    await db.insert(
        Tables.users, sampleUser(id: alice, email: aliceEmail).toColumns());
    await db.insert(
      Tables.observations,
      sampleObservation(
        id: 'obs-alice',
        projectId: projectId,
        userId: alice,
        tagId: 'tag-local',
        sessionId: null,
      ).copyWith(
        notes: 'first pass',
        sync: sampleSync().copyWith(
          revision: revision,
          updatedAt: DateTime.utc(2026, 8, 19, 9),
          lastModifiedBy: alice,
          originDeviceId: receivingDevice,
        ),
      ).toColumns(),
    );
  }

  Future<List<Map<String, Object?>>> observationRows() =>
      db.query(Tables.observations);

  Future<int> conflictRowCount() async {
    final tables = await db.query('sqlite_master',
        where: 'type = ? AND name = ?',
        whereArgs: ['table', SyncConflictStore.table]);
    if (tables.isEmpty) return 0;
    return (await db.query(SyncConflictStore.table)).length;
  }

  group('the fresh-insert branch', () {
    test("a viewer's save is refused on the device, not merely at the server",
        () async {
      await joinAs('user-viewer', ProjectRole.viewer);

      final result = await saveAs('user-viewer', alicePayload());

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
      expect(result.wrote, isFalse);
      expect(result.receiverRole, ProjectRole.viewer);
      expect(await observationRows(), isEmpty);
    });

    test('a refused import leaves no trace of the payload at all — including '
        "no Users row for the payload's observer", () async {
      // The sixth consequence of §4.19, applied to the new refusal: an import
      // that "failed" must not deposit an identity anchor a later file import
      // could match on. Clause 6 gets this for free by running before the
      // observer is resolved, and that is worth pinning rather than assuming.
      await joinAs('user-viewer', ProjectRole.viewer);

      await saveAs('user-viewer', alicePayload());

      final aliceRows = await db.query(Tables.users,
          where: 'user_id = ?', whereArgs: [alice]);
      expect(aliceRows, isEmpty);
    });

    test('a contributor may import', () async {
      await joinAs('user-contributor', ProjectRole.contributor);

      final result = await saveAs('user-contributor', alicePayload());

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(result.receiverRole, isNull,
          reason: 'carried only to explain a refusal');
      expect(await observationRows(), hasLength(1));
    });

    test('an owner may import', () async {
      final result = await saveAs(projectOwner, alicePayload());

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(await observationRows(), hasLength(1));
    });
  });

  group('the _upsertReplica update branch', () {
    test("a viewer's save is refused and the held row is untouched", () async {
      await joinAs('user-viewer', ProjectRole.viewer);
      await seedAlicesRowLocally();

      final result = await saveAs(
          'user-viewer', alicePayload(revision: 9, notes: 'corrected'));

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
      expect(result.wrote, isFalse);
      final held = Observation.fromRow((await observationRows()).single);
      expect(held.notes, 'first pass');
      expect(held.sync.revision, 1);
    });

    test('a refused update records no conflict, because there was no overwrite '
        'to make recoverable', () async {
      await joinAs('user-viewer', ProjectRole.viewer);
      await seedAlicesRowLocally();

      await saveAs('user-viewer', alicePayload(revision: 9, notes: 'x'));

      expect(await conflictRowCount(), 0);
    });

    test('a viewer is refused even when the incoming copy would lose anyway',
        () async {
      // The refusal is about the person, not about the merge. Answering
      // "your copy is already up to date" here would be a true sentence about
      // the wrong question, and would tell a viewer their save had been
      // considered on its merits.
      await joinAs('user-viewer', ProjectRole.viewer);
      await seedAlicesRowLocally(revision: 20);

      final result = await saveAs('user-viewer', alicePayload(revision: 3));

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
    });

    test('a contributor may bring their held copy up to date', () async {
      await joinAs('user-contributor', ProjectRole.contributor);
      await seedAlicesRowLocally();

      // `confirmChanges: true` because the correction replaces a note this
      // device holds, which is clause 4's consent gate doing its own job. The
      // point here is that clause 6 lets a contributor reach that gate at all.
      final result = await saveAs('user-contributor',
          alicePayload(revision: 9, notes: 'clear signal, corrected'),
          confirmChanges: true);

      expect(result.outcome, SharedObservationImportOutcome.replicaUpdated);
      final held = Observation.fromRow((await observationRows()).single);
      expect(held.notes, 'clear signal, corrected');
    });
  });

  group('the v1 fallback branch', () {
    // Not one of the two branches the task named, and it is a third write of an
    // `Observations` row on this same path — which is the reason clause 6 is
    // asked once at the top of `_save` rather than at each write. A guard per
    // branch is the two-lists defect §4.19 clause 1 exists because of.
    test("a viewer's save is refused there too", () async {
      await joinAs('user-viewer', ProjectRole.viewer);

      final result = await saveAs('user-viewer', legacyPayload());

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
      expect(await observationRows(), isEmpty);
    });

    test('a contributor still gets the receiver-owned copy', () async {
      await joinAs('user-contributor', ProjectRole.contributor);

      final result = await saveAs('user-contributor', legacyPayload());

      expect(result.outcome, SharedObservationImportOutcome.legacyCopyCreated);
      expect(Observation.fromRow((await observationRows()).single).userId,
          'user-contributor');
    });
  });

  group('no membership row: a snapshot refuses, an unreadable role defers', () {
    // `BaseRepository.assertRoleMayWrite`'s reasoning, narrowed by task
    // 11.237, and clause 6 follows it here deliberately. A device's SQLite
    // file legitimately holds projects it cannot answer for, and there it
    // defers to the server. Where it *can* answer — the project's row and its
    // membership rows are here and none names the receiver — pasting a
    // bearing in is a write into somebody else's project, and the refusal
    // names the join code rather than a role the person does not have.
    test('a user the device can see is not on the project is refused, and '
        'told how to join', () async {
      final result = await saveAs('user-stranger', alicePayload());

      expect(
        result.outcome,
        SharedObservationImportOutcome.refusedNotPermitted,
      );
      expect(result.receiverIsNotAMember, isTrue);
      expect(result.receiverRole, isNull);
      expect(await observationRows(), isEmpty);
    });

    test('a role string this build cannot interpret permits here and is '
        'refused at the server', () async {
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'membership-future',
          projectId: projectId,
          userId: 'user-stranger',
        ).toColumns()
          ..['role'] = 'auditor',
      );

      final result = await saveAs('user-stranger', alicePayload());

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
    });
  });

  group('the actor question: the gradient governs the receiver, never the '
      'payload', () {
    test("a colleague's share imports even though the colleague holds no role "
        'in this project', () async {
      // §4.17's accepted cost, read from the device's side: the row is held
      // here and does not replicate until Alice is a member. Applying the
      // gradient to her — the wrong actor — would refuse the ordinary case
      // sharing exists for and turn a documented delay into local data loss.
      await joinAs('user-contributor', ProjectRole.contributor);

      final result = await saveAs('user-contributor', alicePayload());

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(result.observerUserId, alice,
          reason: 'Phase 6 attribution survives; the receiver is not the '
              'author');
    });

    test("a viewer's share imports when the *receiver* may write", () async {
      // Alice is explicitly a viewer here. She is still the observer the row is
      // attributed to, because being unable to write on this device says
      // nothing about who made an observation somewhere else.
      await db.insert(
          Tables.users, sampleUser(id: alice, email: aliceEmail).toColumns());
      await joinAs(alice, ProjectRole.viewer);
      await joinAs('user-contributor', ProjectRole.contributor);

      final result = await saveAs('user-contributor', alicePayload());

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(
          Observation.fromRow((await observationRows()).single).userId, alice);
    });

    test("an owner's payload lends the receiving viewer nothing", () async {
      // The mirror of the case above, and the one that would matter: rights
      // travel with the person acting, not with the payload. A payload
      // observed by this project's owner must not let a viewer write.
      await joinAs('user-viewer', ProjectRole.viewer);
      final ownerPayload = ObservationShare.encode(
        sampleObservation(
          id: 'obs-owner',
          projectId: projectId,
          userId: projectOwner,
          tagId: 'tag-local',
          sessionId: null,
        ),
        tag: sampleTag(id: 'tag-alice'),
        observer: sampleUser(id: projectOwner, email: 'owner@nau.edu'),
      );

      final result = await saveAs('user-viewer', ownerPayload);

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
      expect(await observationRows(), isEmpty);
    });

    test('the receiver is judged in the project being written to, not in some '
        'other project on this device', () async {
      // A viewer here who is an owner of a different project on the same
      // device. The role must be resolved against the destination project.
      await joinAs('user-viewer', ProjectRole.viewer);
      await db.insert(Tables.projects,
          sampleProject(id: 'project-other', ownerUserId: 'user-viewer')
              .toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
                id: 'membership-other',
                projectId: 'project-other',
                userId: 'user-viewer')
            .toColumns(),
      );

      final result = await saveAs('user-viewer', alicePayload());

      expect(result.outcome,
          SharedObservationImportOutcome.refusedNotPermitted);
      expect(result.receiverRole, ProjectRole.viewer);
    });
  });
}
