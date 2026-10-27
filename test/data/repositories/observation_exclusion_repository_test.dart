import 'package:flutter_test/flutter_test.dart';
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
import 'package:uuid/uuid.dart';

import '../fixtures.dart';

/// **Task 11.7.** Two things are on trial here.
///
/// **First, that neither superseding nor excluding touches the observation.**
/// Phases 6 and 8 went to deliberate trouble to keep an observation's
/// authorship and measurements the property of the person who recorded them —
/// an observation is a primary scientific record, and an owner rewriting a
/// colleague's field note breaks provenance in a way that matters to a
/// publication, a permit or an enforcement action. The plan doc says a test
/// must assert that rather than a comment claiming it, because a future task
/// will otherwise "simplify" this feature into plain edit access on the row.
/// `preserves the original byte for byte` below is that test.
///
/// **Second, the role gradient**, which for this feature is not uniform:
/// superseding is contributor-level on anyone's row, excluding is owner-only.
/// The reasoning is on `exclusionVerdict` and
/// `ObservationExclusionRepository.assertMayMark`.
void main() {
  late AppDatabase database;
  late UserRepository users;
  late ProjectRepository projects;
  late ProjectMembershipRepository memberships;
  late ObservationRepository observations;
  late ObservationExclusionRepository marks;

  const ownerActor = MutationActor.user('user-1');
  final at = DateTime.utc(2026, 8, 21, 9, 0, 0);

  SyncMeta metaFor(String userId) =>
      SyncMeta.initial(now: at, modifiedBy: userId, originDeviceId: 'device-1');

  ObservationExclusion markOf(
    String observationId, {
    required String byUserId,
    required ObservationExclusionKind kind,
    String? replacement,
    String? id,
  }) => ObservationExclusion(
    exclusionId: id ?? const Uuid().v4(),
    projectId: 'project-1',
    observationId: observationId,
    userId: byUserId,
    kind: kind,
    supersededByObservationId: replacement,
    sync: metaFor(byUserId),
  );

  /// The stored row, straight out of SQLite — not through the model, because
  /// what is on trial is the columns.
  Future<Map<String, Object?>> storedObservation(String id) async {
    final rows = await database.raw.query(
      Tables.observations,
      where: 'observation_id = ? AND project_id = ?',
      whereArgs: [id, 'project-1'],
    );
    return rows.single;
  }

  setUp(() async {
    database = await AppDatabase.openInMemory();
    users = UserRepository(database.raw);
    projects = ProjectRepository(database.raw);
    memberships = ProjectMembershipRepository(database.raw);
    observations = ObservationRepository(database.raw);
    marks = ObservationExclusionRepository(database.raw);

    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'other@example.com'));
    await projects.insert(sampleProject());
    await memberships.insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
    await TagRepository(database.raw).insert(sampleTag());

    // The observation under test belongs to user-2, so every check below is
    // about somebody acting on *another person's* record. Planted as a raw
    // row — the shape of a bearing that arrived by sync — because user-2 is
    // not on the project until each test says which role they hold, and
    // since task 11.237 a repository refuses a write by somebody the device
    // can see is not on the project.
    await database.raw.insert(
      Tables.observations,
      sampleObservation(
        id: 'obs-theirs',
        userId: 'user-2',
        sessionId: null,
      ).copyWith(sync: metaFor('user-2')).toColumns(),
    );
    await observations.insert(
      sampleObservation(
        id: 'obs-replacement',
        userId: 'user-1',
        sessionId: null,
      ).copyWith(sync: metaFor('user-1')),
    );
  });

  tearDown(() => database.close());

  Future<void> joinAs(ProjectRole role) => memberships.insert(
    sampleMembership(id: 'membership-2', userId: 'user-2', role: role),
    authority: MembershipInsertAuthority.byOwner(ownerActor),
  );

  group('the original observation is never written', () {
    test('preserves the original byte for byte — every column, including '
        'user_id, last_modified_by, revision and every measurement', () async {
      final before = await storedObservation('obs-theirs');

      // Both actions, by the project's owner, on a row they did not author.
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-supersede',
        ),
      );
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-exclude',
        ),
      );

      final after = await storedObservation('obs-theirs');

      // Whole-row equality rather than a list of columns somebody has to keep
      // in step with the schema: a column added later is covered the day it is
      // added, and a future change that starts writing one fails here.
      expect(after, before);

      // Spelled out anyway for the three the plan names by name, so a failure
      // reads as the thing that actually went wrong rather than as a map diff.
      expect(after['user_id'], 'user-2');
      expect(after['last_modified_by'], 'user-2');
      expect(after['revision'], before['revision']);
      expect(after['updated_at'], before['updated_at']);
      expect(after['true_north_bearing'], before['true_north_bearing']);
      expect(after['deleted_at'], isNull);
    });

    test('and withdrawing a mark does not write it either', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final before = await storedObservation('obs-theirs');

      final stored = (await marks.findByProject('project-1')).single;
      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      expect(await storedObservation('obs-theirs'), before);
    });

    test('the observation stays readable and un-tombstoned — 11.7 requires it '
        'visible with its state shown, not hidden', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final o = await observations.findById(
        'obs-theirs',
        projectId: 'project-1',
      );
      expect(o, isNotNull);
      expect(o!.userId, 'user-2');
      expect(o.sync.deletedAt, isNull);
    });
  });

  group('who may mark', () {
    test(
      'a viewer may do neither, and is told what they would need to be',
      () async {
        await joinAs(ProjectRole.viewer);
        for (final kind in ObservationExclusionKind.values) {
          await expectLater(
            marks.insert(
              markOf(
                'obs-theirs',
                byUserId: 'user-2',
                kind: kind,
                id: 'm-$kind',
              ),
            ),
            throwsA(isA<UnauthorizedMutation>()),
          );
        }
        expect(await marks.findByProject('project-1'), isEmpty);

        try {
          await marks.insert(
            markOf(
              'obs-theirs',
              byUserId: 'user-2',
              kind: ObservationExclusionKind.excluded,
            ),
          );
          fail('expected a refusal');
        } on UnauthorizedMutation catch (error) {
          expect(error.toString(), contains('owner'));
          expect(error.toString(), contains('viewer'));
        }
      },
    );

    test(
      "a contributor may supersede somebody else's observation — that is "
      'the whole point of the feature, since editing stays author-only',
      () async {
        await joinAs(ProjectRole.contributor);
        await marks.insert(
          markOf(
            'obs-replacement', // authored by user-1, marked by user-2
            byUserId: 'user-2',
            kind: ObservationExclusionKind.superseded,
            replacement: 'obs-theirs',
            id: 'mark-1',
          ),
        );
        expect(
          (await marks.activeByObservation('project-1')).keys,
          contains('obs-replacement'),
        );
      },
    );

    test('a contributor may not exclude — removing evidence with nothing in '
        "its place is the owner's data-quality rung", () async {
      await joinAs(ProjectRole.contributor);
      await expectLater(
        marks.insert(
          markOf(
            'obs-theirs',
            byUserId: 'user-2',
            kind: ObservationExclusionKind.excluded,
          ),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('an owner may do both', () async {
      await joinAs(ProjectRole.contributor);
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      await marks.insert(
        markOf(
          'obs-replacement',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-theirs',
          id: 'mark-2',
        ),
      );
      expect(await marks.findByProject('project-1'), hasLength(2));
    });
  });

  group('reversal', () {
    test('withdrawing takes the mark out of the live set and puts the '
        'observation back in analysis', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      expect(await marks.activeByObservation('project-1'), hasLength(1));

      final stored = (await marks.findByProject('project-1')).single;
      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      expect(await marks.activeByObservation('project-1'), isEmpty);
    });

    test('the withdrawal is a tombstone, not a delete — so it merges to other '
        'devices instead of resurrecting on the next sync', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final stored = (await marks.findByProject('project-1')).single;
      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      final rows = await marks.findByProject('project-1', includeDeleted: true);
      expect(rows, hasLength(1));
      expect(rows.single.sync.deletedAt, isNotNull);
      expect(rows.single.sync.revision, greaterThan(stored.sync.revision));
    });

    test("a contributor cannot withdraw an owner's exclusion — the mark is "
        'the marker\'s row', () async {
      await joinAs(ProjectRole.contributor);
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final stored = (await marks.findByProject('project-1')).single;
      await expectLater(
        marks.withdraw(
          stored,
          actor: const MutationActor.user('user-2'),
          deviceId: 'device-1',
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });
  });

  /// **Task 11.15 — an owner must be able to withdraw a contributor's mark.**
  ///
  /// Task 11.7 made a mark the marker's own row and stopped there, which left
  /// a hole with a name: a contributor who marks a bearing as replaced by
  /// mistake and then leaves the project makes that mark **permanent**. No
  /// owner could undo it and neither could the observation's own author, so a
  /// bearing that belongs in a publication or a permit stays discarded and the
  /// one person who could explain it is gone.
  ///
  /// The fix is [MutationRule.authorOrOwner] in the shared rule table, not a
  /// hand-rolled check at the withdraw call site. What is on trial here is the
  /// enforcement of it against a real database — both arms of the disjunction,
  /// and that widening it did not widen anything else.
  group('who may withdraw a mark (task 11.15)', () {
    /// A supersede made by `user-2`, a contributor — the mark this task is
    /// about. Excluding is owner-only to make, so only a supersede can be
    /// authored by someone who is not an owner in the first place.
    Future<ObservationExclusion> contributorSupersede() async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-2',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-1',
        ),
      );
      return (await marks.findByProject('project-1')).single;
    }

    test("an owner can withdraw a contributor's supersede", () async {
      await joinAs(ProjectRole.contributor);
      final stored = await contributorSupersede();

      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      expect(await marks.activeByObservation('project-1'), isEmpty);
    });

    test("the mark's own author can still withdraw it", () async {
      // The arm task 11.7 already had. Widening the rule must not cost it.
      await joinAs(ProjectRole.contributor);
      final stored = await contributorSupersede();

      await marks.withdraw(
        stored,
        actor: const MutationActor.user('user-2'),
        deviceId: 'device-1',
      );

      expect(await marks.activeByObservation('project-1'), isEmpty);
    });

    test('an unrelated contributor cannot withdraw somebody else\'s '
        'supersede', () async {
      await joinAs(ProjectRole.contributor);
      await users.insert(sampleUser(id: 'user-3', email: 'third@example.com'));
      await memberships.insert(
        sampleMembership(
          id: 'membership-3',
          userId: 'user-3',
          role: ProjectRole.contributor,
        ),
        authority: MembershipInsertAuthority.byOwner(ownerActor),
      );
      final stored = await contributorSupersede();

      await expectLater(
        marks.withdraw(
          stored,
          actor: const MutationActor.user('user-3'),
          deviceId: 'device-1',
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await marks.activeByObservation('project-1'), hasLength(1));
    });

    test('the case that motivates the task: the author has left the project '
        'and an owner can still withdraw', () async {
      await joinAs(ProjectRole.contributor);
      final stored = await contributorSupersede();

      // user-2 leaves. Their membership is closed, exactly as the owner
      // dashboard closes it — the mark row itself is untouched and still
      // names them, which is why the author-only rule stranded it.
      await memberships.update(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.contributor,
          endDate: at,
        ),
        actor: ownerActor,
      );
      expect(
        (await memberships.findForUser('project-1', 'user-2'))?.role,
        isNull,
        reason:
            'the author must genuinely be off the project for this test '
            'to be testing anything',
      );

      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      expect(await marks.activeByObservation('project-1'), isEmpty);
    });

    test('widening withdrawal did not widen exclusion: an owner-made '
        'exclusion is still owner-only to undo', () async {
      // The rung and the authorship are separate questions, and 11.15 only
      // widened the second. The person here is the mark's *own author*, so
      // after this task they pass the authorship arm — and must still be
      // refused, because they were demoted out of the rung that exclusion
      // sits on. Nothing but the kind check stands between them and undoing
      // an owner-level judgement they no longer hold.
      await joinAs(ProjectRole.owner);
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-2',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final stored = (await marks.findByProject('project-1')).single;
      await memberships.update(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.contributor,
        ),
        actor: ownerActor,
      );

      await expectLater(
        marks.withdraw(
          stored,
          actor: const MutationActor.user('user-2'),
          deviceId: 'device-1',
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    /// The screen and the repository must give the same answer, or the menu
    /// renders a live "Count in estimates again" that throws at the tap —
    /// task 11.12's standing complaint, and exactly what the old
    /// `canExclude || canSupersede` guess produced once 11.7 shipped.
    ///
    /// This asserts the agreement rather than restating the rule, so a change
    /// to either side that the other does not follow is a failure here.
    test(
      'the screen affordance and the repository agree, case for case',
      () async {
        await joinAs(ProjectRole.contributor);
        await users.insert(
          sampleUser(id: 'user-3', email: 'third@example.com'),
        );
        await memberships.insert(
          sampleMembership(
            id: 'membership-3',
            userId: 'user-3',
            role: ProjectRole.contributor,
          ),
          authority: MembershipInsertAuthority.byOwner(ownerActor),
        );

        // (actor, is that actor an owner, their standing on the project)
        const actors = [
          // owner, not the mark's author
          ('user-1', true, ProjectStanding.member(ProjectRole.owner)),
          // contributor, the mark's author
          ('user-2', false, ProjectStanding.member(ProjectRole.contributor)),
          // contributor, a bystander
          ('user-3', false, ProjectStanding.member(ProjectRole.contributor)),
        ];

        for (final (actorId, isOwner, standing) in actors) {
          await marks.insert(
            markOf(
              'obs-theirs',
              byUserId: 'user-2',
              kind: ObservationExclusionKind.superseded,
              replacement: 'obs-replacement',
              id: 'mark-$actorId',
            ),
          );
          final stored = (await marks.findByProject(
            'project-1',
          )).firstWhere((m) => m.exclusionId == 'mark-$actorId');

          final screenSays = withdrawMarkVerdict(
            standing: standing,
            isOwner: isOwner,
            actorUserId: actorId,
            markUserId: stored.userId,
            markKind: stored.kind,
          );

          var repositoryAllowed = true;
          try {
            await marks.withdraw(
              stored,
              actor: MutationActor.user(actorId),
              deviceId: 'device-1',
            );
          } on UnauthorizedMutation {
            repositoryAllowed = false;
          }

          expect(
            screenSays.canWithdraw,
            repositoryAllowed,
            reason: 'the menu and the repository disagree for $actorId',
          );
          if (!screenSays.canWithdraw) {
            expect(
              screenSays.reason,
              isNotNull,
              reason: 'a disabled control must say why (task 11.12)',
            );
          }
        }
      },
    );
  });

  /// **Task 11.18.** 11.15 let an owner withdraw a contributor's mark, and
  /// left the contributor with no way to find out. The information already
  /// exists on the tombstoned row — [ObservationExclusion.userId] never
  /// changes, so it still names whoever made the mark, and
  /// [SyncMeta.lastModifiedBy] is overwritten with the withdrawer's id by
  /// [BaseRepository.softDeleteByKey]. This is what
  /// [ObservationExclusionRepository.withdrawnByObservation] is on trial for:
  /// that both halves survive and can be told apart.
  group('withdrawn-mark history for display (task 11.18)', () {
    // The marks below are made by user-2, some of them exclusions, which are
    // owner-only. This group is about what is *displayed* afterwards, not
    // about who may mark — so user-2 is simply an owner here. (Until task
    // 11.237 a user with no membership row was permitted by deferral; the
    // device can now see they are not on the project, and refuses.)
    setUp(() => joinAs(ProjectRole.owner));

    Future<void> setDeletedAt(String exclusionId, DateTime at) =>
        database.raw.update(
          Tables.observationExclusions,
          {'deleted_at': at.toUtc().toIso8601String()},
          where: 'exclusion_id = ? AND project_id = ?',
          whereArgs: [exclusionId, 'project-1'],
        );

    test('a withdrawn mark is returned, keyed by its observation, still '
        'naming its original author and now naming its withdrawer', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-2',
          kind: ObservationExclusionKind.excluded,
          id: 'mark-1',
        ),
      );
      final stored = (await marks.findByProject('project-1')).single;
      await marks.withdraw(stored, actor: ownerActor, deviceId: 'device-1');

      final withdrawn = await marks.withdrawnByObservation('project-1');
      expect(withdrawn.keys, ['obs-theirs']);
      final row = withdrawn['obs-theirs']!;
      expect(
        row.userId,
        'user-2',
        reason: 'the original marker — untouched by withdrawal',
      );
      expect(
        row.sync.lastModifiedBy,
        'user-1',
        reason: 'the withdrawer, per softDeleteByKey',
      );
      expect(row.sync.isDeleted, isTrue);
    });

    test(
      'a live mark that has never been withdrawn does not appear here',
      () async {
        await marks.insert(
          markOf(
            'obs-theirs',
            byUserId: 'user-2',
            kind: ObservationExclusionKind.excluded,
            id: 'mark-1',
          ),
        );
        expect(await marks.withdrawnByObservation('project-1'), isEmpty);
      },
    );

    test('an observation marked again after a withdrawal appears in both '
        'the live map and the withdrawn-history map at once', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-2',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-1',
        ),
      );
      final first = (await marks.findByProject('project-1')).single;
      await marks.withdraw(first, actor: ownerActor, deviceId: 'device-1');

      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-2',
        ),
      );

      expect(
        (await marks.activeByObservation('project-1')).keys,
        contains('obs-theirs'),
      );
      expect(
        (await marks.withdrawnByObservation('project-1')).keys,
        contains('obs-theirs'),
      );
    });

    test('when an observation has more than one withdrawn mark, the most '
        'recently withdrawn one is shown', () async {
      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-2',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-old',
        ),
      );
      final old = (await marks.findByProject('project-1')).single;
      await marks.withdraw(old, actor: ownerActor, deviceId: 'device-1');
      await setDeletedAt('mark-old', DateTime.utc(2026, 1, 1));

      await marks.insert(
        markOf(
          'obs-theirs',
          byUserId: 'user-1',
          kind: ObservationExclusionKind.superseded,
          replacement: 'obs-replacement',
          id: 'mark-new',
        ),
      );
      final fresh = (await marks.findByProject(
        'project-1',
      )).firstWhere((m) => m.exclusionId == 'mark-new');
      await marks.withdraw(
        fresh,
        actor: const MutationActor.user('user-1'),
        deviceId: 'device-1',
      );
      await setDeletedAt('mark-new', DateTime.utc(2026, 6, 1));

      final withdrawn = await marks.withdrawnByObservation('project-1');
      expect(withdrawn['obs-theirs']!.exclusionId, 'mark-new');
    });
  });
}
