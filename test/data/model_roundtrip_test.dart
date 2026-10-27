import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/actual_tag_location_repository.dart';
import 'package:tritrack/data/repositories/estimated_position_repository.dart';
import 'package:tritrack/data/repositories/non_detection_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/triangulation_session_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'fixtures.dart';

/// Round-trips every model through the real database. Because insert uses
/// `toColumns` and read uses `fromRow` against the actual schema, any
/// column-name mismatch, type-coercion bug, or missing column surfaces here
/// (either as a SQLite error on insert or a failed equality on read).
void main() {
  late AppDatabase database;

  setUp(() async {
    database = await AppDatabase.openInMemory();
  });

  tearDown(() async {
    await database.close();
  });

  // Insert the FK parents once so child round-trips have valid references.
  Future<void> seedGraph() async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());
    await TriangulationSessionRepository(database.raw).insert(sampleSession());
  }

  test('User round-trips', () async {
    final repo = UserRepository(database.raw);
    final user = sampleUser();
    await repo.insert(user);
    expect(await repo.findById('user-1'), user);
  });

  test('Project round-trips (including default datum)', () async {
    await UserRepository(database.raw).insert(sampleUser());
    final repo = ProjectRepository(database.raw);
    final project = sampleProject();
    await repo.insert(project);
    final loaded = await repo.findById('project-1');
    expect(loaded, project);
    expect(loaded!.datum, 'WGS84');
  });

  test('ProjectMembership round-trips', () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    final repo = ProjectMembershipRepository(database.raw);
    final membership = sampleMembership();
    await repo.insert(
      membership,
      authority: const MembershipInsertAuthority.bootstrapOwner(),
    );
    expect(await repo.findById('membership-1', projectId: 'project-1'), membership);
  });

  test('Tag round-trips (composite key)', () async {
    // Keyed `(tag_id, project_id)` since task 11.219, so this is where the
    // composite round-trip is exercised — it used to be `ProjectTag`, whose
    // `(project_id, tag_id)` pair was the identity of a link. That table
    // left the wire with copy-on-add.
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    final repo = TagRepository(database.raw);
    final tag = sampleTag();
    // **`insert` stores the tag it was handed and nothing else** (task
    // 11.243). It created an animal per collar at v16; a tag is equipment
    // now, so a collar with no animal is the normal starting state.
    final stored = await repo.insert(tag);
    expect(stored, tag);
    // Read back, the colour is the neutral constant and there is no animal
    // name, because no deployment says there is one.
    expect(
      await repo.findById('tag-1', projectId: 'project-1'),
      tag.copyWith(colorHex: TagColorPalette.noIndividual),
    );
  });

  test('Individual round-trips (composite key)', () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    final repo = IndividualRepository(database.raw);
    final individual = sampleIndividual();
    await repo.insert(individual);
    expect(
      await repo.findById('individual-1', projectId: 'project-1'),
      individual,
    );
  });

  test('TagLibraryEntry round-trips', () async {
    // Device-local, so no project and no role — see `TagLibraryRepository`.
    final repo = TagLibraryRepository(database.raw);
    final entry = sampleTagLibraryEntry();
    await repo.insert(entry);
    expect(await repo.findById(entry.tagId), entry);
  });

  test('TriangulationSession round-trips (local/utc/offset triple)', () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());
    final repo = TriangulationSessionRepository(database.raw);
    final session = sampleSession();
    await repo.insert(session);
    expect(await repo.findById('session-1', projectId: 'project-1'), session);
  });

  test('Observation round-trips with all optional fields populated', () async {
    await seedGraph();
    final repo = ObservationRepository(database.raw);
    final obs = sampleObservation();
    await repo.insert(obs);
    expect(await repo.findById('obs-1', projectId: 'project-1'), obs);
  });

  test('Observation round-trips with all optionals null', () async {
    await seedGraph();
    final repo = ObservationRepository(database.raw);
    final obs = sampleMinimalObservation();
    await repo.insert(obs);
    final loaded = await repo.findById('obs-min', projectId: 'project-1');
    expect(loaded, obs);
    expect(loaded!.altitudeAgl, 0);
  });

  test('NonDetection round-trips (JSON tag list)', () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    final repo = NonDetectionRepository(database.raw);
    final nd = sampleNonDetection();
    await repo.insert(nd);
    final loaded = await repo.findById('nd-1', projectId: 'project-1');
    expect(loaded, nd);
    expect(loaded!.tagIdsListenedFor, ['tag-1', 'tag-2']);
  });

  test('EstimatedPosition round-trips (JSON observation list + ellipse)',
      () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());
    final repo = EstimatedPositionRepository(database.raw);
    final est = sampleEstimatedPosition();
    await repo.insert(est);
    final loaded = await repo.findByProjectAndTag('project-1', 'tag-1');
    expect(loaded, hasLength(1));
    expect(loaded.first, est);
  });

  test('ActualTagLocation round-trips', () async {
    await UserRepository(database.raw).insert(sampleUser());
    await ProjectRepository(database.raw).insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());
    final repo = ActualTagLocationRepository(database.raw);
    final loc = sampleActualLocation();
    await repo.insert(loc);
    final loaded = await repo.findByProjectAndTag('project-1', 'tag-1');
    expect(loaded.first, loc);
  });

  test('email is normalized on insert for cross-device dedup', () async {
    final repo = UserRepository(database.raw);
    await repo.insert(sampleUser(id: 'u-mixed', email: '  Coco@Example.COM '));
    final loaded = await repo.findById('u-mixed');
    expect(loaded!.email, 'coco@example.com');
  });
}
