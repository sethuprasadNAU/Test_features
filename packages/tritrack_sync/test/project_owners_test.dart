import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Who owns a project (task 11.1). Shared by the client's repository check,
/// the server's `RowAuthorizer`, and the server's `ProjectAuthorizer` — the
/// three places that must not disagree — so it is tested here, once, with no
/// database on either side.
Map<String, Object?> membership(
  String userId, {
  String role = 'owner',
  Object? endDate,
  Object? deletedAt,
}) => {
  'membership_id': '$userId-$role',
  'user_id': userId,
  'role': role,
  'end_date': endDate,
  'deleted_at': deletedAt,
};

void main() {
  group('resolveProjectOwners', () {
    test('every open owner membership counts, and they are co-equal', () {
      expect(
        resolveProjectOwners(
          membershipRows: [membership('a'), membership('b')],
          creatorUserId: 'a',
        ),
        {'a', 'b'},
      );
    });

    test('an owner who received the project by transfer owns it', () {
      // The case task 8.4's `owner_user_id` rule could not express: the
      // creator handed the project on and closed their own stint, so the
      // column names someone who is no longer an owner.
      expect(
        resolveProjectOwners(
          membershipRows: [
            membership('creator', endDate: '2026-08-17T00:00:00Z'),
            membership('successor'),
          ],
          creatorUserId: 'creator',
        ),
        {'successor'},
      );
    });

    test('a non-owner role never confers ownership', () {
      expect(
        resolveProjectOwners(
          membershipRows: [
            membership('a', role: 'contributor'),
            membership('b', role: 'viewer'),
          ],
          creatorUserId: null,
        ),
        isEmpty,
      );
    });

    test('an ended or tombstoned owner membership does not count', () {
      expect(
        resolveProjectOwners(
          membershipRows: [
            membership('ended', endDate: '2026-08-17T00:00:00Z'),
            membership('deleted', deletedAt: '2026-08-17T00:00:00Z'),
          ],
          creatorUserId: null,
        ),
        isEmpty,
      );
    });

    test('the creator is the fallback only when no owner membership is open', () {
      // Two real cases: a project created before task 8.4 adopted the table on
      // a device whose backfill has not run, and the window inside a first
      // publish where the batch's `Projects` row is not yet written.
      expect(
        resolveProjectOwners(membershipRows: const [], creatorUserId: 'c'),
        {'c'},
      );
      expect(
        resolveProjectOwners(
          membershipRows: [membership('a')],
          creatorUserId: 'c',
        ),
        {'a'},
        reason: 'a real owner membership displaces the fallback entirely',
      );
    });

    test('no memberships and no creator names nobody', () {
      expect(
        resolveProjectOwners(membershipRows: const [], creatorUserId: null),
        isEmpty,
      );
    });

    test('a wrongly-typed user_id is skipped, not coerced', () {
      expect(
        resolveProjectOwners(
          membershipRows: [
            {'user_id': 12345, 'role': 'owner', 'end_date': null,
             'deleted_at': null},
          ],
          creatorUserId: null,
        ),
        isEmpty,
      );
    });
  });

  group('isOpenOwnerMembership', () {
    test('all three columns must hold', () {
      expect(isOpenOwnerMembership(membership('a')), isTrue);
      expect(
        isOpenOwnerMembership(membership('a', role: 'contributor')),
        isFalse,
      );
      expect(isOpenOwnerMembership(membership('a', endDate: 'x')), isFalse);
      expect(isOpenOwnerMembership(membership('a', deletedAt: 'x')), isFalse);
    });
  });
}
