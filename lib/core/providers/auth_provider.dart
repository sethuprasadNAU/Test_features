import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/auth/auth_client.dart';
import '../../data/auth/session_store.dart';
import '../../data/sync/server_identity_adopter.dart';
import '../../data/sync/sync_state_store.dart';
import 'active_selection_provider.dart';
import 'app_context_provider.dart';
import 'database_provider.dart';
import 'device_id_provider.dart';
import 'server_config_provider.dart';
import 'server_http_client_provider.dart';

part 'auth_provider.g.dart';

/// Thrown when the server's redemption response names a different account
/// than the user asked to sign in as. Never expected in normal operation —
/// treat it as a sign the server is not the one you think it is.
class IdentityMismatch implements Exception {
  const IdentityMismatch();
  @override
  String toString() => 'IdentityMismatch';
}

/// Thrown when the server accepted the sign-in code — **so the code is now
/// spent** — but the session could not be written to the keychain/keystore.
///
/// **Task 11.38, the half that is not about entitlements.** Before this
/// existed, a storage failure at that point fell through to a generic
/// handler that said "could not reach the server", leaving somebody signed
/// out, holding a code that would never work again, and looking for a
/// network problem that was not there. [SessionStore.ensureWritable] now
/// makes this rare — the store is checked before the code is redeemed — but
/// rare is not never: the keychain can become unavailable in the fraction of
/// a second between the two, and a check that passes is not a guarantee.
/// When that happens the person is owed the truth, which is that their code
/// is gone and storage is the reason.
class SessionStorageFailedAfterRedemption implements Exception {
  const SessionStorageFailedAfterRedemption(this.cause);

  final Object cause;

  @override
  String toString() => 'SessionStorageFailedAfterRedemption: $cause';
}

@Riverpod(keepAlive: true)
SessionStore sessionStore(Ref ref) => SessionStore();

/// The device's signed-in state, or null.
///
/// **Signed out is a fully supported state, not a degraded one.** Nothing that
/// reads local data consults this; recording, mapping, position estimation and
/// backup all work identically either way. This exists so the sync layer
/// (10.7/10.8) has something to ask, and so the UI can say which it is.
@Riverpod(keepAlive: true)
class CurrentSession extends _$CurrentSession {
  @override
  Future<StoredSession?> build() async {
    final config = await ref.watch(serverConfigProvider.future);
    // No server configured means no session, without touching the keychain —
    // task 10.2's "zero network calls, and nothing server-shaped happens"
    // invariant extends to not reading credentials that cannot be used.
    if (!config.isConfigured) return null;

    final stored = await ref.read(sessionStoreProvider).read();
    if (stored == null) return null;
    if (stored.isExpiredAt(DateTime.now().toUtc())) {
      // Locally expired: drop it rather than presenting a session that the
      // next request would be refused for anyway.
      await ref.read(sessionStoreProvider).clear();
      return null;
    }
    return stored;
  }

  /// Asks the server to email a sign-in link.
  Future<MagicLinkRequest> requestLink(String email) async {
    final client = await _requireClient();
    return client.requestMagicLink(email);
  }

  Future<LinkStatus> linkStatus(String requestId) async {
    final client = await _requireClient();
    return client.linkStatus(requestId);
  }

