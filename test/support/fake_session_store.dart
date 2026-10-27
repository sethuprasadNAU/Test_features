import 'package:tritrack/data/auth/session_store.dart';

/// In-memory [SessionStore] for tests.
///
/// `flutter_secure_storage` talks to the platform keychain/keystore, and there
/// is no platform channel under `flutter test` — a real read never completes,
/// which shows up as `pumpAndSettle timed out` rather than as an obvious
/// failure. Overriding `sessionStoreProvider` with this is the standard setup
/// for any test that renders a screen reading sign-in state.
///
/// **That convenience is also how task 11.38 stayed invisible for a whole
/// phase.** Every test that has ever touched sign-in installs this fake, so
/// the one line that fails on macOS — the real `write`, reaching the real
/// keychain — has never been executed by anything under `test/`. Nothing here
/// can fix that; only a test running as a real app bundle can, which is what
/// `integration_test/session_store_keychain_test.dart` is for. What this class
/// *can* do is let a suite exercise the code paths that run when storage
/// fails, which is why [failMode] exists.
class FakeSessionStore extends SessionStore {
  FakeSessionStore([this._session, this.failMode = StorageFailMode.none]);

  StoredSession? _session;

  /// Where, if anywhere, this store should pretend the keychain refused it.
  StorageFailMode failMode;

  /// Every session ever written, in order. A test asserting that a failed
  /// sign-in stored nothing needs to distinguish "never written" from
  /// "written and then cleared".
  final List<StoredSession> writes = [];

  /// How many times [ensureWritable] has been asked. Ordering assertions use
  /// this: the check is only worth anything if it runs before the code is
  /// redeemed, and a test that only checks the outcome cannot tell.
  int ensureWritableCalls = 0;

  @override
  Future<void> ensureWritable() async {
    ensureWritableCalls++;
    if (failMode == StorageFailMode.onProbe) {
      throw const SessionStorageUnavailable(
        'simulated: the keychain refused the probe write',
      );
    }
  }

  @override
  Future<StoredSession?> read() async {
    if (failMode == StorageFailMode.onRead) {
      throw const SessionStorageUnavailable(
        'simulated: the keychain refused the read',
      );
    }
    return _session;
  }

  @override
  Future<void> write(StoredSession session) async {
    if (failMode == StorageFailMode.onWrite) {
      throw const SessionStorageUnavailable(
        'simulated: the keychain refused the write',
      );
    }
    writes.add(session);
    _session = session;
  }

  @override
  Future<void> clear() async => _session = null;
}

/// Which secure-store operation a [FakeSessionStore] should fail.
///
/// [onProbe] and [onWrite] are deliberately separate: on macOS both are the
/// same underlying `-34018`, but they reach the user as opposite statements —
/// "your code is untouched" versus "your code is spent" — and only a test that
/// can produce each one independently proves both statements are reachable.
enum StorageFailMode {
  none,

  /// `ensureWritable` throws. Sign-in must abort before redeeming.
  onProbe,

  /// The probe passes and the real write throws. Models the keychain becoming
  /// unavailable between the check and the store; rare, and the reason the
  /// probe is not the only defence.
  onWrite,

  /// `read` throws, as it does on an unsigned macOS build at launch.
  onRead,
}
