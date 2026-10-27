// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'receiver_altitude_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// **Survives an app restart, on purpose.** Four hours spans a restart in
/// practice — a phone rebooted at a fuel stop, or the app killed in the
/// background between passes, which is exactly what iOS does to an app that
/// has been out of sight for an hour. If the value lived in memory only, a
/// restart would return it to zero with nothing said, which is the silent
/// change this design refuses. Persisting it is also what makes the
/// four-hour rule honest across a restart: [ReceiverAltitudeState.resolve]
/// runs on the stored timestamps at load, so a phone switched on the next
/// morning owes the notice rather than the value.
///
/// `keepAlive: true` for the reason `PulseRateUnitSetting` gives: the save
/// path reads it with a bare `ref.read` and nothing guarantees a listener.

@ProviderFor(ReceiverAltitudeSetting)
final receiverAltitudeSettingProvider = ReceiverAltitudeSettingProvider._();

/// **Survives an app restart, on purpose.** Four hours spans a restart in
/// practice — a phone rebooted at a fuel stop, or the app killed in the
/// background between passes, which is exactly what iOS does to an app that
/// has been out of sight for an hour. If the value lived in memory only, a
/// restart would return it to zero with nothing said, which is the silent
/// change this design refuses. Persisting it is also what makes the
/// four-hour rule honest across a restart: [ReceiverAltitudeState.resolve]
/// runs on the stored timestamps at load, so a phone switched on the next
/// morning owes the notice rather than the value.
///
/// `keepAlive: true` for the reason `PulseRateUnitSetting` gives: the save
/// path reads it with a bare `ref.read` and nothing guarantees a listener.
final class ReceiverAltitudeSettingProvider
    extends
        $AsyncNotifierProvider<ReceiverAltitudeSetting, ReceiverAltitudeState> {
  /// **Survives an app restart, on purpose.** Four hours spans a restart in
  /// practice — a phone rebooted at a fuel stop, or the app killed in the
  /// background between passes, which is exactly what iOS does to an app that
  /// has been out of sight for an hour. If the value lived in memory only, a
  /// restart would return it to zero with nothing said, which is the silent
  /// change this design refuses. Persisting it is also what makes the
  /// four-hour rule honest across a restart: [ReceiverAltitudeState.resolve]
  /// runs on the stored timestamps at load, so a phone switched on the next
  /// morning owes the notice rather than the value.
  ///
  /// `keepAlive: true` for the reason `PulseRateUnitSetting` gives: the save
  /// path reads it with a bare `ref.read` and nothing guarantees a listener.
  ReceiverAltitudeSettingProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'receiverAltitudeSettingProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$receiverAltitudeSettingHash();

  @$internal
  @override
  ReceiverAltitudeSetting create() => ReceiverAltitudeSetting();
}

String _$receiverAltitudeSettingHash() =>
    r'793b9000b7d3b16e1cece628ac1d6c44b0543965';

/// **Survives an app restart, on purpose.** Four hours spans a restart in
/// practice — a phone rebooted at a fuel stop, or the app killed in the
/// background between passes, which is exactly what iOS does to an app that
/// has been out of sight for an hour. If the value lived in memory only, a
/// restart would return it to zero with nothing said, which is the silent
/// change this design refuses. Persisting it is also what makes the
/// four-hour rule honest across a restart: [ReceiverAltitudeState.resolve]
/// runs on the stored timestamps at load, so a phone switched on the next
/// morning owes the notice rather than the value.
///
/// `keepAlive: true` for the reason `PulseRateUnitSetting` gives: the save
/// path reads it with a bare `ref.read` and nothing guarantees a listener.

abstract class _$ReceiverAltitudeSetting
    extends $AsyncNotifier<ReceiverAltitudeState> {
  FutureOr<ReceiverAltitudeState> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref =
        this.ref
            as $Ref<AsyncValue<ReceiverAltitudeState>, ReceiverAltitudeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<
                AsyncValue<ReceiverAltitudeState>,
                ReceiverAltitudeState
              >,
              AsyncValue<ReceiverAltitudeState>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// The state **as it stands now** — the four-hour rule applied at the moment
/// of reading — or the ground default while the preference is being read
/// off disk. The record screen must not show an altitude nobody set for the
/// frame it takes to load one, and the ground default is what a fresh
/// install would show anyway.
///
/// Resolving here rather than in the screen means a screen that rebuilds
/// after the window has run out shows the notice without anything having
/// written to disk; the write happens on the next mutation, every one of
/// which resolves first.

@ProviderFor(receiverAltitude)
final receiverAltitudeProvider = ReceiverAltitudeProvider._();

/// The state **as it stands now** — the four-hour rule applied at the moment
/// of reading — or the ground default while the preference is being read
/// off disk. The record screen must not show an altitude nobody set for the
/// frame it takes to load one, and the ground default is what a fresh
/// install would show anyway.
///
/// Resolving here rather than in the screen means a screen that rebuilds
/// after the window has run out shows the notice without anything having
/// written to disk; the write happens on the next mutation, every one of
/// which resolves first.

final class ReceiverAltitudeProvider
    extends
        $FunctionalProvider<
          ReceiverAltitudeState,
          ReceiverAltitudeState,
          ReceiverAltitudeState
        >
    with $Provider<ReceiverAltitudeState> {
  /// The state **as it stands now** — the four-hour rule applied at the moment
  /// of reading — or the ground default while the preference is being read
  /// off disk. The record screen must not show an altitude nobody set for the
  /// frame it takes to load one, and the ground default is what a fresh
  /// install would show anyway.
  ///
  /// Resolving here rather than in the screen means a screen that rebuilds
  /// after the window has run out shows the notice without anything having
  /// written to disk; the write happens on the next mutation, every one of
  /// which resolves first.
  ReceiverAltitudeProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'receiverAltitudeProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$receiverAltitudeHash();

  @$internal
  @override
  $ProviderElement<ReceiverAltitudeState> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  ReceiverAltitudeState create(Ref ref) {
    return receiverAltitude(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(ReceiverAltitudeState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<ReceiverAltitudeState>(value),
    );
  }
}

String _$receiverAltitudeHash() => r'da30fec9a4565f0f755d626d5fad966d190907a7';
