// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'device_lock_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
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

@ProviderFor(DeviceLockWarningNotice)
final deviceLockWarningNoticeProvider = DeviceLockWarningNoticeProvider._();

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
final class DeviceLockWarningNoticeProvider
    extends $AsyncNotifierProvider<DeviceLockWarningNotice, bool> {
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
  DeviceLockWarningNoticeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'deviceLockWarningNoticeProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$deviceLockWarningNoticeHash();

  @$internal
  @override
  DeviceLockWarningNotice create() => DeviceLockWarningNotice();
}

String _$deviceLockWarningNoticeHash() =>
    r'db2907c49094b9d3ad9cecfc7076bede3f010584';

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

abstract class _$DeviceLockWarningNotice extends $AsyncNotifier<bool> {
  FutureOr<bool> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<bool>, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<bool>, bool>,
              AsyncValue<bool>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
