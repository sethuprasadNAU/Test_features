import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/models/estimated_position.dart';
import 'package:tritrack/data/models/individual.dart';
import 'package:tritrack/data/models/non_detection.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/tag_library_entry.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack/data/models/triangulation_session.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/models/user_email.dart';

/// Deterministic model builders for tests. All timestamps are fixed so
/// round-trip equality is stable. Times use whole seconds because ISO-8601
/// text storage does not preserve sub-second precision uniformly.

final _now = DateTime.utc(2026, 7, 16, 18, 30, 0);
final _localNow = _now.toLocal();

/// **Puts [userIds] on [projectId] as contributors, as raw rows** — the fixture
/// task 11.237 made necessary.
///
/// Every repository write is gated on the person the row's `last_modified_by`
/// names, and since 11.237 that gate refuses somebody the device can see is
/// **not on the project** — the read-only-snapshot rule. A test that plants a
/// colleague's tag or bearing through a repository in a project owned by
/// somebody else is planting it *as* that colleague, so the colleague has to
/// be on the project first, exactly as they would be on a phone. This seeds
/// that in one line, skipping anybody who already holds an open row so a
/// test that grants a role of its own does not collide with
/// `idx_memberships_one_open`.
///
/// Raw rather than through `ProjectMembershipRepository`, because a fixture is
/// a fact about the world the test starts in, not an act somebody performed.
Future<void> seedContributors(
  DatabaseExecutor db, {
  required String projectId,
  required Iterable<String> userIds,
}) async {
  final open = await db.query(
    Tables.projectMemberships,
    columns: ['user_id'],
    where: 'project_id = ? AND end_date IS NULL AND deleted_at IS NULL',
    whereArgs: [projectId],
  );
  final already = {for (final row in open) row['user_id'] as String};
  for (final userId in {...userIds}) {
    if (already.contains(userId)) continue;
    // A membership names a user the schema insists exists. A fixture's audit
    // stamp (`sampleSync` says `user-1`) often names nobody the test ever
    // created, so a placeholder profile is written for anyone missing — and
    // only for them, so a test that inserts the real person later still can.
    final exists = await db.query(
      Tables.users,
      columns: ['user_id'],
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (exists.isEmpty) {
      await db.insert(
        Tables.users,
        sampleUser(id: userId, email: '$userId@seeded.example').toColumns(),
      );
    }
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'seeded-membership-$projectId-$userId',
        projectId: projectId,
        userId: userId,
        role: ProjectRole.contributor,
      ).toColumns(),
    );
  }
}

SyncMeta sampleSync() => SyncMeta.initial(
      now: _now,
      modifiedBy: 'user-1',
      originDeviceId: 'device-A',
    );

User sampleUser({String id = 'user-1', String email = 'coco@example.com'}) =>
    User(
      userId: id,
      firstName: 'Sam',
      lastName: 'Ranger',
      email: email,
      sync: sampleSync(),
    );

UserEmail sampleUserEmail({
  String id = 'user-email-1',
  String userId = 'user-1',
  String email = 'old@example.com',
}) =>
    UserEmail(
      userEmailId: id,
      userId: userId,
      email: email,
      recordedAt: _now,
      sync: sampleSync(),
    );

Project sampleProject({
  String id = 'project-1',
  String ownerUserId = 'user-1',
}) =>
    Project(
      projectId: id,
      projectName: 'Mesa Coyotes',
      description: 'Winter range study',
      notes: 'Canis latrans',
      ownerUserId: ownerUserId,
      creationDate: _now,
      bboxMinLat: 35.1,
      bboxMinLon: -111.7,
      bboxMaxLat: 35.3,
      bboxMaxLon: -111.5,
      sync: sampleSync(),
    );

ProjectMembership sampleMembership({
  String id = 'membership-1',
  String projectId = 'project-1',
  String userId = 'user-1',
  ProjectRole role = ProjectRole.owner,
  DateTime? endDate,
}) =>
    ProjectMembership(
      membershipId: id,
      projectId: projectId,
      userId: userId,
      joinDate: _now,
      endDate: endDate,
      role: role,
      sync: sampleSync(),
    );

