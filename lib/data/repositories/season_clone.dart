import 'package:sqflite/sqflite.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:uuid/uuid.dart';

import '../db/data_arrival.dart';
import '../models/deployment.dart';
import '../models/project.dart';
import '../models/project_membership.dart';
import '../models/sync_meta.dart';
import 'actual_tag_location_repository.dart';
import 'deployment_repository.dart';
import 'estimated_position_repository.dart';
import 'individual_repository.dart';
import 'project_membership_repository.dart';
import 'project_repository.dart';
import 'tag_repository.dart';

/// What a season clone does with each synced table (task 11.56).
///
/// **This is the table-by-table answer the plan asked for, and it is a list
/// with a guard rather than a list.** `season_clone_test.dart` asserts that
/// every table in `Tables.all` has an entry here, so a table added next month
/// is a red test naming it rather than a season that silently leaves the new
/// thing behind — or silently carries it across. Each value below is also
/// checked against what [SeasonClone.clone] actually wrote, so the map cannot
/// say one thing while the code does another.
enum SeasonCloneDisposition {
  /// Not project data at all — people and their addresses. Nothing to copy.
  global,

  /// The one new `Projects` row itself: the study area, the settings, the
  /// description, a fresh id, the creator as owner, and the source's lineage.
  theProject,

  /// **Exactly one row, for the creator, as owner.** Michael's decision of
  /// 2026-08-29, settled and not re-opened: members do not carry over.
  /// Copying a membership row would put people into a project without their
  /// acting, which task 11.55 refuses and task 11.24's rule exists to
  /// prevent. Last season's team joins the new one the way anybody joins any
  /// project — the owner publishes it and shares its join code, and each
  /// person asks. (The decision was worded as *invitations*; task 11.81
  /// replaced those with the join code, and the consequence is unchanged:
  /// people join by their own action.)
  creatorOnly,

  /// Copied with a fresh id, the same `lineage_id`, and `copied_at` set —
  /// exactly what `TagRepository.copyFromLibrary` does for one collar.
  copied,

  /// Copied where **both** ends were copied, with both ends re-pointed at
  /// the new project's rows and the dates carried unchanged. A deployment
  /// names a tag and an animal, and re-pointing one end without the other
  /// makes a link that spans two projects — the class of mistake task 11.239
  /// spent a task on, one table over. `season_clone_test.dart` asserts on
  /// every copied deployment that both ends are the new project's.
  copiedIfBothEndsWere,

  /// **Not copied as rows; each copied tag starts a fresh history.** Task
  /// 11.32 made a bearing remember what its tag read when it was taken, and a
  /// version row is that memory *for the bearings of one project*. Last
  /// season's readings are what last season's bearings point at, and they
  /// stay beside those bearings. The new project's first version is what its
  /// tag reads on the day the season starts — the copied frequency — and
  /// next season's re-tuned collar is then an ordinary drift recorded against
  /// that. Carrying the old chain forward would put rows in the new project
  /// that nothing in it can ever reference, and would claim, per row, that
  /// the tag read that value *in this project* over a period before this
  /// project existed. Comparing two seasons is done through `lineage_id` in
  /// an export, which is what it is for.
  freshHistory,

  /// Last season's observations. **Never copied** — the whole point of a new
  /// season is that they stay where they were taken.
  notCopied,

