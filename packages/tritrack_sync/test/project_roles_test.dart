import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.3. The gradient is resolved from membership rows by **one**
/// function, on both sides of the wire, for the reason task 11.1 hoisted
/// [resolveProjectOwners]: an app and a server that disagree about someone's
/// role disagree about whether their field record exists.
void main() {
  Map<String, Object?> membership(
    String userId, {
    required String role,
    String? endDate,
    String? deletedAt,
  }) => {
    'user_id': userId,
    'role': role,
    'end_date': endDate,
    'deleted_at': deletedAt,
  };

  group('what each rung may do', () {
    test('a viewer writes nothing and manages nothing', () {
      expect(ProjectRole.viewer.mayWriteProjectData, isFalse);
      expect(ProjectRole.viewer.mayManageProject, isFalse);
    });

    test('a contributor writes but does not manage', () {
      // Writing project data and managing who else may are different
      // permissions; a contributor holds exactly one of them. Which *rows* a
      // contributor may write is the rule table's answer, not this one.
      expect(ProjectRole.contributor.mayWriteProjectData, isTrue);
      expect(ProjectRole.contributor.mayManageProject, isFalse);
    });

    test('an owner does both', () {
      expect(ProjectRole.owner.mayWriteProjectData, isTrue);
      expect(ProjectRole.owner.mayManageProject, isTrue);
    });
  });

  group('resolveProjectRole', () {
    test('reads the role off an open membership row', () {
      for (final role in ProjectRole.values) {
        expect(
          resolveProjectRole(
            membershipRows: [membership('u1', role: role.db)],
            creatorUserId: 'someone-else',
            userId: 'u1',
          ),
          role,
        );
      }
    });

    test('a closed stint and a tombstoned row both grant nothing', () {
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('u1', role: 'contributor', endDate: '2026-09-01'),
          ],
          creatorUserId: null,
          userId: 'u1',
        ),
        isNull,
      );
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('u1', role: 'contributor', deletedAt: '2026-09-01'),
          ],
          creatorUserId: null,
          userId: 'u1',
        ),
        isNull,
      );
    });

    test('someone with no row at all holds no role', () {
      expect(
        resolveProjectRole(
          membershipRows: [membership('u1', role: 'owner')],
          creatorUserId: 'u1',
          userId: 'stranger',
        ),
        isNull,
      );
    });

    test('the creator fallback applies when no open owner membership exists',
        () {
      // The case task 11.1's [resolveProjectOwners] carries: a project made
      // before task 8.4 adopted the membership table, or the window inside a
      // first publish where the `Projects` row is not yet stored. Answering
      // "no role" here would lock a creator out of their own project.
      expect(
        resolveProjectRole(
          membershipRows: const [],
          creatorUserId: 'creator',
          userId: 'creator',
        ),
        ProjectRole.owner,
      );
    });

    test('but not once a real owner membership exists', () {
      // A creator who transferred the project away and closed their own stint
      // must not be handed it back by the fallback.
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('creator', role: 'owner', endDate: '2026-09-01'),
            membership('successor', role: 'owner'),
          ],
          creatorUserId: 'creator',
          userId: 'creator',
        ),
        isNull,
      );
    });

    test('a demoted creator holds the role their membership row says', () {
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('creator', role: 'viewer'),
            membership('successor', role: 'owner'),
          ],
          creatorUserId: 'creator',
          userId: 'creator',
        ),
        ProjectRole.viewer,
      );
    });

    test('a role string this build does not recognise resolves to nothing', () {
      // Fails closed rather than guessing. Every caller reads null as "no
      // rights", which is the only safe reading of a value that cannot be
      // interpreted — and the permissive reading is the one that would matter.
      expect(
        resolveProjectRole(
          membershipRows: [membership('u1', role: 'superuser')],
          creatorUserId: null,
          userId: 'u1',
        ),
        isNull,
      );
    });

    test('two open rows for one pair resolve to the least permissive', () {
      // The pair invariant is supposed to make this impossible and task 11.10
      // adds the index that will. Until then, `findForUser` takes the first row
      // it finds, and an *arbitrary* answer to a permission question should
      // fail toward less access rather than more.
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('u1', role: 'contributor'),
            membership('u1', role: 'viewer'),
          ],
          creatorUserId: null,
          userId: 'u1',
        ),
        ProjectRole.viewer,
      );
      // Order-independent: the same two rows the other way round.
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('u1', role: 'viewer'),
            membership('u1', role: 'contributor'),
          ],
          creatorUserId: null,
          userId: 'u1',
        ),
        ProjectRole.viewer,
      );
    });

    test('an open owner row still wins, because ownership is co-equal', () {
      // `owner` is resolved through [resolveProjectOwners] before the
      // least-permissive rule applies, so someone holding both an owner
      // membership and some stray lesser one is an owner. That is deliberate:
      // ownership is the answer 11.1 made authoritative, and a second row must
      // not be a way to quietly demote a co-owner.
      expect(
        resolveProjectRole(
          membershipRows: [
            membership('u1', role: 'owner'),
            membership('u1', role: 'viewer'),
          ],
          creatorUserId: null,
          userId: 'u1',
        ),
        ProjectRole.owner,
      );
    });

    test('a null or empty user holds nothing', () {
      expect(
        resolveProjectRole(
          membershipRows: [membership('', role: 'owner')],
          creatorUserId: null,
          userId: null,
        ),
        isNull,
      );
      expect(
        resolveProjectRole(
          membershipRows: [membership('', role: 'owner')],
          creatorUserId: null,
          userId: '',
        ),
        isNull,
      );
    });
  });
}
