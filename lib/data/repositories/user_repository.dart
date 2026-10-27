import 'package:tritrack_sync/tritrack_sync.dart' as sync;

import '../db/schema.dart';
import '../models/user.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';

class UserRepository extends BaseRepository {
  UserRepository(super.db)
    : super(
        table: Tables.users,
        pk: const ['user_id'],
        rule: MutationRule.author,
      );

  /// Canonical form of an email for cross-device dedup: trimmed + lowercased.
  ///
  /// Delegates to `package:tritrack_sync`'s `normalizeEmail` (moved there by
  /// task 10.6). It has to be shared: the server's `auth_accounts.email` is
  /// authoritative for which `user_id` an address maps to, and a server that
  /// normalized differently from the client would hand two devices different
  /// ids for the same person. Kept as a static here so the ~10 existing call
  /// sites (merge dedup, share payloads, profile editing) don't all have to
  /// change, and so "the app's notion of a normalized email" still has one
  /// obvious name.
  static String normalizeEmail(String email) => sync.normalizeEmail(email);

  /// Inserts a user, storing the email in normalized form so it can serve as
  /// the cross-device identity anchor regardless of how it was typed.
  Future<void> insert(User user) {
    final columns = user.toColumns()..['email'] = normalizeEmail(user.email);
    return insertRow(columns);
  }

  Future<User?> findById(String id, {bool includeDeleted = false}) async {
    final row = await findRowById(id, includeDeleted: includeDeleted);
    return row == null ? null : User.fromRow(row);
  }

  Future<int> update(
    User user, {
    required MutationActor actor,
    String? deviceId,
  }) {
    final columns = user.toColumns()..['email'] = normalizeEmail(user.email);
    return updateById(user.userId, columns, actor: actor, deviceId: deviceId);
  }
}