  /// Completes sign-in on **this** device with a pasted link or code.
  ///
  /// [expectedEmail] is the address the user typed when requesting the link,
  /// and adoption is refused unless the server's response names the same one.
  ///
  /// **That check is the difference between a hostile server relabelling one
  /// row and it silently reattributing a colleague's field records.**
  /// `ServerIdentityAdopter` folds every local `Users` row bearing the given
  /// address onto the server's id and hard-deletes the old row. If the address
  /// came only from the response body, a malicious or MITM'd server — and the
  /// LAN prototype runs over cleartext today (§2.5) — could answer a perfectly
  /// legitimate redemption with someone else's address and have this device
  /// reassign that person's observations. Comparing against what the user
  /// typed means the server can only ever confirm an identity the user already
  /// asserted, never substitute one.
  ///
  /// **What that check does not bound, and what does** (task 10.75, finding
  /// K-4). Matching the email proves the server confirmed the identity the
  /// user asserted. It proves nothing about the `user_id` in the same
  /// response, which is an opaque server-chosen string that becomes a primary
  /// key on eleven tables. Security model §4.20 sets out why the server is
  /// trusted to *name* that id and is not trusted with its shape, with which
  /// local rows it collects, or with destroying the row it supersedes;
  /// `ServerIdentityAdopter` enforces all three and throws
  /// [IdentityAdoptionRefused] rather than writing a partial result.
  ///
  /// Order matters too: **check that the session store works**, then redeem,
  /// then **adopt the server's `user_id` into the local database, then** store
  /// the session.
  /// Adoption must land before anything can sync, because the whole design
  /// rests on this device never pushing rows under its old locally-minted id
  /// — and it is also why the adopter can safely leave sync clocks untouched.
  /// Storing the session last means a crash between the two leaves the device
  /// signed out with its local data intact, which is a recoverable state; the
  /// reverse order could leave it signed in but un-adopted, which is not.
  Future<void> completeSignIn(
    String pastedTokenOrLink, {
    required String expectedEmail,
  }) async {
    final token = extractSignInToken(pastedTokenOrLink);
    if (token == null) throw const RedemptionRejected();

    final client = await _requireClient();
    final deviceId = await ref.read(deviceIdProvider.future);
    final store = ref.read(sessionStoreProvider);

    // **Check the keychain before spending the code (task 11.38).**
    // Redeeming is the one irreversible step in this method: the server marks
    // the code used and will never accept it again. Everything after it can
    // be retried; nothing can un-spend it. So the last thing that can fail —
    // storing the session — is asked whether it works *first*, while failing
    // still costs nothing but a message. This throws
    // [SessionStorageUnavailable] and the code remains valid.
    await store.ensureWritable();

    final redeemed = await client.redeem(token: token, deviceId: deviceId);

    if (normalizeEmail(redeemed.email) != normalizeEmail(expectedEmail)) {
      throw const IdentityMismatch();
    }

    final db = await ref.read(appDatabaseProvider.future);
    final localUser = await ref.read(currentUserProvider.future);
    await ServerIdentityAdopter(db.raw).adopt(
      serverUserId: redeemed.userId,
      email: redeemed.email,
      firstName: localUser.firstName,
      lastName: localUser.lastName,
      activeUserId: localUser.userId,
      deviceId: deviceId,
      now: DateTime.now().toUtc(),
    );

    final session = StoredSession(
      token: redeemed.token,
      userId: redeemed.userId,
      email: redeemed.email,
      expiresAt: redeemed.expiresAt,
    );
    try {
      await store.write(session);
    } on SessionStorageUnavailable catch (e) {
      // Past the point of no return: the code is spent and the local identity
      // adoption has landed. Re-typed rather than rethrown so the screen can
      // say so — see [SessionStorageFailedAfterRedemption]. The adoption is
      // deliberately left in place; it is this person's own server id, it is
      // correct, and undoing it would be a second identity remap performed to
      // tidy up after a keychain error.
      throw SessionStorageFailedAfterRedemption(e.cause);
    }

    // The active user is now the adopted id; everything downstream re-reads.
    await ref.read(activeUserIdProvider.notifier).set(redeemed.userId);
    ref.invalidate(currentUserProvider);
    state = AsyncData(session);

    // A session is now established: forget the last sync attempt so the next
    // `syncIfDue` check (on this foreground) finds a round due immediately,
    // rather than waiting out whatever interval was left over from before
    // sign-out (task 11.62). Best-effort — an unreadable store already
    // degrades safely everywhere else it is read.
    try {
      await SyncStateStore().clearLastAttemptAt();
    } catch (_) {}
  }

