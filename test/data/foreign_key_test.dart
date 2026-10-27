import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';

import 'fixtures.dart';

void main() {
  late AppDatabase database;
  late UserRepository users;
  late ProjectRepository projects;
  late ObservationRepository observations;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    users = UserRepository(database.raw);
    projects = ProjectRepository(database.raw);
    observations = ObservationRepository(database.raw);
  });

  tearDown(() async {
    await database.close();
  });

  test('inserting a project with a missing owner is rejected', () async {
    // No user inserted first — owner_user_id violates the FK.
    expect(
      () => projects.insert(sampleProject(ownerUserId: 'ghost-user')),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('a valid user -> project chain inserts successfully', () async {
    await users.insert(sampleUser());
    await projects.insert(sampleProject());

    final loaded = await projects.findById('project-1');
    expect(loaded, isNotNull);
    expect(loaded!.ownerUserId, 'user-1');
  });

  test('inserting an observation with a dangling tag is rejected', () async {
    await users.insert(sampleUser());
    await projects.insert(sampleProject());
    // tag-1 was never inserted, so tag_id violates the FK.
    expect(
      () => observations.insert(
        sampleMinimalObservation(),
      ),
      throwsA(isA<DatabaseException>()),
    );
  });
}
