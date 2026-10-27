import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/estimated_position_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.3, the client's half.** The server is the authority — see
/// `server/test/integration/member_authorization_test.dart`, which proves every
/// one of these over a real socket with no app involved. What this file is
/// about is the app *agreeing*: a `viewer`'s device should refuse the write at
/// the point of the tap rather than record it happily and accumulate one
/// permanently-refused row per sync.
///
/// The rule tested here is narrower than the server's on purpose, and the last
/// group is why.
void main() {
  late AppDatabase database;
  late UserRepository users;
  late ProjectRepository projects;
  late ProjectMembershipRepository memberships;
  late ObservationRepository observations;
  late EstimatedPositionRepository estimates;

  const owner = MutationActor.user('user-1');
  const member = MutationActor.user('user-2');
  final at = DateTime.utc(2026, 7, 16, 18, 30, 0);

  /// A row built as the app builds one: `last_modified_by` is the acting user,
  /// which is what [BaseRepository.insertRow] reads to know who is inserting.
  SyncMeta metaFor(MutationActor actor) =>
      SyncMeta.initial(now: at, modifiedBy: actor.userId, originDeviceId: 'd');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    users = UserRepository(database.raw);
    projects = ProjectRepository(database.raw);
    memberships = ProjectMembershipRepository(database.raw);
    observations = ObservationRepository(database.raw);
    estimates = EstimatedPositionRepository(database.raw);

    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'other@example.com'));
    await projects.insert(sampleProject());
    await memberships.insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
    await TagRepository(database.raw).insert(sampleTag());
  });

  tearDown(() => database.close());

  Future<void> joinAs(ProjectRole role) => memberships.insert(
    sampleMembership(id: 'membership-2', userId: 'user-2', role: role),
    authority: MembershipInsertAuthority.byOwner(owner),
  );

  group('a viewer', () {
    setUp(() => joinAs(ProjectRole.viewer));

    test('cannot record an observation', () async {
      await expectLater(
        observations.insert(
          sampleObservation(
            id: 'obs-viewer',
            sessionId: null,
            userId: 'user-2',
          ).copyWith(sync: metaFor(member)),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await observations.findById('obs-viewer', projectId: 'project-1'),
          isNull);
    });

    test('cannot create a position estimate either — the anyUser tables are '
        'the half with no author column to stop them', () async {
      await expectLater(
        estimates.insert(
          sampleEstimatedPosition(id: 'est-viewer')
              .copyWith(sync: metaFor(member)),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('cannot edit or delete a row they wrote before their role changed',
        () async {
      // Seeded as a contributor's row, then the role is lowered. The gradient
      // is about the person now, not about who wrote the row.
      await observations.insert(
        sampleObservation(id: 'obs-old', sessionId: null, userId: 'user-2')
            .copyWith(sync: metaFor(owner)),
      );
      final row =
          (await observations.findById('obs-old', projectId: 'project-1'))!;
      await expectLater(
        observations.update(row.copyWith(notes: 'edited'), actor: member),
        throwsA(isA<UnauthorizedMutation>()),
      );
      await expectLater(
        observations.softDelete(row, actor: member),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('and the refusal says what they would need to be', () async {
      // A screen catching this has to be able to explain it to somebody
      // standing in a drainage, not print a rule name at them.
      try {
        await estimates.insert(
          sampleEstimatedPosition(id: 'est-msg')
              .copyWith(sync: metaFor(member)),
        );
        fail('expected a refusal');
      } on UnauthorizedMutation catch (error) {
        expect(error.toString(), contains('contributor or owner'));
        expect(error.toString(), contains('viewer'));
      }
    });
  });

  group('a contributor', () {
    setUp(() => joinAs(ProjectRole.contributor));

    test('may record an observation', () async {
      await observations.insert(
        sampleObservation(id: 'obs-carol', sessionId: null, userId: 'user-2')
            .copyWith(sync: metaFor(member)),
      );
      expect(
        await observations.findById('obs-carol', projectId: 'project-1'),
        isNotNull,
      );
    });

    test('and may write the shared tables recording depends on', () async {
      // "Contributor writes its own and nothing else" cannot mean *no shared
      // row*: recording one observation also writes a session row and may link
      // a tag, and neither table has an author column. Reading it that way
      // would leave the role unable to do the one thing it is for.
      await estimates.insert(
        sampleEstimatedPosition(id: 'est-carol')
            .copyWith(sync: metaFor(member)),
      );
      expect(await estimates.findById('est-carol', projectId: 'project-1'),
          isNotNull);
    });

    test('but still cannot touch another member\'s observation', () async {
      // Unchanged from Phase 8 — the rule table, not the gradient.
      await observations.insert(
        sampleObservation(sessionId: null).copyWith(sync: metaFor(owner)),
      );
      final row = (await observations.findById('obs-1',
          projectId: 'project-1'))!;
      await expectLater(
        observations.update(row.copyWith(notes: 'not mine'), actor: member),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('nor rename the project', () async {
      await expectLater(
        projects.update(
          sampleProject().copyWith(projectName: 'Seized'),
          actor: member,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });
  });

  group('an owner', () {
    test('may do all of it', () async {
      await observations.insert(
        sampleObservation(sessionId: null).copyWith(sync: metaFor(owner)),
      );
      await estimates.insert(
        sampleEstimatedPosition().copyWith(sync: metaFor(owner)),
      );
      expect(
        await projects.update(
          sampleProject().copyWith(projectName: 'Renamed'),
          actor: owner,
        ),
        1,
      );
    });
  });

  group('where the client deliberately does not decide', () {
    // The client refuses on an explicit `viewer`, and — since task 11.237 —
    // on a project it can *see* the person is not on. It still does not
    // refuse where it has nothing to answer with: the server refuses a caller
    // with no role, and this SQLite file legitimately contains projects the
    // device has no membership row for — a never-published project, pre-8.4
    // data whose backfill has not run. Those are answered by the creator
    // fallback and still write.

    test('a project with no membership rows at all still writes', () async {
      // Pre-8.4 data whose lazy backfill has not run, and the ordinary
      // never-published project: `Projects.owner_user_id` names the person.
      await database.raw.delete(Tables.projectMemberships);
      await observations.insert(
        sampleObservation(id: 'obs-backfill', sessionId: null)
            .copyWith(sync: metaFor(owner)),
      );
      expect(
        await observations.findById('obs-backfill', projectId: 'project-1'),
        isNotNull,
      );
    });

    test(
      'but a project imported from somebody else is a read-only snapshot '
      '(task 11.237)',
      () async {
        // A colleague's backup: their id is the creator, their membership row
        // is the only one, and this device holds nothing naming the person
        // using it. Until 11.237 this wrote — and the write could never leave
        // the device. Michael chose the refusal, and the refusal names the
        // way in.
        await projects.update(
          sampleProject(ownerUserId: 'user-1'),
          actor: owner,
        );
        await expectLater(
          observations.insert(
            sampleObservation(
              id: 'obs-imported',
              sessionId: null,
              userId: 'user-2',
            ).copyWith(sync: metaFor(member)),
          ),
          throwsA(
            isA<UnauthorizedMutation>().having(
              (e) => e.notAMember,
              'notAMember',
              isTrue,
            ),
          ),
        );
        expect(
          await observations.findById('obs-imported', projectId: 'project-1'),
          isNull,
        );
      },
    );

    test('replication is never subject to the gradient', () async {
      // `ProjectMerger` and `SharedObservationImporter` write raw statements
      // rather than going through a repository, so they never reach this check
      // — but a row that names no acting user at all must not be refused
      // either, or a legacy row with a null `last_modified_by` would be.
      await joinAs(ProjectRole.viewer);
      await observations.insert(
        sampleObservation(id: 'obs-replica', sessionId: null, userId: 'user-2')
            .copyWith(
          sync: SyncMeta.initial(now: at, modifiedBy: null, originDeviceId: 'd'),
        ),
      );
      expect(
        await observations.findById('obs-replica', projectId: 'project-1'),
        isNotNull,
      );
    });
  });
}
