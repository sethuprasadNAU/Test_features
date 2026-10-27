// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gps_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Throttled GPS stream (5-10s between fixes per the battery budget in the
/// technical doc). Screens should watch this rather than polling
/// `Geolocator.getCurrentPosition()` directly, so throttling/pausing stays
/// in one place. Pausing while the app is backgrounded is wired in whichever
/// phase adds app-lifecycle observation (Phase 4 UI shell).
///
/// **Asking this why it produced nothing is the one thing it cannot answer.**
/// It throws [LocationPermissionDeniedException] on a refusal, and that
/// exception does not survive the provider boundary — see its doc, and
/// [locationProblemProvider] for the answer that does.

@ProviderFor(gpsPosition)
final gpsPositionProvider = GpsPositionProvider._();

/// Throttled GPS stream (5-10s between fixes per the battery budget in the
/// technical doc). Screens should watch this rather than polling
/// `Geolocator.getCurrentPosition()` directly, so throttling/pausing stays
/// in one place. Pausing while the app is backgrounded is wired in whichever
/// phase adds app-lifecycle observation (Phase 4 UI shell).
///
/// **Asking this why it produced nothing is the one thing it cannot answer.**
/// It throws [LocationPermissionDeniedException] on a refusal, and that
/// exception does not survive the provider boundary — see its doc, and
/// [locationProblemProvider] for the answer that does.

final class GpsPositionProvider
    extends
        $FunctionalProvider<AsyncValue<Position>, Position, Stream<Position>>
    with $FutureModifier<Position>, $StreamProvider<Position> {
  /// Throttled GPS stream (5-10s between fixes per the battery budget in the
  /// technical doc). Screens should watch this rather than polling
  /// `Geolocator.getCurrentPosition()` directly, so throttling/pausing stays
  /// in one place. Pausing while the app is backgrounded is wired in whichever
  /// phase adds app-lifecycle observation (Phase 4 UI shell).
  ///
  /// **Asking this why it produced nothing is the one thing it cannot answer.**
  /// It throws [LocationPermissionDeniedException] on a refusal, and that
  /// exception does not survive the provider boundary — see its doc, and
  /// [locationProblemProvider] for the answer that does.
  GpsPositionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'gpsPositionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$gpsPositionHash();

  @$internal
  @override
  $StreamProviderElement<Position> $createElement($ProviderPointer pointer) =>
      $StreamProviderElement(pointer);

  @override
  Stream<Position> create(Ref ref) {
    return gpsPosition(ref);
  }
}

String _$gpsPositionHash() => r'29afd0774d812d4c84139315041f8ec1abe81d93';

/// [describeLocationProblem] as a provider, so a screen can be put into the
/// refused state in a test.
///
/// **keepAlive, and it cannot throw.** Both matter: a `@riverpod` autoDispose
/// provider awaited with `ref.read(...future)` is torn down mid-load, which is
/// the defect this exists to route around, and a provider that throws hands
/// the caller nothing usable. See `provider_error.dart` for the measurements.
///
/// Not cached in any useful sense — permission changes while the app is
/// backgrounded and this is read once per failure — so callers should
/// `ref.invalidate` it before reading if they need a fresh answer. The screens
/// here read it immediately after a failed attempt, which is fresh enough.

@ProviderFor(locationProblem)
final locationProblemProvider = LocationProblemProvider._();

/// [describeLocationProblem] as a provider, so a screen can be put into the
/// refused state in a test.
///
/// **keepAlive, and it cannot throw.** Both matter: a `@riverpod` autoDispose
/// provider awaited with `ref.read(...future)` is torn down mid-load, which is
/// the defect this exists to route around, and a provider that throws hands
/// the caller nothing usable. See `provider_error.dart` for the measurements.
///
/// Not cached in any useful sense — permission changes while the app is
/// backgrounded and this is read once per failure — so callers should
/// `ref.invalidate` it before reading if they need a fresh answer. The screens
/// here read it immediately after a failed attempt, which is fresh enough.

final class LocationProblemProvider
    extends
        $FunctionalProvider<
          AsyncValue<LocationProblem?>,
          LocationProblem?,
          FutureOr<LocationProblem?>
        >
    with $FutureModifier<LocationProblem?>, $FutureProvider<LocationProblem?> {
  /// [describeLocationProblem] as a provider, so a screen can be put into the
  /// refused state in a test.
  ///
  /// **keepAlive, and it cannot throw.** Both matter: a `@riverpod` autoDispose
  /// provider awaited with `ref.read(...future)` is torn down mid-load, which is
  /// the defect this exists to route around, and a provider that throws hands
  /// the caller nothing usable. See `provider_error.dart` for the measurements.
  ///
  /// Not cached in any useful sense — permission changes while the app is
  /// backgrounded and this is read once per failure — so callers should
  /// `ref.invalidate` it before reading if they need a fresh answer. The screens
  /// here read it immediately after a failed attempt, which is fresh enough.
  LocationProblemProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'locationProblemProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$locationProblemHash();

  @$internal
  @override
  $FutureProviderElement<LocationProblem?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<LocationProblem?> create(Ref ref) {
    return locationProblem(ref);
  }
}

String _$locationProblemHash() => r'26da8dd766535d977bbeed691f84d8ca95ed51c0';
