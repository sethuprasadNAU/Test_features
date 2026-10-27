// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'auth_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(sessionStore)
final sessionStoreProvider = SessionStoreProvider._();

final class SessionStoreProvider
    extends $FunctionalProvider<SessionStore, SessionStore, SessionStore>
    with $Provider<SessionStore> {
  SessionStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'sessionStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$sessionStoreHash();

  @$internal
  @override
  $ProviderElement<SessionStore> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  SessionStore create(Ref ref) {
    return sessionStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SessionStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SessionStore>(value),
    );
  }
}

String _$sessionStoreHash() => r'2b7c8a212511c3f583f43183bd07db0fd354bd98';

/// The device's signed-in state, or null.
///
/// **Signed out is a fully supported state, not a degraded one.** Nothing that
/// reads local data consults this; recording, mapping, position estimation and
/// backup all work identically either way. This exists so the sync layer
/// (10.7/10.8) has something to ask, and so the UI can say which it is.

@ProviderFor(CurrentSession)
final currentSessionProvider = CurrentSessionProvider._();

/// The device's signed-in state, or null.
///
/// **Signed out is a fully supported state, not a degraded one.** Nothing that
/// reads local data consults this; recording, mapping, position estimation and
/// backup all work identically either way. This exists so the sync layer
/// (10.7/10.8) has something to ask, and so the UI can say which it is.
final class CurrentSessionProvider
    extends $AsyncNotifierProvider<CurrentSession, StoredSession?> {
  /// The device's signed-in state, or null.
  ///
  /// **Signed out is a fully supported state, not a degraded one.** Nothing that
  /// reads local data consults this; recording, mapping, position estimation and
  /// backup all work identically either way. This exists so the sync layer
  /// (10.7/10.8) has something to ask, and so the UI can say which it is.
  CurrentSessionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'currentSessionProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$currentSessionHash();

  @$internal
  @override
  CurrentSession create() => CurrentSession();
}

String _$currentSessionHash() => r'ab340a6f1f0247b2e5517decb51ef55f7bbb6cdb';

/// The device's signed-in state, or null.
///
/// **Signed out is a fully supported state, not a degraded one.** Nothing that
/// reads local data consults this; recording, mapping, position estimation and
/// backup all work identically either way. This exists so the sync layer
/// (10.7/10.8) has something to ask, and so the UI can say which it is.

abstract class _$CurrentSession extends $AsyncNotifier<StoredSession?> {
  FutureOr<StoredSession?> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<AsyncValue<StoredSession?>, StoredSession?>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<StoredSession?>, StoredSession?>,
              AsyncValue<StoredSession?>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
