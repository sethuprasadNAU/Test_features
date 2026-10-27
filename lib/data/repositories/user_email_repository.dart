import '../db/schema.dart';
import '../models/user_email.dart';
import 'base_repository.dart';
import 'mutation_authorization.dart';
import 'user_repository.dart';

/// Address history for [Tables.users] rows — never updated in place, only
/// appended to (a changed email writes a new row here for the *old* address,
/// then the `Users` row itself is updated to the new one). See
/// `ProjectMerger`/`SharedObservationImporter` for how this backs cross-device
/// dedup once a user's current email alone can no longer match.
class UserEmailRepository extends BaseRepository {
  UserEmailRepository(super.db)
    : super(
        table: Tables.userEmails,
        pk: const ['user_email_id'],
        rule: MutationRule.author,
      );

  /// Records [row], normalizing the email the same way [UserRepository] does
  /// so prior-email matching compares like with like.
  Future<void> insert(UserEmail row) {
    final columns = row.toColumns()
      ..['email'] = UserRepository.normalizeEmail(row.email);
    return insertRow(columns);
  }
}