/// **The mode columns default to null, and that is the interesting case**
/// (task 11.187). A tag row pushed by a build that predates schema v12 has
/// exactly this shape, and it must read as one mode called "Normal" rather than
/// as a collar with no modes — see `buildPulseModes`. A test about named modes
/// passes them explicitly.
Tag sampleTag({
  String id = 'tag-1',
  String projectId = 'project-1',
  String? lineageId,
  DateTime? copiedAt,
  String colorHex = TagColorPalette.defaultColor,
  String tagName = 'Coco',
  double frequencyMhz = 150.325,
  double? pulseRate = 40,
  String? pulseMode1Name,
  String? pulseMode2Name,
  double? pulseMode2RateBpm,
  String? pulseMode3Name,
  double? pulseMode3RateBpm,
  /// Who the row says wrote it. `sampleSync` stamps `user-1`; a test whose
  /// project is owned by somebody else, and which inserts through a
  /// repository, names a member here — since task 11.237 the repository
  /// refuses a stamp the device can see is not on the project.
  String? modifiedBy,
}) =>
    Tag(
      tagId: id,
      projectId: projectId,
      // **Defaults to the tag's own id, which is what every route that does
      // not copy produces** (task 11.219): the v14 migration set it that way
      // for every tag that predated lineages, and a tag created straight
      // into a project does the same. A test about copy-on-add passes an
      // explicit one to make two rows the same collar.
      lineageId: lineageId ?? id,
      copiedAt: copiedAt,
      frequencyMhz: frequencyMhz,
      pulseRate: pulseRate,
      pulsePattern: 'steady',
      tagName: tagName,
      status: TagStatus.active,
      notes: 'collar #12',
      colorHex: colorHex,
      pulseMode1Name: pulseMode1Name,
      pulseMode2Name: pulseMode2Name,
      pulseMode2RateBpm: pulseMode2RateBpm,
      pulseMode3Name: pulseMode3Name,
      pulseMode3RateBpm: pulseMode3RateBpm,
      sync: modifiedBy == null
          ? sampleSync()
          : SyncMeta.initial(
              now: _now,
              modifiedBy: modifiedBy,
              originDeviceId: 'device-A',
            ),
    );

/// Task 11.240: an animal. Defaults are a bird called Marie with the palette's
/// first colour. **A tag fixture that should be hers is linked with
/// [sampleDeployment]** (task 11.243) — nothing here links the two by name,
/// because nothing in the app does.
Individual sampleIndividual({
  String id = 'individual-1',
  String projectId = 'project-1',
  String name = 'Marie',
  String colorHex = TagColorPalette.defaultColor,
  IndividualStatus status = IndividualStatus.alive,
  String? species,
  IndividualSex? sex,
  String? lineageId,
  String? modifiedBy,
}) =>
    Individual(
      individualId: id,
      projectId: projectId,
      name: name,
      colorHex: colorHex,
      status: status,
      species: species,
      sex: sex,
      notes: null,
      lineageId: lineageId ?? id,
      sync: modifiedBy == null
          ? sampleSync()
          : SyncMeta.initial(
              now: _now,
              modifiedBy: modifiedBy,
              originDeviceId: 'device-A',
            ),
    );

/// **Task 11.243: the dated link.** Defaults put `tag-1` on `individual-1`
/// from a fixed date with no removed date — a collar that is on, now, which
/// is what most tests mean by "Marie's collar".
///
/// **`attachedDate` is explicit rather than defaulted to null**, because a
/// deployment with no attached date covers no interval and attributes no
/// bearings (design §4). A fixture that defaulted to null would silently make
/// every derivation test pass for the wrong reason;
/// `deployment_repository_test.dart` asks for that case by name.
Deployment sampleDeployment({
  String id = 'deployment-1',
  String projectId = 'project-1',
  String tagId = 'tag-1',
  String individualId = 'individual-1',
  DateTime? attachedDate,

  /// **Asks for the null-attached-date case by name**, because
  /// `attachedDate: null` cannot: null is what "use the default" looks like
  /// in a named optional, and a fixture that could not tell the two apart
  /// would silently give every caller a date. The case matters — a
  /// deployment with no attached date attributes no bearings at all.
  bool noAttachedDate = false,
  DateTime? removedDate,
  String? modifiedBy,
}) =>
    Deployment(
      deploymentId: id,
      projectId: projectId,
      tagId: tagId,
      individualId: individualId,
      attachedDate: noAttachedDate ? null : (attachedDate ?? _now),
      removedDate: removedDate,
      sync: modifiedBy == null
          ? sampleSync()
          : SyncMeta.initial(
              now: _now,
              modifiedBy: modifiedBy,
              originDeviceId: 'device-A',
            ),
    );