  /// Signs out, leaving the app **fully functional locally**.
  ///
  /// Nothing local is removed: the adopted `user_id` stays (it is now this
  /// person's id everywhere, and reverting it would be a second identity
  /// remap for no reason), and every observation, project and estimate is
  /// untouched. Signing out stops sync; it does not take the app away.
  ///
  /// **Sync bookkeeping stays too** — every project's cursor, linked flag,
  /// last-success stamp and remembered failure in `SyncStateStore` — so the
  /// same person signing back in resumes where they left off rather than
  /// re-pulling every project from zero (task 11.304; the measurement and the
  /// guard are `test/core/providers/sign_out_leaves_sync_state_test.dart`).
  /// The one thing this removes is the session.
  Future<void> signOut() async {
    final stored = state.value;
    if (stored != null) {
      try {
        final client = await _requireClient();
        await client.signOut(stored.token);
      } catch (_) {
        // The server being unreachable must not trap someone in a signed-in
        // state on their own device. Local sign-out proceeds regardless; the
        // session simply expires server-side, or is revoked from another
        // device.
      }
    }
    await ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
  }

  /// **Signs out every device this person is signed in on (task 11.28).**
  ///
  /// Returns how many sessions the server revoked, including this one — the
  /// count is the whole point of the confirmation, because "3 devices signed
  /// out" tells somebody whether the number matches what they expected and
  /// "signed out" does not.
  ///
  /// **Unlike [signOut], a failure here is not swallowed.** Local sign-out is
  /// allowed to proceed against an unreachable server because the alternative
  /// traps somebody in a signed-in state on their own device, and the local
  /// half is all that is really being asked for. This is the opposite: the
  /// entire point is the *server* forgetting the credentials, and clearing
  /// only this device while telling the person they had signed out everywhere
  /// would be a false statement about a control they reached for because they
  /// think somebody has their token. It throws, and the screen says so.
  ///
  /// The local session is cleared only after the server has confirmed, so a
  /// failed attempt leaves this device signed in and able to try again.
  Future<int> signOutEverywhere() async {
    final stored = state.value;
    if (stored == null) return 0;
    final client = await _requireClient();
    final revoked = await client.revokeAllSessions(stored.token);
    await ref.read(sessionStoreProvider).clear();
    state = const AsyncData(null);
    return revoked;
  }

  /// **This person's signed-in devices, most recent first** (task 11.36).
  ///
  /// Returns an empty list when signed out rather than throwing: a screen
  /// asking "which devices am I signed in on" while signed out has a correct
  /// answer, and it is "none".
  Future<List<DeviceSession>> listSessions() async {
    final stored = state.value;
    if (stored == null) return const [];
    final client = await _requireClient();
    return client.listSessions(stored.token);
  }

  /// **Ends every session on one device** — the lost phone, without signing
  /// out the laptop in your hands (task 11.36, over task 11.35's route).
  ///
  /// **Revoking the device you are holding signs you out here, and this method
  /// is where that is made true rather than left to the screen.** The server
  /// has already destroyed the session by the time this returns, so a device
  /// that kept its stored token would go on believing it was signed in until
  /// its next request failed — and the screen would show a sign-out control
  /// for a session that no longer exists. Clearing locally is not a courtesy;
  /// it is this device's state catching up with what it just asked for.
  ///
  /// Returns how many sessions were ended. Throws on any server refusal, for
  /// the reason [signOutEverywhere] gives: a failure somebody reads as success
  /// is the worst outcome a revocation control has.
  Future<int> revokeDevice(String deviceId) async {
    final stored = state.value;
    if (stored == null) return 0;
    final client = await _requireClient();
    final revoked = await client.revokeDevice(
      sessionToken: stored.token,
      deviceId: deviceId,
    );
    if (deviceId == await ref.read(deviceIdProvider.future)) {
      await ref.read(sessionStoreProvider).clear();
      state = const AsyncData(null);
    }
    return revoked;
  }

  Future<AuthClient> _requireClient() async {
    final config = await ref.read(serverConfigProvider.future);
    final http = await ref.read(serverHttpClientProvider.future);
    if (!config.isConfigured || http == null) {
      throw StateError('No server is configured.');
    }
    return AuthClient(httpClient: http, baseUrl: config.baseUrl!);
  }
}