  /// **Only if the person asks, and then only the most recent one per copied
  /// animal.** Michael, 2026-09-16: a crew going back out wants to know where
  /// each animal was last, to re-establish contact — so the last position
  /// estimate and the last truth point of each animal come across, and
  /// nothing else from either table does. "Of each animal" is decided the
  /// way a bearing's animal is: by which animal wore the collar at the row's
  /// moment (`DeploymentRepository.animalForObservationIn`), so a collar that
  /// was on nobody at the time carries nothing, and a collar that moved
  /// between two animals carries one row for each.
  ///
  /// Two columns are not carried as they were. A truth point's `user_id`
  /// names who found it, and the server refuses a *new* row that names
  /// anybody but the pusher (`DenialReason.namesForeignUser`) — so a copy
  /// naming last season's finder would sit on the phone unpushable forever.
  /// It keeps the finder when that is the person cloning and records none
  /// otherwise, which is what a null there already means. Its
  /// `tag_version_id` names a version in last season's chain; the copy
  /// carries none rather than point at a version the point was never
  /// recorded against. An estimate's `observation_ids_used` **is** carried:
  /// it is the honest record of what the estimate was computed from, the
  /// column is unvalidated by design and feeds nothing that decides access
  /// (`unvalidatedIdListColumns`), and the bearings it names still exist —
  /// in last season's project, where they belong.
  lastKnownPerAnimal,
}

/// The disposition of every synced table. Guarded, not trusted — see
/// [SeasonCloneDisposition].
const Map<String, SeasonCloneDisposition> seasonCloneDispositions = {
  Tables.users: SeasonCloneDisposition.global,
  Tables.userEmails: SeasonCloneDisposition.global,
  Tables.projects: SeasonCloneDisposition.theProject,
  Tables.projectMemberships: SeasonCloneDisposition.creatorOnly,
  Tables.individuals: SeasonCloneDisposition.copied,
  Tables.tags: SeasonCloneDisposition.copied,
  Tables.deployments: SeasonCloneDisposition.copiedIfBothEndsWere,
  Tables.tagVersions: SeasonCloneDisposition.freshHistory,
  Tables.triangulationSessions: SeasonCloneDisposition.notCopied,
  Tables.observations: SeasonCloneDisposition.notCopied,
  Tables.observationExclusions: SeasonCloneDisposition.notCopied,
  Tables.nonDetections: SeasonCloneDisposition.notCopied,
  Tables.estimatedPositions: SeasonCloneDisposition.lastKnownPerAnimal,
  Tables.actualTagLocations: SeasonCloneDisposition.lastKnownPerAnimal,
};

/// What a clone of [source] would copy — counted before anything is written,
/// so the screen can say what is about to happen with numbers rather than
/// with a description.
class SeasonClonePlan {
  const SeasonClonePlan({
    required this.source,
    required this.animals,
    required this.animalsRecordedDead,
    required this.collars,
    required this.collarRecords,
    required this.collarRecordsWithoutBothEnds,
    required this.lastKnownEstimates,
    required this.lastKnownTruthPoints,
  });

  final Project source;

  /// Live animals in the source, including the dead ones.
  final int animals;

  /// Of [animals], those whose status is `dead` — the ones the person may
  /// choose to leave behind.
  final int animalsRecordedDead;

  /// Live collars in the source.
  final int collars;

  /// Deployments whose collar and animal are both live in the source. These
  /// copy; if the person leaves the dead animals behind, the ones on a dead
  /// animal do not (see [SeasonCloneResult.collarRecords]).
  final int collarRecords;

  /// Deployments the clone will skip because their collar or their animal is
  /// no longer in the source project (removed, but the link was not). Zero on
  /// any project the app's own screens built; reported rather than hidden
  /// because a nonzero value is a fact about the source worth a sentence.
  final int collarRecordsWithoutBothEnds;

  /// How many animals have a last known position estimate to bring over —
  /// one row each, counted over every live animal in the source.
  final int lastKnownEstimates;

  /// How many animals have a last known truth point to bring over.
  final int lastKnownTruthPoints;
}

/// What a clone wrote.
class SeasonCloneResult {
  const SeasonCloneResult({
    required this.project,
    required this.animals,
    required this.collars,
    required this.collarRecords,
    required this.lastKnownEstimates,
    required this.lastKnownTruthPoints,
  });

  final Project project;
  final int animals;
  final int collars;
  final int collarRecords;
  final int lastKnownEstimates;
  final int lastKnownTruthPoints;
}

