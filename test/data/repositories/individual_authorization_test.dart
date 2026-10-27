import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/deployment_linking.dart';
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.255 — deleting an animal is an owner's decision; nothing else
/// about `Individuals` moved.**
///
/// `PERMISSIONS_MATRIX.md` §8 entry 13, Michael's option (a), 2026-09-15:
/// "I like the idea of deleting an animal is an own only decision." This is
/// the client half of that — [tag_authorization_test.dart]'s shape, one rung
/// over. The server half is `permissions_matrix_test.dart`'s "shared tables"
/// group.
///
/// **The other half of the same task is what must NOT move**, and this file
/// asserts that as carefully as the refusal: a contributor still creates,
/// edits and links/unlinks exactly as task 11.240/11.243 left it.
void main() {
  late AppDatabase database;
  late IndividualRepository individuals;
  late DeploymentRepository deployments;
  late DeploymentLinking linking;

  const owner = MutationActor.user('user-1');
  const contributor = MutationActor.user('user-2');
  const projectId = 'project-1';

  setUp(() async {
    database = await AppDatabase.openInMemory();
    individuals = IndividualRepository(database.raw);
    deployments = DeploymentRepository(database.raw);
    linking = DeploymentLinking(database.raw);

    final users = UserRepository(database.raw);
    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'other@example.com'));
    await ProjectRepository(database.raw).insert(sampleProject(id: projectId));
    await ProjectMembershipRepository(database.raw).insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
  });

  tearDown(() => database.close());

  Future<void> joinAsContributor() =>
      ProjectMembershipRepository(database.raw).insert(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.contributor,
        ),
        authority: MembershipInsertAuthority.byOwner(owner),
      );

  group('what stays contributor-level — only the tombstone moved', () {
    test('a contributor may name a new animal', () async {
      await joinAsContributor();
      await individuals.insert(
        sampleIndividual(id: 'chick', modifiedBy: 'user-2'),
      );
      expect(
        await individuals.findById('chick', projectId: projectId),
        isNotNull,
      );
    });

    test('a contributor may edit name, colour and status', () async {
      await joinAsContributor();
      await individuals.insert(sampleIndividual(id: 'marie'));
      final stored = (await individuals.findById(
        'marie',
        projectId: projectId,
      ))!;
      await individuals.update(
        stored.copyWith(
          name: 'Renamed',
          colorHex: '#ABCDEF',
          status: IndividualStatus.dead,
        ),
        actor: contributor,
      );
      final after = (await individuals.findById(
        'marie',
        projectId: projectId,
      ))!;
      expect(after.name, 'Renamed');
      expect(after.colorHex, '#ABCDEF');
      expect(after.status, IndividualStatus.dead);
    });

    test('a contributor may link and unlink a collar', () async {
      await joinAsContributor();
      await individuals.insert(sampleIndividual(id: 'marie'));
      await TagRepository(
        database.raw,
      ).insert(sampleTag(id: 'collar'));
      await deployments.link(
        sampleDeployment(
          id: 'd1',
          tagId: 'collar',
          individualId: 'marie',
          modifiedBy: 'user-2',
        ),
      );
      expect(
        await deployments.findByIndividual('marie', projectId: projectId),
        hasLength(1),
      );
      await deployments.unlink('d1', projectId: projectId, actor: contributor);
      final after = (await deployments.findById(
        'd1',
        projectId: projectId,
        includeDeleted: true,
      ))!;
      expect(after.sync.isDeleted, isTrue);
    });
  });

  group('deleting an animal — refused for a contributor', () {
    test('IndividualRepository.remove refuses, and writes nothing', () async {
      await joinAsContributor();
      await individuals.insert(sampleIndividual(id: 'marie'));
      await expectLater(
        individuals.remove(
          'marie',
          projectId: projectId,
          actor: contributor,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      final still = await individuals.findById(
        'marie',
        projectId: projectId,
        includeDeleted: true,
      );
      expect(still, isNotNull);
      expect(still!.sync.isDeleted, isFalse);
    });

    test(
      'DeploymentLinking.deleteAnimal refuses before the first write',
      () async {
        await joinAsContributor();
        await individuals.insert(sampleIndividual(id: 'marie'));
        await TagRepository(database.raw).insert(sampleTag(id: 'collar'));
        await deployments.link(
          sampleDeployment(id: 'd1', tagId: 'collar', individualId: 'marie'),
        );
        await expectLater(
          linking.deleteAnimal(
            projectId: projectId,
            individualId: 'marie',
            actor: contributor,
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );
        final animal = await individuals.findById(
          'marie',
          projectId: projectId,
          includeDeleted: true,
        );
        expect(animal, isNotNull);
        expect(animal!.sync.isDeleted, isFalse);
        final deployment = (await deployments.findById(
          'd1',
          projectId: projectId,
        ))!;
        expect(
          deployment.sync.isDeleted,
          isFalse,
          reason:
              'the collar must not have been withdrawn ahead of a delete '
              'that was then refused',
        );
      },
    );

    test('a viewer is refused too', () async {
      await ProjectMembershipRepository(database.raw).insert(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.viewer,
        ),
        authority: MembershipInsertAuthority.byOwner(owner),
      );
      await individuals.insert(sampleIndividual(id: 'marie'));
      await expectLater(
        individuals.remove(
          'marie',
          projectId: projectId,
          actor: contributor,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('the refusal names the rung, not a rule identifier', () async {
      await joinAsContributor();
      await individuals.insert(sampleIndividual(id: 'marie'));
      try {
        await individuals.remove(
          'marie',
          projectId: projectId,
          actor: contributor,
        );
        fail('expected a refusal');
      } on UnauthorizedMutation catch (error) {
        expect(error.toString(), contains('owner'));
        expect(error.toString(), contains('contributor'));
      }
    });
  });

  group('deleting an animal — an owner may', () {
    test('IndividualRepository.remove', () async {
      await individuals.insert(sampleIndividual(id: 'marie'));
      await individuals.remove('marie', projectId: projectId, actor: owner);
      expect(await individuals.findById('marie', projectId: projectId), isNull);
    });

    test('DeploymentLinking.deleteAnimal', () async {
      await individuals.insert(sampleIndividual(id: 'marie'));
      await TagRepository(database.raw).insert(sampleTag(id: 'collar'));
      await deployments.link(
        sampleDeployment(id: 'd1', tagId: 'collar', individualId: 'marie'),
      );
      final withdrawn = await linking.deleteAnimal(
        projectId: projectId,
        individualId: 'marie',
        actor: owner,
      );
      expect(withdrawn, 1);
      expect(await individuals.findById('marie', projectId: projectId), isNull);
    });
  });
}
