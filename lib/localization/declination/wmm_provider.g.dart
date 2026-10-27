// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'wmm_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The magnetic-declination service, loaded once from the embedded coefficient
/// asset. Phase 3 (compass) and Phase 4 (observation logging) watch this to
/// convert magnetic bearings to true north for the observation's own date.

@ProviderFor(wmmService)
final wmmServiceProvider = WmmServiceProvider._();

/// The magnetic-declination service, loaded once from the embedded coefficient
/// asset. Phase 3 (compass) and Phase 4 (observation logging) watch this to
/// convert magnetic bearings to true north for the observation's own date.

final class WmmServiceProvider
    extends
        $FunctionalProvider<
          AsyncValue<WmmService>,
          WmmService,
          FutureOr<WmmService>
        >
    with $FutureModifier<WmmService>, $FutureProvider<WmmService> {
  /// The magnetic-declination service, loaded once from the embedded coefficient
  /// asset. Phase 3 (compass) and Phase 4 (observation logging) watch this to
  /// convert magnetic bearings to true north for the observation's own date.
  WmmServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'wmmServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$wmmServiceHash();

  @$internal
  @override
  $FutureProviderElement<WmmService> $createElement($ProviderPointer pointer) =>
      $FutureProviderElement(pointer);

  @override
  FutureOr<WmmService> create(Ref ref) {
    return wmmService(ref);
  }
}

String _$wmmServiceHash() => r'24ecb2e6b8cd8eea12abbabb1d2c0f3596e9ec4c';