/// Starts a new season's project from last season's (task 11.56).
///
/// The case, in Michael's words: going back out for another field season
/// with a similar team, *"mostly the same animals but a few new chicks and a
/// few mortalities"*, reusing the same collars or re-tuning them. The team,
/// the animals, the collars and the study area carry over; **last season's
/// observations must not.** [seasonCloneDispositions] is the table-by-table
/// statement of that.
///
/// **One transaction**, for the reason `IndividualMerge` gives: a clone that
/// wrote the project and half the animals and then failed would leave a
/// season a person cannot use and cannot easily delete either. Nothing is
/// visible until all of it is.
///
/// **Who may do this: any current member of the source.** Cloning reads
/// what §4.21.4 already lets every role read, and writes only into a project
/// the person creates and owns — which is P1, creating a project, and open to
/// everybody. The source is not touched.
class SeasonClone {
  SeasonClone(this.database);

  final Database database;

  static const _uuid = Uuid();

  /// Counts what [clone] would copy from [sourceProjectId], writing nothing.
  ///
  /// Throws [ArgumentError] when the source is not a live project on this
  /// device — a screen mistake, not a state to report.
  Future<SeasonClonePlan> plan(String sourceProjectId) async {
    final source = await ProjectRepository(database).findById(sourceProjectId);
    if (source == null) {
      throw ArgumentError('no live project $sourceProjectId on this device');
    }
    final individuals = await IndividualRepository(
      database,
    ).findByProject(sourceProjectId);
    final tags = await TagRepository(database).findByProject(sourceProjectId);
    final deployments = await DeploymentRepository(
      database,
    ).findByProject(sourceProjectId);
    final liveTagIds = {for (final t in tags) t.tagId};
    final liveIndividualIds = {for (final i in individuals) i.individualId};
    final withBothEnds = deployments
        .where(
          (d) =>
              liveTagIds.contains(d.tagId) &&
              liveIndividualIds.contains(d.individualId),
        )
        .length;
    final lastEstimates = _lastPerAnimal(
      await EstimatedPositionRepository(
        database,
      ).findByProject(sourceProjectId),
      deployments,
      animals: liveIndividualIds,
      tagOf: (e) => e.tagId,
      at: (e) => e.timestampUtc,
    );
    final lastTruthPoints = _lastPerAnimal(
      await ActualTagLocationRepository(
        database,
      ).findByProject(sourceProjectId),
      deployments,
      animals: liveIndividualIds,
      tagOf: (l) => l.tagId,
      at: (l) => l.timestampUtc,
    );
    return SeasonClonePlan(
      source: source,
      animals: individuals.length,
      animalsRecordedDead: individuals
          .where((i) => i.status == IndividualStatus.dead)
          .length,
      collars: tags.length,
      collarRecords: withBothEnds,
      collarRecordsWithoutBothEnds: deployments.length - withBothEnds,
      lastKnownEstimates: lastEstimates.length,
      lastKnownTruthPoints: lastTruthPoints.length,
    );
  }

  /// The most recent of [rows] for each animal in [animals], attributed the
  /// way a bearing is — by the deployment covering the row's moment. A row
  /// whose collar was on nobody then, or on two animals at once (a data
  /// error the interlock should have refused), belongs to no animal here.
  static Map<String, T> _lastPerAnimal<T>(
    Iterable<T> rows,
    Iterable<Deployment> deployments, {
    required Set<String> animals,
    required String Function(T) tagOf,
    required DateTime Function(T) at,
  }) {
    final last = <String, T>{};
    for (final row in rows) {
      final animal = DeploymentRepository.animalForObservationIn(
        deployments,
        tagId: tagOf(row),
        at: at(row),
      ).sole;
      if (animal == null || !animals.contains(animal)) continue;
      final held = last[animal];
      if (held == null || at(row).isAfter(at(held))) last[animal] = row;
    }
    return last;
  }

