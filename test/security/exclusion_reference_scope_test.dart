import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/analysis/analysis_eligibility.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation_exclusion.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_exclusion_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';

/// **Task 11.9 — the reference question `Observation_Exclusions` had never been
/// asked.**
///
/// An exclusion row names the observation it takes out of analysis, and there
/// is deliberately no foreign key on either side of the wire tying that name to
/// an observation the writer may see (`schema.dart`'s three reasons, restated
/// on `RowValidator`). `sync_tables.dart` justifies the absence of an
/// `observationColumns` set with one sentence — *"the observation this row
/// names is always in the same project, so the ordinary project scope already
/// carries it"* — and **nothing in the code enforces that sentence.** The
/// server was measured accepting a mark that names another project's
/// observation (`scripts/verify_11_9_team_surface.py`, probe 1); it is refused
/// only when the row's *own* `project_id` is foreign, which is a different
/// question.
///
/// So the sentence is not a constraint. What makes it harmless is a *second*
/// property, which is what this file puts on trial: **every consumer of a mark
/// resolves it inside one project.** The mark and the observation are matched
/// by `observation_id` alone, so if either read reached across projects, a
/// mark written in a project the attacker belongs to would silently retire an
/// observation in a project they do not — and the person who loses the bearing
/// is whoever happens to be a member of both.
///
/// Observation ids are v4 UUIDs, so a collision is not something to wait for —
/// but it is something to *arrange*, and Phase 6.3's replica import is the
/// supported way: a shared observation keeps its identity when it lands in
/// another project, which is exactly how one id comes to exist in two. The
/// fixture below builds that state directly.
///
/// Each test carries its own positive control in the same body: the identical
/// mark, aimed inside its own project, must take the observation out. Without
/// it a filter that returned nothing at all would report a clean sweep, which
/// is the failure mode eight consecutive gates found in this project's own
/// instruments.
void main() {
  late AppDatabase database;
  late ObservationRepository observations;
  late ObservationExclusionRepository marks;

  final at = DateTime.utc(2026, 8, 22, 9, 0, 0);

  /// The one observation id that exists in **both** projects — the state
  /// Phase 6.3's replica import produces, and the only state in which a
  /// cross-project reference could bite.
  const shared = 'obs-shared-identity';

  SyncMeta metaFor(String userId) =>
      SyncMeta.initial(now: at, modifiedBy: userId, originDeviceId: 'device-1');

  ObservationExclusion markOf({
    required String projectId,
    required String observationId,
    required String id,
    ObservationExclusionKind kind = ObservationExclusionKind.superseded,
  }) => ObservationExclusion(
    exclusionId: id,
    projectId: projectId,
    observationId: observationId,
    userId: 'user-1',
    kind: kind,
    sync: metaFor('user-1'),
  );

  setUp(() async {
    database = await AppDatabase.openInMemory();
    final users = UserRepository(database.raw);
    final projects = ProjectRepository(database.raw);
    final memberships = ProjectMembershipRepository(database.raw);
    observations = ObservationRepository(database.raw);
    marks = ObservationExclusionRepository(database.raw);

    await users.insert(sampleUser());

    // Two projects on one device, which is the ordinary case for anyone who
    // works on more than one study. The attacker is a contributor in
    // `project-attacker`; the victim's data lives in `project-victim`.
    for (final id in ['project-attacker', 'project-victim']) {
      await projects.insert(sampleProject(id: id));
      await memberships.insert(
        sampleMembership(id: 'membership-$id', projectId: id),
        authority: MembershipInsertAuthority.bootstrapOwner(),
      );
    }
    // A tag in each project. Since task 11.219 a tag belongs to one project,
    // so the two are separate rows rather than one row linked twice.
    for (final id in ['project-attacker', 'project-victim']) {
      await TagRepository(
        database.raw,
      ).insert(sampleTag(id: 'tag-$id', projectId: id));
    }

    // The same observation id in both projects — a replica, exactly as
    // `SharedObservationImporter` produces one.
    for (final id in ['project-attacker', 'project-victim']) {
      await observations.insert(
        sampleObservation(
          id: shared,
          projectId: id,
          tagId: 'tag-$id',
          sessionId: null,
        ),
      );
    }
    // And one observation that exists only in the victim's project, so a mark
    // naming it from the attacker's project has nothing local to hide behind.
    await observations.insert(
      sampleObservation(
        id: 'obs-victim-only',
        projectId: 'project-victim',
        tagId: 'tag-project-victim',
        sessionId: null,
      ),
    );
  });

  tearDown(() => database.close());

  test('a mark written in one project does not reach an identically-keyed '
      'observation in another', () async {
    await marks.insert(
      markOf(
        projectId: 'project-attacker',
        observationId: shared,
        id: 'mark-across',
      ),
    );

    final victimMarks = await marks.activeByObservation('project-victim');
    expect(
      victimMarks,
      isEmpty,
      reason: 'a mark scoped to another project reached this one',
    );

    final victimRows = await observations.findByProject('project-victim');
    expect(
      AnalysisEligibility.eligible(victimRows, victimMarks).map((o) => o.observationId),
      containsAll(<String>[shared, 'obs-victim-only']),
      reason: 'the victim project lost an observation to a foreign mark',
    );

    // POSITIVE CONTROL, same run: the identical mark inside its own project
    // does take the observation out. Without this, a filter that matched
    // nothing would pass every assertion above.
    final attackerMarks = await marks.activeByObservation('project-attacker');
    expect(attackerMarks.keys, [shared]);
    final attackerRows = await observations.findByProject('project-attacker');
    expect(
      AnalysisEligibility.eligible(attackerRows, attackerMarks),
      isEmpty,
      reason: 'the control did not fire — this test measured nothing',
    );
  });

  test('a mark naming an observation that is not in its project at all is '
      'inert rather than corrupting', () async {
    await marks.insert(
      markOf(
        projectId: 'project-attacker',
        observationId: 'obs-victim-only',
        id: 'mark-foreign',
      ),
    );
    await marks.insert(
      markOf(
        projectId: 'project-attacker',
        observationId: 'no-such-observation-anywhere',
        id: 'mark-ghost',
      ),
    );

    final victimMarks = await marks.activeByObservation('project-victim');
    expect(victimMarks, isEmpty);
    final victimRows = await observations.findByProject('project-victim');
    expect(
      AnalysisEligibility.eligible(victimRows, victimMarks),
      hasLength(victimRows.length),
      reason: 'a dangling reference removed a bearing from the analysis',
    );

    // The attacker's own project keeps both dangling marks and loses nothing,
    // because nothing there carries those ids either.
    final attackerMarks = await marks.activeByObservation('project-attacker');
    expect(attackerMarks.keys, hasLength(2));
    final attackerRows = await observations.findByProject('project-attacker');
    expect(
      AnalysisEligibility.eligible(attackerRows, attackerMarks),
      hasLength(attackerRows.length),
    );

    // POSITIVE CONTROL: a mark that DOES name a local observation still bites.
    await marks.insert(
      markOf(
        projectId: 'project-attacker',
        observationId: shared,
        id: 'mark-local',
      ),
    );
    final withLocal = await marks.activeByObservation('project-attacker');
    expect(
      AnalysisEligibility.eligible(attackerRows, withLocal),
      isEmpty,
      reason: 'the control did not fire — this test measured nothing',
    );
  });

  test('the withdrawal history is scoped the same way', () async {
    await marks.insert(
      markOf(
        projectId: 'project-attacker',
        observationId: shared,
        id: 'mark-withdrawn',
      ),
    );
    final stored = (await marks.findByProject('project-attacker')).single;
    await marks.withdraw(
      stored,
      actor: const MutationActor.user('user-1'),
      deviceId: 'device-1',
    );

    expect(await marks.withdrawnByObservation('project-victim'), isEmpty);
    // POSITIVE CONTROL: it is there, in the project it belongs to.
    expect(
      (await marks.withdrawnByObservation('project-attacker')).keys,
      [shared],
      reason: 'the control did not fire — this test measured nothing',
    );
  });
}
