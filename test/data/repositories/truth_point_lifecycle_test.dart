import 'package:csv/csv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/actual_tag_location_csv.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/actual_tag_location_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.92** — a truth point could be created and nothing else.
///
/// The harm, stated once: somebody walks in and finds the collar, records where
/// it actually was, and then a whole season of those points can leave the phone
/// only inside a full backup, cannot be listed anywhere, and cannot be
/// corrected. This file is the data half — the export carrying every field
/// through a real rename, and the delete being a delete you can undo.
void main() {
  late AppDatabase database;
  late TagRepository tags;
  late TagVersionRepository versions;
  late ActualTagLocationRepository truthPoints;

  const finder = MutationActor.user('user-1');
  final at = DateTime.utc(2026, 8, 22, 9, 0, 0);
  final later = DateTime.utc(2026, 10, 4, 9, 0, 0);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    final users = UserRepository(database.raw);
    final projects = ProjectRepository(database.raw);
    final memberships = ProjectMembershipRepository(database.raw);
    tags = TagRepository(database.raw);
    versions = TagVersionRepository(database.raw);
    truthPoints = ActualTagLocationRepository(database.raw);

    await users.insert(sampleUser());
    await projects.insert(sampleProject());
    await memberships.insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
    await tags.insert(
      sampleTag().copyWith(
        sync: SyncMeta.initial(
          now: at,
          modifiedBy: finder.userId,
          originDeviceId: 'device-A',
        ),
      ),
    );
  });

  tearDown(() => database.close());

  Future<Tag> storedTag() async => (await tags.findById('tag-1', projectId: 'project-1'))!;

  /// Records the truth point exactly as the Record screen does: pointed at
  /// whatever version the tag reads at the moment somebody stood in front of
  /// the collar.
  Future<void> recordTruthPoint({
    String id = 'loc-1',
    GroundTruthKind kind = GroundTruthKind.animalAndCollar,
  }) async {
    await versions.createInitialVersion(
      await storedTag(),
      now: at,
      modifiedBy: finder.userId,
      deviceId: 'device-A',
    );
    await truthPoints.insert(
      sampleActualLocation(
        id: id,
        foundKind: kind,
        tagVersionId: await versions.currentVersionIdFor('tag-1'),
      ),
    );
  }

  /// The export the Data Export screen produces, built the same way it builds
  /// it — the point of going through the repository rather than a hand-made
  /// `RecordedTagState` is that this exercises the wiring, not the formatter.
  Future<List<Object?>> exportedRow() async {
    final points = await truthPoints.findByProject('project-1');
    final tag = await storedTag();
    final states = await versions.recordedStatesForRows(
      [
        for (final p in points)
          (rowId: p.locationId, tagId: p.tagId, tagVersionId: p.tagVersionId),
      ],
      tagsById: {tag.tagId: tag},
    );
    final users = UserRepository(database.raw);
    final usersById = <String, User>{};
    for (final id in points.map((p) => p.userId).whereType<String>().toSet()) {
      final u = await users.findById(id, includeDeleted: true);
      if (u != null) usersById[id] = u;
    }
    final csvText = ActualTagLocationCsv.export(
      points,
      tagsById: {tag.tagId: tag},
      usersById: usersById,
      recordedStates: states,
    );
    final rows = Csv().decode(csvText);
    return [rows[0], ...rows.skip(1)];
  }

  Future<Object?> column(String name, {int row = 1}) async {
    final rows = await exportedRow();
    final header = (rows[0] as List).map((h) => h.toString()).toList();
    return (rows[row] as List)[header.indexOf(name)];
  }

  group('the export gets a truth point off the device', () {
    test('all seven fields are present for a point recorded today', () async {
      await recordTruthPoint();

      expect(await column('latitude'), '35.196');
      expect(await column('longitude'), '-111.616');
      expect(await column('precision_m'), '15.0');
      expect(await column('found_kind'), 'animal_and_collar');
      expect(await column('timestamp_utc'), isNot(''));
      expect(await column('tag_name'), 'Coco');
      expect(await column('tag_current_name'), 'Coco');
      // Task 11.93's two columns, through the same wiring.
      expect(await column('found_by'), 'Sam Ranger');
      expect(await column('position_source'), 'gps_fix');
    });

    // **The case the `tag_version_id` column was added for, and which nothing
    // had ever read.** A collar gets renamed the week the animal gets a name.
    test('after the tag is renamed, the recorded name is what it was called '
        'when it was found, and the current name is what it is called now',
        () async {
      await recordTruthPoint();

      await tags.update(
        (await storedTag()).copyWith(tagName: 'F-07 Juniper'),
        actor: finder,
        intent: TagEditIntent.change,
        now: later,
      );

      expect(
        await column('tag_name'),
        'Coco',
        reason: 'the collar somebody found was called Coco; an export made '
            'today has to line up with the one made before the rename',
      );
      expect(
        await column('tag_current_name'),
        'F-07 Juniper',
        reason: 'and this is the name the person reading the file recognises',
      );
    });

    test('a deleted truth point is not in the export', () async {
      await recordTruthPoint();
      final point = (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      await truthPoints.softDelete(point, actor: finder, deviceId: 'device-A');

      final rows = await exportedRow();
      expect(rows, hasLength(1), reason: 'the header alone');
    });
  });

  group('who found it, and who may change it (task 11.93)', () {
    /// Adds a second person to the project as a contributor — somebody who did
    /// **not** find the collar.
    Future<MutationActor> addContributor() async {
      final users = UserRepository(database.raw);
      final memberships = ProjectMembershipRepository(database.raw);
      await users.insert(sampleUser(id: 'user-2', email: 'driver@example.com'));
      await memberships.insert(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.contributor,
        ),
        // Granted by the project's owner, which is who adds a teammate.
        authority: const MembershipInsertAuthority.byOwner(finder),
      );
      return const MutationActor.user('user-2');
    }

    // **The gate this task was explicitly forbidden to tighten, asserted so the
    // next person to read the `user_id` column cannot "fix" it.**
    //
    // Michael settled it on 2026-08-31: recording who found a truth point does
    // not make editing it author-only, because **the person who saw the pride
    // and the person driving the truck may not be the same person.** A rule
    // that required the finder to make the correction would mean the only
    // person who can fix a point is the one who was looking through binoculars
    // while somebody else drove.
    test('a contributor who did not find the point can still edit it',
        () async {
      await recordTruthPoint();
      final driver = await addContributor();
      final point =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(point.userId, 'user-1', reason: 'found by somebody else');

      await truthPoints.update(
        point.copyWith(uncertaintyRadius: 40),
        actor: driver,
        deviceId: 'device-B',
      );

      final corrected =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(corrected.uncertaintyRadius, 40);
      expect(
        corrected.userId,
        'user-1',
        reason: 'correcting the figure does not make the driver the person '
            'who found the collar',
      );
      expect(
        corrected.sync.lastModifiedBy,
        'user-2',
        reason: 'who changed it is recorded too — in the column that means '
            'that, which is a different fact from who found it',
      );
    });

    test('a contributor who did not find the point can still delete it',
        () async {
      await recordTruthPoint();
      final driver = await addContributor();
      final point =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;

      await truthPoints.softDelete(point, actor: driver, deviceId: 'device-B');
      expect(await truthPoints.findByProject('project-1'), isEmpty);
    });

    // The screen's answer and the repository's must agree, or a control renders
    // disabled for a write that would in fact succeed — task 11.12's defect,
    // mirrored.
    test('the on-screen verdict does not consult authorship either', () {
      expect(
        truthPointEditVerdict(
          standing: const ProjectStanding.member(ProjectRole.contributor),
        ).canEdit,
        isTrue,
      );
      expect(
        truthPointEditVerdict(
          standing: const ProjectStanding.member(ProjectRole.viewer),
        ).canEdit,
        isFalse,
      );
    });

    // **The repository declares its rule by hand, and nothing else checks it
    // against the shared table.** Flipping `tableMutationRules` on its own
    // changed no client behaviour and turned no test red — measured while
    // writing these tests — so this asserts the two agree for the one table
    // this task is about. The general case is a finding, not a fix: see the
    // Discovered Scope entry for task 11.93.
    test('the repository is governed by the shared rule, not a local copy', () {
      expect(truthPoints.rule, MutationRule.anyUser);
      expect(truthPoints.rule, tableMutationRules[Tables.actualTagLocations]);
    });

    // **The no-backfill rule, at the storage layer.** A point written before
    // schema v11 records no finder and no position source, and reading it back
    // must produce null rather than a value invented from `last_modified_by`
    // or assumed to be a GPS fix.
    test('a point from before schema v11 reads back as not recorded',
        () async {
      await versions.createInitialVersion(
        await storedTag(),
        now: at,
        modifiedBy: finder.userId,
        deviceId: 'device-A',
      );
      await truthPoints.insert(
        sampleActualLocation(userId: null, positionSource: null),
      );

      final stored =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(stored.userId, isNull);
      expect(stored.positionSource, isNull);
      expect(
        stored.sync.lastModifiedBy,
        isNotNull,
        reason: 'the row does know who last touched it — which is exactly the '
            'value a backfill would have been tempted to use',
      );
    });

    // **Item 2 and item 3 of this task, together, which is why they shipped in
    // one migration.** Moving the position of a point that was a GPS fix makes
    // it a third thing; without the column that third thing would be
    // indistinguishable from a measurement.
    test('moving a fix by hand records it as a fix moved by hand', () async {
      await recordTruthPoint();
      final point =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(point.positionSource, PositionSource.gpsFix);

      await truthPoints.update(
        point.copyWith(
          latitude: 35.2,
          longitude: -111.62,
          positionSource: positionSourceAfterHandMove(point.positionSource),
        ),
        actor: finder,
        deviceId: 'device-A',
      );

      final moved =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(moved.latitude, 35.2);
      expect(
        moved.positionSource,
        PositionSource.gpsFixAdjusted,
        reason: 'it is no longer where the phone said it was, and it is not a '
            'pin placed from scratch either',
      );
    });
  });

  group('correcting and deleting', () {
    test('the precision can be corrected without touching what the point was '
        'recorded against', () async {
      await recordTruthPoint();
      final point = (await truthPoints.findById('loc-1', projectId: 'project-1'))!;

      await truthPoints.update(
        point.copyWith(
          uncertaintyRadius: 3,
          foundKind: GroundTruthKind.collarOnly,
        ),
        actor: finder,
        deviceId: 'device-A',
      );

      final corrected =
          (await truthPoints.findById('loc-1', projectId: 'project-1'))!;
      expect(corrected.uncertaintyRadius, 3);
      expect(corrected.foundKind, GroundTruthKind.collarOnly);
      expect(
        corrected.tagVersionId,
        point.tagVersionId,
        reason: 'correcting a precision figure today says nothing about what '
            'the collar was called when it was found',
      );
      expect(corrected.sync.revision, greaterThan(point.sync.revision));
    });

    // Deleting field data. The delete is soft, which is what makes the undo in
    // the snackbar a real undo rather than a re-creation under a new id — and
    // what stops the row resurrecting on the next sync.
    test('a delete is a tombstone, and the undo brings the same row back',
        () async {
      await recordTruthPoint();
      final point = (await truthPoints.findById('loc-1', projectId: 'project-1'))!;

      await truthPoints.softDelete(point, actor: finder, deviceId: 'device-A');
      expect(await truthPoints.findByProject('project-1'), isEmpty);
      final tombstoned = await truthPoints.findById(
        'loc-1',
        projectId: 'project-1',
        includeDeleted: true,
      );
      expect(tombstoned, isNotNull);
      expect(tombstoned!.sync.isDeleted, isTrue);

      await truthPoints.restore(point, actor: finder, deviceId: 'device-A');
      final restored = await truthPoints.findByProject('project-1');
      expect(restored, hasLength(1));
      expect(restored.single.locationId, 'loc-1');
      expect(
        restored.single.uncertaintyRadius,
        15.0,
        reason: 'the same row, not a new one',
      );
    });
  });
}
