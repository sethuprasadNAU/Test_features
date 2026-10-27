// Task 11.38 — the guard that would actually have caught it.
//
// **Why nothing under `test/` can do this job.** `flutter test` runs on the
// `flutter_tester` harness, which has no platform channels, so a real
// `SessionStore.read()` never completes. That is not an incidental gap: it is
// the reason `test/support/fake_session_store.dart` exists, and every one of
// the eight test files that touch sign-in installs that fake. The single line
// that fails on macOS — the real `write`, reaching the real Security
// framework — had therefore never been executed by anything in this
// repository, on any platform, before this file. Sign-in and sync had never
// worked on macOS in any build, and no test could have said so.
//
// `integration_test` runs as the genuine compiled app bundle, with its real
// `Info.plist`, its real entitlements and its real code signature. That is
// what makes the keychain reachable, and it is the same harness task 10.50
// built for App Transport Security:
//
//   flutter test integration_test/session_store_keychain_test.dart -d macos
//   ./scripts/verify_session_store_keychain.sh          # macOS, wraps the above
//
// Living under `integration_test/` rather than `test/` keeps it out of the
// default `flutter test` invocation (task 10.41's invariant) — Flutter's test
// runner never discovers this directory on its own, so no skip tag is needed
// to keep the offline suite green.
//
// **On an ad-hoc-signed build this test fails**, with the same `-34018` the
// person hit by hand on 2026-08-26. That is the intended behaviour: an
// unsigned build genuinely cannot sign in, and a guard that passed anyway
// would be worse than no guard. See README.md, "Signing the macOS build".
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tritrack/data/auth/session_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The real store, constructed exactly as `sessionStoreProvider` constructs
  // it — same accessibility options, same data-protection-keychain setting.
  // Substituting anything here would rebuild the blind spot this file exists
  // to remove.
  final store = SessionStore();

  StoredSession sampleSession() => StoredSession(
    token: 'integration-test-token',
    userId: 'integration-test-user',
    email: 'keychain-probe@example.invalid',
    // Far enough out that `isExpiredAt` cannot make a stored session look
    // absent and turn a real storage failure into a green run.
    expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
  );

  // Never leave a token-shaped value in a developer's login keychain, and
  // never let one test's leftovers make the next one pass.
  tearDown(() async {
    try {
      await store.clear();
    } catch (_) {}
  });

  testWidgets('the secure store round-trips a session on this platform', (
    _,
  ) async {
    final written = sampleSession();
    await store.write(written);

    final readBack = await store.read();

    expect(
      readBack,
      isNotNull,
      reason:
          'The keychain accepted the write but returned nothing. A session '
          'that does not survive being stored means sign-in does not survive '
          'a restart.',
    );
    expect(readBack!.token, written.token);
    expect(readBack.userId, written.userId);
    expect(readBack.email, written.email);
    expect(
      readBack.expiresAt.toIso8601String(),
      written.expiresAt.toIso8601String(),
    );
  });

  testWidgets('ensureWritable succeeds on a correctly signed build', (
    _,
  ) async {
    // This is the exact call `completeSignIn` now makes before it redeems a
    // sign-in code. If it throws here, sign-in on this platform will refuse
    // to start rather than spending somebody's code — correct behaviour, and
    // still a build that cannot sign in.
    await expectLater(store.ensureWritable(), completes);
  });

  testWidgets('ensureWritable leaves an existing session untouched', (
    _,
  ) async {
    // The probe writes. If it ever shared a key with the real session, a
    // sign-in attempt would destroy the session already stored — so this is
    // a property worth holding, not a formality.
    final written = sampleSession();
    await store.write(written);

    await store.ensureWritable();

    final readBack = await store.read();
    expect(readBack, isNotNull);
    expect(readBack!.token, written.token);
  });

  testWidgets('clear removes the session', (_) async {
    await store.write(sampleSession());
    await store.clear();

    expect(
      await store.read(),
      isNull,
      reason:
          'Signing out must actually remove the token from the keychain. A '
          'clear that silently does nothing leaves a live credential on a '
          'device somebody believes they have signed out of.',
    );
  });
}