/// Task 11.32: what a tag read at the moment a record was taken.
///
/// Defaults match [sampleTag] exactly, so a fixture pair reads as "the tag has
/// not been edited since"; override a field to build the drift case a test is
/// actually about.
TagVersion sampleTagVersion({
  String id = 'tag-version-1',
  String projectId = 'project-1',
  String tagId = 'tag-1',
  String tagName = 'Coco',
  double frequencyMhz = 150.325,
  double? pulseRate = 40,
  String? pulsePattern = 'steady',
  DateTime? effectiveFrom,
  String? pulseMode1Name,
  String? pulseMode2Name,
  double? pulseMode2RateBpm,
  String? pulseMode3Name,
  double? pulseMode3RateBpm,
}) =>
    TagVersion(
      tagVersionId: id,
      projectId: projectId,
      tagId: tagId,
      effectiveFrom: effectiveFrom ?? _now,
      frequencyMhz: frequencyMhz,
      pulseRate: pulseRate,
      pulsePattern: pulsePattern,
      tagName: tagName,
      pulseMode1Name: pulseMode1Name,
      pulseMode2Name: pulseMode2Name,
      pulseMode2RateBpm: pulseMode2RateBpm,
      pulseMode3Name: pulseMode3Name,
      pulseMode3RateBpm: pulseMode3RateBpm,
      sync: sampleSync(),
    );

/// An entry in this device's personal tag library (task 11.219).
///
/// Defaults match [sampleTag] so a fixture pair reads as "the project's tag
/// was copied from this entry"; that is what an equal `lineageId` means, and
/// it is why the two default to the same one.
TagLibraryEntry sampleTagLibraryEntry({
  String id = 'library-tag-1',
  String? lineageId = 'tag-1',
  String colorHex = TagColorPalette.defaultColor,
  String tagName = 'Coco',
  double frequencyMhz = 150.325,
  double? pulseRate = 40,
}) =>
    TagLibraryEntry(
      tagId: id,
      lineageId: lineageId ?? id,
      frequencyMhz: frequencyMhz,
      pulseRate: pulseRate,
      pulsePattern: 'steady',
      tagName: tagName,
      status: TagStatus.active,
      notes: 'collar #12',
      colorHex: colorHex,
      sync: sampleSync(),
    );

TriangulationSession sampleSession({
  String id = 'session-1',
  String projectId = 'project-1',
  String tagId = 'tag-1',
}) =>
    TriangulationSession(
      sessionId: id,
      projectId: projectId,
      tagId: tagId,
      label: 'Coco morning fix',
      startedAtLocal: _localNow,
      startedAtUtc: _now,
      startedAtOffset: '-07:00',
      notes: 'ridge line',
      sync: sampleSync(),
    );

/// Observation with every optional field populated — exercises the full
/// column set for round-trip coverage.
Observation sampleObservation({
  String id = 'obs-1',
  String projectId = 'project-1',
  String userId = 'user-1',
  String tagId = 'tag-1',
  String? sessionId = 'session-1',
  String? tagVersionId = 'tag-version-1',
  double latitude = 35.19,
  double longitude = -111.62,
  /// **Null by default, which is the shape of every bearing recorded before
  /// schema v12** (task 11.187) — read through `signalType` instead. Pass a
  /// slot, and `signalType` follows it: `Observation` asserts the two agree,
  /// because a caller free to set them independently is how they come to
  /// disagree about one bearing.
  int? pulseMode,
  /// **Null by default, and that is the shape of every bearing recorded
  /// before schema v13** (task 11.193): nobody was asked whether the signal
  /// sounded wrong. `false` is a different answer — somebody had the control
  /// in front of them and did not tick it — so a fixture that wants that says
  /// so.
  bool? signalIrregular,

  /// **When the bearing was taken.** Defaults to the fixture's fixed `now`;
  /// a test about *which animal a bearing was about* passes one, because
  /// that derivation is a question about time (task 11.244, design §7) and a
  /// fixture where every bearing shares one instant cannot ask it.
  DateTime? timestampUtc,
}) =>
    Observation(
      observationId: id,
      projectId: projectId,
      userId: userId,
      tagId: tagId,
      sessionId: sessionId,
      timestampLocal: timestampUtc?.toLocal() ?? _localNow,
      timestampUtc: timestampUtc ?? _now,
      timezoneOffset: '-07:00',
      latitude: latitude,
      longitude: longitude,
      positionAccuracyM: 8.5,
      positionSource: PositionSource.gpsFix,
      elevation: 2103.0,
      altitudeAgl: 1.5,
      observationType: ObservationType.directional,
      magneticBearing: 145.0,
      trueNorthBearing: 155.2,
      bearingUncertainty: 12.0,
      bearingCaptureMethod: BearingCaptureMethod.rangeCapture,
      bearingMethod: BearingMethod.peak,
      magneticBearingStart: 140.0,
      magneticBearingEnd: 150.0,
      trueNorthBearingStart: 150.2,
      trueNorthBearingEnd: 160.2,
      magneticDeclination: 10.2,
      wmmModelVersion: 'WMM2025',
      antennaType: 'yagi_3el',
      receiverGain: 3.0,
      pulseMode: pulseMode,
      signalIrregular: signalIrregular,
      signalType: SignalType.forPulseModeSlot(pulseMode),
      signalStrength: SignalStrength.medium,
      bearingQuality: BearingQuality.good,
      notes: 'clear signal',
      tagVersionId: tagVersionId,
      sync: sampleSync(),
    );

