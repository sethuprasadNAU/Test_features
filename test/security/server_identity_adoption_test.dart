import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/server_identity_adopter.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 10.75, finding **K-4** — the client adopts a server-chosen `user_id`.
///
/// `test/data/sync/server_identity_adopter_test.dart` is the correctness suite
/// and every one of its tests hands the adopter a well-formed
/// `'server-uuid-1'`. **No test drove a hostile `serverUserId` at all**, which
/// is how "is a non-empty String" survived as the whole of the check on a
/// value that becomes a primary key on eleven tables. This file is the
/// adversarial half.
///
/// Security model **§4.20** is the written trust boundary these tests enforce.
/// The four groups map to its four clauses one-to-one, deliberately, so that a
/// clause removed from the model has a visibly orphaned test:
///
/// 1. the server names the id — **shape is not its call** (`a hostile id`)
/// 2. the server does not name **whose rows those are** (`a hostile id`, the
///    collision case)
/// 3. the device, not the server, decides **which local rows are one person**
///    (`a shared institutional mailbox`)
/// 4. nothing may be destroyed unrecorded (`the superseded row survives`)
///
/// Plus `refusal is total`, which is the property the other three rest on: a
/// refusal that had already written half a remap would be worse than no check.
void main() {
  late AppDatabase appDb;
  late Database db;

  const serverId = 'server-uuid-1';
  const localId = 'local-uuid-1';
  const deviceId = 'device-A';
  const signedInEmail = 'sam@example.com';
  final now = DateTime.utc(2026, 8, 1, 12);

  setUp(() async {
    appDb = await AppDatabase.openInMemory();
    db = appDb.raw;
  });

  tearDown(() => appDb.close());

  String stamp(DateTime at) => DbCodec.encodeUtc(at);

  Future<void> insertUser({
    required String id,
    required String email,
    String firstName = 'Sam',
    String lastName = 'Ranger',
  }) async {
    await db.insert(Tables.users, {
      'user_id': id,
      'first_name': firstName,
      'last_name': lastName,
      'email': email,
      'created_at': stamp(now.subtract(const Duration(days: 30))),
      'updated_at': stamp(now.subtract(const Duration(days: 30))),
      'revision': 0,
      'last_modified_by': id,
      'origin_device_id': deviceId,
    });
  }

  Future<void> insertProject({
    required String id,
    required String ownerId,
  }) async {
    await db.insert(Tables.projects, {
      'project_id': id,
      'project_name': 'Elk Study',
      'owner_user_id': ownerId,
      'creation_date': stamp(now),
      'datum': 'WGS84',
      'created_at': stamp(now),
      'updated_at': stamp(now),
      'revision': 0,
      'last_modified_by': ownerId,
      'origin_device_id': deviceId,
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
  }

  Future<void> insertObservation({
    required String id,
    required String projectId,
    required String userId,
  }) async {
    await db.insert(Tables.observations, {
      'observation_id': id,
      'project_id': projectId,
      'user_id': userId,
      'timestamp_local': stamp(now),
      'timestamp_utc': stamp(now),
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'magnetic_bearing': 271.5,
      'created_at': stamp(now.subtract(const Duration(days: 2))),
      'updated_at': stamp(now.subtract(const Duration(days: 2))),
      'revision': 3,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
  }

  Future<void> seedTypicalDevice({String email = signedInEmail}) async {
    await insertUser(id: localId, email: email);
    await insertProject(id: 'proj-1', ownerId: localId);
    await insertObservation(id: 'obs-1', projectId: 'proj-1', userId: localId);
  }

  Future<IdentityAdoptionReport> adopt({
    String serverUserId = serverId,
    String email = signedInEmail,
    String? activeUserId = localId,
  }) {
    return ServerIdentityAdopter(db).adopt(
      serverUserId: serverUserId,
      email: email,
      firstName: 'Sam',
      lastName: 'Ranger',
      activeUserId: activeUserId,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Everything the database holds, as a comparable snapshot — used to assert
  /// that a refusal changed *nothing*, rather than that it changed nothing
  /// the test happened to look at.
  Future<String> snapshotEverything() async {
    final out = <String, Object?>{};
    for (final table in syncTables) {
      out[table.name] = await db.query(table.name, orderBy: null);
    }
    await SyncConflictStore.ensureTable(db);
    out[SyncConflictStore.table] = await db.query(SyncConflictStore.table);
    return jsonEncode(out.map((k, v) => MapEntry(k, v.toString())));
  }

  group('§4.20 clause 1 — a hostile id: shape is not the server\'s call', () {
    // Every one of these is a string. That was the entire check.
    final malformed = <String, String>{
      'empty': '',
      'whitespace only': '   ',
      'a NUL byte': 'server\u0000uuid',
      'a newline': 'server-uuid-1\nowner_user_id',
      'a carriage return': 'server\r\nuuid',
      'an ANSI escape': 'server\u001b[31muuid',
      'a DEL byte': 'server\u007fuuid',
      'longer than the primary-key bound': 'x' * 201,
    };

    for (final entry in malformed.entries) {
      test('a server id containing ${entry.key} is refused', () async {
        await seedTypicalDevice();
        final before = await snapshotEverything();

        await expectLater(
          adopt(serverUserId: entry.value),
          throwsA(
            isA<IdentityAdoptionRefused>().having(
              (e) => e.reason,
              'reason',
              contains('cannot store'),
            ),
          ),
        );

        expect(
          await snapshotEverything(),
          before,
          reason: 'a refused adoption must leave the database untouched',
        );
      });
    }

    test('a legal but absurd id still cannot smuggle in an unstorable '
        'User_Emails key', () async {
      // The composite `user_email_id` is '<serverUserId>::<priorEmail>'. A
      // 200-character id is individually within bounds and the derived key is
      // not — a derived key needs its own check, not its parts'.
      final longButLegal = 'a' * 200;
      await insertUser(id: localId, email: 'old-address@example.com');
      await db.insert(Tables.userEmails, {
        'user_email_id': '$localId::$signedInEmail',
        'user_id': localId,
        'email': signedInEmail,
        'recorded_at': stamp(now),
        'created_at': stamp(now),
        'updated_at': stamp(now),
        'revision': 0,
        'last_modified_by': localId,
        'origin_device_id': deviceId,
      });
      final before = await snapshotEverything();

      await expectLater(
        adopt(serverUserId: longButLegal),
        throwsA(isA<IdentityAdoptionRefused>()),
      );
      expect(await snapshotEverything(), before);
    });

    test('the ordinary well-formed id is still adopted', () async {
      // The negative control. A refusal-everything implementation would pass
      // every test above and be useless.
      await seedTypicalDevice();
      final report = await adopt();

      expect(report.remappedFrom, {localId});
      expect(report.createdServerUserRow, isTrue);
      expect(
        (await db.query(Tables.observations)).single['user_id'],
        serverId,
      );
    });
  });

  group('§4.20 clause 2 — the server does not name whose rows those are', () {
    test('a server id this device already holds for someone else is '
        'refused', () async {
      // The attack the redemption-time email check does NOT bound: the server
      // legitimately confirms sam@example.com and answers with the `user_id`
      // of Alex, a colleague whose replicated rows this device already holds.
      // Without this check, Sam's observations are rewritten onto Alex's
      // `Users` row with a bumped revision that beats Alex's own copy on the
      // next sync — silently, with every foreign key still valid.
      await seedTypicalDevice();
      await insertUser(
        id: 'alex-uuid',
        email: 'alex@nau.edu',
        firstName: 'Alex',
      );
      await insertObservation(
        id: 'obs-alex',
        projectId: 'proj-1',
        userId: 'alex-uuid',
      );
      final before = await snapshotEverything();

      await expectLater(
        adopt(serverUserId: 'alex-uuid'),
        throwsA(
          isA<IdentityAdoptionRefused>().having(
            (e) => e.reason,
            'reason',
            contains('different person'),
          ),
        ),
      );

      expect(await snapshotEverything(), before);
      // Named explicitly, because this is the harm: Sam's observation is
      // still Sam's, and Alex's is still Alex's.
      final obs = await db.query(Tables.observations);
      expect(
        {for (final row in obs) row['observation_id']: row['user_id']},
        {'obs-1': localId, 'obs-alex': 'alex-uuid'},
      );
    });

    test('an existing row carrying the signed-in address is not a '
        'collision', () async {
      // The idempotent re-run: the server row is this person. Must not be
      // mistaken for the attack above.
      await insertUser(id: serverId, email: signedInEmail);
      await insertProject(id: 'proj-1', ownerId: serverId);

      final report = await adopt(activeUserId: serverId);

      expect(report.createdServerUserRow, isFalse);
      expect(report.remappedFrom, isEmpty);
    });

    test('an existing row carrying a Phase 7 placeholder is not a '
        'collision', () async {
      // A placeholder address names nobody, so there is no other person to
      // fuse with.
      await insertUser(id: serverId, email: 'field-user-abc@local.tritrack');
      await insertUser(id: localId, email: signedInEmail);
      await insertProject(id: 'proj-1', ownerId: localId);

      final report = await adopt();

      expect(report.createdServerUserRow, isFalse);
      expect(report.remappedFrom, {localId});
    });

    test('an existing row that recorded the signed-in address as a prior is '
        'not a collision', () async {
      // The genuine changed-address case: this person signed in once under
      // sam@example.com, changed to sam@nau.edu, and the server still knows
      // them by the same id.
      await insertUser(id: serverId, email: 'sam@nau.edu');
      await db.insert(Tables.userEmails, {
        'user_email_id': '$serverId::$signedInEmail',
        'user_id': serverId,
        'email': signedInEmail,
        'recorded_at': stamp(now),
        'created_at': stamp(now),
        'updated_at': stamp(now),
        'revision': 0,
        'last_modified_by': serverId,
        'origin_device_id': deviceId,
      });
      await insertProject(id: 'proj-1', ownerId: serverId);

      final report = await adopt(activeUserId: serverId);

      expect(report.createdServerUserRow, isFalse);
    });
  });

  group('§4.20 clause 3 — a shared institutional mailbox (no attacker)', () {
    // The variant that needs no hostile server at all, and the one that will
    // actually happen: field researchers share institutional mailboxes.
    test('two people on one address are not fused, and neither profile is '
        'destroyed', () async {
      await insertUser(id: localId, email: 'lab@nau.edu', firstName: 'Sam');
      await insertUser(id: 'bo-uuid', email: 'lab@nau.edu', firstName: 'Bo');
      await insertProject(id: 'proj-1', ownerId: localId);
      await insertObservation(id: 'obs-sam', projectId: 'proj-1', userId: localId);
      await insertObservation(
        id: 'obs-bo',
        projectId: 'proj-1',
        userId: 'bo-uuid',
      );

      final report = await adopt(email: 'lab@nau.edu');

      expect(report.remappedFrom, {localId});
      expect(report.heldBack, {'bo-uuid'});

      // Bo's profile still exists — this is the hard DELETE that had no
      // tombstone and no conflict record.
      final bo = await db.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: ['bo-uuid'],
      );
      expect(bo, hasLength(1));
      expect(bo.single['first_name'], 'Bo');

      // And Bo's field data is still attributed to Bo.
      final byObservation = {
        for (final row in await db.query(Tables.observations))
          row['observation_id']: row['user_id'],
      };
      expect(byObservation, {'obs-sam': serverId, 'obs-bo': 'bo-uuid'});
    });

    test('a held-back user is not let back in through a prior address',
        () async {
      // Two anchors, one answer. Holding Bo back means this device cannot
      // tell which person Bo is; a `User_Emails` row does not answer that,
      // so it must not re-admit them.
      await insertUser(id: localId, email: 'lab@nau.edu');
      await insertUser(id: 'bo-uuid', email: 'lab@nau.edu', firstName: 'Bo');
      await db.insert(Tables.userEmails, {
        'user_email_id': 'bo-uuid::lab@nau.edu',
        'user_id': 'bo-uuid',
        'email': 'lab@nau.edu',
        'recorded_at': stamp(now),
        'created_at': stamp(now),
        'updated_at': stamp(now),
        'revision': 0,
        'last_modified_by': 'bo-uuid',
        'origin_device_id': deviceId,
      });
      await insertProject(id: 'proj-1', ownerId: localId);

      final report = await adopt(email: 'lab@nau.edu');

      expect(report.remappedFrom, {localId});
      expect(report.heldBack, {'bo-uuid'});
    });

    test('when the active user is not among the ambiguous matches, none of '
        'them is adopted', () async {
      // Nobody on this device has a basis for claiming either row, so the
      // signed-in identity simply gets its own.
      await insertUser(id: 'sam-uuid', email: 'lab@nau.edu', firstName: 'Sam');
      await insertUser(id: 'bo-uuid', email: 'lab@nau.edu', firstName: 'Bo');
      await insertUser(
        id: 'placeholder-uuid',
        email: 'field-user-zzz@local.tritrack',
      );
      await insertProject(id: 'proj-1', ownerId: 'sam-uuid');

      final report = await adopt(
        email: 'lab@nau.edu',
        activeUserId: 'placeholder-uuid',
      );

      expect(report.remappedFrom, {'placeholder-uuid'});
      expect(report.heldBack, {'sam-uuid', 'bo-uuid'});
      expect(
        (await db.query(Tables.users)).map((u) => u['user_id']),
        unorderedEquals(['sam-uuid', 'bo-uuid', serverId]),
      );
    });

    test('one local row on the address still folds in — the ordinary case is '
        'not collateral damage', () async {
      // The negative control for this clause: "hold everything back" would
      // pass every test above and break the feature.
      await seedTypicalDevice();
      final report = await adopt();
      expect(report.remappedFrom, {localId});
      expect(report.heldBack, isEmpty);
    });
  });

  group('§4.20 clause 4 — the superseded row survives the hard delete', () {
    test('the deleted Users row is captured to Sync_Conflicts first',
        () async {
      await insertUser(
        id: localId,
        email: signedInEmail,
        firstName: 'Samira',
        lastName: 'Okonkwo',
      );
      await insertProject(id: 'proj-1', ownerId: localId);

      final report = await adopt();

      expect(report.remappedFrom, {localId});
      expect(report.supersededRowsCaptured, 1);

      final conflicts = await SyncConflictStore(db).unreviewed('proj-1');
      expect(conflicts, hasLength(1));
      final conflict = conflicts.single;
      expect(conflict.tableName, Tables.users);
      expect(conflict.rowKey, localId);
      // The whole point: the profile that no longer exists anywhere is
      // readable from the record.
      expect(conflict.localSnapshot['first_name'], 'Samira');
      expect(conflict.localSnapshot['last_name'], 'Okonkwo');
      expect(conflict.localSnapshot['user_id'], localId);
      expect(conflict.incomingSnapshot?['user_id'], serverId);
    });

    test('the capture is reachable from every project the device holds',
        () async {
      // `Users` is globally keyed, so there is no honest single project to
      // file this under, and the sync status screen only ever shows the
      // active project's conflicts. A record no screen can show is the same
      // as no record — which is the defect being fixed.
      await insertUser(id: localId, email: signedInEmail);
      await insertProject(id: 'proj-1', ownerId: localId);
      await insertProject(id: 'proj-2', ownerId: localId);

      final report = await adopt();

      expect(report.supersededRowsCaptured, 2);
      expect(await SyncConflictStore(db).unreviewed('proj-1'), hasLength(1));
      expect(await SyncConflictStore(db).unreviewed('proj-2'), hasLength(1));
    });

    test('nothing is captured when nothing is superseded', () async {
      // A record written on every sign-in is one the user learns to dismiss —
      // the same reasoning as §4.19 rule 4's consent prompt.
      await insertUser(id: serverId, email: signedInEmail);
      await insertProject(id: 'proj-1', ownerId: serverId);

      final report = await adopt(activeUserId: serverId);

      expect(report.supersededRowsCaptured, 0);
      expect(await SyncConflictStore(db).unreviewed('proj-1'), isEmpty);
    });

    test('a held-back user produces no capture, because nothing was taken '
        'from them', () async {
      await insertUser(id: localId, email: 'lab@nau.edu');
      await insertUser(id: 'bo-uuid', email: 'lab@nau.edu', firstName: 'Bo');
      await insertProject(id: 'proj-1', ownerId: localId);

      final report = await adopt(email: 'lab@nau.edu');

      expect(report.heldBack, {'bo-uuid'});
      expect(report.supersededRowsCaptured, 1, reason: 'only the active user');
      final conflicts = await SyncConflictStore(db).unreviewed('proj-1');
      expect(conflicts.map((c) => c.rowKey), [localId]);
    });
  });

  group('refusal is total', () {
    test('a refusal after the Users insert rolls that insert back too',
        () async {
      // The refusal that fires latest is the derived-key one inside
      // `_recordPriorEmails`, which runs *after* the new `Users` row is
      // inserted. If the transaction boundary were wrong, this is the case
      // that would leave a half-adopted database — rows split across two ids
      // with no record of which was intended, which the correctness suite
      // calls the one unrecoverable outcome.
      final longButLegal = 'b' * 200;
      await insertUser(id: localId, email: 'old-address@example.com');
      await db.insert(Tables.userEmails, {
        'user_email_id': '$localId::$signedInEmail',
        'user_id': localId,
        'email': signedInEmail,
        'recorded_at': stamp(now),
        'created_at': stamp(now),
        'updated_at': stamp(now),
        'revision': 0,
        'last_modified_by': localId,
        'origin_device_id': deviceId,
      });
      await insertProject(id: 'proj-1', ownerId: localId);
      await insertObservation(
        id: 'obs-1',
        projectId: 'proj-1',
        userId: localId,
      );

      await expectLater(
        adopt(serverUserId: longButLegal),
        throwsA(isA<IdentityAdoptionRefused>()),
      );

      expect(
        (await db.query(Tables.users)).map((u) => u['user_id']),
        [localId],
        reason: 'no partially-created server Users row',
      );
      expect(
        (await db.query(Tables.observations)).single['user_id'],
        localId,
        reason: 'no partially-applied remap',
      );
      expect(
        (await db.query(Tables.observations)).single['revision'],
        3,
        reason: 'no clock bump from a rolled-back rewrite',
      );
    });

    test('a refused adoption can be followed by a good one', () async {
      // A refusal must not wedge the device: the user requests a new code
      // from a server that behaves, and sign-in works.
      await seedTypicalDevice();

      await expectLater(
        adopt(serverUserId: 'bad\u0000id'),
        throwsA(isA<IdentityAdoptionRefused>()),
      );
      final report = await adopt();

      expect(report.remappedFrom, {localId});
      expect((await db.query(Tables.observations)).single['user_id'], serverId);
    });
  });

  group('RowValidator carries the shape rule for every other path', () {
    // Task 10.66: fix the class, not the instance. The adopter is one caller
    // of a bound that belongs on every write path — the merge path and the
    // archive path reach the same columns.
    test('a control character in a primary key is refused table-agnostically',
        () async {
      expect(
        RowValidator.validate(Tables.observations, {
          'observation_id': 'obs\u0000-1',
          'project_id': 'proj-1',
        }),
        isNotEmpty,
      );
    });

    test('an over-long or malformed identity column is refused', () async {
      expect(
        RowValidator.validate(Tables.projects, {
          'project_id': 'proj-1',
          'owner_user_id': 'x' * 5000,
          'email': 'a@b.c',
        }).map((i) => i.field),
        contains('owner_user_id'),
      );
      expect(
        RowValidator.validate(Tables.observations, {
          'observation_id': 'obs-1',
          'project_id': 'proj-1',
          'last_modified_by': 'who\nis this',
        }).map((i) => i.field),
        contains('last_modified_by'),
      );
    });

    test('ordinary identifiers are accepted', () {
      expect(RowValidator.isWellFormedIdentifier('server-uuid-1'), isTrue);
      expect(
        RowValidator.isWellFormedIdentifier(
          '9f8b2c1e-3d4a-4b5c-8e7f-0a1b2c3d4e5f',
        ),
        isTrue,
      );
      expect(RowValidator.isWellFormedIdentifier(''), isFalse);
      expect(RowValidator.isWellFormedIdentifier(null), isFalse);
      expect(RowValidator.isWellFormedIdentifier(42), isFalse);
    });
  });
}
