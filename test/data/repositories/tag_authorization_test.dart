import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.11, the client's half.** Who may create a tag, and who may change
/// one.
///
/// The split under test is deliberate and is the task's whole decision:
/// creating a tag is open to a contributor because a field tech who cannot
/// create one cannot record the observation at all, while changing an existing
/// tag is owners only because it rewrites what every observation already
/// pointing at that tag means.
///
/// The server enforces the same two rules over a socket — see
/// `server/test/integration/member_authorization_test.dart`. This is the app
/// agreeing, so a refusal happens at the tap rather than as a permanently
/// refused row on every sync.
void main() {
  late AppDatabase database;
  late TagRepository tags;

  const owner = MutationActor.user('user-1');
  const member = MutationActor.user('user-2');
  final at = DateTime.utc(2026, 8, 21, 9, 0, 0);

  SyncMeta metaFor(MutationActor actor) =>
      SyncMeta.initial(now: at, modifiedBy: actor.userId, originDeviceId: 'd');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    final users = UserRepository(database.raw);
    final projects = ProjectRepository(database.raw);
    final memberships = ProjectMembershipRepository(database.raw);
    tags = TagRepository(database.raw);

    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'other@example.com'));
    await projects.insert(sampleProject());
    await memberships.insert(
      sampleMembership(),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
  });

  tearDown(() => database.close());

  Future<void> joinAs(ProjectRole role) =>
      ProjectMembershipRepository(database.raw).insert(
        sampleMembership(id: 'membership-2', userId: 'user-2', role: role),
        authority: MembershipInsertAuthority.byOwner(owner),
      );

  /// A tag the project already has — the thing an edit would change the
  /// meaning of. One row since task 11.219, where it was a tag plus a link.
  Future<void> seedProjectTag() async {
    await tags.insert(sampleTag().copyWith(sync: metaFor(owner)));
  }

  group('creating a tag', () {
    test('a contributor may — this is the rule the task exists to protect',
        () async {
      await joinAs(ProjectRole.contributor);
      await tags.insert(sampleTag(id: 'tag-new').copyWith(sync: metaFor(member)));
      expect(
        await tags.findById('tag-new', projectId: 'project-1'),
        isNotNull,
      );
    });

    test('a viewer may not', () async {
      await joinAs(ProjectRole.viewer);
      await expectLater(
        tags.insert(sampleTag(id: 'tag-viewer').copyWith(sync: metaFor(member))),
        throwsA(isA<UnauthorizedMutation>()),
      );
      // And it is refused before the row exists. **Task 11.219 made that
      // structural rather than careful**: the project is half the tag's key
      // now, so the ordinary role gradient in `BaseRepository.insertRow`
      // resolves against it and refuses the insert itself. It used to be a
      // check `TagRepository` had to make on a `projectId` passed beside the
      // row, because a global tag had no project to resolve against — and
      // the reason it had to was that a viewer refused at the *link* instead
      // would be left holding an orphan tag they could never push.
      expect(await tags.findById('tag-viewer', projectId: 'project-1'), isNull);
    });

    test('a viewer is told what they would need to be', () async {
      await joinAs(ProjectRole.viewer);
      try {
        await tags.insert(
          sampleTag(id: 'tag-msg').copyWith(sync: metaFor(member)),
        );
        fail('expected a refusal');
      } on UnauthorizedMutation catch (error) {
        expect(error.toString(), contains('contributor or owner'));
        expect(error.toString(), contains('viewer'));
      }
    });

    test('a collar in nobody\'s project is a library entry, which no role '
        'governs', () async {
      // **The "unlinked tag" case, rewritten by task 11.219 rather than
      // deleted.** There used to be a `Tags` row in no project, permitted
      // because there was no project to refuse against. A `Tags` row cannot
      // exist without a project now; the thing that has no project is a
      // library entry, and it is device-local, so no role governs it and a
      // viewer may keep their own equipment list.
      await joinAs(ProjectRole.viewer);
      final library = TagLibraryRepository(database.raw);
      await library.insert(sampleTagLibraryEntry(id: 'lib-loose'));
      expect(await library.findById('lib-loose'), isNotNull);
    });
  });

  group('changing a tag the project uses', () {
    setUp(seedProjectTag);

    test('a contributor may not rename it', () async {
      await joinAs(ProjectRole.contributor);
      final stored = (await tags.findById('tag-1', projectId: 'project-1'))!;
      await expectLater(
        tags.update(
          stored.copyWith(tagName: 'Renamed'),
          actor: member,
          intent: TagEditIntent.correction,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect((await tags.findById('tag-1', projectId: 'project-1'))!.tagName, 'Coco');
    });

    test('nor retire it — retiring is a status change and gets no exemption',
        () async {
      await joinAs(ProjectRole.contributor);
      final stored = (await tags.findById('tag-1', projectId: 'project-1'))!;
      await expectLater(
        tags.update(
          stored.copyWith(status: TagStatus.recovered),
          actor: member,
          // Status is a fact about the collar's life, never versioned — no
          // intent, and the refusal below is about the rung, not the version.
          intent: null,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect((await tags.findById('tag-1', projectId: 'project-1'))!.status, TagStatus.active);
    });

    test('a viewer may not either', () async {
      await joinAs(ProjectRole.viewer);
      await expectLater(
        tags.update(
          (await tags.findById('tag-1', projectId: 'project-1'))!.copyWith(tagName: 'Renamed'),
          actor: member,
          intent: TagEditIntent.correction,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('an owner may', () async {
      final stored = (await tags.findById('tag-1', projectId: 'project-1'))!;
      await tags.update(
        stored.copyWith(tagName: 'Renamed'),
        actor: owner,
        intent: TagEditIntent.correction,
      );
      expect((await tags.findById('tag-1', projectId: 'project-1'))!.tagName, 'Renamed');
    });

    test('the refusal names the rung, not a rule identifier', () async {
      await joinAs(ProjectRole.contributor);
      try {
        await tags.update(
          (await tags.findById('tag-1', projectId: 'project-1'))!.copyWith(tagName: 'Renamed'),
          actor: member,
          intent: TagEditIntent.correction,
        );
        fail('expected a refusal');
      } on UnauthorizedMutation catch (error) {
        expect(error.toString(), contains('owner'));
        expect(error.toString(), contains('contributor'));
      }
    });

    test('a tag removed from the project still counts — it still names the '
        'collar in that project\'s past observations', () async {
      await joinAs(ProjectRole.contributor);
      await tags.removeFromProject('tag-1', projectId: 'project-1', actor: owner);
      await expectLater(
        tags.update(
          (await tags.findById(
            'tag-1',
            projectId: 'project-1',
            includeDeleted: true,
          ))!.copyWith(tagName: 'Renamed'),
          actor: member,
          intent: TagEditIntent.correction,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('and only an owner may remove it in the first place (task 11.24)',
        () async {
      await joinAs(ProjectRole.contributor);
      await expectLater(
        tags.removeFromProject('tag-1', projectId: 'project-1', actor: member),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('putting a removed tag back is owner-only too — a contributor is '
        'refused on the device, not at the next push (task 11.221)', () async {
      // Until task 11.219 the put-back was the "additive half" and stayed
      // contributor-level. The server now treats clearing the tombstone as a
      // change to an existing tag, which is an owner's; Michael confirmed
      // owner-only as the wanted rule on 2026-09-10. Without the local check
      // the row came back on the contributor's phone and the push refused it.
      await joinAs(ProjectRole.contributor);
      await tags.removeFromProject('tag-1', projectId: 'project-1', actor: owner);
      await expectLater(
        tags.restoreToProject('tag-1', projectId: 'project-1', actor: member),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await tags.findByProject('project-1'), isEmpty);
      // The owner's own undo still works.
      await tags.restoreToProject('tag-1', projectId: 'project-1', actor: owner);
      expect(await tags.findByProject('project-1'), hasLength(1));
    });
  });

  group('where the client deliberately does not decide', () {
    test('a project this device holds no rows for permits, and defers to the '
        'server', () async {
      // The deferral rule `BaseRepository.assertRoleMayWrite` states, as
      // narrowed by task 11.237: this SQLite file legitimately holds projects
      // the device cannot answer for. `p-lone` is created here by `user-1`
      // and `user-1` writes into it — the creator fallback is the answer, and
      // the write goes through with no membership row at all.
      await ProjectRepository(database.raw).insert(sampleProject(id: 'p-lone'));
      await tags.insert(
        sampleTag(id: 'tag-lone', projectId: 'p-lone')
            .copyWith(sync: metaFor(owner)),
      );
      final stored = (await tags.findById('tag-lone', projectId: 'p-lone'))!;
      await tags.update(
        stored.copyWith(tagName: 'Renamed'),
        actor: owner,
        intent: TagEditIntent.correction,
      );
      expect(
        (await tags.findById('tag-lone', projectId: 'p-lone'))!.tagName,
        'Renamed',
      );
    });

    test('but a project imported from somebody else refuses, with the join '
        'code named (task 11.237)', () async {
      // `user-2` has joined nothing here, and the project's own row says
      // `user-1` made it: the device can see `user-2` is not on it, and that
      // is a read-only snapshot rather than a deferral.
      await ProjectRepository(database.raw).insert(sampleProject(id: 'p-lone'));
      await expectLater(
        tags.insert(
          sampleTag(id: 'tag-lone', projectId: 'p-lone')
              .copyWith(sync: metaFor(member)),
        ),
        throwsA(
          isA<UnauthorizedMutation>().having(
            (e) => e.notAMember,
            'notAMember',
            isTrue,
          ),
        ),
      );
    });

    test('a replication write is never subject to either rule', () async {
      await seedProjectTag();
      const replication = MutationActor.replication('merge');
      final stored = (await tags.findById('tag-1', projectId: 'project-1'))!;
      await tags.update(
        stored.copyWith(tagName: 'Replicated'),
        actor: replication,
        intent: TagEditIntent.correction,
      );
      expect((await tags.findById('tag-1', projectId: 'project-1'))!.tagName, 'Replicated');
    });
  });
}
