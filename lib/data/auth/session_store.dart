import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The signed-in state this device holds.
class StoredSession {
  const StoredSession({
    required this.token,
    required this.userId,
    required this.email,
    required this.expiresAt,
  });

  /// The bearer token. Never write this anywhere but the keychain/keystore,
  /// and never log it.
  final String token;

  /// The server's authoritative `user_id`, already adopted locally.
  final String userId;
  final String email;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);

  Map<String, Object?> toJson() => {
    'token': token,
    'user_id': userId,
    'email': email,
    'expires_at': expiresAt.toIso8601String(),
  };

  static StoredSession? fromJson(Map<String, Object?> json) {
    final token = json['token'];
    final userId = json['user_id'];
    final email = json['email'];
    final expiresAt = DateTime.tryParse((json['expires_at'] as String?) ?? '');
    if (token is! String ||
        userId is! String ||
        email is! String ||
        expiresAt == null) {
      return null;
    }
    return StoredSession(
      token: token,
      userId: userId,
      email: email,
      expiresAt: expiresAt.toUtc(),
    );
  }
}

/// Thrown when the platform keychain/keystore cannot be used at all.
///
/// **This is a platform/configuration failure, not a user error and not a
/// network one**, and the distinction is the whole reason this type exists.
/// Task 11.38: on macOS the keychain refused every write with `-34018`
/// ("a required entitlement isn't present") because the app was signed ad
/// hoc with no `keychain-access-groups` entitlement. The failure surfaced
/// through `completeSignIn`'s generic error path as "could not reach the
/// server" — which was false in every particular: the server had been
/// reached, had answered, and had already spent the sign-in code.
///
/// Anything catching this must say that **storage** failed, and must not
/// suggest that retrying the same way will help. See
/// [SessionStore.ensureWritable] for the check that turns this from an
/// after-the-fact report into a before-anything-is-spent one.
class SessionStorageUnavailable implements Exception {
  const SessionStorageUnavailable(this.cause);

  /// The underlying platform error. Worth logging; not worth showing, since
  /// it is a `PlatformException` with an OSStatus code inside it.
  final Object cause;

  @override
  String toString() => 'SessionStorageUnavailable: $cause';
}

/// Persists the session in the platform keychain/keystore.
///
/// **Not SharedPreferences, and not the SQLite database** — this is the
/// concrete requirement behind the security model's §4.8 decision not to adopt
/// SQLCipher. That decision rests on the observation that a plaintext session
/// token on a lost device is *worse* than the local data SQLCipher would have
/// protected: the data is a static snapshot, while a live token grants ongoing
/// access to everything the project will ever contain. Storing it here is what
/// makes that reasoning hold; storing it in prefs would invalidate it.
///
/// `flutter_secure_storage` maps to the iOS/macOS Keychain and the Android
/// Keystore-backed `EncryptedSharedPreferences`. **Neither actually requires a
/// device passcode to be set** — both stores exist and accept reads/writes on
/// a passcode-less device; what a passcode adds is that the OS's file-based/
/// full-disk encryption is then keyed to it, which is the layer §4.8 (and the
/// SQLCipher decision) actually depends on. Corrected 2026-09 (task 10.79):
/// this comment previously said both stores were "gated on the device
/// passcode," which the code does not require and never did — see
/// `DeviceLockWarningNotice` (`lib/core/providers/device_lock_provider.dart`)
/// for the check §4.8 asks for instead, and §4.8 itself for why the app warns
/// rather than blocks.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // `first_unlock` rather than the default: a background sync may run
            // while the device is locked, and the token has to be readable then.
            // Not `always` — that would survive a passcode being removed, which is
            // exactly the protection this relies on.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
            // macOS gets the same `first_unlock` reasoning as iOS, and for the
            // same reason: the default is `unlocked`, which would make a
            // background sync fail on a locked Mac. `usesDataProtectionKeychain`
            // is left at its default of `true` on purpose — the data-protection
            // keychain is the one gated on the login password, which is what
            // §4.8's reasoning depends on. Turning it off makes task 11.38's
            // `-34018` disappear by falling back to the legacy file keychain,
            // which is a security regression dressed up as a fix; the
            // entitlement is the real answer. See
            // `macos/Runner/DebugProfile.entitlements`.
            mOptions: MacOsOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
            // Android needs no options here: v10 encrypts with its own ciphers by
            // default (the old `encryptedSharedPreferences` flag is deprecated
            // because Jetpack Security was), so the default is already the
            // Keystore-backed path.
          );

  static const _key = 'tritrack_session_v1';

  final FlutterSecureStorage _storage;

  /// The probe key used by [ensureWritable]. Deliberately not [_key]: the
  /// check must never be able to damage a session that is already stored.
  static const _probeKey = 'tritrack_session_writable_probe';

  /// Round-trips a throwaway value through the secure store, throwing
  /// [SessionStorageUnavailable] if it cannot.
  ///
  /// **Why it writes rather than only reading.** The macOS failure in task
  /// 11.38 was asymmetric: reading a key that is not there returns "not
  /// found" and looks exactly like a healthy empty store, while writing
  /// reaches `SecItemAdd` and fails with `-34018`. A read-only probe would
  /// have reported a working keychain on the one platform where it did not
  /// work. So the probe writes, reads back, and compares — the same three
  /// operations a stored session depends on.
  ///
  /// Callers use this to move a storage failure *before* an irreversible
  /// step. See `CurrentSession.completeSignIn`.
  Future<void> ensureWritable() async {
    const probe = 'writable';
    try {
      await _storage.write(key: _probeKey, value: probe);
      final readBack = await _storage.read(key: _probeKey);
      if (readBack != probe) {
        // A store that accepts a write and then returns something else is not
        // usable, and is worth catching here rather than later: it would
        // otherwise present as a corrupt session on next launch, far from its
        // cause and indistinguishable from being signed out.
        throw StateError(
          'the secure store did not return the value just written',
        );
      }
    } catch (e) {
      throw SessionStorageUnavailable(e);
    } finally {
      // Best effort. A store that cannot delete the probe has already failed
      // the check above, and a leftover probe key is harmless either way — it
      // holds a constant, not a credential.
      try {
        await _storage.delete(key: _probeKey);
      } catch (_) {}
    }
  }

  Future<StoredSession?> read() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (e) {
      // Deliberately distinct from the corrupt-value case below. "The keychain
      // refused us" and "the keychain held something we could not parse" look
      // identical to a caller that only ever receives `null`, and they need
      // opposite responses: the first is a platform fault to report, the
      // second is simply being signed out.
      throw SessionStorageUnavailable(e);
    }
    if (raw == null) return null;
    try {
      return StoredSession.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      // Corrupt or from an incompatible version. Treat as signed out rather
      // than throwing: being signed out is a fully supported state, so there
      // is nothing to recover and nothing to report.
      return null;
    }
  }

  Future<void> write(StoredSession session) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(session.toJson()));
    } catch (e) {
      throw SessionStorageUnavailable(e);
    }
  }

  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (e) {
      throw SessionStorageUnavailable(e);
    }
  }
}
