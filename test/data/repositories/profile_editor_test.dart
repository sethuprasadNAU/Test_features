import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/models/user_email.dart';
import 'package:tritrack/data/repositories/profile_editor.dart';
import 'package:tritrack/data/repositories/user_email_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';

import '../fixtures.dart';

/// Plain `test()`, not `testWidgets`: a full profile-save round trip through
/// `ProfileScreen` reliably hangs under `testWidgets` (see
/// `profile_screen_test.dart`'s header comment), so the actual persistence
/// logic (`ProfileEditor.apply`) is covered here instead, on the real event
/// loop — mirrors `app_context_provider_test.dart`'s approach.
/// A user's recorded prior addresses, most recent first.
///
/// Was `UserEmailRepository.findByUserId` until task 11.212, which widened
/// `sync_auth_uncalled_methods_test.dart` over `lib/data/repositories/` and
/// found it had no caller anywhere in `lib/` — the table's two real readers,
/// `ProjectMerger` and `ServerIdentityAdopter`, query it directly. Its only
/// callers were the three assertions below, so it lives here now.
Future<List<UserEmail>> priorAddresses(
  UserEmailRepository repo,
  String userId,
) async {
  final rows = await repo.findRows(
    where: 'user_id = ?',
    whereArgs: [userId],
    orderBy: 'recorded_at DESC',
  );
  return rows.map(UserEmail.fromRow).toList();
}

void main() {
  late Database db;
  late UserRepository userRepo;
  late UserEmailRepository userEmailRepo;
  late ProfileEditor editor;

  setUp(() async {
    final database = await AppDatabase.openInMemory();
    addTearDown(database.close);
    db = database.raw;
    userRepo = UserRepository(db);
    userEmailRepo = UserEmailRepository(db);
    editor = ProfileEditor(userRepo, userEmailRepo);
    await db.insert(
      Tables.users,
      sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
    );
  });

  test(
    'a name-only edit updates in place and writes no User_Emails row',
    () async {
      final existing = (await userRepo.findById('user-1'))!;
      await editor.apply(
        existing: existing,
        firstName: 'Samantha',
        lastName: existing.lastName,
        email: existing.email,
        deviceId: 'device-A',
      );

      final updated = await userRepo.findById('user-1');
      expect(updated!.firstName, 'Samantha');
      expect(updated.email, 'sam@example.com');
      expect(await priorAddresses(userEmailRepo, 'user-1'), isEmpty);
    },
  );

  test(
    'an email change records the old address and updates to the new one, same user_id',
    () async {
      final existing = (await userRepo.findById('user-1'))!;
      final updated = await editor.apply(
        existing: existing,
        firstName: existing.firstName,
        lastName: existing.lastName,
        email: 'new@example.com',
        deviceId: 'device-A',
        newId: () => 'ue-1',
        now: () => DateTime.utc(2026, 7, 31, 12),
      );

      expect(updated.userId, 'user-1');
      expect(updated.email, 'new@example.com');

      final stored = await userRepo.findById('user-1');
      expect(
        stored!.userId,
        'user-1',
        reason: 'must update in place, not create a second user',
      );
      expect(stored.email, 'new@example.com');

      final priorEmails = await priorAddresses(userEmailRepo, 'user-1');
      expect(priorEmails, hasLength(1));
      expect(priorEmails.single.email, 'sam@example.com');
      expect(priorEmails.single.userId, 'user-1');
    },
  );

  test(
    'a case-only email change is not treated as a real change (normalized comparison)',
    () async {
      final existing = (await userRepo.findById('user-1'))!;
      await editor.apply(
        existing: existing,
        firstName: existing.firstName,
        lastName: existing.lastName,
        email: 'SAM@EXAMPLE.COM',
        deviceId: 'device-A',
      );

      expect(
        await priorAddresses(userEmailRepo, 'user-1'),
        isEmpty,
        reason: 're-casing the same address is not an identity-anchor change',
      );
    },
  );
}
