import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_meta.dart';

part 'user.freezed.dart';

/// A person. The same human has a *different* `user_id` per device; email
/// (normalized/lowercased) is the cross-device identity anchor used to dedup
/// on merge (technical doc, "User identity across devices"). Normalization is
/// the repository's job, not the model's.
@freezed
abstract class User with _$User {
  const User._();

  const factory User({
    required String userId,
    required String firstName,
    required String lastName,
    required String email,
    required SyncMeta sync,
  }) = _User;

  /// True for the auto-generated `field-user-<uuid>@local.tritrack` identity
  /// (`app_context_provider.dart`'s `currentUser`) that every fresh install
  /// starts with. Real identity has never been captured for this user, so
  /// cross-device merge/dedup can never match them to anyone else — see
  /// Phase 7's first-run identity capture.
  bool get hasPlaceholderIdentity => isPlaceholderEmail(email);

  factory User.fromRow(Map<String, Object?> row) => User(
    userId: row['user_id'] as String,
    firstName: row['first_name'] as String,
    lastName: row['last_name'] as String,
    email: row['email'] as String,
    sync: SyncMeta.fromRow(row),
  );

  Map<String, Object?> toColumns() => {
    'user_id': userId,
    'first_name': firstName,
    'last_name': lastName,
    'email': email,
    ...sync.toColumns(),
  };
}
