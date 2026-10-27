import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'device_lock_provider.g.dart';

/// Security Model §4.8, control 2: a one-time, non-blocking warning when this
/// device has no passcode, PIN, pattern or biometric lock configured.
///
/// **Why this exists.** §4.8 deliberately does not adopt SQLCipher; its whole
/// case for that is that the OS's own full-disk/file-based encryption already
/// covers a lost-but-locked device, keyed to the screen-lock secret. On a
/// device with no lock at all, that OS protection **does not exist** — the
/// sandbox holding `tri_track.db` and the session token is exactly as open as
/// it looks after boot. Nothing in this app can add that protection back; all
/// it can do is tell the person, once, so a passcode-less device is a choice
/// rather than a fact nobody was told.
///
/// **Never gates app use.** Locking a field tech out of a capture tool
/// mid-survey over a device setting is a worse outcome than the exposure this
/// warns about (§4.8 point 2, verbatim). This provider only ever answers
/// "should the one-time notice show," never "may this screen render."
///
/// **The platform check is [LocalAuthentication.isDeviceSupported], not
/// biometric enrollment.** That method asks the OS whether the device can
/// satisfy `deviceOwnerAuthentication` — a passcode/PIN/pattern *or* a
/// biometric with a passcode fallback — which is exactly "is a lock
/// configured," not "is Face ID/Touch ID/fingerprint enrolled." A device with
/// a PIN and no biometrics reports supported; a device with neither reports
/// not supported. `authenticate()` is never called, so nothing is ever
/// scanned, prompted or stored.
///
/// **"Once" means once ever, not once per insecure launch.** A device that
/// gains a lock after being warned needs nothing further; a device that later
/// loses one it already had is the same live exposure recurring, but this
/// follows [CloudBackupRetirementNotice]'s precedent rather than inventing a
/// re-arming rule the security model doesn't ask for — see the entry this
/// task is named in for the class this belongs to.
@Riverpod(keepAlive: true)
class DeviceLockWarningNotice extends _$DeviceLockWarningNotice {
  static const _dismissedKey = 'device_lock_warning_dismissed_v1';

  final _prefs = SharedPreferencesAsync();

  /// Overridable in tests; production always uses a real [LocalAuthentication].
  @visibleForTesting
  static LocalAuthentication Function() authFactory = LocalAuthentication.new;

  @override
  Future<bool> build() async {
    final dismissed = await _prefs.getBool(_dismissedKey) ?? false;
    if (dismissed) return false;
    try {
      final hasLock = await authFactory().isDeviceSupported();
      return !hasLock;
    } on Object {
      // The platform could not answer (unsupported platform, plugin channel
      // failure, or similar). Say nothing rather than warning on every launch
      // about a check that never actually ran — an unverifiable warning that
      // never goes away is worse than no warning, per this project's rule on
      // honest fallbacks: an "unknown" answer is not evidence of an unlocked
      // device.
      return false;
    }
  }

  /// Acknowledged. Persists so this never shows again on this device.
  Future<void> dismiss() async {
    state = const AsyncData(false);
    await _prefs.setBool(_dismissedKey, true);
  }
}
