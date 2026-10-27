// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'shared_observation_preview_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The pasted-and-parsed [SharedObservation] currently previewed as a
/// temporary map overlay (design doc §10: "Paste incoming payload to parse
/// and preview on map as a temporary overlay"). Deliberately in-memory only,
/// not persisted — a preview is ephemeral by design ("not stored unless
/// explicitly saved") and should not survive an app restart.

@ProviderFor(SharedObservationPreview)
final sharedObservationPreviewProvider = SharedObservationPreviewProvider._();

/// The pasted-and-parsed [SharedObservation] currently previewed as a
/// temporary map overlay (design doc §10: "Paste incoming payload to parse
/// and preview on map as a temporary overlay"). Deliberately in-memory only,
/// not persisted — a preview is ephemeral by design ("not stored unless
/// explicitly saved") and should not survive an app restart.
final class SharedObservationPreviewProvider
    extends $NotifierProvider<SharedObservationPreview, SharedObservation?> {
  /// The pasted-and-parsed [SharedObservation] currently previewed as a
  /// temporary map overlay (design doc §10: "Paste incoming payload to parse
  /// and preview on map as a temporary overlay"). Deliberately in-memory only,
  /// not persisted — a preview is ephemeral by design ("not stored unless
  /// explicitly saved") and should not survive an app restart.
  SharedObservationPreviewProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'sharedObservationPreviewProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$sharedObservationPreviewHash();

  @$internal
  @override
  SharedObservationPreview create() => SharedObservationPreview();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SharedObservation? value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SharedObservation?>(value),
    );
  }
}

String _$sharedObservationPreviewHash() =>
    r'76e18adad89caa7d427d13445d838bb93a9e0c97';

/// The pasted-and-parsed [SharedObservation] currently previewed as a
/// temporary map overlay (design doc §10: "Paste incoming payload to parse
/// and preview on map as a temporary overlay"). Deliberately in-memory only,
/// not persisted — a preview is ephemeral by design ("not stored unless
/// explicitly saved") and should not survive an app restart.

abstract class _$SharedObservationPreview
    extends $Notifier<SharedObservation?> {
  SharedObservation? build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<SharedObservation?, SharedObservation?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<SharedObservation?, SharedObservation?>,
              SharedObservation?,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
