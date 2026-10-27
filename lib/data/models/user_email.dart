import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import 'sync_meta.dart';

part 'user_email.freezed.dart';

/// An address a [User] has used at some point — recorded when their email
/// changes (see the Profile screen), never mutated afterward. `user_id` is
/// stable per device, so this table only matters for matching one human
/// across two devices with independently generated ids: if the address
/// changed on one device and not the other, the current-email anchor alone
/// can no longer dedupe them, and `ProjectMerger`/`SharedObservationImporter`
/// fall back to this history — see their prior-email matching, which always
/// treats a current-email match as authoritative over a prior one.
@freezed
abstract class UserEmail with _$UserEmail {
  const UserEmail._();

  const factory UserEmail({
    required String userEmailId,
    required String userId,
    required String email,
    required DateTime recordedAt,
    required SyncMeta sync,
  }) = _UserEmail;

  factory UserEmail.fromRow(Map<String, Object?> row) => UserEmail(
        userEmailId: row['user_email_id'] as String,
        userId: row['user_id'] as String,
        email: row['email'] as String,
        recordedAt: DbCodec.decodeUtc(row['recorded_at']),
        sync: SyncMeta.fromRow(row),
      );

  Map<String, Object?> toColumns() => {
        'user_email_id': userEmailId,
        'user_id': userId,
        'email': email,
        'recorded_at': DbCodec.encodeUtc(recordedAt),
        ...sync.toColumns(),
      };
}
