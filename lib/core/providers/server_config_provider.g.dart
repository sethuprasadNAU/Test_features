// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_config_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// The address this app ships with, [centralServerBaseUrl] (task 11.324,
/// item 4) — a provider only so a test can substitute a real-looking address
/// while the constant is still empty. Nothing in the app overrides it.

@ProviderFor(centralServerAddress)
final centralServerAddressProvider = CentralServerAddressProvider._();

/// The address this app ships with, [centralServerBaseUrl] (task 11.324,
/// item 4) — a provider only so a test can substitute a real-looking address
/// while the constant is still empty. Nothing in the app overrides it.

final class CentralServerAddressProvider
    extends $FunctionalProvider<String, String, String>
    with $Provider<String> {
  /// The address this app ships with, [centralServerBaseUrl] (task 11.324,
  /// item 4) — a provider only so a test can substitute a real-looking address
  /// while the constant is still empty. Nothing in the app overrides it.
  CentralServerAddressProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'centralServerAddressProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$centralServerAddressHash();

  @$internal
  @override
  $ProviderElement<String> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  String create(Ref ref) {
    return centralServerAddress(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(String value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<String>(value),
    );
  }
}

String _$centralServerAddressHash() =>
    r'741faa8bac767d65444ad770115fd4f438eaa36c';

@ProviderFor(ServerConfigNotifier)
final serverConfigProvider = ServerConfigNotifierProvider._();

final class ServerConfigNotifierProvider
    extends $AsyncNotifierProvider<ServerConfigNotifier, ServerConfig> {
  ServerConfigNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverConfigProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverConfigNotifierHash();

  @$internal
  @override
  ServerConfigNotifier create() => ServerConfigNotifier();
}

String _$serverConfigNotifierHash() =>
    r'd35c6972e237d8de02e0a0e0f2952e4944f2ee8a';

abstract class _$ServerConfigNotifier extends $AsyncNotifier<ServerConfig> {
  FutureOr<ServerConfig> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<ServerConfig>, ServerConfig>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<ServerConfig>, ServerConfig>,
              AsyncValue<ServerConfig>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

/// Whether this is anything other than a debug build.
///
/// **A provider rather than a bare `!kDebugMode` read at each site**, so that
/// the behaviour a beta tester actually gets can be exercised in a test. A
/// test binary is neither release nor profile, so every check keyed on the
/// constant is permanently unexercised from inside `flutter test` — §4.1's
/// "a control with no failing-path test is decoration", one level up from the
/// `releaseMode:` parameter that already exists for the same reason. Overriding
/// this in a test is how `test/features/more/server_address_refused_test.dart`
/// puts the app into the state task 11.66 measured on a phone.

@ProviderFor(nonDebugBuild)
final nonDebugBuildProvider = NonDebugBuildProvider._();

/// Whether this is anything other than a debug build.
///
/// **A provider rather than a bare `!kDebugMode` read at each site**, so that
/// the behaviour a beta tester actually gets can be exercised in a test. A
/// test binary is neither release nor profile, so every check keyed on the
/// constant is permanently unexercised from inside `flutter test` — §4.1's
/// "a control with no failing-path test is decoration", one level up from the
/// `releaseMode:` parameter that already exists for the same reason. Overriding
/// this in a test is how `test/features/more/server_address_refused_test.dart`
/// puts the app into the state task 11.66 measured on a phone.

final class NonDebugBuildProvider extends $FunctionalProvider<bool, bool, bool>
    with $Provider<bool> {
  /// Whether this is anything other than a debug build.
  ///
  /// **A provider rather than a bare `!kDebugMode` read at each site**, so that
  /// the behaviour a beta tester actually gets can be exercised in a test. A
  /// test binary is neither release nor profile, so every check keyed on the
  /// constant is permanently unexercised from inside `flutter test` — §4.1's
  /// "a control with no failing-path test is decoration", one level up from the
  /// `releaseMode:` parameter that already exists for the same reason. Overriding
  /// this in a test is how `test/features/more/server_address_refused_test.dart`
  /// puts the app into the state task 11.66 measured on a phone.
  NonDebugBuildProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'nonDebugBuildProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$nonDebugBuildHash();

  @$internal
  @override
  $ProviderElement<bool> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  bool create(Ref ref) {
    return nonDebugBuild(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$nonDebugBuildHash() => r'a62173608c6a219736e9c5911518552c00f270ea';

/// **Why this device will not use the server address it has saved, or null.**
///
/// The one thing every surface reads to answer that question, so the sync bar,
/// the sync-status screen and the Server Connection screen cannot come to
/// disagree — which is precisely what task 11.66 measured them doing, three
/// ways, about one fact.
///
/// **Null does not mean "the server is reachable."** It means nothing about
/// this address disqualifies it before a request is made. Reachability is a
/// different question with a different answer, and conflating the two is the
/// defect, in the other direction.
///
/// Deliberately returns a value and never throws: see [InvalidServerUrl] for
/// what happens to an exception raised inside a provider on this project.

@ProviderFor(serverUrlRefusal)
final serverUrlRefusalProvider = ServerUrlRefusalProvider._();

/// **Why this device will not use the server address it has saved, or null.**
///
/// The one thing every surface reads to answer that question, so the sync bar,
/// the sync-status screen and the Server Connection screen cannot come to
/// disagree — which is precisely what task 11.66 measured them doing, three
/// ways, about one fact.
///
/// **Null does not mean "the server is reachable."** It means nothing about
/// this address disqualifies it before a request is made. Reachability is a
/// different question with a different answer, and conflating the two is the
/// defect, in the other direction.
///
/// Deliberately returns a value and never throws: see [InvalidServerUrl] for
/// what happens to an exception raised inside a provider on this project.

final class ServerUrlRefusalProvider
    extends
        $FunctionalProvider<
          AsyncValue<ServerUrlProblem?>,
          ServerUrlProblem?,
          FutureOr<ServerUrlProblem?>
        >
    with
        $FutureModifier<ServerUrlProblem?>,
        $FutureProvider<ServerUrlProblem?> {
  /// **Why this device will not use the server address it has saved, or null.**
  ///
  /// The one thing every surface reads to answer that question, so the sync bar,
  /// the sync-status screen and the Server Connection screen cannot come to
  /// disagree — which is precisely what task 11.66 measured them doing, three
  /// ways, about one fact.
  ///
  /// **Null does not mean "the server is reachable."** It means nothing about
  /// this address disqualifies it before a request is made. Reachability is a
  /// different question with a different answer, and conflating the two is the
  /// defect, in the other direction.
  ///
  /// Deliberately returns a value and never throws: see [InvalidServerUrl] for
  /// what happens to an exception raised inside a provider on this project.
  ServerUrlRefusalProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'serverUrlRefusalProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$serverUrlRefusalHash();

  @$internal
  @override
  $FutureProviderElement<ServerUrlProblem?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<ServerUrlProblem?> create(Ref ref) {
    return serverUrlRefusal(ref);
  }
}

String _$serverUrlRefusalHash() => r'202b0422b2f7ca2c328ab0ae45fa9f5287b75f90';