  /// Creates the new project and copies into it. See the class comment and
  /// [seasonCloneDispositions] for what copies.
  ///
  /// [includeAnimalsRecordedDead] — whether a bird recorded as dead last
  /// season comes across (as dead: status copies, and a dead bird does not
  /// come back to life). Which way this should default is Michael's call and
  /// the screen puts the choice to him with the count; the engine takes a
  /// value and has no opinion.
  ///
  /// [includeLastKnownPositions] — whether each copied animal's most recent
  /// position estimate and most recent truth point come across
  /// ([SeasonCloneDisposition.lastKnownPerAnimal]). Michael asked for this on
  /// 2026-09-16 and for it to default to on; the default lives on the screen.
  ///
  /// Throws [ArgumentError] for a missing source or an empty [name], and
  /// whatever the repositories throw — a viewer of the source is *not*
  /// refused (they own the new project), but `OverlappingDeployment` from a
  /// source whose links already break the interlock rolls the whole clone
  /// back rather than writing a season the app's own screens would refuse.
  Future<SeasonCloneResult> clone({
    required String sourceProjectId,
    required String name,
    required String creatorUserId,
    required bool includeAnimalsRecordedDead,
    required bool includeLastKnownPositions,
    String? deviceId,
    DateTime? now,
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('a season needs a name');
    final at = now ?? DateTime.now();
    final result = await database.transaction((txn) async {
      final projects = ProjectRepository(txn);
      final source = await projects.findById(sourceProjectId);
      if (source == null) {
        throw ArgumentError('no live project $sourceProjectId on this device');
      }
      final sync = SyncMeta.initial(
        now: at,
        modifiedBy: creatorUserId,
        originDeviceId: deviceId,
      );

      // 1. The project. Study area, settings, description and notes carry
      //    over as a starting point; the id, the owner and the creation date
      //    are new; the lineage is the source's, so an export can tell the
      //    two seasons are one study.
      final project = Project(
        projectId: _uuid.v4(),
        projectName: trimmed,
        description: source.description,
        notes: source.notes,
        ownerUserId: creatorUserId,
        creationDate: at,
        bboxMinLat: source.bboxMinLat,
        bboxMinLon: source.bboxMinLon,
        bboxMaxLat: source.bboxMaxLat,
        bboxMaxLon: source.bboxMaxLon,
        datum: source.datum,
        coordinateFormat: source.coordinateFormat,
        triangulationWindowMinutes: source.triangulationWindowMinutes,
        lineageId: source.effectiveLineageId,
        copiedAt: at,
        // Task 11.331: the same field site, so the same zone.
        timeZone: source.timeZone,
        sync: sync,
      );
      await projects.insert(project);

      // 2. The creator's owner row — and nobody else's. This has to come
      //    before any other write into the new project, because every insert
      //    below asks the role gradient whether the creator may write it.
      await ProjectMembershipRepository(txn).insert(
        ProjectMembership(
          membershipId: _uuid.v4(),
          projectId: project.projectId,
          userId: creatorUserId,
          joinDate: at,
          role: ProjectRole.owner,
          sync: sync,
        ),
        authority: const MembershipInsertAuthority.bootstrapOwner(),
      );

      // 3. The animals, before the collars' links can name them.
      final individuals = IndividualRepository(txn);
      final individualIds = <String, String>{};
      for (final animal in await individuals.findByProject(sourceProjectId)) {
        if (!includeAnimalsRecordedDead &&
            animal.status == IndividualStatus.dead) {
          continue;
        }
        final copy = animal.copyWith(
          individualId: _uuid.v4(),
          projectId: project.projectId,
          copiedAt: at.toUtc(),
          sync: sync,
        );
        await individuals.insert(copy);
        individualIds[animal.individualId] = copy.individualId;
      }

      // 4. The collars. `insert` writes each one's first version row, which
      //    is the fresh history `SeasonCloneDisposition.freshHistory` argues
      //    for. Not recorded in the tag library: the collar is already there
      //    if this person created it, and is somebody else's if not — the
      //    same reasoning as `copyFromLibrary`.
      final tags = TagRepository(txn);
      final tagIds = <String, String>{};
      for (final tag in await tags.findByProject(sourceProjectId)) {
        final copy = tag.copyWith(
          tagId: _uuid.v4(),
          projectId: project.projectId,
          copiedAt: at.toUtc(),
          sync: sync,
        );
        await tags.insert(copy, recordInLibrary: false);
        tagIds[tag.tagId] = copy.tagId;
      }

      // 5. The links, last, and only where both ends came across. Through
      //    `link` so the interlock is asked of the copies exactly as it was
      //    of the originals.
      final deployments = DeploymentRepository(txn);
      final sourceLinks = await deployments.findByProject(sourceProjectId);
      var collarRecords = 0;
      for (final link in sourceLinks) {
        final tagId = tagIds[link.tagId];
        final individualId = individualIds[link.individualId];
        if (tagId == null || individualId == null) continue;
        await deployments.link(
          Deployment(
            deploymentId: _uuid.v4(),
            projectId: project.projectId,
            tagId: tagId,
            individualId: individualId,
            attachedDate: link.attachedDate,
            removedDate: link.removedDate,
            notes: link.notes,
            sync: sync,
            // Task 11.331: each copied record keeps the zone its days were
            // written in, so they stay the same days in the new season.
            timeZone: link.timeZone,
          ),
        );
        collarRecords += 1;
      }

      // 6. Where each animal was last, if asked. Attributed against the
      //    *source's* links, because that is where the row's moment lives;
      //    written against the new project's collar. A row whose collar did
      //    not copy has nothing to hang on and is skipped.
      var lastKnownEstimates = 0;
      var lastKnownTruthPoints = 0;
      if (includeLastKnownPositions) {
        final copiedAnimals = individualIds.keys.toSet();
        final estimates = EstimatedPositionRepository(txn);
        final lastEstimates = _lastPerAnimal(
          await estimates.findByProject(sourceProjectId),
          sourceLinks,
          animals: copiedAnimals,
          tagOf: (e) => e.tagId,
          at: (e) => e.timestampUtc,
        );
        for (final estimate in lastEstimates.values) {
          final tagId = tagIds[estimate.tagId];
          if (tagId == null) continue;
          await estimates.insert(
            estimate.copyWith(
              positionId: _uuid.v4(),
              projectId: project.projectId,
              tagId: tagId,
              sync: sync,
            ),
          );
          lastKnownEstimates += 1;
        }
        final truthPoints = ActualTagLocationRepository(txn);
        final lastTruthPoints = _lastPerAnimal(
          await truthPoints.findByProject(sourceProjectId),
          sourceLinks,
          animals: copiedAnimals,
          tagOf: (l) => l.tagId,
          at: (l) => l.timestampUtc,
        );
        for (final point in lastTruthPoints.values) {
          final tagId = tagIds[point.tagId];
          if (tagId == null) continue;
          await truthPoints.insert(
            point.copyWith(
              locationId: _uuid.v4(),
              projectId: project.projectId,
              tagId: tagId,
              // See `SeasonCloneDisposition.lastKnownPerAnimal` for both.
              tagVersionId: null,
              userId: point.userId == creatorUserId ? creatorUserId : null,
              sync: sync,
            ),
          );
          lastKnownTruthPoints += 1;
        }
      }

      return SeasonCloneResult(
        project: project,
        animals: individualIds.length,
        collars: tagIds.length,
        collarRecords: collarRecords,
        lastKnownEstimates: lastKnownEstimates,
        lastKnownTruthPoints: lastKnownTruthPoints,
      );
    });
    // One announcement for the whole clone, after it is committed (task
    // 11.45's rule) — the projects list and every per-project reader learn
    // about the new season at once.
    DataArrival.announce();
    return result;
  }
}
