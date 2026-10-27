import 'package:uuid/uuid.dart';

import '../db/data_arrival.dart';
import '../models/sync_meta.dart';
import '../models/user.dart';
import '../models/user_email.dart';
import 'mutation_authorization.dart';
import 'user_email_repository.dart';
import 'user_repository.dart';

/// Applies a profile edit (Phase 7.2): updates the existing user row in
/// place, and — if the email changed — records the superseded address in
/// [UserEmailRepository] first, so cross-device merge can still recognize
/// this person via their prior address (see `ProjectMerger`'s prior-email
/// fallback). `user_id` never changes.
///
/// Kept as a small standalone class rather than inline in `ProfileScreen` so
/// this persistence logic is unit-testable with a plain `test()` — a full
/// save round trip through the widget layer reliably hangs under
/// `testWidgets` (real `sqflite_common_ffi` I/O on a background isolate
/// never resolves inside the fake-async pump loop; see
/// `project_setup_screen_test.dart`).
class ProfileEditor {
  const ProfileEditor(this.userRepo, this.userEmailRepo);

  final UserRepository userRepo;
  final UserEmailRepository userEmailRepo;

  /// Returns the updated [User]. [newId]/[now] are injectable for
  /// deterministic tests.
  Future<User> apply({
    required User existing,
    required String firstName,
    required String lastName,
    required String email,
    required String deviceId,
    String Function() newId = _defaultNewId,
    DateTime Function() now = DateTime.now,
  }) async {
    final emailChanged =
        UserRepository.normalizeEmail(email) != UserRepository.normalizeEmail(existing.email);

    if (emailChanged) {
      final recordedAt = now();
      await userEmailRepo.insert(UserEmail(
        userEmailId: newId(),
        userId: existing.userId,
        email: existing.email,
        recordedAt: recordedAt,
        sync: SyncMeta.initial(
          now: recordedAt,
          modifiedBy: existing.userId,
          originDeviceId: deviceId,
        ),
      ));
    }

    final updated = existing.copyWith(firstName: firstName, lastName: lastName, email: email);
    await userRepo.update(updated,
        actor: MutationActor.user(existing.userId), deviceId: deviceId);
    // The log names the author of every bearing, and reads that name from the
    // `Users` row this just rewrote. Without this, correcting your own name
    // leaves every row in the log attributed to the old one until the app is
    // restarted (task 11.45).
    DataArrival.announce();
    return updated;
  }

  static String _defaultNewId() => const Uuid().v4();
}
