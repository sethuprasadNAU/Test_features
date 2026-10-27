import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the actual on-device upgrade path for schema v5 (Phase 7's
/// `User_Emails` table) — a database opened at v4 with an existing user must
/// upgrade cleanly to v5 and be able to record that user's prior email.
void main() {
  test('upgrading a v4 database adds a usable User_Emails table', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 4, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 4);

    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': '2026-07-16T18:30:00.000Z',
      'updated_at': '2026-07-16T18:30:00.000Z',
      'revision': 0,
    });

    await runMigrations(db, from: 4, to: latestSchemaVersion);

    await db.insert(Tables.userEmails, {
      'user_email_id': 'ue-1',
      'user_id': 'user-1',
      'email': 'old@example.com',
      'recorded_at': '2026-07-01T00:00:00.000Z',
      'created_at': '2026-07-16T18:30:00.000Z',
      'updated_at': '2026-07-16T18:30:00.000Z',
      'revision': 0,
    });

    final rows = await db.query(Tables.userEmails);
    expect(rows.single['email'], 'old@example.com');
    expect(rows.single['user_id'], 'user-1');

    await db.close();
  });
}