/// Observation with all optionals null — exercises the null path.
Observation sampleMinimalObservation({
  String id = 'obs-min',
  String projectId = 'project-1',
  String userId = 'user-1',
  String tagId = 'tag-1',
}) =>
    Observation(
      observationId: id,
      projectId: projectId,
      userId: userId,
      tagId: tagId,
      timestampLocal: _localNow,
      timestampUtc: _now,
      timezoneOffset: '-07:00',
      latitude: 35.19,
      longitude: -111.62,
      positionSource: PositionSource.manualEntry,
      elevation: 2103.0,
      observationType: ObservationType.omnidirectional,
      signalType: SignalType.mortalitySignal,
      signalStrength: SignalStrength.veryStrong,
      sync: sampleSync(),
    );

NonDetection sampleNonDetection({
  String id = 'nd-1',
  String projectId = 'project-1',
  String userId = 'user-1',
}) =>
    NonDetection(
      nonDetectionId: id,
      projectId: projectId,
      userId: userId,
      timestampLocal: _localNow,
      timestampUtc: _now,
      timezoneOffset: '-07:00',
      latitude: 35.2,
      longitude: -111.6,
      positionAccuracyM: 6.0,
      positionSource: PositionSource.gpsFix,
      elevation: 2100.0,
      tagIdsListenedFor: const ['tag-1', 'tag-2'],
      notes: 'quiet',
      sync: sampleSync(),
    );

EstimatedPosition sampleEstimatedPosition({
  String id = 'est-1',
  String projectId = 'project-1',
  String tagId = 'tag-1',
}) =>
    EstimatedPosition(
      positionId: id,
      projectId: projectId,
      tagId: tagId,
      timestampLocal: _localNow,
      timestampUtc: _now,
      timezoneOffset: '-07:00',
      latitude: 35.195,
      longitude: -111.615,
      semiMajorAxis: 120.0,
      semiMinorAxis: 60.0,
      rotationAngle: 42.0,
      method: EstimationMethod.lenthMle,
      observationIdsUsed: const ['obs-1', 'obs-2', 'obs-3'],
      notes: 'good geometry',
      sync: sampleSync(),
    );

ActualTagLocation sampleActualLocation({
  String id = 'loc-1',
  String projectId = 'project-1',
  String tagId = 'tag-1',
  GroundTruthKind? foundKind = GroundTruthKind.animalAndCollar,
  String? tagVersionId = 'tag-version-1',
  // Task 11.93. Defaulted to the values a point recorded today carries; pass
  // null for either to build the pre-schema-v11 row, whose author and position
  // source are genuinely not recorded.
  String? userId = 'user-1',
  PositionSource? positionSource = PositionSource.gpsFix,
}) =>
    ActualTagLocation(
      locationId: id,
      projectId: projectId,
      tagId: tagId,
      timestampLocal: _localNow,
      timestampUtc: _now,
      timezoneOffset: '-07:00',
      latitude: 35.196,
      longitude: -111.616,
      uncertaintyRadius: 15.0,
      notes: 'found collar',
      foundKind: foundKind,
      tagVersionId: tagVersionId,
      userId: userId,
      positionSource: positionSource,
      sync: sampleSync(),
    );
