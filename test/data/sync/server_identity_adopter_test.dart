import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/server_identity_adopter.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 10.6's correctness core: adopting the server's authoritative `user_id`
/// by rewriting this device's local rows onto it.
///
/// The failure this guards against is the worst one in the phase — a
/// half-applied remap leaves rows split across two ids with no record of which
/// was intended, and there is no clean recovery from that.
void main() {
  late AppDatabase appDb;
  late Database db;

  const serverId = 'server-uuid-1';
  const localId = 'local-uuid-1';
  const deviceId = 'device-A';
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
  }) async {
    await db.insert(Tables.users, {
      'user_id': id,
      'first_name': firstName,
      'last_name': 'Ranger',
      'email': email,
      'created_at': stamp(now.subtract(const Duration(days: 30))),
      'updated_at': stamp(now.subtract(const Duration(days: 30))),
      'revision': 0,
      'last_modified_by': id,
      'origin_device_id': deviceId,
    });
  }

  Future<void> insertPriorEmail({
    required String userId,
    required String email,
  }) async {
    await db.insert(Tables.userEmails, {
      'user_email_id': '$userId::$email',
      'user_id': userId,
      'email': email,
      'recorded_at': stamp(now.subtract(const Duration(days: 10))),
      'created_at': stamp(now.subtract(const Duration(days: 10))),
      'updated_at': stamp(now.subtract(const Duration(days: 10))),
      'revision': 0,
      'last_modified_by': userId,
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

  Future<void> insertMembership({
    required String id,
    required String projectId,
    required String userId,
  }) async {
    await db.insert(Tables.projectMemberships, {
      'membership_id': id,
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp(now),
      'role': 'owner',
      'created_at': stamp(now),
      'updated_at': stamp(now),
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
  }

  Future<void> insertObservation({
    required String id,
    required String projectId,
    required String userId,
    int revision = 3,
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
      'created_at': stamp(now.subtract(const Duration(days: 2))),
      'updated_at': stamp(now.subtract(const Duration(days: 2))),
      'revision': revision,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
  }

  Future<IdentityAdoptionReport> adopt({
    String email = 'sam@example.com',
    String? activeUserId = localId,
  }) {
    return ServerIdentityAdopter(db).adopt(
      serverUserId: serverId,
      email: email,
      firstName: 'Sam',
      lastName: 'Ranger',
      activeUserId: activeUserId,
      deviceId: deviceId,
      now: now,
    );
  }

  /// Seeds the ordinary first-sign-in shape: one local user who owns a project
  /// with a membership row and an observation.
  Future<void> seedTypicalDevice({String email = 'sam@example.com'}) async {
    await insertUser(id: localId, email: email);
    await insertProject(id: 'proj-1', ownerId: localId);
    await insertMembership(id: 'mem-1', projectId: 'proj-1', userId: localId);
    await insertObservation(id: 'obs-1', projectId: 'proj-1', userId: localId);
  }

  group('the ordinary first sign-in', () {
    test('every user-referencing column follows the remap', () async {
      await seedTypicalDevice();
      final report = await adopt();

      expect(report.remappedFrom, {localId});
      expect(report.createdServerUserRow, isTrue);

      final observation = (await db.query(Tables.observations)).single;
      expect(observation['user_id'], serverId);
      expect(observation['last_modified_by'], serverId);

      // Ownership and membership both follow, so the device still sees itself
      // as owner — the acceptance criterion names this explicitly.
      final project = (await db.query(Tables.projects)).single;
      expect(project['owner_user_id'], serverId);
      final membership = (await db.query(Tables.projectMemberships)).single;
      expect(membership['user_id'], serverId);
    });

    test('the old Users row is gone and exactly one user remains', () async {
      await seedTypicalDevice();
      await adopt();

      final users = await db.query(Tables.users);
      expect(users, hasLength(1));
      expect(users.single['user_id'], serverId);
      expect(users.single['email'], 'sam@example.com');
    });

    test(
      'the profile typed at first run is carried over, not discarded',
      () async {
        await insertUser(
          id: localId,
          email: 'sam@example.com',
          firstName: 'Samantha',
        );
        await adopt();

        final user = (await db.query(Tables.users)).single;
        expect(user['first_name'], 'Samantha');
        expect(user['last_name'], 'Ranger');
      },
    );

    test(
      'rewritten rows get a bumped sync clock so the change propagates',
      () async {
        // Found by the Gate A review: NOT bumping is only safe on a first
        // sign-in. On a later one (address changed, server mints a new id) the
        // rewrite would lose last-write-wins against the server's copies —
        // equal revision, equal updated_at — and the next pull would silently
        // revert the attribution.
        await seedTypicalDevice();
        final before = (await db.query(Tables.observations)).single;
        await adopt();
        final after = (await db.query(Tables.observations)).single;

        expect(after['revision'], (before['revision']! as int) + 1);
        expect(after['updated_at'], isNot(before['updated_at']));
        expect(after['updated_at'], stamp(now));
      },
    );

    test('an idempotent re-run bumps nothing — no churn', () async {
      // The bump above is a one-time cost per genuine identity change, not the
      // every-round rewriting the "One user, many devices" analysis forbids.
      await seedTypicalDevice();
      await adopt();
      final afterFirst = (await db.query(Tables.observations)).single;

      await adopt(activeUserId: serverId);
      final afterSecond = (await db.query(Tables.observations)).single;

      expect(afterSecond['revision'], afterFirst['revision']);
      expect(afterSecond['updated_at'], afterFirst['updated_at']);
    });
  });

  group('idempotency', () {
    test('running twice produces the same result as running once', () async {
      await seedTypicalDevice();
      await adopt();
      final usersAfterFirst = await db.query(Tables.users);
      final observationsAfterFirst = await db.query(Tables.observations);

      final second = await adopt(activeUserId: serverId);

      expect(second.remappedFrom, isEmpty);
      expect(second.createdServerUserRow, isFalse);
      expect(second.changedAnything, isFalse);
      expect(await db.query(Tables.users), usersAfterFirst);
      expect(await db.query(Tables.observations), observationsAfterFirst);
    });

    test('a third run still changes nothing', () async {
      await seedTypicalDevice();
      await adopt();
      await adopt(activeUserId: serverId);
      final snapshot = await db.query(Tables.observations);
      await adopt(activeUserId: serverId);
      expect(await db.query(Tables.observations), snapshot);
    });

    test(
      'adopting when the device is already on the server id is a no-op',
      () async {
        await insertUser(id: serverId, email: 'sam@example.com');
        await insertProject(id: 'proj-1', ownerId: serverId);
        final report = await adopt(activeUserId: serverId);

        expect(report.changedAnything, isFalse);
        expect(report.rowsRewritten, 0);
      },
    );
  });

  group('crash safety', () {
    test(
      'a failure mid-remap leaves the database completely untouched',
      () async {
        await seedTypicalDevice();
        final usersBefore = await db.query(Tables.users);
        final observationsBefore = await db.query(Tables.observations);
        final projectsBefore = await db.query(Tables.projects);

        // Force a failure *after* the rewrite work has started, by running the
        // adopter inside a transaction the test then aborts. This is the
        // interrupted-midway case: the whole thing must roll back, leaving no
        // rows stranded on the old id.
        await expectLater(
          db.transaction((txn) async {
            await ServerIdentityAdopter(txn).adopt(
              serverUserId: serverId,
              email: 'sam@example.com',
              firstName: 'Sam',
              lastName: 'Ranger',
              activeUserId: localId,
              deviceId: deviceId,
              now: now,
            );
            throw StateError('interrupted');
          }),
          throwsStateError,
        );

        expect(await db.query(Tables.users), usersBefore);
        expect(await db.query(Tables.observations), observationsBefore);
        expect(await db.query(Tables.projects), projectsBefore);
      },
    );

    test('re-running after an interruption completes cleanly', () async {
      await seedTypicalDevice();
      await expectLater(
        db.transaction((txn) async {
          await ServerIdentityAdopter(txn).adopt(
            serverUserId: serverId,
            email: 'sam@example.com',
            firstName: 'Sam',
            lastName: 'Ranger',
            activeUserId: localId,
            deviceId: deviceId,
            now: now,
          );
          throw StateError('interrupted');
        }),
        throwsStateError,
      );

      final report = await adopt();
      expect(report.remappedFrom, {localId});

      // No row stranded on the old id anywhere.
      for (final table in syncTables) {
        for (final column in table.userColumns) {
          final rows = await db.rawQuery(
            'SELECT COUNT(*) AS n FROM ${table.name} WHERE $column = ?',
            [localId],
          );
          expect(rows.single['n'], 0, reason: '${table.name}.$column');
        }
      }
    });
  });

  group('two devices converge', () {
    test('different locally-minted ids both land on the server id', () async {
      // Device A.
      await seedTypicalDevice();
      await adopt();
      final deviceAUser = (await db.query(Tables.users)).single['user_id'];

      // Device B: a *different* locally minted id for the same person.
      final bAppDb = await AppDatabase.openInMemory();
      addTearDown(bAppDb.close);
      const otherLocalId = 'local-uuid-2';
      await bAppDb.raw.insert(Tables.users, {
        'user_id': otherLocalId,
        'first_name': 'Sam',
        'last_name': 'Ranger',
        'email': 'sam@example.com',
        'created_at': stamp(now),
        'updated_at': stamp(now),
        'revision': 0,
        'last_modified_by': otherLocalId,
        'origin_device_id': 'device-B',
      });
      await ServerIdentityAdopter(bAppDb.raw).adopt(
        serverUserId: serverId,
        email: 'sam@example.com',
        firstName: 'Sam',
        lastName: 'Ranger',
        activeUserId: otherLocalId,
        deviceId: 'device-B',
        now: now,
      );
      final deviceBUser = (await bAppDb.raw.query(
        Tables.users,
      )).single['user_id'];

      expect(deviceAUser, serverId);
      expect(deviceBUser, serverId);
      expect(deviceAUser, deviceBUser);
    });
  });

  group('matching rules', () {
    test(
      'a placeholder-identity active user is adopted despite the address',
      () async {
        // Nobody else has ever used this device, so the person signing in is
        // unambiguously this user.
        await insertUser(id: localId, email: 'field-user-abc@local.tritrack');
        await insertProject(id: 'proj-1', ownerId: localId);

        final report = await adopt();
        expect(report.remappedFrom, {localId});
        expect(
          (await db.query(Tables.projects)).single['owner_user_id'],
          serverId,
        );
      },
    );

    test('a placeholder address is not recorded as a prior email', () async {
      await insertUser(id: localId, email: 'field-user-abc@local.tritrack');
      await adopt();
      // It was never a real mailbox and matches nobody, so recording it would
      // only add noise to future cross-device dedup.
      expect(await db.query(Tables.userEmails), isEmpty);
    });

    test(
      'signing in with a recorded prior address adopts, not duplicates',
      () async {
        // Phase 7 records every address a user has ever used so a changed email
        // doesn't fracture their identity; Phase 6's merge already matches on it.
        // Adoption honours the same anchor rather than minting a second identity
        // on a device that already knows the two are the same person.
        await insertUser(id: localId, email: 'sam.new@example.com');
        await insertPriorEmail(userId: localId, email: 'sam@example.com');
        await insertProject(id: 'proj-1', ownerId: localId);

        final report = await adopt(email: 'sam@example.com');

        expect(report.remappedFrom, {localId});
        expect(
          (await db.query(Tables.projects)).single['owner_user_id'],
          serverId,
        );
      },
    );

    test(
      'the superseded address is kept, so old backups still match',
      () async {
        await insertUser(id: localId, email: 'sam.new@example.com');
        await insertPriorEmail(userId: localId, email: 'sam@example.com');

        await adopt(email: 'sam@example.com');

        final priors = await db.query(
          Tables.userEmails,
          where: 'user_id = ?',
          whereArgs: [serverId],
        );
        expect(
          priors.map((r) => r['email']),
          contains('sam.new@example.com'),
          reason: 'a backup written under the old address must still match',
        );
      },
    );

    test(
      'an address two local users claim as prior is too ambiguous to match',
      () async {
        // A reassigned institutional mailbox. Guessing here would fuse two
        // people, so the same exclusion ProjectMerger makes applies.
        await insertUser(id: localId, email: 'alex@nau.edu');
        await insertUser(id: 'local-uuid-2', email: 'kim@nau.edu');
        await insertPriorEmail(userId: localId, email: 'lab@nau.edu');
        await insertPriorEmail(userId: 'local-uuid-2', email: 'lab@nau.edu');
        await insertProject(id: 'proj-1', ownerId: localId);

        final report = await adopt(email: 'lab@nau.edu');

        expect(report.remappedFrom, isEmpty);
        expect(
          (await db.query(Tables.projects)).single['owner_user_id'],
          localId,
        );
      },
    );

    test('another person on the same device keeps their records', () async {
      // Signing in as someone whose address does not match the device's local
      // identity must not reassign that identity's field records — that is the
      // provenance violation Phase 8 and 11.7 exist to prevent.
      await insertUser(id: localId, email: 'alex@nau.edu');
      await insertProject(id: 'proj-1', ownerId: localId);
      await insertObservation(
        id: 'obs-1',
        projectId: 'proj-1',
        userId: localId,
      );

      final report = await adopt(email: 'sam@gmail.com');

      expect(report.remappedFrom, isEmpty);
      expect((await db.query(Tables.observations)).single['user_id'], localId);
      expect(
        (await db.query(Tables.projects)).single['owner_user_id'],
        localId,
      );
      // The signed-in identity still gets a local row of its own.
      final users = await db.query(Tables.users);
      expect(users.map((u) => u['user_id']), containsAll([localId, serverId]));
    });

    test('two local rows sharing the email do NOT both fold in', () async {
      // Task 10.75 (finding K-4), the honest-path variant. This test asserted
      // the opposite until 10.75: both rows folded in and one profile was
      // hard-deleted. That is right for a merge duplicate of one person and
      // catastrophic for two people on a shared institutional mailbox, and
      // nothing in the data tells them apart — so the ambiguous case is held
      // back rather than guessed at, the same rule the prior-address branch
      // has always applied.
      await insertUser(id: localId, email: 'sam@example.com');
      await insertUser(id: 'local-uuid-dup', email: 'sam@example.com');
      await insertProject(id: 'proj-1', ownerId: localId);
      await insertObservation(
        id: 'obs-1',
        projectId: 'proj-1',
        userId: 'local-uuid-dup',
      );

      final report = await adopt();

      expect(report.remappedFrom, {localId}, reason: 'only the active user');
      expect(report.heldBack, {'local-uuid-dup'});
      // The other person still exists and still owns their observation.
      expect(
        (await db.query(Tables.users)).map((u) => u['user_id']),
        unorderedEquals(['local-uuid-dup', serverId]),
      );
      expect(
        (await db.query(Tables.observations)).single['user_id'],
        'local-uuid-dup',
      );
    });

    test("another user's replicated rows are never touched", () async {
      // Phase 6 replica import legitimately stores other people's rows with
      // their own ids; adoption must remap only the signing-in person.
      await seedTypicalDevice();
      await insertUser(id: 'teammate-1', email: 'kim@example.com');
      await insertObservation(
        id: 'obs-teammate',
        projectId: 'proj-1',
        userId: 'teammate-1',
      );

      await adopt();

      final teammateRow = (await db.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-teammate'],
      )).single;
      expect(teammateRow['user_id'], 'teammate-1');
      expect(teammateRow['last_modified_by'], 'teammate-1');
    });
  });

  group('referential integrity', () {
    test('foreign keys stay valid throughout (they are enforced)', () async {
      await seedTypicalDevice();
      await adopt();
      final violations = await db.rawQuery('PRAGMA foreign_key_check');
      expect(violations, isEmpty);
    });

    test('the remap covers every user column syncTables declares', () async {
      // Guards the reuse: if a table gains a user column, this fails rather
      // than silently leaving those rows on the old id.
      await seedTypicalDevice();
      await adopt();
      for (final table in syncTables) {
        for (final column in table.userColumns) {
          final rows = await db.rawQuery(
            'SELECT COUNT(*) AS n FROM ${table.name} WHERE $column = ?',
            [localId],
          );
          expect(rows.single['n'], 0, reason: '${table.name}.$column');
        }
      }
    });
  });
}
