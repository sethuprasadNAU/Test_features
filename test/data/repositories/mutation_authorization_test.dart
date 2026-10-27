import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/non_detection_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_email_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';

import '../fixtures.dart';

/// Since task 10.35 `Non_Detections` is keyed `(non_detection_id,
/// project_id)`, so the base-repository helpers take the whole key.
const _nonDetectionKey = {
  'non_detection_id': 'nd-1',
  'project_id': 'project-1',
};

/// Task 8.1: authorization lives at the repository layer, so a screen that
/// forgets to gate an affordance still can't write another user's row.
/// Advisory only — see `mutation_authorization.dart`.
void main() {
  late AppDatabase database;
  late UserRepository users;
  late ObservationRepository observations;
  late ProjectRepository projects;

  const author = MutationActor.user('user-1');
  const stranger = MutationActor.user('user-2');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    users = UserRepository(database.raw);
    observations = ObservationRepository(database.raw);
    projects = ProjectRepository(database.raw);

    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'other@example.com'));
    await projects.insert(sampleProject());
    await TagRepository(database.raw).insert(sampleTag());
    await observations.insert(sampleObservation(sessionId: null));
  });

  tearDown(() async {
    await database.close();
  });

  group('author rule', () {
    test('the author may update and soft-delete their own observation',
        () async {
      final edited = sampleObservation(sessionId: null).copyWith(notes: 'mine to edit');
      expect(await observations.update(edited, actor: author), 1);
      expect((await observations.findById('obs-1', projectId: 'project-1'))!.notes, 'mine to edit');
      expect(await observations.softDelete(edited, actor: author), 1);
    });

    test('another user cannot update someone else\'s observation', () async {
      final edited = sampleObservation(sessionId: null).copyWith(notes: 'not mine');
      await expectLater(
        observations.update(edited, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect((await observations.findById('obs-1', projectId: 'project-1'))!.notes, isNot('not mine'));
    });

    test('another user cannot soft-delete or restore someone else\'s '
        'observation', () async {
      final observation = sampleObservation(sessionId: null);
      await expectLater(
        observations.softDelete(observation, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      await observations.softDelete(observation, actor: author);
      await expectLater(
        observations.restore(observation, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await observations.findById('obs-1', projectId: 'project-1'), isNull);
    });

    test('a user may edit their own profile but not another user\'s',
        () async {
      final theirs = sampleUser(id: 'user-2', email: 'other@example.com')
          .copyWith(firstName: 'Renamed');
      await expectLater(
        users.update(theirs, actor: author),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await users.update(theirs, actor: stranger), 1);
    });

    test('another user cannot update or soft-delete someone else\'s non-detection',
        () async {
      final nonDetections = NonDetectionRepository(database.raw);
      await nonDetections.insert(sampleNonDetection());

      final edited = sampleNonDetection().copyWith(notes: 'not mine');
      await expectLater(
        nonDetections.update(edited, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      await expectLater(
        nonDetections.softDeleteByKey(_nonDetectionKey, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );

      expect(await nonDetections.update(edited, actor: author), 1);
      expect(
          await nonDetections.softDeleteByKey(_nonDetectionKey, actor: author), 1);
    });

    test('another user cannot soft-delete someone else\'s recorded prior email',
        () async {
      final userEmails = UserEmailRepository(database.raw);
      await userEmails.insert(sampleUserEmail());

      await expectLater(
        userEmails.softDeleteById('user-email-1', actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await userEmails.softDeleteById('user-email-1', actor: author), 1);
    });
  });

  group('owner rule', () {
    // Task 11.1 moved this off `Projects.owner_user_id`. It still passes
    // unchanged because `project-1` has no membership rows here, so
    // [resolveProjectOwners] falls back to the creator column — which is the
    // pre-8.4-project and mid-publish case the fallback exists for. The
    // membership-backed cases live in `project_ownership_test.dart`.
    test('only a project owner may update or soft-delete the project',
        () async {
      final renamed = sampleProject().copyWith(projectName: 'Renamed');
      await expectLater(
        projects.update(renamed, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await projects.update(renamed, actor: author), 1);

      await expectLater(
        projects.softDeleteById('project-1', actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await projects.softDeleteById('project-1', actor: author), 1);
    });
  });

  group('projectOwner rule (task 8.4)', () {
    test('only a project owner may update a Project_Memberships row',
        () async {
      final memberships = ProjectMembershipRepository(database.raw);
      // user-2 (stranger) holds a contributor membership on user-1's
      // project — updating it (e.g. changing role) must require project-1's
      // owner (user-1), not the membership row's own subject (user-2).
      await memberships.insert(
        sampleMembership(
          id: 'membership-1',
          projectId: 'project-1',
          userId: 'user-2',
        ).copyWith(role: ProjectRole.contributor),
        // Task 11.2: an insert into this table now names the authority it acts
        // under. user-1 owns project-1, so adding somebody is theirs to do.
        authority: MembershipInsertAuthority.byOwner(author),
      );

      final promoted = (await memberships.findById('membership-1', projectId: 'project-1'))!
          .copyWith(role: ProjectRole.owner);
      await expectLater(
        memberships.update(promoted, actor: stranger),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect((await memberships.findById('membership-1', projectId: 'project-1'))!.role, ProjectRole.contributor);

      expect(await memberships.update(promoted, actor: author), 1);
      expect((await memberships.findById('membership-1', projectId: 'project-1'))!.role, ProjectRole.owner);
    });

    test('no chicken-and-egg for the very first — owner\'s own — row', () async {
      final memberships = ProjectMembershipRepository(database.raw);
      // No membership row exists yet anywhere for project-1, and the owner's
      // own first row can still be created. Task 11.1 moved the *resolution*
      // onto the membership table but kept this property, via
      // [resolveProjectOwners]'s fallback to `Projects.owner_user_id`.
      //
      // **Task 11.2 changed why it holds.** It used to hold because inserts
      // were never authorized at all; now it holds because
      // `bootstrapOwner` authorizes exactly this case and nothing wider. The
      // test below is the other half of that, and could not have been written
      // before.
      await memberships.insert(
        sampleMembership(id: 'membership-owner', projectId: 'project-1'),
        authority: const MembershipInsertAuthority.bootstrapOwner(),
      );
      expect(await memberships.findById('membership-owner', projectId: 'project-1'), isNotNull);
    });

    test(
      'the bootstrap door cannot hand ownership to anyone but the creator '
      '(task 11.2)',
      () async {
        final memberships = ProjectMembershipRepository(database.raw);
        // The escalation `bootstrapOwner`'s second condition exists to stop:
        // project-1 has no owner membership yet, so the "no open owner"
        // condition passes — and the row still must not land, because it names
        // somebody `Projects.owner_user_id` does not.
        await expectLater(
          memberships.insert(
            sampleMembership(
              id: 'membership-usurper',
              projectId: 'project-1',
              userId: 'user-2',
            ),
            authority: const MembershipInsertAuthority.bootstrapOwner(),
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );
        expect(
          await memberships.findById(
            'membership-usurper',
            projectId: 'project-1',
          ),
          isNull,
        );
      },
    );

    test(
      'the bootstrap door cannot be replayed once a project has an owner '
      '(task 11.2)',
      () async {
        final memberships = ProjectMembershipRepository(database.raw);
        await memberships.insert(
          sampleMembership(id: 'membership-owner', projectId: 'project-1'),
          authority: const MembershipInsertAuthority.bootstrapOwner(),
        );
        // The creator now holds an open owner membership. Replaying the
        // bootstrap — which authorizes itself on the *absence* of one — must
        // stop working, or it would be a permanent unchecked insert path.
        await expectLater(
          memberships.insert(
            sampleMembership(id: 'membership-again', projectId: 'project-1'),
            authority: const MembershipInsertAuthority.bootstrapOwner(),
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );
      },
    );

    test(
      'a non-owner cannot add a member by inserting a row (task 11.2)',
      () async {
        final memberships = ProjectMembershipRepository(database.raw);
        // The gap task 11.2 closed: Phase 8 checks updates and deletes, and in
        // this one table the *insert* is the grant. Before this, `stranger`
        // adding themselves as an owner of somebody else's project was an
        // ordinary insert and went through.
        await expectLater(
          memberships.insert(
            sampleMembership(
              id: 'membership-self-grant',
              projectId: 'project-1',
              userId: 'user-2',
            ),
            authority: MembershipInsertAuthority.byOwner(stranger),
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );
        expect(
          await memberships.findById(
            'membership-self-grant',
            projectId: 'project-1',
          ),
          isNull,
        );
      },
    );
  });

  group('MutationRule.permits (task 8.2 — Map/Log agreement)', () {
    // `log_screen.dart` and `map_screen.dart` both gate their Edit
    // affordance with `MutationRule.author.permits(currentUserId, o.userId)`
    // instead of each doing its own `userId ==` comparison. Asserting the
    // shared primitive here — under the same three scenarios
    // `log_screen_test.dart` drives through a full widget pump — is what
    // guarantees the two screens can't drift apart the way they did before
    // 8.2 (map showed Edit unconditionally). A MapScreen widget harness
    // doesn't exist (pre-existing gap, see the plan doc's backlog), so this
    // is the level this task's "surfaces agree" criterion is verified at.
    test('the author may edit their own observation', () {
      expect(MutationRule.author.permits('user-1', 'user-1'), isTrue);
    });

    test('another user may not edit it', () {
      expect(MutationRule.author.permits('user-2', 'user-1'), isFalse);
    });

    test('no signed-in user may not edit it', () {
      expect(MutationRule.author.permits(null, 'user-1'), isFalse);
    });
  });

  group('malformed governing column (task 10.67)', () {
    // Task 10.67: `_authorize` read the governing column with a naked
    // `row[column] as String?` — the client-side sibling of the exact shape
    // task 10.64 fixed server-side in `RowAuthorizer._governingValue`. A
    // non-null, wrong-typed value already failed closed (the cast throws
    // rather than defaulting to `null`, which `MutationRule.permits` reads
    // as "nothing to deny" — so this was never the authorization-bypass
    // shape 10.64 found), but via an unlabeled `TypeError` rather than a
    // named, documented failure. Writing a malformed column requires going
    // around the repository/model layer entirely (a raw update), since no
    // normal write path can produce one — which is exactly why this needs
    // its own regression rather than trusting the cast's incidental
    // behavior to keep failing safely after a future refactor.
    // `owner_user_id`/`user_id` are `TEXT NOT NULL REFERENCES Users(user_id)`.
    // Two independent guards mean an actually-wrong-*type* value (as opposed
    // to a right-typed-but-nonexistent one) is exceptionally hard to produce
    // through SQL at all: `AppDatabase` forces `PRAGMA foreign_keys = ON`
    // (so any value has to match a real `Users.user_id`), and — confirmed
    // live while writing this test — SQLite's TEXT column affinity silently
    // converts a bound `int`/`double` to its text representation on INSERT,
    // so binding `999` does not even reach `_governingValue` as an `int`; it
    // arrives as the *string* `"999"`. A `BLOB` is the one SQLite storage
    // class TEXT affinity does not convert, so it's the only way to place a
    // genuinely non-`String`, non-`null` value in the column — which is what
    // this test does, with foreign keys off (a `BLOB` can never satisfy the
    // `REFERENCES` check regardless).
    Future<void> withForeignKeysOff(Future<void> Function() body) async {
      await database.raw.execute('PRAGMA foreign_keys = OFF');
      try {
        await body();
      } finally {
        await database.raw.execute('PRAGMA foreign_keys = ON');
      }
    }

    test(
      'a non-string owner_user_id fails closed with a named error, not a '
      'raw TypeError',
      () async {
        await withForeignKeysOff(() => database.raw.rawUpdate(
              'UPDATE Projects SET owner_user_id = ? WHERE project_id = ?',
              [
                Uint8List.fromList([1, 2, 3]),
                'project-1',
              ],
            ));
        final renamed = sampleProject().copyWith(projectName: 'Renamed');
        await expectLater(
          projects.update(renamed, actor: author),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'a non-string user_id (author column) fails closed with a named '
      'error',
      () async {
        await withForeignKeysOff(() => database.raw.rawUpdate(
              'UPDATE Observations SET user_id = ? WHERE observation_id = ?',
              [
                Uint8List.fromList([1, 2, 3]),
                'obs-1',
              ],
            ));
        final edited = sampleObservation(
          sessionId: null,
        ).copyWith(notes: 'edit attempt');
        await expectLater(
          observations.update(edited, actor: author),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('replication bypass', () {
    test('replicates a row authored by another user', () async {
      final edited = sampleObservation(sessionId: null).copyWith(notes: 'from their device');
      const replication = MutationActor.replication('test');
      expect(await observations.update(edited, actor: replication), 1);
      expect((await observations.findById('obs-1', projectId: 'project-1'))!.notes,
          'from their device');
    });

    test('leaves last_modified_by intact rather than claiming the edit',
        () async {
      final before = (await observations.findById('obs-1', projectId: 'project-1'))!;
      await observations.update(
        before.copyWith(notes: 'replicated'),
        actor: const MutationActor.replication('test'),
      );
      final after = (await observations.findById('obs-1', projectId: 'project-1'))!;
      expect(after.sync.lastModifiedBy, before.sync.lastModifiedBy);
    });
  });
}
