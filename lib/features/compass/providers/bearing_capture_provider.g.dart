// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bearing_capture_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(BearingCaptureUi)
final bearingCaptureUiProvider = BearingCaptureUiProvider._();

final class BearingCaptureUiProvider
    extends $NotifierProvider<BearingCaptureUi, BearingCaptureUiState> {
  BearingCaptureUiProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'bearingCaptureUiProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$bearingCaptureUiHash();

  @$internal
  @override
  BearingCaptureUi create() => BearingCaptureUi();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(BearingCaptureUiState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<BearingCaptureUiState>(value),
    );
  }
}

String _$bearingCaptureUiHash() => r'b373ff2403764d8da71ad3375fe52e7757255425';

abstract class _$BearingCaptureUi extends $Notifier<BearingCaptureUiState> {
  BearingCaptureUiState build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<BearingCaptureUiState, BearingCaptureUiState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<BearingCaptureUiState, BearingCaptureUiState>,
              BearingCaptureUiState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
