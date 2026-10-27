import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the on-device upgrade path for schema v8 (task 11.10): a
/// partial unique index on `Project_Memberships(project_id, user_id)` that
/// holds only while the membership is open, backing up the one-open-
/// membership-per-project rule that was previously enforced by code alone.
void main() {
  const t = '2026-08-21T00:00:00.000Z';

  /// A v7 database, built by running the real migrations rather than by
  /// hand, so this is the shape a device in the field actually has.
  Future<Database> openV7() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 7, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 7);
    return db;
  }

  Future<void> seedUserAndProject(
    Database db, {
    required String userId,
    required String projectId,
  }) async {
    await db.insert(Tables.users, {
      'user_id': userId,
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': '$userId@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Peaks $projectId',
      'owner_user_id': userId,
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
  }

  Map<String, Object?> membershipRow({
    required String membershipId,
    required String projectId,
    required String userId,
    String? endDate,
    String role = 'contributor',
  }) => {
    'membership_id': membershipId,
    'project_id': projectId,
    'user_id': userId,
    'join_date': t,
    'end_date': endDate,
    'role': role,
    'created_at': t,
    'updated_at': t,
    'revision': 0,
  };

  test('the upgrade preserves every existing membership row', () async {
    final db = await openV7();
    await seedUserAndProject(db, userId: 'user-1', projectId: 'proj-1');
    await db.insert(
      Tables.projectMemberships,
      membershipRow(
        membershipId: 'mem-1',
        projectId: 'proj-1',
        userId: 'user-1',
        role: 'owner',
      ),
    );

    await runMigrations(db, from: 7, to: 8);

    final rows = await db.query(Tables.projectMemberships);
    expect(rows, hasLength(1));
    expect(rows.single['membership_id'], 'mem-1');
    expect(rows.single['role'], 'owner');

    await db.close();
  });

  test(
    'a second open membership for the same person and project is refused',
    () async {
      final db = await openV7();
      await seedUserAndProject(db, userId: 'user-1', projectId: 'proj-1');
      await runMigrations(db, from: 7, to: 8);

      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-1',
          projectId: 'proj-1',
          userId: 'user-1',
        ),
      );

      // Exactly the shape two concurrent invitation acceptances would leave
      // behind if the code check alone had lost the race.
      await expectLater(
        db.insert(
          Tables.projectMemberships,
          membershipRow(
            membershipId: 'mem-2',
            projectId: 'proj-1',
            userId: 'user-1',
          ),
          conflictAlgorithm: ConflictAlgorithm.abort,
        ),
        throwsA(isA<DatabaseException>()),
      );

      final rows = await db.query(Tables.projectMemberships);
      expect(rows, hasLength(1));

      await db.close();
    },
  );

  test(
    'a rejoin — a closed row plus a fresh open one — is still allowed',
    () async {
      final db = await openV7();
      await seedUserAndProject(db, userId: 'user-1', projectId: 'proj-1');
      await runMigrations(db, from: 7, to: 8);

      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-1',
          projectId: 'proj-1',
          userId: 'user-1',
          endDate: t,
        ),
      );
      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-2',
          projectId: 'proj-1',
          userId: 'user-1',
        ),
      );

      final rows = await db.query(Tables.projectMemberships);
      expect(rows, hasLength(2));

      await db.close();
    },
  );

  test(
    'the same person may hold an open membership in two different projects',
    () async {
      final db = await openV7();
      await seedUserAndProject(db, userId: 'user-1', projectId: 'proj-1');
      await seedUserAndProject(db, userId: 'user-2', projectId: 'proj-2');
      await runMigrations(db, from: 7, to: 8);

      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-1',
          projectId: 'proj-1',
          userId: 'user-1',
        ),
      );
      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-2',
          projectId: 'proj-2',
          userId: 'user-1',
        ),
      );

      final rows = await db.query(Tables.projectMemberships);
      expect(rows, hasLength(2));

      await db.close();
    },
  );

  test(
    'two different people may each hold an open membership in one project',
    () async {
      final db = await openV7();
      await seedUserAndProject(db, userId: 'user-1', projectId: 'proj-1');
      await db.insert(Tables.users, {
        'user_id': 'user-2',
        'first_name': 'Alex',
        'last_name': 'Ranger',
        'email': 'user-2@example.com',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });
      await runMigrations(db, from: 7, to: 8);

      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-1',
          projectId: 'proj-1',
          userId: 'user-1',
        ),
      );
      await db.insert(
        Tables.projectMemberships,
        membershipRow(
          membershipId: 'mem-2',
          projectId: 'proj-1',
          userId: 'user-2',
        ),
      );

      final rows = await db.query(Tables.projectMemberships);
      expect(rows, hasLength(2));

      await db.close();
    },
  );
}
